from __future__ import annotations

import hashlib
import json
import sqlite3
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .migrations import LATEST_SCHEMA_VERSION, migrate
from .presentation import (
    canonical_json,
    capability_activity_title,
    project_public_result,
    public_timeline_event_payload,
    timeline_item_dict,
    upsert_timeline_item,
)
from .read_models import decode_task_cursor, encode_task_cursor


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _loads(value: Optional[str], default: Any) -> Any:
    if value is None:
        return default
    return json.loads(value)


class SubmissionConflictError(ValueError):
    pass


class InboxEventConflictError(ValueError):
    pass


class StalePlannerDecisionError(RuntimeError):
    pass


class InvalidPlannerTransitionError(ValueError):
    pass


class ActionAdmissionSupersededError(InvalidPlannerTransitionError):
    """A concurrent stop, input request or completion revoked dispatch admission."""


class PlannerBudgetExceededError(RuntimeError):
    pass


class StaleArtifactRevisionError(RuntimeError):
    pass


class StaleActionInputError(RuntimeError):
    pass


class StaleControlInterruptError(RuntimeError):
    pass


class Storage:
    """Small durable store for the V1 task/action protocol.

    The model/process is intentionally not the source of truth. Every task,
    action and trace event is checkpointed in SQLite so a host restart can
    resume from the last acknowledged state.
    """

    def __init__(self, path: str):
        self.path = path
        self._lock = threading.RLock()
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._memory_connection: Optional[sqlite3.Connection] = None
        if path == ":memory:":
            self._memory_connection = sqlite3.connect(":memory:", check_same_thread=False)
            self._memory_connection.row_factory = sqlite3.Row
            self._memory_connection.execute("PRAGMA foreign_keys=ON")
            self._memory_connection.execute("PRAGMA busy_timeout=10000")
        self.initialize()

    def _connect(self) -> sqlite3.Connection:
        if self._memory_connection is not None:
            return self._memory_connection
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA busy_timeout=10000")
        return conn

    def _close(self, conn: sqlite3.Connection) -> None:
        if conn is not self._memory_connection:
            conn.close()

    def initialize(self) -> None:
        with self._lock:
            conn = self._connect()
            try:
                migrate(conn)
            finally:
                self._close(conn)

    def schema_version(self) -> int:
        with self._lock:
            conn = self._connect()
            try:
                return int(conn.execute("PRAGMA user_version").fetchone()[0])
            finally:
                self._close(conn)

    @property
    def latest_schema_version(self) -> int:
        return LATEST_SCHEMA_VERSION

    def create_task(
        self,
        task_id: str,
        goal: str,
        invocation_source: str,
        policy_snapshot: Dict[str, Any],
        status: str = "active",
        thread_id: Optional[str] = None,
        parent_task_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        task, _ = self.create_or_get_task(
            task_id=task_id,
            goal=goal,
            invocation_source=invocation_source,
            policy_snapshot=policy_snapshot,
            submission_id=None,
            status=status,
            thread_id=thread_id,
            parent_task_id=parent_task_id,
        )
        return task

    def create_or_get_task(
        self,
        *,
        task_id: str,
        goal: str,
        invocation_source: str,
        policy_snapshot: Dict[str, Any],
        submission_id: Optional[str],
        status: str = "active",
        thread_id: Optional[str] = None,
        parent_task_id: Optional[str] = None,
    ) -> Tuple[Dict[str, Any], bool]:
        """Create one Task, or replay the Task bound to an existing submission.

        submission_id is the Task-intake idempotency identity. Reusing the
        same ID with different semantic payload fails closed instead of
        silently returning or creating a different Task.
        """

        now = utc_now()
        normalized_goal = goal.strip()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")

                resolved_parent_task_id = parent_task_id.strip() if isinstance(parent_task_id, str) else None
                if resolved_parent_task_id == "":
                    resolved_parent_task_id = None
                requested_thread_id = thread_id.strip() if isinstance(thread_id, str) else None
                if requested_thread_id == "":
                    requested_thread_id = None

                if resolved_parent_task_id is not None:
                    if resolved_parent_task_id == task_id:
                        raise ValueError("parent_task_id cannot point to the new Task itself")
                    parent = conn.execute(
                        "SELECT * FROM tasks WHERE id = ?",
                        (resolved_parent_task_id,),
                    ).fetchone()
                    if parent is None:
                        raise ValueError("parent_task_id does not reference an existing Task")
                    if str(parent["status"]).lower() not in {"completed", "failed", "cancelled"}:
                        raise ValueError("parent_task_id must reference a terminal Task episode")
                    inherited_thread_id = str(parent["thread_id"] or parent["id"])
                    if requested_thread_id is not None and requested_thread_id != inherited_thread_id:
                        raise ValueError("thread_id conflicts with parent Task thread")
                    resolved_thread_id = inherited_thread_id
                else:
                    # A root Task's thread identity is Host-derived from the
                    # final Task ID. Keep it unresolved until after submission
                    # replay detection so a retry's fresh candidate task_id
                    # cannot turn an exact replay into a false conflict.
                    resolved_thread_id = requested_thread_id

                if submission_id is not None:
                    existing = conn.execute(
                        "SELECT * FROM tasks WHERE submission_id = ?",
                        (submission_id,),
                    ).fetchone()
                    if existing is not None:
                        same_payload = (
                            existing["goal"] == normalized_goal
                            and existing["invocation_source"] == invocation_source
                            and _loads(existing["policy_snapshot_json"], {}) == policy_snapshot
                            and (
                                resolved_thread_id is None
                                or str(existing["thread_id"] or existing["id"]) == resolved_thread_id
                            )
                            and existing["parent_task_id"] == resolved_parent_task_id
                        )
                        if not same_payload:
                            raise SubmissionConflictError(
                                "submission_id is already bound to different task input"
                            )
                        task = self._task_dict(existing)
                        conn.commit()
                        return task, False

                if resolved_thread_id is None:
                    resolved_thread_id = task_id

                conn.execute(
                    """
                    INSERT INTO tasks
                    (id, goal, invocation_source, policy_snapshot_json, status,
                     current_step, submission_id, thread_id, parent_task_id,
                     created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    """,
                    (
                        task_id,
                        normalized_goal,
                        invocation_source,
                        _json(policy_snapshot),
                        status,
                        submission_id,
                        resolved_thread_id,
                        resolved_parent_task_id,
                        now,
                        now,
                    ),
                )
                conn.execute(
                    """
                    INSERT INTO task_runtime
                    (task_id, phase, plan_json, wait_reason, wait_json,
                     pending_clarification_id, interpreted_goal_summary, updated_at)
                    VALUES (?, 'planning', '[]', NULL, NULL, NULL, NULL, ?)
                    """,
                    (task_id, now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "task.created",
                        _json({
                            "goal": normalized_goal,
                            "invocation_source": invocation_source,
                            "submission_id": submission_id,
                            "thread_id": resolved_thread_id,
                            "parent_task_id": resolved_parent_task_id,
                        }),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"task:{task_id}:accepted",
                    kind="PUBLIC_WORKLOG",
                    presentation_state="COMPLETE",
                    title="任务已交给小卷",
                    summary=normalized_goal,
                    payload={"task_id": task_id},
                    source_type="TASK",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                task = self._task_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)
        return task, True

    def get_runtime_state(self, task_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
            finally:
                self._close(conn)
        if row is None:
            return None
        return {
            "task_id": row["task_id"],
            "phase": row["phase"],
            "plan": _loads(row["plan_json"], []),
            "wait_reason": row["wait_reason"],
            "wait": _loads(row["wait_json"], None),
            "wait_id": row["wait_id"],
            "wait_kind": row["wait_kind"],
            "pending_clarification_id": row["pending_clarification_id"],
            "interpreted_goal_summary": row["interpreted_goal_summary"],
            "current_task_brief": row["current_task_brief"] or row["interpreted_goal_summary"],
            "runtime_revision": int(row["runtime_revision"]),
            "inbox_watermark": int(row["inbox_watermark"]),
            "planner_calls": int(row["planner_calls"]),
            "block_reason": row["block_reason"],
            "updated_at": row["updated_at"],
        }

    def set_task_runtime(
        self,
        *,
        task_id: str,
        status: str,
        phase: str,
        plan: List[str],
        wait_reason: Optional[str],
        wait_payload: Optional[Dict[str, Any]],
        pending_clarification_id: Optional[str],
        interpreted_goal_summary: Optional[str],
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                if conn.execute("SELECT 1 FROM tasks WHERE id = ?", (task_id,)).fetchone() is None:
                    raise KeyError(task_id)
                conn.execute(
                    "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                    (status, now, task_id),
                )
                conn.execute(
                    """
                    INSERT INTO task_runtime
                    (task_id, phase, plan_json, wait_reason, wait_json,
                     pending_clarification_id, interpreted_goal_summary, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(task_id) DO UPDATE SET
                        phase = excluded.phase,
                        plan_json = excluded.plan_json,
                        wait_reason = excluded.wait_reason,
                        wait_json = excluded.wait_json,
                        pending_clarification_id = excluded.pending_clarification_id,
                        interpreted_goal_summary = excluded.interpreted_goal_summary,
                        updated_at = excluded.updated_at
                    """,
                    (
                        task_id,
                        phase,
                        _json(plan),
                        wait_reason,
                        _json(wait_payload) if wait_payload is not None else None,
                        pending_clarification_id,
                        interpreted_goal_summary,
                        now,
                    ),
                )
                terminal = status.lower()
                if terminal in {"completed", "failed", "cancelled"}:
                    state = "COMPLETE" if terminal == "completed" else "FAILED"
                    title = {
                        "completed": "任务已完成",
                        "failed": "任务失败",
                        "cancelled": "任务已取消",
                    }[terminal]
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="RESULT" if terminal == "completed" else "FAILURE_NOTE",
                        presentation_state=state,
                        title=title,
                        summary=None,
                        payload={"task_id": task_id, "status": terminal},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="IMPORTANT" if terminal == "failed" else "QUIET",
                        now=now,
                    )
                conn.commit()
            finally:
                self._close(conn)
        state = self.get_runtime_state(task_id)
        assert state is not None
        return state

    def restore_pending_clarification_wait(self, *, task_id: str, clarification_id: str) -> Dict[str, Any]:
        """Re-arm the same pending Clarification after bounded side work finishes."""

        now = utc_now()
        wait_id = str(uuid.uuid4())
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                clarification = conn.execute(
                    "SELECT * FROM clarifications WHERE id = ? AND task_id = ? AND LOWER(status) = 'pending'",
                    (clarification_id, task_id),
                ).fetchone()
                if clarification is None:
                    raise InvalidPlannerTransitionError("Clarification is no longer pending")
                conn.execute(
                    "UPDATE tasks SET status = 'waiting', updated_at = ? WHERE id = ?",
                    (now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'planning', runtime_revision = runtime_revision + 1,
                        wait_reason = 'user_input', wait_json = ?, wait_id = ?,
                        wait_kind = 'CLARIFICATION', wait_target_type = 'CLARIFICATION',
                        wait_target_id = ?, wake_at = NULL,
                        pending_clarification_id = ?, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (
                        _json({"clarification_id": clarification_id}),
                        wait_id,
                        clarification_id,
                        clarification_id,
                        now,
                        task_id,
                    ),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "clarification.wait_restored",
                        _json({"clarification_id": clarification_id, "wait_id": wait_id}),
                        now,
                    ),
                )
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)
        state = self.get_runtime_state(task_id)
        assert state is not None
        return state

    def record_planner_decision(
        self,
        *,
        decision_id: str,
        task_id: str,
        decision_type: str,
        decision: Dict[str, Any],
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT COALESCE(MAX(sequence), 0) + 1 AS next_sequence FROM planner_decisions WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                assert row is not None
                sequence = int(row["next_sequence"])
                conn.execute(
                    """
                    INSERT INTO planner_decisions
                    (id, task_id, sequence, decision_type, decision_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (decision_id, task_id, sequence, decision_type, _json(decision), now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "planner.decision",
                        _json({
                            "decision_id": decision_id,
                            "sequence": sequence,
                            "decision_type": decision_type,
                        }),
                        now,
                    ),
                )
                conn.commit()
            finally:
                self._close(conn)
        return {
            "decision_id": decision_id,
            "task_id": task_id,
            "sequence": sequence,
            "decision_type": decision_type,
            "decision": decision,
            "created_at": now,
        }

    def planner_decisions(self, task_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """
                    SELECT id, task_id, sequence, decision_type, decision_json, created_at
                    FROM planner_decisions WHERE task_id = ? ORDER BY sequence
                    """,
                    (task_id,),
                ).fetchall()
            finally:
                self._close(conn)
        return [
            {
                "decision_id": row["id"],
                "task_id": row["task_id"],
                "sequence": row["sequence"],
                "decision_type": row["decision_type"],
                "decision": _loads(row["decision_json"], {}),
                "created_at": row["created_at"],
            }
            for row in rows
        ]

    def open_action_task_ids(self, capability_ids: List[str]) -> List[str]:
        """Return ACTIVE Tasks whose current semantic Action is in the supplied capability set."""

        ids = [value for value in capability_ids if isinstance(value, str) and value]
        if not ids:
            return []
        placeholders = ",".join("?" for _ in ids)
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    f"""
                    SELECT DISTINCT a.task_id
                    FROM actions a
                    JOIN tasks t ON t.id = a.task_id
                    WHERE a.action_type IN ({placeholders})
                      AND LOWER(a.status) IN ('pending','planned','dispatched','executing','reconciling','retry_wait')
                      AND LOWER(t.status) = 'active'
                    ORDER BY a.task_id
                    """,
                    ids,
                ).fetchall()
            finally:
                self._close(conn)
        return [str(row["task_id"]) for row in rows]

    def get_open_action(self, task_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    """
                    SELECT * FROM actions
                    WHERE task_id = ? AND LOWER(status) IN ('pending','planned','dispatched','executing','verifying','reconciling','retry_wait')
                    ORDER BY step_index ASC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
            finally:
                self._close(conn)
        return None if row is None else self._action_dict(row)

    def work_item_actions(self, task_id: str) -> Dict[str, Dict[str, Any]]:
        """Latest durable Action per deliverable, including pending confirmation.

        This is a read model; it does not dispatch or retry work.
        """
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """SELECT a.*, EXISTS(
                        SELECT 1 FROM action_input_requests r
                        WHERE r.action_id = a.id AND LOWER(r.status) = 'pending'
                    ) AS waiting_input
                    FROM actions a WHERE a.task_id = ?
                    ORDER BY a.step_index, a.created_at, a.id""", (task_id,)
                ).fetchall()
                result = {}
                for row in rows:
                    action = self._action_dict(row)
                    item_id = action.get("payload", {}).get("item_id")
                    if isinstance(item_id, str) and item_id:
                        result[item_id] = {**action, "waiting_input": bool(row["waiting_input"])}
                return result
            finally:
                self._close(conn)

    def create_action(
        self,
        action_id: str,
        task_id: str,
        step_index: int,
        action_type: str,
        payload: Dict[str, Any],
        expected: Dict[str, Any],
        idempotency_key: str,
        on_verified: str = "COMPLETE",
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute(
                    """
                    INSERT INTO actions
                    (id, task_id, step_index, action_type, payload_json, expected_json,
                     status, idempotency_key, on_verified, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
                    """,
                    (
                        action_id,
                        task_id,
                        step_index,
                        action_type,
                        _json(payload),
                        _json(expected),
                        idempotency_key,
                        on_verified,
                        now,
                        now,
                    ),
                )
                conn.execute(
                    "UPDATE tasks SET current_step = ?, updated_at = ? WHERE id = ?",
                    (step_index, now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "action.planned",
                        _json({"action_id": action_id, "step_index": step_index, "action_type": action_type}),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="ACTIVE",
                    title=capability_activity_title(action_type, "preparing"),
                    summary=None,
                    payload={"action_id": action_id, "capability": action_type},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
            finally:
                self._close(conn)
        return self.get_action(action_id)  # type: ignore[return-value]

    def record_verified_observation(
        self,
        *,
        task_id: str,
        action_id: str,
        capability: str,
        data: Dict[str, Any],
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                if action is None:
                    raise KeyError(action_id)

                existing = conn.execute(
                    "SELECT * FROM observations WHERE action_id = ?",
                    (action_id,),
                ).fetchone()
                if existing is not None:
                    return {
                        "observation_id": existing["id"],
                        "task_id": existing["task_id"],
                        "action_id": existing["action_id"],
                        "capability": existing["capability"],
                        "data": _loads(existing["data_json"], {}),
                        "verified": bool(existing["verified"]),
                        "created_at": existing["created_at"],
                        "duplicate": True,
                    }

                conn.execute(
                    """
                    UPDATE actions
                    SET status = 'succeeded', result_json = ?, error_text = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                    (_json(data), now, action_id),
                )
                cursor = conn.execute(
                    """
                    INSERT INTO observations
                    (task_id, action_id, capability, data_json, verified, created_at)
                    VALUES (?, ?, ?, ?, 1, ?)
                    """,
                    (task_id, action_id, capability, _json(data), now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "observation.verified",
                        _json({"action_id": action_id, "capability": capability}),
                        now,
                    ),
                )
                summary = data.get("summary") if isinstance(data.get("summary"), str) else None
                if summary is not None and len(summary) > 240:
                    summary = summary[:237] + "..."
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="COMPLETE",
                    title=capability_activity_title(capability, "complete"),
                    summary=summary,
                    payload={"action_id": action_id, "capability": capability, "observation_id": int(cursor.lastrowid)},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                observation_id = int(cursor.lastrowid)
            finally:
                self._close(conn)
        return {
            "observation_id": observation_id,
            "task_id": task_id,
            "action_id": action_id,
            "capability": capability,
            "data": data,
            "verified": True,
            "created_at": now,
            "duplicate": False,
        }

    def verified_observations(self, task_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """
                    SELECT id, task_id, action_id, capability, data_json, created_at
                    FROM observations
                    WHERE task_id = ? AND verified = 1
                    ORDER BY id
                    """,
                    (task_id,),
                ).fetchall()
            finally:
                self._close(conn)
        return [
            {
                "observation_id": row["id"],
                "task_id": row["task_id"],
                "action_id": row["action_id"],
                "capability": row["capability"],
                "data": _loads(row["data_json"], {}),
                "created_at": row["created_at"],
            }
            for row in rows
        ]

    def create_clarification(
        self,
        *,
        clarification_id: str,
        task_id: str,
        decision_id: str,
        clarification: Dict[str, Any],
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                clarification_columns = {
                    row["name"] for row in conn.execute("PRAGMA table_info(clarifications)").fetchall()
                }
                if "answer_type" in clarification_columns:
                    # Compatibility with early local Planner V0 databases. The
                    # runtime no longer exposes answer_type semantically.
                    conn.execute(
                        """
                        INSERT INTO clarifications
                        (id, task_id, decision_id, question, answer_type, accepts_text,
                         payload_json, status, response_json, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NULL, ?, ?)
                        """,
                        (
                            clarification_id,
                            task_id,
                            decision_id,
                            clarification["question"],
                            "text" if clarification["accepts_text"] else "choice",
                            int(clarification["accepts_text"]),
                            _json(clarification),
                            now,
                            now,
                        ),
                    )
                else:
                    conn.execute(
                        """
                        INSERT INTO clarifications
                        (id, task_id, decision_id, question, accepts_text, payload_json,
                         status, response_json, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, 'pending', NULL, ?, ?)
                        """,
                        (
                            clarification_id,
                            task_id,
                            decision_id,
                            clarification["question"],
                            int(clarification["accepts_text"]),
                            _json(clarification),
                            now,
                            now,
                        ),
                    )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "clarification.requested",
                        _json({"clarification_id": clarification_id, "decision_id": decision_id}),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"clarification:{clarification_id}:waiting",
                    kind="WAITING_FOR_USER",
                    presentation_state="NEEDS_USER",
                    title=clarification["question"],
                    summary=None,
                    payload={
                        "clarification_id": clarification_id,
                        "suggested_options": clarification["suggested_options"],
                        "accepts_text": clarification["accepts_text"],
                    },
                    source_type="CLARIFICATION",
                    source_id=clarification_id,
                    attention_level="USER_REQUIRED",
                    now=now,
                )
                conn.commit()
            finally:
                self._close(conn)
        return {
            "clarification_id": clarification_id,
            "task_id": task_id,
            "decision_id": decision_id,
            "status": "pending",
            "payload": clarification,
            "created_at": now,
        }

    def pending_clarification(self, task_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    """
                    SELECT * FROM clarifications
                    WHERE task_id = ? AND status = 'pending'
                    ORDER BY created_at DESC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
            finally:
                self._close(conn)
        if row is None:
            return None
        return {
            "clarification_id": row["id"],
            "task_id": row["task_id"],
            "decision_id": row["decision_id"],
            "status": row["status"],
            "payload": _loads(row["payload_json"], {}),
            "response": _loads(row["response_json"], None),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def admit_inbox_event(
        self,
        *,
        task_id: str,
        event_id: str,
        event_type: str,
        source: str,
        payload: Dict[str, Any],
        target_type: Optional[str] = None,
        target_id: Optional[str] = None,
        occurred_at: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Durably admit one internal Runtime input and fence stale Planner work."""

        if not event_id.strip():
            raise ValueError("event_id must not be empty")
        if not event_type.strip():
            raise ValueError("event_type must not be empty")
        now = utc_now()
        payload_json = canonical_json(payload)
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if task is None or runtime is None:
                    raise KeyError(task_id)

                # Exact duplicate delivery is acknowledged before checking
                # whether the Task has since become terminal. A retry of an
                # already-admitted event must remain idempotent forever.
                existing = conn.execute(
                    "SELECT * FROM task_inbox_events WHERE event_id = ?",
                    (event_id,),
                ).fetchone()
                if existing is not None:
                    same = (
                        existing["task_id"] == task_id
                        and existing["event_type"] == event_type
                        and existing["source"] == source
                        and existing["target_type"] == target_type
                        and existing["target_id"] == target_id
                        and canonical_json(_loads(existing["payload_json"], {})) == payload_json
                    )
                    if not same:
                        raise InboxEventConflictError(
                            "event_id is already bound to different inbox content"
                        )
                    conn.commit()
                    return {
                        "seq": int(existing["seq"]),
                        "event_id": existing["event_id"],
                        "task_id": existing["task_id"],
                        "event_type": existing["event_type"],
                        "status": existing["status"],
                        "duplicate": True,
                    }

                if str(task["status"]).lower() in {"completed", "failed", "cancelled"}:
                    raise InvalidPlannerTransitionError("terminal task cannot accept new inbox input")

                if target_type == "CLARIFICATION" and target_id is not None:
                    correlated = conn.execute(
                        "SELECT task_id FROM clarifications WHERE id = ?",
                        (target_id,),
                    ).fetchone()
                    if correlated is None or correlated["task_id"] != task_id:
                        raise InvalidPlannerTransitionError(
                            "reply Clarification does not belong to this Task"
                        )
                if target_type == "WAIT" and target_id is not None:
                    if runtime["wait_id"] != target_id:
                        raise InvalidPlannerTransitionError("stale wait event")
                if target_type == "ACTION_INPUT" and target_id is not None:
                    request = conn.execute(
                        "SELECT task_id FROM action_input_requests WHERE id = ?",
                        (target_id,),
                    ).fetchone()
                    if request is None or request["task_id"] != task_id:
                        raise InvalidPlannerTransitionError("ActionInputRequest does not belong to this Task")

                cursor = conn.execute(
                    """
                    INSERT INTO task_inbox_events
                    (event_id, task_id, event_type, source, target_type, target_id,
                     payload_json, raw_ref, status, ignore_reason, occurred_at,
                     received_at, consumed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 'ACCEPTED', NULL, ?, ?, NULL)
                    """,
                    (
                        event_id,
                        task_id,
                        event_type,
                        source,
                        target_type,
                        target_id,
                        payload_json,
                        occurred_at,
                        now,
                    ),
                )
                seq = int(cursor.lastrowid)

                # Input admission itself invalidates Planner work based on the
                # previous snapshot. USER_TURN also makes a previously waiting
                # semantic task eligible for planning without resolving any
                # existing Clarification yet.
                next_status = str(task["status"])
                next_phase = str(runtime["phase"])
                if event_type == "USER_TURN":
                    if (
                        str(runtime["wait_kind"] or "").upper() == "RETRY_BACKOFF"
                        and str(runtime["wait_target_type"] or "").upper() == "PLANNER"
                    ):
                        retry_payload = _loads(runtime["wait_json"], {})
                        retry_call_number = retry_payload.get("planner_call_number")
                        conn.execute(
                            """
                            UPDATE task_runtime
                            SET wait_reason = NULL, wait_json = NULL, wait_id = NULL,
                                wait_kind = NULL, wait_target_type = NULL,
                                wait_target_id = NULL, wake_at = NULL
                            WHERE task_id = ?
                            """,
                            (task_id,),
                        )
                        conn.execute(
                            "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                            (
                                task_id,
                                "planner.retry_superseded_by_user_turn",
                                _json({"user_turn_event_id": event_id, "planner_call_number": retry_call_number}),
                                now,
                            ),
                        )
                        if isinstance(retry_call_number, int):
                            upsert_timeline_item(
                                conn,
                                task_id=task_id,
                                source_key=f"planner:{task_id}:{retry_call_number}:activity",
                                kind="AGENT_ACTIVITY",
                                presentation_state="COMPLETE",
                                title="已收到你的补充，继续重新规划",
                                summary=None,
                                payload={"call_number": retry_call_number, "retry_superseded": True},
                                source_type="TASK_RUNTIME",
                                source_id=task_id,
                                attention_level="QUIET",
                                now=now,
                            )
                    next_status = "active"
                    open_action = conn.execute(
                        """
                        SELECT * FROM actions WHERE task_id = ? AND LOWER(status) IN
                          ('pending','dispatched','planned','executing','verifying','reconciling','retry_wait')
                        ORDER BY step_index LIMIT 1
                        """,
                        (task_id,),
                    ).fetchone()
                    if open_action is None:
                        next_phase = "planning"
                    else:
                        active_attempt = conn.execute(
                            """
                            SELECT 1 FROM action_attempts
                            WHERE action_id = ? AND UPPER(status) IN ('IN_FLIGHT','WAITING_INPUT')
                            LIMIT 1
                            """,
                            (open_action["id"],),
                        ).fetchone()
                        open_status = str(open_action["status"]).lower()
                        if active_attempt is None and open_status in {"pending", "planned", "dispatched", "retry_wait"}:
                            # New semantic steering arrived before any current
                            # invocation can produce a new side effect. This is
                            # safe to supersede, including a scheduled retry.
                            reason = (
                                "superseded by user turn before retry"
                                if open_status == "retry_wait"
                                else "superseded by user turn before dispatch"
                            )
                            conn.execute(
                                "UPDATE actions SET status = 'cancelled', error_text = ?, updated_at = ? WHERE id = ?",
                                (reason, now, open_action["id"]),
                            )
                            conn.execute(
                                """
                                UPDATE action_input_requests
                                SET status = 'CANCELLED', response_json = ?, updated_at = ?
                                WHERE action_id = ? AND attempt_id IS NULL
                                  AND UPPER(status) IN ('PENDING','ANSWERED')
                                """,
                                (_json({"reason": "user_turn_superseded_action"}), now, open_action["id"]),
                            )
                            conn.execute(
                                """
                                UPDATE task_inbox_events
                                SET status = 'IGNORED', ignore_reason = 'user_turn_superseded_action', consumed_at = ?
                                WHERE task_id = ? AND target_type = 'ACTION_INPUT'
                                  AND target_id IN (
                                    SELECT id FROM action_input_requests WHERE action_id = ?
                                  )
                                  AND UPPER(status) = 'ACCEPTED'
                                """,
                                (now, task_id, open_action["id"]),
                            )
                            if open_status == "retry_wait":
                                conn.execute(
                                    """
                                    UPDATE task_runtime
                                    SET wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL
                                    WHERE task_id = ?
                                    """,
                                    (task_id,),
                                )
                            conn.execute(
                                "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                                (
                                    task_id,
                                    "action.superseded_before_retry" if open_status == "retry_wait" else "action.superseded_before_dispatch",
                                    _json({"action_id": open_action["id"], "user_turn_event_id": event_id}),
                                    now,
                                ),
                            )
                            upsert_timeline_item(
                                conn,
                                task_id=task_id,
                                source_key=f"action:{open_action['id']}:activity",
                                kind="TOOL_ACTIVITY",
                                presentation_state="INFO",
                                title="已停止旧操作，按你的新要求重新规划",
                                summary=None,
                                payload={"action_id": open_action["id"], "superseded": True},
                                source_type="ACTION",
                                source_id=str(open_action["id"]),
                                attention_level="QUIET",
                                now=now,
                            )
                            next_phase = "planning"
                    content = payload.get("content")
                    text = None
                    if isinstance(content, dict) and isinstance(content.get("text"), str):
                        text = content["text"].strip()
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"inbox:{event_id}:user-turn",
                        kind="USER_INPUT",
                        presentation_state="COMPLETE",
                        title="你补充了任务",
                        summary=text[:240] if text else None,
                        payload={
                            "event_id": event_id,
                            "attachment_ids": payload.get("attachment_ids", []),
                        },
                        source_type="INBOX_EVENT",
                        source_id=event_id,
                        attention_level="QUIET",
                        now=now,
                    )

                conn.execute(
                    "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                    (next_status, now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = ?, runtime_revision = runtime_revision + 1, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (next_phase, now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "inbox.accepted",
                        _json({
                            "event_id": event_id,
                            "seq": seq,
                            "event_type": event_type,
                            "source": source,
                        }),
                        now,
                    ),
                )
                conn.commit()
                revision_row = conn.execute(
                    "SELECT runtime_revision FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                assert revision_row is not None
                return {
                    "seq": seq,
                    "event_id": event_id,
                    "task_id": task_id,
                    "event_type": event_type,
                    "status": "ACCEPTED",
                    "runtime_revision": int(revision_row["runtime_revision"]),
                    "duplicate": False,
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def get_inbox_event(self, event_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT * FROM task_inbox_events WHERE event_id = ?",
                    (event_id,),
                ).fetchone()
            finally:
                self._close(conn)
        if row is None:
            return None
        return {
            "seq": int(row["seq"]),
            "event_id": row["event_id"],
            "task_id": row["task_id"],
            "event_type": row["event_type"],
            "source": row["source"],
            "target_type": row["target_type"],
            "target_id": row["target_id"],
            "payload": _loads(row["payload_json"], {}),
            "status": row["status"],
            "ignore_reason": row["ignore_reason"],
            "received_at": row["received_at"],
            "consumed_at": row["consumed_at"],
        }

    def inbox_events(self, task_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    "SELECT * FROM task_inbox_events WHERE task_id = ? ORDER BY seq",
                    (task_id,),
                ).fetchall()
            finally:
                self._close(conn)
        return [
            {
                "seq": int(row["seq"]),
                "event_id": row["event_id"],
                "event_type": row["event_type"],
                "source": row["source"],
                "target_type": row["target_type"],
                "target_id": row["target_id"],
                "payload": _loads(row["payload_json"], {}),
                "status": row["status"],
                "received_at": row["received_at"],
                "consumed_at": row["consumed_at"],
            }
            for row in rows
        ]

    def task_policy_basis(self, task_id: str) -> Dict[str, Any]:
        """Read the durable inputs that deterministically define effective Task policy."""

        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute(
                    "SELECT runtime_revision FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if task is None or runtime is None:
                    conn.commit()
                    raise KeyError(task_id)
                rows = conn.execute(
                    """
                    SELECT * FROM task_inbox_events
                    WHERE task_id = ? AND event_type = 'USER_TURN' AND UPPER(status) != 'IGNORED'
                    ORDER BY seq
                    """,
                    (task_id,),
                ).fetchall()
                result = {
                    "task": self._task_dict(task),
                    "runtime_revision": int(runtime["runtime_revision"]),
                    "user_turns": [
                        {
                            "seq": int(row["seq"]),
                            "event_id": row["event_id"],
                            "event_type": row["event_type"],
                            "source": row["source"],
                            "payload": _loads(row["payload_json"], {}),
                            "status": row["status"],
                            "received_at": row["received_at"],
                        }
                        for row in rows
                    ],
                }
                conn.commit()
                return result
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def planner_basis(self, task_id: str) -> Dict[str, Any]:
        """Read one consistent basis for a potentially slow Planner call."""

        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if task is None or runtime is None:
                    conn.commit()
                    raise KeyError(task_id)
                action = conn.execute(
                    """
                    SELECT * FROM actions
                    WHERE task_id = ? AND LOWER(status) IN
                        ('pending','dispatched','planned','executing','verifying','reconciling','retry_wait')
                    ORDER BY step_index LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                clarification = conn.execute(
                    """
                    SELECT * FROM clarifications
                    WHERE task_id = ? AND LOWER(status) = 'pending'
                    ORDER BY created_at DESC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                event_rows = conn.execute(
                    """
                    SELECT * FROM task_inbox_events
                    WHERE task_id = ? AND UPPER(status) = 'ACCEPTED'
                    ORDER BY seq
                    """,
                    (task_id,),
                ).fetchall()
                policy_turn_rows = conn.execute(
                    """
                    SELECT * FROM task_inbox_events
                    WHERE task_id = ? AND event_type = 'USER_TURN' AND UPPER(status) != 'IGNORED'
                    ORDER BY seq
                    """,
                    (task_id,),
                ).fetchall()
                watermark_row = conn.execute(
                    "SELECT COALESCE(MAX(seq), 0) AS watermark FROM task_inbox_events WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                observation_rows = conn.execute(
                    """
                    SELECT id, task_id, action_id, capability, data_json, created_at
                    FROM observations
                    WHERE task_id = ? AND verified = 1
                    ORDER BY id
                    """,
                    (task_id,),
                ).fetchall()
                latest_decision = conn.execute(
                    "SELECT MAX(created_at) AS created_at FROM planner_decisions WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                latest_rejected_input = conn.execute(
                    """
                    SELECT air.*, a.action_type
                    FROM action_input_requests air
                    JOIN actions a ON a.id = air.action_id
                    WHERE air.task_id = ? AND UPPER(air.status) = 'ANSWERED'
                    ORDER BY air.updated_at DESC
                    LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                latest_failed_action = conn.execute(
                    """
                    SELECT id, action_type, failure_code, failure_detail_json, error_text, updated_at
                    FROM actions
                    WHERE task_id = ? AND LOWER(status) = 'failed' AND error_text IS NOT NULL
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()

                last_semantic_failure = None
                if latest_rejected_input is not None:
                    rejected_response = _loads(latest_rejected_input["response_json"], {})
                    last_decision_at = latest_decision["created_at"] if latest_decision is not None else None
                    if (
                        isinstance(rejected_response, dict)
                        and rejected_response.get("approved") is False
                        and (
                            last_decision_at is None
                            or str(latest_rejected_input["updated_at"]) > str(last_decision_at)
                        )
                    ):
                        last_semantic_failure = {
                            "kind": "USER_REJECTED_ACTION_INPUT",
                            "capability": str(latest_rejected_input["action_type"]),
                            "reason": str(latest_rejected_input["reason"]),
                            "prompt": str(latest_rejected_input["prompt"]),
                            "response": rejected_response,
                            "occurred_at": str(latest_rejected_input["updated_at"]),
                        }
                if latest_failed_action is not None:
                    last_decision_at = latest_decision["created_at"] if latest_decision is not None else None
                    failure_at = str(latest_failed_action["updated_at"])
                    current_failure_at = (
                        str(last_semantic_failure.get("occurred_at"))
                        if last_semantic_failure is not None
                        else None
                    )
                    if (
                        (last_decision_at is None or failure_at > str(last_decision_at))
                        and (current_failure_at is None or failure_at >= current_failure_at)
                    ):
                        failure_code = latest_failed_action["failure_code"]
                        failure_detail = _loads(latest_failed_action["failure_detail_json"], None)
                        last_semantic_failure = {
                            "kind": "ACTION_TASK_DENIED" if failure_code == "TASK_DENIED" else "ACTION_MODEL_CORRECTABLE_FAILURE",
                            "action_id": str(latest_failed_action["id"]),
                            "capability": str(latest_failed_action["action_type"]),
                            "reason_code": str(failure_code) if failure_code else None,
                            "reason": str(latest_failed_action["error_text"]),
                            "detail": failure_detail,
                            "occurred_at": failure_at,
                        }

                pending = None
                if clarification is not None:
                    pending = {
                        "clarification_id": clarification["id"],
                        "question": clarification["question"],
                        "payload": _loads(clarification["payload_json"], {}),
                    }
                accepted_events = [
                    {
                        "seq": int(row["seq"]),
                        "event_id": row["event_id"],
                        "event_type": row["event_type"],
                        "source": row["source"],
                        "payload": _loads(row["payload_json"], {}),
                        "received_at": row["received_at"],
                    }
                    for row in event_rows
                ]
                policy_user_turns = [
                    {
                        "seq": int(row["seq"]),
                        "event_id": row["event_id"],
                        "event_type": row["event_type"],
                        "source": row["source"],
                        "payload": _loads(row["payload_json"], {}),
                        "status": row["status"],
                        "received_at": row["received_at"],
                    }
                    for row in policy_turn_rows
                ]
                observations = [
                    {
                        "observation_id": row["id"],
                        "task_id": row["task_id"],
                        "action_id": row["action_id"],
                        "capability": row["capability"],
                        "data": _loads(row["data_json"], {}),
                        "created_at": row["created_at"],
                    }
                    for row in observation_rows
                ]
                result = {
                    "task": self._task_dict(task),
                    "runtime": {
                        "task_id": runtime["task_id"],
                        "phase": runtime["phase"],
                        "plan": _loads(runtime["plan_json"], []),
                        "wait_reason": runtime["wait_reason"],
                        "wait_kind": runtime["wait_kind"],
                        "wait_id": runtime["wait_id"],
                        "pending_clarification_id": runtime["pending_clarification_id"],
                        "current_task_brief": runtime["current_task_brief"]
                        or runtime["interpreted_goal_summary"],
                        "runtime_revision": int(runtime["runtime_revision"]),
                        "planner_calls": int(runtime["planner_calls"]),
                    },
                    "open_action": None if action is None else self._action_dict(action),
                    "pending_clarification": pending,
                    "accepted_events": accepted_events,
                    "policy_user_turns": policy_user_turns,
                    "basis_inbox_seq": int(watermark_row["watermark"]),
                    "verified_observations": observations,
                    "last_semantic_failure": last_semantic_failure,
                }
                conn.commit()
                return result
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def _discovery_epoch(self, conn, task_id):
        from .discovery_progress import progress_epoch
        rows = conn.execute("SELECT id, action_id, capability, data_json FROM observations WHERE task_id=? AND verified=1 ORDER BY created_at,id", (task_id,)).fetchall()
        observations = [{"observation_id": r["id"], "action_id": r["action_id"],
                         "capability": r["capability"], "data": _loads(r["data_json"], {})} for r in rows]
        user_seq = conn.execute("SELECT COALESCE(MAX(seq),0) FROM task_inbox_events WHERE task_id=? AND event_type='USER_TURN'", (task_id,)).fetchone()[0]
        return progress_epoch(observations, user_seq)

    def capability_discovery_state(self, task_id: str) -> Dict[str, Any]:
        from .discovery_progress import state_view
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute("SELECT budget_json,capability_searches FROM task_runtime WHERE task_id=?", (task_id,)).fetchone()
                if row is None:
                    raise KeyError(task_id)
                state = state_view(_loads(row['budget_json'], {}).get('discovery'), self._discovery_epoch(conn, task_id))
                return {**state, 'total_searches': int(row['capability_searches'])}
            finally:
                self._close(conn)

    def record_capability_search(self, task_id: str, catalog_key: str, result: Dict[str, Any]) -> Dict[str, Any]:
        """Atomically account for standalone AND concurrent Work Unit discovery."""
        from .discovery_progress import record_result
        with self._lock:
            conn = self._connect()
            try:
                conn.execute('BEGIN IMMEDIATE')
                row = conn.execute('SELECT budget_json FROM task_runtime WHERE task_id=?', (task_id,)).fetchone()
                if row is None:
                    raise KeyError(task_id)
                budget = _loads(row['budget_json'], {})
                state, result = record_result(budget.get('discovery'), self._discovery_epoch(conn, task_id), catalog_key, result)
                budget['discovery'] = state
                conn.execute('UPDATE task_runtime SET budget_json=?, capability_searches=capability_searches+1, revealed_capabilities_json=? WHERE task_id=?',
                             (_json(budget), _json(state.get('seen_ids', [])), task_id))
                conn.commit()
                return result
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def reserve_planner_call(self, task_id: str, *, max_calls: int) -> int:
        if max_calls < 1:
            raise ValueError("max_calls must be positive")
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                row = conn.execute(
                    "SELECT planner_calls FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if row is None:
                    raise KeyError(task_id)
                used = int(row["planner_calls"])
                if used >= max_calls:
                    conn.execute(
                        "UPDATE tasks SET status = 'blocked', updated_at = ? WHERE id = ?",
                        (now, task_id),
                    )
                    conn.execute(
                        """
                        UPDATE task_runtime
                        SET phase = 'planning', block_reason = 'planner_budget_exhausted',
                            runtime_revision = runtime_revision + 1, updated_at = ?
                        WHERE task_id = ?
                        """,
                        (now, task_id),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:planner-budget",
                        kind="FAILURE_NOTE",
                        presentation_state="NEEDS_USER",
                        title="任务已暂停",
                        summary="规划次数达到安全上限，需要检查任务或重新继续。",
                        payload={"reason": "planner_budget_exhausted"},
                        source_type="TASK_RUNTIME",
                        source_id=task_id,
                        attention_level="IMPORTANT",
                        now=now,
                    )
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (task_id, "planner.budget_exhausted", _json({"max_calls": max_calls}), now),
                    )
                    conn.commit()
                    raise PlannerBudgetExceededError("planner call budget exhausted")
                next_count = used + 1
                conn.execute(
                    "UPDATE task_runtime SET planner_calls = ?, updated_at = ? WHERE task_id = ?",
                    (next_count, now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "planner.call.started", _json({"call_number": next_count}), now),
                )
                has_observation = conn.execute(
                    "SELECT 1 FROM observations WHERE task_id = ? AND verified = 1 LIMIT 1",
                    (task_id,),
                ).fetchone() is not None
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"planner:{task_id}:{next_count}:activity",
                    kind="AGENT_ACTIVITY",
                    presentation_state="ACTIVE",
                    title="小卷正在思考下一步" if has_observation else "小卷正在思考",
                    summary=None,
                    payload={"call_number": next_count},
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                return next_count
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def record_planner_call_failure(
        self,
        *,
        task_id: str,
        call_number: int,
        error: Exception,
    ) -> None:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "planner.call.failed",
                        _json({
                            "call_number": call_number,
                            "error_type": type(error).__name__,
                            "error": str(error)[:500],
                        }),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"planner:{task_id}:{call_number}:activity",
                    kind="AGENT_ACTIVITY",
                    presentation_state="FAILED",
                    title="小卷暂时没能完成思考",
                    summary=None,
                    payload={"call_number": call_number},
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
            finally:
                self._close(conn)

    def consecutive_planner_failures(self, task_id: str) -> int:
        """Count non-stale Planner failures since the last committed decision."""

        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """
                    SELECT event_type, data_json
                    FROM traces
                    WHERE task_id = ?
                      AND event_type IN (
                          'planner.call.failed',
                          'planner.call.committed',
                          'inbox.accepted',
                          'task.operator_resumed'
                      )
                    ORDER BY id DESC
                    """,
                    (task_id,),
                ).fetchall()
            finally:
                self._close(conn)
        failures = 0
        for row in rows:
            event_type = row["event_type"]
            if event_type in {"planner.call.committed", "task.operator_resumed"}:
                break
            if event_type == "inbox.accepted":
                data = _loads(row["data_json"], {})
                if str(data.get("event_type") or "").upper() == "USER_TURN":
                    break
                continue
            if event_type == "planner.call.failed":
                failures += 1
        return failures

    def schedule_planner_retry_wait(
        self,
        *,
        task_id: str,
        call_number: int,
        retry_index: int,
        max_auto_retries: int,
        wait_id: str,
        wake_at: str,
        error_type: str,
    ) -> Dict[str, Any]:
        """Persist a short Planner-provider backoff without losing Task truth."""

        if retry_index < 1:
            raise ValueError("retry_index must be positive")
        if max_auto_retries < 1:
            raise ValueError("max_auto_retries must be positive")
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)
                ).fetchone()
                if task is None or runtime is None:
                    raise KeyError(task_id)
                if str(task["status"]).lower() in {"completed", "failed", "cancelled"}:
                    conn.commit()
                    return {"scheduled": False, "reason": "terminal"}
                wait_payload = {
                    "planner_call_number": call_number,
                    "retry_index": retry_index,
                    "max_auto_retries": max_auto_retries,
                    "error_type": error_type,
                }
                conn.execute(
                    "UPDATE tasks SET status = 'waiting', updated_at = ? WHERE id = ?",
                    (now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'planning', runtime_revision = runtime_revision + 1,
                        wait_reason = 'planner_retry_backoff', wait_json = ?,
                        wait_id = ?, wait_kind = 'RETRY_BACKOFF',
                        wait_target_type = 'PLANNER', wait_target_id = ?, wake_at = ?,
                        block_reason = NULL, block_payload_json = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (_json(wait_payload), wait_id, task_id, wake_at, now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "planner.retry_wait",
                        _json({
                            "call_number": call_number,
                            "retry_index": retry_index,
                            "max_auto_retries": max_auto_retries,
                            "wait_id": wait_id,
                            "wake_at": wake_at,
                            "error_type": error_type,
                        }),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"planner:{task_id}:{call_number}:activity",
                    kind="AGENT_ACTIVITY",
                    presentation_state="ACTIVE",
                    title="后台规划连接波动，正在自动恢复",
                    summary="当前进度已保留，将自动继续。",
                    payload={
                        "call_number": call_number,
                        "retry_index": retry_index,
                        "retry_wait_id": wait_id,
                    },
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                return {"scheduled": True, "wait_id": wait_id, "wake_at": wake_at}
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def resume_planner_retry_wait(
        self,
        *,
        task_id: str,
        wait_id: str,
        event_id: str,
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)
                ).fetchone()
                event = conn.execute(
                    "SELECT * FROM task_inbox_events WHERE event_id = ? AND task_id = ?",
                    (event_id, task_id),
                ).fetchone()
                if task is None or runtime is None or event is None:
                    raise KeyError(task_id)
                if runtime["wait_id"] != wait_id:
                    raise InvalidPlannerTransitionError("stale Planner retry wait")
                if (
                    str(runtime["wait_kind"] or "").upper() != "RETRY_BACKOFF"
                    or str(runtime["wait_target_type"] or "").upper() != "PLANNER"
                ):
                    raise InvalidPlannerTransitionError("wait is not Planner retry backoff")
                if event["target_type"] != "WAIT" or event["target_id"] != wait_id:
                    raise InvalidPlannerTransitionError("timer event does not target Planner retry wait")
                if str(event["status"]).upper() == "CONSUMED":
                    conn.commit()
                    return self._task_dict(task)
                if str(event["status"]).upper() != "ACCEPTED":
                    raise InvalidPlannerTransitionError("timer event is not consumable")

                retry_payload = _loads(runtime["wait_json"], {})
                call_number = retry_payload.get("planner_call_number")
                conn.execute(
                    "UPDATE task_inbox_events SET status = 'CONSUMED', consumed_at = ? WHERE event_id = ?",
                    (now, event_id),
                )
                conn.execute(
                    "UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?",
                    (now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'planning', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "planner.retry_resumed",
                        _json({"wait_id": wait_id, "event_id": event_id, "planner_call_number": call_number}),
                        now,
                    ),
                )
                if isinstance(call_number, int):
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"planner:{task_id}:{call_number}:activity",
                        kind="AGENT_ACTIVITY",
                        presentation_state="COMPLETE",
                        title="后台规划已恢复，继续处理",
                        summary=None,
                        payload={"call_number": call_number, "retry_resumed": True},
                        source_type="TASK_RUNTIME",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                return self._task_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def record_planner_task_denied(
        self,
        *,
        task_id: str,
        call_number: int,
        capability_id: str,
        detail: str,
    ) -> None:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "planner.decision.task_denied",
                        _json({
                            "call_number": call_number,
                            "capability": capability_id,
                            "reason_code": "TASK_DENIED",
                            "detail": detail[:500],
                        }),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"planner:{task_id}:{call_number}:activity",
                    kind="AGENT_ACTIVITY",
                    presentation_state="INFO",
                    title="已按当前任务限制停止这轮方案",
                    summary="这轮方案包含当前任务明确禁止的操作，未进入执行。",
                    payload={"call_number": call_number, "reason_code": "TASK_DENIED"},
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
            finally:
                self._close(conn)

    def record_stale_planner_result(
        self,
        *,
        task_id: str,
        call_number: int,
        basis_runtime_revision: int,
        basis_inbox_seq: int,
        error: Optional[Exception] = None,
    ) -> None:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                current = conn.execute(
                    "SELECT runtime_revision FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "planner.failure.stale" if error is not None else "planner.result.stale",
                        _json({
                            "call_number": call_number,
                            "basis_runtime_revision": basis_runtime_revision,
                            "current_runtime_revision": int(current["runtime_revision"]) if current else None,
                            "basis_inbox_seq": basis_inbox_seq,
                            **(
                                {
                                    "error_type": type(error).__name__,
                                    "error": str(error)[:500],
                                }
                                if error is not None
                                else {}
                            ),
                        }),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"planner:{task_id}:{call_number}:activity",
                    kind="AGENT_ACTIVITY",
                    presentation_state="INFO",
                    title="已根据最新要求重新调整",
                    summary="这轮思考没有继续采用，任务会按最新状态继续处理。",
                    payload={"call_number": call_number, "superseded": True},
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
            finally:
                self._close(conn)

    def apply_planner_decision_atomic(
        self,
        *,
        task_id: str,
        expected_runtime_revision: int,
        basis_inbox_seq: int,
        decision_id: str,
        decision: Dict[str, Any],
        action_id: Optional[str] = None,
        clarification_id: Optional[str] = None,
        wait_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Persist one accepted PlannerDecision and its semantic transition atomically."""

        now = utc_now()
        decision_type = str(decision["decision_type"])
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if task is None or runtime is None:
                    raise KeyError(task_id)
                # Concurrency fencing must run before semantic-state rejection.
                # If the user cancelled/changed the Task while the model was
                # thinking, that result is stale work, not a Planner bug.
                current_revision = int(runtime["runtime_revision"])
                if current_revision != expected_runtime_revision:
                    raise StalePlannerDecisionError(
                        f"runtime revision changed from {expected_runtime_revision} to {current_revision}"
                    )
                if str(task["status"]).lower() in {"completed", "failed", "cancelled"}:
                    raise InvalidPlannerTransitionError("terminal task cannot apply PlannerDecision")
                newer_event = conn.execute(
                    "SELECT seq FROM task_inbox_events WHERE task_id = ? AND seq > ? ORDER BY seq LIMIT 1",
                    (task_id, basis_inbox_seq),
                ).fetchone()
                if newer_event is not None:
                    raise StalePlannerDecisionError(
                        f"new inbox event {int(newer_event['seq'])} arrived after Planner basis"
                    )
                open_action = conn.execute(
                    """
                    SELECT id FROM actions
                    WHERE task_id = ? AND LOWER(status) IN
                        ('pending','dispatched','planned','executing','verifying','reconciling','retry_wait')
                    LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                if open_action is not None:
                    raise StalePlannerDecisionError("task gained an unfinished Action before Planner result applied")

                accepted_user_turns = conn.execute(
                    """
                    SELECT * FROM task_inbox_events
                    WHERE task_id = ? AND seq <= ? AND UPPER(status) = 'ACCEPTED'
                      AND event_type = 'USER_TURN'
                    ORDER BY seq
                    """,
                    (task_id, basis_inbox_seq),
                ).fetchall()
                pending = conn.execute(
                    """
                    SELECT * FROM clarifications
                    WHERE task_id = ? AND LOWER(status) = 'pending'
                    ORDER BY created_at DESC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()

                state_update = decision.get("state_update") or {}
                pending_update = state_update.get("pending_clarification")
                if accepted_user_turns and pending is not None and pending_update is None:
                    raise InvalidPlannerTransitionError(
                        "Planner must explicitly RESOLVE/KEEP/CANCEL the pending Clarification when consuming UserTurns"
                    )
                if pending_update is not None and pending is None:
                    raise InvalidPlannerTransitionError(
                        "Planner cannot update a pending Clarification when none exists"
                    )
                if pending is not None:
                    if pending_update == "RESOLVED":
                        event_ids = [row["event_id"] for row in accepted_user_turns]
                        pending_id_for_projection = str(pending["id"])
                        pending_question = str(pending["question"])
                        conn.execute(
                            """
                            UPDATE clarifications
                            SET status = 'answered', response_json = ?, resolved_by_event_id = ?, updated_at = ?
                            WHERE id = ?
                            """,
                            (
                                _json({"user_turn_event_ids": event_ids}),
                                event_ids[-1] if event_ids else None,
                                now,
                                pending["id"],
                            ),
                        )
                        upsert_timeline_item(
                            conn,
                            task_id=task_id,
                            source_key=f"clarification:{pending_id_for_projection}:waiting",
                            kind="WAITING_FOR_USER",
                            presentation_state="COMPLETE",
                            title=pending_question,
                            summary="已根据你的补充继续处理。",
                            payload={"clarification_id": pending_id_for_projection, "resolved": True},
                            source_type="CLARIFICATION",
                            source_id=pending_id_for_projection,
                            attention_level="QUIET",
                            now=now,
                        )
                        pending = None
                    elif pending_update == "CANCEL":
                        pending_id_for_projection = str(pending["id"])
                        pending_question = str(pending["question"])
                        conn.execute(
                            "UPDATE clarifications SET status = 'cancelled', updated_at = ? WHERE id = ?",
                            (now, pending["id"]),
                        )
                        upsert_timeline_item(
                            conn,
                            task_id=task_id,
                            source_key=f"clarification:{pending_id_for_projection}:waiting",
                            kind="WAITING_FOR_USER",
                            presentation_state="INFO",
                            title=pending_question,
                            summary="任务已变化，不再需要回答这个问题。",
                            payload={"clarification_id": pending_id_for_projection, "cancelled": True},
                            source_type="CLARIFICATION",
                            source_id=pending_id_for_projection,
                            attention_level="QUIET",
                            now=now,
                        )
                        pending = None
                    elif pending_update == "KEEP" or pending_update is None:
                        pass
                    else:
                        raise InvalidPlannerTransitionError("invalid pending Clarification update")

                if decision_type == "CLARIFY" and pending is not None:
                    raise InvalidPlannerTransitionError(
                        "CLARIFY cannot create a second pending Clarification"
                    )
                if decision_type in {"COMPLETE", "STOP", "CANCEL"} and pending is not None:
                    raise InvalidPlannerTransitionError(
                        "terminal PlannerDecision cannot leave a pending Clarification"
                    )
                if decision_type == "WAIT" and decision.get("wait", {}).get("kind") == "user_input" and pending is None:
                    raise InvalidPlannerTransitionError(
                        "WAIT(user_input) requires an existing pending Clarification"
                    )

                sequence_row = conn.execute(
                    "SELECT COALESCE(MAX(sequence), 0) + 1 AS next_sequence FROM planner_decisions WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                assert sequence_row is not None
                sequence = int(sequence_row["next_sequence"])
                conn.execute(
                    """
                    INSERT INTO planner_decisions
                    (id, task_id, sequence, decision_type, decision_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (decision_id, task_id, sequence, decision_type, _json(decision), now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "planner.decision",
                        _json({
                            "decision_id": decision_id,
                            "sequence": sequence,
                            "decision_type": decision_type,
                            "basis_runtime_revision": expected_runtime_revision,
                            "basis_inbox_seq": basis_inbox_seq,
                        }),
                        now,
                    ),
                )

                planner_call_number = int(runtime["planner_calls"])
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"planner:{task_id}:{planner_call_number}:activity",
                    kind="AGENT_ACTIVITY",
                    presentation_state="COMPLETE",
                    title="小卷已完成这轮思考",
                    summary=None,
                    payload={"call_number": planner_call_number},
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )

                plan = decision["plan_update"] if decision.get("plan_update") is not None else _loads(runtime["plan_json"], [])
                brief = runtime["current_task_brief"] or runtime["interpreted_goal_summary"]
                requested_brief = state_update.get("current_task_brief")
                if requested_brief:
                    brief = requested_brief.strip()
                elif brief is None:
                    brief = str(decision["interpreted_goal_summary"]).strip()

                next_status = "active"
                next_phase = "planning"
                legacy_wait_reason: Optional[str] = None
                wait_kind: Optional[str] = None
                wait_target_type: Optional[str] = None
                wait_target_id: Optional[str] = None
                wake_at: Optional[str] = None
                wait_payload: Optional[Dict[str, Any]] = None
                pending_id = str(pending["id"]) if pending is not None else None
                result: Dict[str, Any] = {}

                if decision_type == "EXECUTE":
                    if action_id is None:
                        raise InvalidPlannerTransitionError("EXECUTE requires action_id")
                    action = decision.get("action")
                    assert isinstance(action, dict)
                    step_index = int(task["current_step"]) + 1
                    capability = str(action["capability"])
                    conn.execute(
                        """
                        INSERT INTO actions
                        (id, task_id, step_index, action_type, payload_json, expected_json,
                         status, idempotency_key, on_verified, planner_decision_id,
                         created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, '{}', 'pending', ?, ?, ?, ?, ?)
                        """,
                        (
                            action_id,
                            task_id,
                            step_index,
                            capability,
                            _json(action["arguments"]),
                            f"{task_id}:{step_index}:{capability}",
                            decision.get("on_verified") or "REPLAN",
                            decision_id,
                            now,
                            now,
                        ),
                    )
                    conn.execute(
                        "UPDATE tasks SET current_step = ? WHERE id = ?",
                        (step_index, task_id),
                    )
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "action.planned",
                            _json({
                                "action_id": action_id,
                                "step_index": step_index,
                                "action_type": capability,
                                "decision_id": decision_id,
                            }),
                            now,
                        ),
                    )
                    public_action_title = capability_activity_title(capability, "preparing")
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"action:{action_id}:activity",
                        kind="TOOL_ACTIVITY",
                        presentation_state="ACTIVE",
                        title=public_action_title,
                        summary=None,
                        payload={"action_id": action_id, "capability": capability},
                        source_type="ACTION",
                        source_id=action_id,
                        attention_level="QUIET",
                        now=now,
                    )
                    # Keep a durable, user-facing semantic breadcrumb for each
                    # accepted Planner round. This is NOT model chain-of-thought:
                    # it contains only the committed action category and a
                    # bounded operational summary derived from durable state.
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"planner:{task_id}:{planner_call_number}:public-next",
                        kind="PUBLIC_WORKLOG",
                        presentation_state="INFO",
                        title=(
                            f"下一步：{public_action_title}"
                            if planner_call_number == 1
                            else f"根据当前结果，下一步：{public_action_title}"
                        ),
                        summary=(
                            "这一步来自当前已验证状态；完成后会继续更新，不展示模型私有推理。"
                        ),
                        payload={"call_number": planner_call_number, "action_id": action_id},
                        source_type="TASK_RUNTIME",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                    next_phase = "executing"
                    result["action_id"] = action_id

                elif decision_type == "CLARIFY":
                    if clarification_id is None or wait_id is None:
                        raise InvalidPlannerTransitionError("CLARIFY requires clarification_id and wait_id")
                    clarification = decision.get("clarification")
                    assert isinstance(clarification, dict)
                    conn.execute(
                        """
                        INSERT INTO clarifications
                        (id, task_id, decision_id, question, accepts_text, payload_json,
                         status, response_json, contract_version, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, 'pending', NULL, 1, ?, ?)
                        """,
                        (
                            clarification_id,
                            task_id,
                            decision_id,
                            clarification["question"],
                            int(clarification["accepts_text"]),
                            _json(clarification),
                            now,
                            now,
                        ),
                    )
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "clarification.requested",
                            _json({"clarification_id": clarification_id, "decision_id": decision_id}),
                            now,
                        ),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"clarification:{clarification_id}:waiting",
                        kind="WAITING_FOR_USER",
                        presentation_state="NEEDS_USER",
                        title=clarification["question"],
                        summary=None,
                        payload={
                            "clarification_id": clarification_id,
                            "suggested_options": clarification["suggested_options"],
                            "accepts_text": clarification["accepts_text"],
                        },
                        source_type="CLARIFICATION",
                        source_id=clarification_id,
                        attention_level="USER_REQUIRED",
                        now=now,
                    )
                    next_status = "waiting"
                    next_phase = "planning"
                    legacy_wait_reason = "user_input"
                    wait_kind = "CLARIFICATION"
                    wait_target_type = "CLARIFICATION"
                    wait_target_id = clarification_id
                    wait_payload = {"clarification_id": clarification_id}
                    pending_id = clarification_id
                    result["clarification_id"] = clarification_id

                elif decision_type == "WAIT":
                    if wait_id is None:
                        raise InvalidPlannerTransitionError("WAIT requires wait_id")
                    wait = decision.get("wait")
                    assert isinstance(wait, dict)
                    kind = str(wait["kind"])
                    kind_map = {
                        "until_time": "TIME",
                        "provider_event": "PROVIDER_EVENT",
                        "external_condition": "EXTERNAL_CONDITION",
                        "user_input": "CLARIFICATION",
                    }
                    next_status = "waiting"
                    next_phase = "planning"
                    legacy_wait_reason = kind
                    wait_kind = kind_map[kind]
                    wait_payload = wait
                    wake_at = wait.get("resume_at")
                    if kind == "user_input" and pending_id is not None:
                        wait_target_type = "CLARIFICATION"
                        wait_target_id = pending_id
                    result["wait"] = wait

                elif decision_type == "COMPLETE":
                    completion = decision.get("completion")
                    assert isinstance(completion, dict)
                    next_status = "completed"
                    next_phase = "planning"
                    conn.execute(
                        "UPDATE tasks SET result_json = ?, terminal_reason = NULL, finished_at = ? WHERE id = ?",
                        (_json(completion), now, task_id),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="RESULT",
                        presentation_state="COMPLETE",
                        title="任务已完成",
                        summary=completion.get("summary"),
                        payload={"task_id": task_id, "status": "completed"},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                    result["completion"] = completion

                elif decision_type == "STOP":
                    reason = decision.get("stop_reason")
                    next_status = "failed"
                    next_phase = "planning"
                    conn.execute(
                        "UPDATE tasks SET terminal_reason = ?, finished_at = ? WHERE id = ?",
                        (reason, now, task_id),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="FAILURE_NOTE",
                        presentation_state="FAILED",
                        title="任务无法继续",
                        summary=str(reason) if reason is not None else None,
                        payload={"task_id": task_id, "status": "failed"},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="IMPORTANT",
                        now=now,
                    )
                    result["stop_reason"] = reason

                elif decision_type == "CANCEL":
                    cancellation = decision.get("cancellation")
                    assert isinstance(cancellation, dict)
                    reason = str(cancellation["reason"]).strip()
                    next_status = "cancelled"
                    next_phase = "planning"
                    conn.execute(
                        """
                        UPDATE tasks
                        SET terminal_reason = ?, cancel_requested_at = COALESCE(cancel_requested_at, ?),
                            cancel_reason = COALESCE(cancel_reason, ?), finished_at = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        (reason, now, reason, now, now, task_id),
                    )
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (task_id, "task.cancelled_by_planner", _json({"reason": reason}), now),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="FAILURE_NOTE",
                        presentation_state="INFO",
                        title="任务已取消",
                        summary=reason,
                        payload={"task_id": task_id, "status": "cancelled"},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                    result["cancellation"] = cancellation
                else:
                    raise InvalidPlannerTransitionError(f"unsupported PlannerDecision {decision_type}")

                if accepted_user_turns:
                    conn.execute(
                        """
                        UPDATE task_inbox_events
                        SET status = 'CONSUMED', consumed_at = ?
                        WHERE task_id = ? AND seq <= ? AND UPPER(status) = 'ACCEPTED'
                          AND event_type = 'USER_TURN'
                        """,
                        (now, task_id, basis_inbox_seq),
                    )

                conn.execute(
                    "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                    (next_status, now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = ?, plan_json = ?, wait_reason = ?, wait_json = ?,
                        pending_clarification_id = ?, interpreted_goal_summary = ?,
                        current_task_brief = ?, runtime_revision = runtime_revision + 1,
                        wait_id = ?, wait_kind = ?, wait_target_type = ?, wait_target_id = ?,
                        wake_at = ?, block_reason = NULL, block_payload_json = NULL,
                        inbox_watermark = CASE WHEN inbox_watermark > ? THEN inbox_watermark ELSE ? END,
                        updated_at = ?
                    WHERE task_id = ?
                    """,
                    (
                        next_phase,
                        _json(plan),
                        legacy_wait_reason,
                        _json(wait_payload) if wait_payload is not None else None,
                        pending_id,
                        str(decision["interpreted_goal_summary"]),
                        brief,
                        wait_id if next_status == "waiting" else None,
                        wait_kind if next_status == "waiting" else None,
                        wait_target_type if next_status == "waiting" else None,
                        wait_target_id if next_status == "waiting" else None,
                        wake_at if next_status == "waiting" else None,
                        basis_inbox_seq,
                        basis_inbox_seq,
                        now,
                        task_id,
                    ),
                )
                conn.commit()
                return {
                    "decision_id": decision_id,
                    "sequence": sequence,
                    "decision_type": decision_type,
                    "created_at": now,
                    **result,
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    @staticmethod
    def _content_digest(content: Dict[str, Any]) -> str:
        return hashlib.sha256(canonical_json(content).encode("utf-8")).hexdigest()

    @staticmethod
    def _binding_digest(binding: Dict[str, Any]) -> str:
        return hashlib.sha256(canonical_json(binding).encode("utf-8")).hexdigest()

    def create_artifact(
        self,
        *,
        task_id: str,
        artifact_id: str,
        revision_id: str,
        kind: str,
        title: str,
        content: Dict[str, Any],
        created_by: str,
        created_by_action_id: Optional[str] = None,
        source_decision_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        now = utc_now()
        digest = self._content_digest(content)
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                if conn.execute("SELECT 1 FROM tasks WHERE id = ?", (task_id,)).fetchone() is None:
                    raise KeyError(task_id)
                conn.execute(
                    """
                    INSERT INTO artifacts
                    (id, task_id, kind, title, current_revision_id, final_revision_id,
                     created_by_action_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, NULL, NULL, ?, ?, ?)
                    """,
                    (artifact_id, task_id, kind, title, created_by_action_id, now, now),
                )
                conn.execute(
                    """
                    INSERT INTO artifact_revisions
                    (id, artifact_id, revision_number, content_json, content_ref, content_digest,
                     created_by, source_event_id, source_action_id, source_decision_id, created_at)
                    VALUES (?, ?, 1, ?, NULL, ?, ?, NULL, ?, ?, ?)
                    """,
                    (
                        revision_id,
                        artifact_id,
                        canonical_json(content),
                        digest,
                        created_by,
                        created_by_action_id,
                        source_decision_id,
                        now,
                    ),
                )
                conn.execute(
                    "UPDATE artifacts SET current_revision_id = ? WHERE id = ?",
                    (revision_id, artifact_id),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"artifact:{artifact_id}:current",
                    kind="ARTIFACT",
                    presentation_state="COMPLETE",
                    title=title,
                    summary=None,
                    payload={
                        "artifact_id": artifact_id,
                        "artifact_kind": kind,
                        "revision_id": revision_id,
                        "revision_number": 1,
                    },
                    source_type="ARTIFACT",
                    source_id=artifact_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "artifact.created", _json({"artifact_id": artifact_id, "revision_id": revision_id, "kind": kind}), now),
                )
                conn.commit()
                return self.get_artifact(task_id=task_id, artifact_id=artifact_id)  # type: ignore[return-value]
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def get_artifact(self, *, task_id: str, artifact_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                artifact = conn.execute(
                    "SELECT * FROM artifacts WHERE id = ? AND task_id = ?",
                    (artifact_id, task_id),
                ).fetchone()
                if artifact is None:
                    return None
                revisions = conn.execute(
                    "SELECT * FROM artifact_revisions WHERE artifact_id = ? ORDER BY revision_number",
                    (artifact_id,),
                ).fetchall()
            finally:
                self._close(conn)
        return {
            "artifact_id": artifact["id"],
            "task_id": artifact["task_id"],
            "kind": artifact["kind"],
            "title": artifact["title"],
            "current_revision_id": artifact["current_revision_id"],
            "final_revision_id": artifact["final_revision_id"],
            "created_at": artifact["created_at"],
            "updated_at": artifact["updated_at"],
            "revisions": [
                {
                    "revision_id": row["id"],
                    "revision_number": int(row["revision_number"]),
                    "content": _loads(row["content_json"], None),
                    "content_ref": row["content_ref"],
                    "content_digest": row["content_digest"],
                    "created_by": row["created_by"],
                    "source_event_id": row["source_event_id"],
                    "created_at": row["created_at"],
                }
                for row in revisions
            ],
        }

    def create_artifact_revision(
        self,
        *,
        task_id: str,
        artifact_id: str,
        revision_id: str,
        expected_revision_id: str,
        content: Dict[str, Any],
        created_by: str,
        event_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        now = utc_now()
        digest = self._content_digest(content)
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                artifact = conn.execute(
                    "SELECT * FROM artifacts WHERE id = ? AND task_id = ?",
                    (artifact_id, task_id),
                ).fetchone()
                if artifact is None:
                    raise KeyError(artifact_id)
                if event_id is not None:
                    replay = conn.execute(
                        "SELECT * FROM artifact_revisions WHERE artifact_id = ? AND source_event_id = ?",
                        (artifact_id, event_id),
                    ).fetchone()
                    if replay is not None:
                        same = replay["id"] == revision_id and replay["content_digest"] == digest
                        if not same:
                            raise StaleArtifactRevisionError(
                                "artifact edit event_id is already bound to different revision content"
                            )
                        conn.commit()
                        value = self.get_artifact(task_id=task_id, artifact_id=artifact_id)
                        assert value is not None
                        return {**value, "idempotent_replay": True}
                if artifact["current_revision_id"] != expected_revision_id:
                    raise StaleArtifactRevisionError(
                        f"artifact current revision is {artifact['current_revision_id']}"
                    )
                previous = conn.execute(
                    "SELECT * FROM artifact_revisions WHERE id = ? AND artifact_id = ?",
                    (expected_revision_id, artifact_id),
                ).fetchone()
                if previous is None:
                    raise KeyError(expected_revision_id)
                next_number = int(previous["revision_number"]) + 1
                conn.execute(
                    """
                    INSERT INTO artifact_revisions
                    (id, artifact_id, revision_number, content_json, content_ref, content_digest,
                     created_by, source_event_id, source_action_id, source_decision_id, created_at)
                    VALUES (?, ?, ?, ?, NULL, ?, ?, ?, NULL, NULL, ?)
                    """,
                    (
                        revision_id,
                        artifact_id,
                        next_number,
                        canonical_json(content),
                        digest,
                        created_by,
                        event_id,
                        now,
                    ),
                )
                conn.execute(
                    "UPDATE artifacts SET current_revision_id = ?, updated_at = ? WHERE id = ?",
                    (revision_id, now, artifact_id),
                )

                invalidated_actions: List[str] = []
                requests = conn.execute(
                    """
                    SELECT air.*, a.status AS action_status
                    FROM action_input_requests air
                    JOIN actions a ON a.id = air.action_id
                    WHERE air.task_id = ? AND air.attempt_id IS NULL
                      AND UPPER(air.status) IN ('PENDING','ANSWERED')
                    """,
                    (task_id,),
                ).fetchall()
                for request in requests:
                    binding = _loads(request["binding_json"], {})
                    revisions = binding.get("artifact_revisions", [])
                    if expected_revision_id not in revisions:
                        continue
                    has_attempt = conn.execute(
                        "SELECT 1 FROM action_attempts WHERE action_id = ? LIMIT 1",
                        (request["action_id"],),
                    ).fetchone() is not None
                    if has_attempt:
                        # An admitted dispatch stays bound to the historical
                        # approved revision; a later edit cannot rewrite it.
                        continue
                    conn.execute(
                        """
                        UPDATE action_input_requests
                        SET status = 'CANCELLED', response_json = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        (_json({"reason": "artifact_revision_changed", "new_revision_id": revision_id}), now, request["id"]),
                    )
                    conn.execute(
                        """
                        UPDATE task_inbox_events
                        SET status = 'IGNORED', ignore_reason = 'artifact_revision_changed', consumed_at = ?
                        WHERE task_id = ? AND target_type = 'ACTION_INPUT' AND target_id = ?
                          AND UPPER(status) = 'ACCEPTED'
                        """,
                        (now, task_id, request["id"]),
                    )
                    if str(request["action_status"]).lower() in {"pending", "planned"}:
                        conn.execute(
                            "UPDATE actions SET status = 'cancelled', error_text = ?, updated_at = ? WHERE id = ?",
                            ("artifact revision changed before dispatch", now, request["action_id"]),
                        )
                        invalidated_actions.append(str(request["action_id"]))
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"action-input:{request['id']}:waiting",
                        kind="WAITING_FOR_USER",
                        presentation_state="INFO",
                        title="内容已修改",
                        summary="旧确认已失效，需要针对新内容重新确认。",
                        payload={"input_request_id": request["id"], "stale": True},
                        source_type="ACTION_INPUT",
                        source_id=str(request["id"]),
                        attention_level="QUIET",
                        now=now,
                    )

                if invalidated_actions:
                    conn.execute("UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?", (now, task_id))
                    conn.execute(
                        """
                        UPDATE task_runtime
                        SET phase = 'planning', runtime_revision = runtime_revision + 1,
                            wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                            wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                        WHERE task_id = ?
                        """,
                        (now, task_id),
                    )

                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"artifact:{artifact_id}:current",
                    kind="ARTIFACT",
                    presentation_state="COMPLETE",
                    title=str(artifact["title"]),
                    summary=None,
                    payload={
                        "artifact_id": artifact_id,
                        "artifact_kind": artifact["kind"],
                        "revision_id": revision_id,
                        "revision_number": next_number,
                    },
                    source_type="ARTIFACT",
                    source_id=artifact_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "artifact.revised", _json({"artifact_id": artifact_id, "from_revision_id": expected_revision_id, "revision_id": revision_id, "invalidated_actions": invalidated_actions}), now),
                )
                conn.commit()
                value = self.get_artifact(task_id=task_id, artifact_id=artifact_id)
                assert value is not None
                return {**value, "idempotent_replay": False}
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def create_action_input_request(
        self,
        *,
        input_request_id: str,
        task_id: str,
        action_id: str,
        attempt_id: Optional[str],
        prompt: str,
        suggested_options: List[Dict[str, Any]],
        accepts_text: bool,
        reason: str,
        binding: Dict[str, Any],
        source_continuation_ref: Optional[str] = None,
    ) -> Dict[str, Any]:
        now = utc_now()
        digest = self._binding_digest(binding)
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                if action is None:
                    raise KeyError(action_id)
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if (task is None or task["cancel_requested_at"] is not None
                        or str(task["status"]).lower() in {"completed", "failed", "cancelled"}
                        or action["interrupt_requested_at"] is not None
                        or str(action["status"]).lower() not in {"pending", "planned", "dispatched", "executing"}):
                    raise ActionAdmissionSupersededError("Action can no longer request user input")
                if binding.get("action_id") != action_id or binding.get("capability_id") != action["action_type"]:
                    raise InvalidPlannerTransitionError("ActionInput binding does not match Action identity")
                if attempt_id is None and not isinstance(binding.get("dispatch_digest"), str):
                    raise InvalidPlannerTransitionError(
                        "pre-dispatch ActionInput must bind the exact dispatch digest"
                    )
                pending = conn.execute(
                    "SELECT * FROM action_input_requests WHERE action_id = ? AND status = 'PENDING'",
                    (action_id,),
                ).fetchone()
                if pending is not None:
                    if pending["binding_digest"] != digest or pending["attempt_id"] != attempt_id:
                        raise StaleActionInputError("another ActionInput already owns this Action")
                    conn.commit()
                    return self.get_action_input_request(pending["id"])  # type: ignore[return-value]
                if attempt_id is None and str(action["status"]).lower() == "executing":
                    raise ActionAdmissionSupersededError("Action already started before confirmation admission")
                for revision_id in binding.get("artifact_revisions", []):
                    revision = conn.execute(
                        """
                        SELECT ar.id FROM artifact_revisions ar
                        JOIN artifacts a ON a.id = ar.artifact_id
                        WHERE ar.id = ? AND a.task_id = ?
                        """,
                        (revision_id, task_id),
                    ).fetchone()
                    if revision is None:
                        raise InvalidPlannerTransitionError("ActionInput binding references unknown ArtifactRevision")
                if attempt_id is not None:
                    attempt = conn.execute(
                        "SELECT * FROM action_attempts WHERE id = ? AND action_id = ?",
                        (attempt_id, action_id),
                    ).fetchone()
                    if attempt is None or str(attempt["status"]).upper() != "IN_FLIGHT":
                        raise InvalidPlannerTransitionError("ActionInput Attempt is not resumable")
                    conn.execute(
                        "UPDATE action_attempts SET status = 'WAITING_INPUT', updated_at = ? WHERE id = ?",
                        (now, attempt_id),
                    )
                conn.execute(
                    """
                    INSERT INTO action_input_requests
                    (id, task_id, action_id, attempt_id, prompt, suggested_options_json,
                     response_schema_json, accepts_text, reason, status, response_json,
                     answered_by_event_id, source_continuation_ref, binding_json, binding_digest,
                     contract_version, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, 'PENDING', NULL, NULL, ?, ?, ?, 1, ?, ?)
                    """,
                    (
                        input_request_id,
                        task_id,
                        action_id,
                        attempt_id,
                        prompt,
                        _json(suggested_options),
                        int(accepts_text),
                        reason,
                        source_continuation_ref,
                        canonical_json(binding),
                        digest,
                        now,
                        now,
                    ),
                )
                wait_id = f"input:{input_request_id}"
                conn.execute("UPDATE tasks SET status = 'waiting', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'executing', runtime_revision = runtime_revision + 1,
                        wait_reason = 'action_input', wait_json = ?, wait_id = ?,
                        wait_kind = 'ACTION_INPUT', wait_target_type = 'ACTION_INPUT',
                        wait_target_id = ?, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (_json({"input_request_id": input_request_id}), wait_id, input_request_id, now, task_id),
                )
                upsert_timeline_item(
                    conn, task_id=task_id, source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY", presentation_state="NEEDS_USER",
                    title="等待你确认" if attempt_id is None else "等待你补充信息",
                    summary=None, payload={"action_id": action_id, "capability": action["action_type"]},
                    source_type="ACTION", source_id=action_id, attention_level="QUIET", now=now,
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action-input:{input_request_id}:waiting",
                    kind="WAITING_FOR_USER",
                    presentation_state="NEEDS_USER",
                    title=prompt,
                    summary=None,
                    payload={"input_request_id": input_request_id, "suggested_options": suggested_options, "accepts_text": accepts_text},
                    source_type="ACTION_INPUT",
                    source_id=input_request_id,
                    attention_level="USER_REQUIRED",
                    now=now,
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action_input.requested", _json({"input_request_id": input_request_id, "action_id": action_id, "attempt_id": attempt_id, "binding_digest": digest}), now),
                )
                conn.commit()
                return self.get_action_input_request(input_request_id)  # type: ignore[return-value]
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def get_clarification(self, clarification_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT * FROM clarifications WHERE id = ?",
                    (clarification_id,),
                ).fetchone()
            finally:
                self._close(conn)
        if row is None:
            return None
        return {
            "clarification_id": row["id"],
            "task_id": row["task_id"],
            "decision_id": row["decision_id"],
            "status": row["status"],
            "payload": _loads(row["payload_json"], {}),
            "response": _loads(row["response_json"], None),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def admit_clarification_response(
        self,
        *,
        task_id: str,
        clarification_id: str,
        event_id: str,
        response: Dict[str, Any],
    ) -> Dict[str, Any]:
        clarification = self.get_clarification(clarification_id)
        if clarification is None or clarification["task_id"] != task_id:
            raise KeyError(clarification_id)
        payload = clarification["payload"]
        option_id = response.get("option_id")
        text = response.get("text")
        content_text: Optional[str] = None
        if option_id is not None:
            if not isinstance(option_id, str):
                raise ValueError("clarification option_id must be a string")
            match = next(
                (item for item in payload.get("suggested_options", []) if item.get("id") == option_id),
                None,
            )
            if match is None:
                raise ValueError("clarification option_id is not one of the suggested options")
            content_text = str(match["label"])
        elif text is not None:
            if not payload.get("accepts_text"):
                raise ValueError("clarification does not accept free text")
            if not isinstance(text, str) or not text.strip():
                raise ValueError("clarification text response must be non-empty")
            content_text = text.strip()
        else:
            raise ValueError("clarification response requires option_id or text")

        normalized_payload = {
            "content": {"kind": "text", "text": content_text},
            "reply_context": {
                "clarification_id": clarification_id,
                "selected_option_id": option_id,
            },
        }
        existing = self.get_inbox_event(event_id)
        if existing is not None:
            return self.admit_inbox_event(
                task_id=task_id,
                event_id=event_id,
                event_type="USER_TURN",
                source="user",
                target_type="CLARIFICATION",
                target_id=clarification_id,
                payload=normalized_payload,
            )
        if str(clarification["status"]).lower() != "pending":
            raise InvalidPlannerTransitionError("Clarification is no longer pending")
        return self.admit_inbox_event(
            task_id=task_id,
            event_id=event_id,
            event_type="USER_TURN",
            source="user",
            target_type="CLARIFICATION",
            target_id=clarification_id,
            payload=normalized_payload,
        )

    def get_action_input_request(self, input_request_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute("SELECT * FROM action_input_requests WHERE id = ?", (input_request_id,)).fetchone()
            finally:
                self._close(conn)
        if row is None:
            return None
        return {
            "input_request_id": row["id"],
            "task_id": row["task_id"],
            "action_id": row["action_id"],
            "attempt_id": row["attempt_id"],
            "prompt": row["prompt"],
            "suggested_options": _loads(row["suggested_options_json"], []),
            "accepts_text": bool(row["accepts_text"]),
            "reason": row["reason"],
            "status": row["status"],
            "response": _loads(row["response_json"], None),
            "source_continuation_ref": row["source_continuation_ref"],
            "binding": _loads(row["binding_json"], {}),
            "binding_digest": row["binding_digest"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def pending_action_input_for_action(self, action_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    """
                    SELECT id FROM action_input_requests
                    WHERE action_id = ? AND UPPER(status) = 'PENDING'
                    ORDER BY created_at DESC LIMIT 1
                    """,
                    (action_id,),
                ).fetchone()
            finally:
                self._close(conn)
        return None if row is None else self.get_action_input_request(str(row["id"]))

    def latest_approved_predispatch_input(self, action_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """
                    SELECT id, response_json FROM action_input_requests
                    WHERE action_id = ? AND attempt_id IS NULL AND UPPER(status) = 'ANSWERED'
                    ORDER BY updated_at DESC
                    """,
                    (action_id,),
                ).fetchall()
            finally:
                self._close(conn)
        for row in rows:
            response = _loads(row["response_json"], {})
            if response.get("approved") is True:
                return self.get_action_input_request(str(row["id"]))
        return None

    def admit_action_input_response(
        self,
        *,
        task_id: str,
        input_request_id: str,
        event_id: str,
        binding_digest: str,
        response: Dict[str, Any],
    ) -> Dict[str, Any]:
        request = self.get_action_input_request(input_request_id)
        if request is None or request["task_id"] != task_id:
            raise KeyError(input_request_id)
        payload = {"binding_digest": binding_digest, "response": response}
        existing = self.get_inbox_event(event_id)
        if existing is not None:
            return self.admit_inbox_event(
                task_id=task_id,
                event_id=event_id,
                event_type="ACTION_INPUT_RESPONSE",
                source="user",
                target_type="ACTION_INPUT",
                target_id=input_request_id,
                payload=payload,
            )
        if request["status"] != "PENDING":
            raise StaleActionInputError("ActionInputRequest is no longer pending")
        if request["binding_digest"] != binding_digest:
            raise StaleActionInputError("ActionInput binding digest is stale")
        if request["attempt_id"] is None and not isinstance(response.get("approved"), bool):
            raise ValueError("pre-dispatch ActionInput response requires approved=true|false")
        return self.admit_inbox_event(
            task_id=task_id,
            event_id=event_id,
            event_type="ACTION_INPUT_RESPONSE",
            source="user",
            target_type="ACTION_INPUT",
            target_id=input_request_id,
            payload=payload,
        )

    def consume_action_input_response(self, *, event_id: str) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                event = conn.execute("SELECT * FROM task_inbox_events WHERE event_id = ?", (event_id,)).fetchone()
                if event is None:
                    raise KeyError(event_id)
                if event["event_type"] != "ACTION_INPUT_RESPONSE" or event["target_type"] != "ACTION_INPUT":
                    raise InvalidPlannerTransitionError("event is not an ActionInput response")
                request = conn.execute("SELECT * FROM action_input_requests WHERE id = ?", (event["target_id"],)).fetchone()
                if request is None:
                    raise KeyError(event["target_id"])
                if str(event["status"]).upper() == "CONSUMED":
                    conn.commit()
                    return self.get_action_input_request(str(request["id"]))  # type: ignore[return-value]
                if str(event["status"]).upper() != "ACCEPTED" or str(request["status"]).upper() != "PENDING":
                    raise StaleActionInputError("ActionInput response is stale")
                payload = _loads(event["payload_json"], {})
                if payload.get("binding_digest") != request["binding_digest"]:
                    raise StaleActionInputError("ActionInput response binding changed")
                response = payload.get("response")
                if not isinstance(response, dict):
                    raise ValueError("ActionInput response must be an object")
                approved = response.get("approved")
                if request["attempt_id"] is None and not isinstance(approved, bool):
                    raise ValueError("pre-dispatch ActionInput response requires approved=true|false")
                task_id = str(request["task_id"])
                action_id = str(request["action_id"])
                attempt_id = request["attempt_id"]
                action = conn.execute("SELECT * FROM actions WHERE id = ?", (action_id,)).fetchone()
                runtime = conn.execute("SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)).fetchone()
                if action is None or runtime is None:
                    raise KeyError(action_id)
                if runtime["wait_target_id"] != request["id"] or runtime["wait_kind"] != "ACTION_INPUT":
                    raise StaleActionInputError("Task no longer waits for this ActionInputRequest")

                conn.execute(
                    """
                    UPDATE action_input_requests
                    SET status = 'ANSWERED', response_json = ?, answered_by_event_id = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (_json(response), event_id, now, request["id"]),
                )
                conn.execute("UPDATE task_inbox_events SET status = 'CONSUMED', consumed_at = ? WHERE event_id = ?", (now, event_id))

                if approved is False:
                    if attempt_id is not None:
                        conn.execute(
                            """
                            UPDATE action_attempts
                            SET status = 'FINISHED', latest_outcome = 'CANCELLED', error_text = ?,
                                finished_at = ?, updated_at = ?
                            WHERE id = ?
                            """,
                            ("user rejected required input", now, now, attempt_id),
                        )
                    conn.execute("UPDATE actions SET status = 'cancelled', error_text = ?, updated_at = ? WHERE id = ?", ("user rejected required input", now, action_id))
                    upsert_timeline_item(
                        conn, task_id=task_id, source_key=f"action:{action_id}:activity",
                        kind="TOOL_ACTIVITY", presentation_state="CANCELLED",
                        title=capability_activity_title(str(action["action_type"]), "cancelled"),
                        summary=None, payload={"action_id": action_id, "capability": action["action_type"]},
                        source_type="ACTION", source_id=action_id, attention_level="QUIET", now=now,
                    )
                    next_phase = "planning"
                    summary = "你取消了这一步，小卷会重新判断接下来怎么处理。"
                else:
                    if attempt_id is not None:
                        conn.execute(
                            """
                            UPDATE action_attempts
                            SET status = 'IN_FLIGHT', source_round = source_round + 1,
                                approved_input_request_id = ?, updated_at = ?
                            WHERE id = ?
                            """,
                            (request["id"], now, attempt_id),
                        )
                        conn.execute("UPDATE actions SET status = 'executing', updated_at = ? WHERE id = ?", (now, action_id))
                    else:
                        conn.execute("UPDATE actions SET status = 'pending', updated_at = ? WHERE id = ?", (now, action_id))
                    next_phase = "executing"
                    summary = "已收到你的确认，继续执行。"

                conn.execute("UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = ?, runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (next_phase, now, task_id),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action-input:{request['id']}:waiting",
                    kind="WAITING_FOR_USER",
                    presentation_state="COMPLETE" if approved is not False else "INFO",
                    title=str(request["prompt"]),
                    summary=summary,
                    payload={"input_request_id": request["id"], "answered": True, "approved": approved},
                    source_type="ACTION_INPUT",
                    source_id=str(request["id"]),
                    attention_level="QUIET",
                    now=now,
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action_input.answered", _json({"input_request_id": request["id"], "event_id": event_id, "approved": approved}), now),
                )
                conn.commit()
                return self.get_action_input_request(str(request["id"]))  # type: ignore[return-value]
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def control_interrupt_candidate_task_ids(self) -> List[str]:
        """Tasks whose accepted UserTurn may urgently control an active Attempt."""

        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """
                    SELECT DISTINCT a.task_id
                    FROM actions a
                    JOIN tasks t ON t.id = a.task_id
                    JOIN action_attempts aa ON aa.action_id = a.id
                    WHERE LOWER(t.status) NOT IN ('completed','failed','cancelled')
                      AND t.cancel_requested_at IS NULL
                      AND LOWER(a.status) IN ('executing','reconciling')
                      AND (
                        UPPER(aa.status) IN ('IN_FLIGHT','WAITING_INPUT')
                        OR aa.latest_outcome = 'UNKNOWN'
                      )
                      AND aa.attempt_number = (
                        SELECT MAX(aa2.attempt_number)
                        FROM action_attempts aa2
                        WHERE aa2.action_id = a.id
                      )
                      AND EXISTS (
                        SELECT 1 FROM task_inbox_events e
                        WHERE e.task_id = a.task_id
                          AND e.event_type = 'USER_TURN'
                          AND UPPER(e.status) = 'ACCEPTED'
                      )
                    ORDER BY a.task_id
                    """
                ).fetchall()
            finally:
                self._close(conn)
        return [str(row["task_id"]) for row in rows]

    def control_interrupt_basis(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Return one durable basis for narrow control-intent classification.

        Only Tasks with a real ActionAttempt that may already have external
        effects are eligible. The classifier sees ordered accepted UserTurns;
        Planner/Tool authority is not exposed here.
        """

        with self._lock:
            conn = self._connect()
            try:
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute("SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)).fetchone()
                if task is None or runtime is None:
                    raise KeyError(task_id)
                if str(task["status"]).lower() in {"completed", "failed", "cancelled"}:
                    return None
                if task["cancel_requested_at"] is not None:
                    return None
                action = conn.execute(
                    """
                    SELECT * FROM actions
                    WHERE task_id = ? AND LOWER(status) IN ('executing','reconciling')
                    ORDER BY step_index ASC
                    LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                if action is None:
                    return None
                attempt = conn.execute(
                    "SELECT * FROM action_attempts WHERE action_id = ? ORDER BY attempt_number DESC LIMIT 1",
                    (action["id"],),
                ).fetchone()
                if attempt is None:
                    return None
                attempt_status = str(attempt["status"]).upper()
                if attempt_status not in {"IN_FLIGHT", "WAITING_INPUT"} and attempt["latest_outcome"] != "UNKNOWN":
                    return None
                turns = conn.execute(
                    """
                    SELECT * FROM task_inbox_events
                    WHERE task_id = ? AND event_type = 'USER_TURN' AND UPPER(status) = 'ACCEPTED'
                    ORDER BY seq ASC
                    """,
                    (task_id,),
                ).fetchall()
                if not turns:
                    return None
                basis_seq = max(int(row["seq"]) for row in turns)
                already = conn.execute(
                    "SELECT 1 FROM control_interrupt_decisions WHERE attempt_id = ? AND basis_inbox_seq = ?",
                    (attempt["id"], basis_seq),
                ).fetchone()
                if already is not None:
                    return None
                return {
                    "task_id": task_id,
                    "goal": str(task["goal"]),
                    "current_task_brief": runtime["current_task_brief"] or runtime["interpreted_goal_summary"],
                    "runtime_revision": int(runtime["runtime_revision"]),
                    "basis_inbox_seq": basis_seq,
                    "action": self._action_dict(action),
                    "attempt": self._attempt_dict(attempt),
                    "user_turns": [
                        {
                            "seq": int(row["seq"]),
                            "event_id": str(row["event_id"]),
                            "text": str((_loads(row["payload_json"], {}).get("content") or {}).get("text") or ""),
                            "received_at": row["received_at"],
                        }
                        for row in turns
                    ],
                }
            finally:
                self._close(conn)

    def apply_control_interrupt_decision(
        self,
        *,
        decision_id: str,
        task_id: str,
        action_id: str,
        attempt_id: str,
        expected_runtime_revision: int,
        basis_inbox_seq: int,
        user_event_ids: List[str],
        intent: str,
        confidence: str,
        reason: str,
    ) -> Dict[str, Any]:
        if intent not in {"NONE", "CANCEL_TASK", "INTERRUPT_CURRENT_ACTION"}:
            raise ValueError("invalid control interrupt intent")
        if confidence not in {"HIGH", "LOW"}:
            raise ValueError("invalid control interrupt confidence")
        if not reason.strip():
            raise ValueError("control interrupt reason must not be empty")
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                existing = conn.execute(
                    "SELECT * FROM control_interrupt_decisions WHERE attempt_id = ? AND basis_inbox_seq = ?",
                    (attempt_id, basis_inbox_seq),
                ).fetchone()
                if existing is not None:
                    conn.commit()
                    return self._control_interrupt_dict(existing)

                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute("SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)).fetchone()
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                attempt = conn.execute("SELECT * FROM action_attempts WHERE id = ? AND action_id = ?", (attempt_id, action_id)).fetchone()
                if task is None or runtime is None or action is None or attempt is None:
                    raise KeyError(attempt_id)

                latest_attempt = conn.execute(
                    "SELECT id FROM action_attempts WHERE action_id = ? ORDER BY attempt_number DESC LIMIT 1",
                    (action_id,),
                ).fetchone()
                latest_turn = conn.execute(
                    """
                    SELECT MAX(seq) AS seq FROM task_inbox_events
                    WHERE task_id = ? AND event_type = 'USER_TURN' AND UPPER(status) = 'ACCEPTED'
                    """,
                    (task_id,),
                ).fetchone()
                current_seq = int(latest_turn["seq"]) if latest_turn is not None and latest_turn["seq"] is not None else 0
                attempt_eligible = (
                    (str(attempt["status"]).upper() in {"IN_FLIGHT", "WAITING_INPUT"} or attempt["latest_outcome"] == "UNKNOWN")
                    and latest_attempt is not None
                    and str(latest_attempt["id"]) == attempt_id
                    and str(action["status"]).lower() in {"executing", "reconciling"}
                )
                stale = (
                    int(runtime["runtime_revision"]) != int(expected_runtime_revision)
                    or current_seq != int(basis_inbox_seq)
                    or not attempt_eligible
                    or str(task["status"]).lower() in {"completed", "failed", "cancelled"}
                    or task["cancel_requested_at"] is not None
                )
                status = "STALE" if stale else "APPLIED"
                effective_intent = intent if confidence == "HIGH" else "NONE"
                conn.execute(
                    """
                    INSERT INTO control_interrupt_decisions
                    (id, task_id, action_id, attempt_id, basis_runtime_revision,
                     basis_inbox_seq, user_event_ids_json, intent, confidence,
                     reason, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        decision_id,
                        task_id,
                        action_id,
                        attempt_id,
                        int(expected_runtime_revision),
                        int(basis_inbox_seq),
                        _json(list(user_event_ids)),
                        intent,
                        confidence,
                        reason.strip(),
                        status,
                        now,
                    ),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "control_interrupt.stale" if stale else "control_interrupt.classified",
                        _json({
                            "decision_id": decision_id,
                            "action_id": action_id,
                            "attempt_id": attempt_id,
                            "basis_inbox_seq": basis_inbox_seq,
                            "intent": intent,
                            "confidence": confidence,
                            "effective_intent": effective_intent if not stale else "NONE",
                        }),
                        now,
                    ),
                )
                if stale:
                    conn.commit()
                    row = conn.execute("SELECT * FROM control_interrupt_decisions WHERE id = ?", (decision_id,)).fetchone()
                    assert row is not None
                    return self._control_interrupt_dict(row)

                if effective_intent == "INTERRUPT_CURRENT_ACTION":
                    conn.execute(
                        "UPDATE actions SET interrupt_requested_at = COALESCE(interrupt_requested_at, ?), interrupt_reason = ?, updated_at = ? WHERE id = ?",
                        (now, reason.strip(), now, action_id),
                    )
                    conn.execute(
                        "UPDATE action_input_requests SET status = 'CANCELLED', updated_at = ? WHERE action_id = ? AND UPPER(status) = 'PENDING'",
                        (now, action_id),
                    )
                    conn.execute(
                        "UPDATE task_runtime SET runtime_revision = runtime_revision + 1, updated_at = ? WHERE task_id = ?",
                        (now, task_id),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"action:{action_id}:interrupt",
                        kind="PUBLIC_WORKLOG",
                        presentation_state="ACTIVE",
                        title="正在停止当前操作",
                        summary="已收到你的新要求；当前操作如果已经发出，会先确认实际状态再继续。",
                        payload={"action_id": action_id, "attempt_id": attempt_id},
                        source_type="ACTION",
                        source_id=action_id,
                        attention_level="QUIET",
                        now=now,
                    )
                elif effective_intent == "CANCEL_TASK":
                    # The same durable user turns caused the cancellation, so
                    # consume them in this transaction instead of leaving
                    # terminal Tasks with orphaned ACCEPTED input.
                    for event_id in user_event_ids:
                        conn.execute(
                            """
                            UPDATE task_inbox_events
                            SET status = 'CONSUMED', consumed_at = ?
                            WHERE event_id = ? AND task_id = ? AND event_type = 'USER_TURN'
                              AND UPPER(status) = 'ACCEPTED'
                            """,
                            (now, event_id, task_id),
                        )
                    conn.execute(
                        "UPDATE actions SET interrupt_requested_at = COALESCE(interrupt_requested_at, ?), interrupt_reason = ?, updated_at = ? WHERE id = ?",
                        (now, reason.strip(), now, action_id),
                    )
                    conn.execute(
                        "UPDATE action_input_requests SET status = 'CANCELLED', updated_at = ? WHERE action_id = ? AND UPPER(status) = 'PENDING'",
                        (now, action_id),
                    )
                    conn.execute(
                        "UPDATE tasks SET cancel_requested_at = COALESCE(cancel_requested_at, ?), cancel_reason = ?, updated_at = ? WHERE id = ?",
                        (now, reason.strip(), now, task_id),
                    )
                    conn.execute(
                        "UPDATE task_runtime SET runtime_revision = runtime_revision + 1, updated_at = ? WHERE task_id = ?",
                        (now, task_id),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:cancellation",
                        kind="PUBLIC_WORKLOG",
                        presentation_state="ACTIVE",
                        title="正在安全停止任务",
                        summary="当前操作已经开始，需要先确认外部状态后结束任务。",
                        payload={"task_id": task_id, "action_id": action_id, "attempt_id": attempt_id},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                conn.commit()
                row = conn.execute("SELECT * FROM control_interrupt_decisions WHERE id = ?", (decision_id,)).fetchone()
                assert row is not None
                return self._control_interrupt_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def control_interrupt_decisions(self, task_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    "SELECT * FROM control_interrupt_decisions WHERE task_id = ? ORDER BY created_at, id",
                    (task_id,),
                ).fetchall()
            finally:
                self._close(conn)
        return [self._control_interrupt_dict(row) for row in rows]

    def admit_cancel_request(self, *, task_id: str, event_id: str, reason: Optional[str]) -> Dict[str, Any]:
        return self.admit_inbox_event(
            task_id=task_id,
            event_id=event_id,
            event_type="CANCEL_REQUEST",
            source="user",
            target_type="TASK",
            target_id=task_id,
            payload={"reason": reason},
        )

    def consume_cancel_request(self, *, event_id: str) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                event = conn.execute("SELECT * FROM task_inbox_events WHERE event_id = ?", (event_id,)).fetchone()
                if event is None or event["event_type"] != "CANCEL_REQUEST":
                    raise KeyError(event_id)
                task_id = str(event["task_id"])
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute("SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)).fetchone()
                if task is None or runtime is None:
                    raise KeyError(task_id)
                if str(event["status"]).upper() == "CONSUMED":
                    conn.commit()
                    return self._task_dict(task)
                if str(event["status"]).upper() != "ACCEPTED":
                    raise InvalidPlannerTransitionError("cancel event is not consumable")
                payload = _loads(event["payload_json"], {})
                reason = payload.get("reason")
                open_action = conn.execute(
                    """
                    SELECT * FROM actions WHERE task_id = ? AND LOWER(status) IN
                      ('pending','planned','dispatched','executing','verifying','reconciling','retry_wait')
                    ORDER BY step_index LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                attempt = None
                if open_action is not None:
                    attempt = conn.execute(
                        "SELECT * FROM action_attempts WHERE action_id = ? ORDER BY attempt_number DESC LIMIT 1",
                        (open_action["id"],),
                    ).fetchone()
                in_flight_or_ambiguous = (
                    attempt is not None
                    and (
                        str(attempt["status"]).upper() in {"IN_FLIGHT", "WAITING_INPUT"}
                        or attempt["latest_outcome"] == "UNKNOWN"
                    )
                )
                conn.execute("UPDATE task_inbox_events SET status = 'CONSUMED', consumed_at = ? WHERE event_id = ?", (now, event_id))
                if in_flight_or_ambiguous:
                    conn.execute(
                        "UPDATE tasks SET cancel_requested_at = ?, cancel_reason = ?, updated_at = ? WHERE id = ?",
                        (now, reason, now, task_id),
                    )
                    conn.execute(
                        "UPDATE task_runtime SET runtime_revision = runtime_revision + 1, updated_at = ? WHERE task_id = ?",
                        (now, task_id),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:cancellation",
                        kind="PUBLIC_WORKLOG",
                        presentation_state="ACTIVE",
                        title="正在安全停止任务",
                        summary="当前操作已经开始，需要先确认外部状态，避免重复或误取消。",
                        payload={"task_id": task_id, "cancel_requested": True},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                    terminal = False
                else:
                    if open_action is not None:
                        conn.execute("UPDATE actions SET status = 'cancelled', error_text = ?, updated_at = ? WHERE id = ?", (reason or "task cancelled", now, open_action["id"]))
                    conn.execute("UPDATE clarifications SET status = 'cancelled', updated_at = ? WHERE task_id = ? AND LOWER(status) = 'pending'", (now, task_id))
                    conn.execute("UPDATE action_input_requests SET status = 'CANCELLED', updated_at = ? WHERE task_id = ? AND UPPER(status) = 'PENDING'", (now, task_id))
                    conn.execute(
                        """
                        UPDATE tasks SET status = 'cancelled', cancel_requested_at = ?, cancel_reason = ?,
                            terminal_reason = ?, finished_at = ?, updated_at = ? WHERE id = ?
                        """,
                        (now, reason, reason or "cancelled by user", now, now, task_id),
                    )
                    conn.execute(
                        """
                        UPDATE task_runtime SET runtime_revision = runtime_revision + 1,
                            wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                            wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                        WHERE task_id = ?
                        """,
                        (now, task_id),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="FAILURE_NOTE",
                        presentation_state="INFO",
                        title="任务已取消",
                        summary=reason,
                        payload={"task_id": task_id, "status": "cancelled"},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                    terminal = True
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "task.cancel_requested", _json({"event_id": event_id, "reason": reason, "terminal": terminal}), now),
                )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                result = self._task_dict(row)
                result["cancellation_pending"] = not terminal
                return result
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def finalize_action_interrupt_after_reconciliation(self, *, task_id: str, action_id: str) -> Dict[str, Any]:
        """Close an interrupted UNKNOWN Action after proving no effect occurred."""

        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                attempt = conn.execute(
                    "SELECT * FROM action_attempts WHERE action_id = ? ORDER BY attempt_number DESC LIMIT 1",
                    (action_id,),
                ).fetchone()
                if task is None or action is None or attempt is None:
                    raise KeyError(action_id)
                if task["cancel_requested_at"] is not None:
                    raise InvalidPlannerTransitionError("Task cancellation owns this reconciliation")
                if action["interrupt_requested_at"] is None:
                    raise InvalidPlannerTransitionError("Action has no interrupt request")
                if str(action["status"]).lower() != "reconciling" or attempt["latest_outcome"] != "UNKNOWN":
                    raise InvalidPlannerTransitionError("Action is not an interrupted UNKNOWN reconciliation candidate")
                conn.execute("UPDATE actions SET status = 'cancelled', updated_at = ? WHERE id = ?", (now, action_id))
                conn.execute("UPDATE tasks SET status = 'active', terminal_reason = NULL, finished_at = NULL, updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime SET phase = 'planning', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.interrupt_reconciled_absent", _json({"action_id": action_id, "attempt_id": attempt["id"]}), now),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:interrupt",
                    kind="PUBLIC_WORKLOG",
                    presentation_state="COMPLETE",
                    title="当前操作已停止",
                    summary="已确认原操作没有发生，将按你的新要求继续。",
                    payload={"action_id": action_id, "attempt_id": attempt["id"]},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                return self._task_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def finalize_cancel_after_reconciliation(self, *, task_id: str, action_id: str) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                if task is None or action is None:
                    raise KeyError(action_id)
                if task["cancel_requested_at"] is None:
                    raise InvalidPlannerTransitionError("Task has no cancellation request")
                conn.execute("UPDATE actions SET status = 'cancelled', updated_at = ? WHERE id = ?", (now, action_id))
                conn.execute(
                    "UPDATE tasks SET status = 'cancelled', terminal_reason = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                    (task["cancel_reason"] or "cancelled by user", now, now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime SET phase = 'reconciling', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"task:{task_id}:terminal",
                    kind="FAILURE_NOTE",
                    presentation_state="INFO",
                    title="任务已取消",
                    summary="已确认当前外部操作未发生，不再重试。",
                    payload={"task_id": task_id, "status": "cancelled"},
                    source_type="TASK",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "task.cancelled_after_reconciliation", _json({"action_id": action_id}), now),
                )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                return self._task_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def block_task(
        self,
        *,
        task_id: str,
        reason: str,
        payload: Optional[Dict[str, Any]] = None,
        public_summary: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Fail closed without making the Task terminal.

        Used for operator/runtime conditions such as Planner provider failure.
        A later explicit resume/input may move the Task back to ACTIVE.
        """

        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if task is None:
                    raise KeyError(task_id)
                if str(task["status"]).lower() in {"completed", "failed", "cancelled"}:
                    conn.commit()
                    return self._task_dict(task)
                conn.execute(
                    "UPDATE tasks SET status = 'blocked', updated_at = ? WHERE id = ?",
                    (now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'planning', block_reason = ?, block_payload_json = ?,
                        runtime_revision = runtime_revision + 1, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (reason, _json(payload or {}), now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "task.blocked", _json({"reason": reason, "payload": payload or {}}), now),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"task:{task_id}:blocked",
                    kind="FAILURE_NOTE",
                    presentation_state="INFO",
                    title="任务已暂停",
                    summary=public_summary,
                    payload={"reason": reason},
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="IMPORTANT",
                    now=now,
                )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                return self._task_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def retry_blocked_planner_task(self, *, task_id: str) -> Dict[str, Any]:
        """Resume only a Planner-provider pause without inventing user input.

        This is an explicit operator/user retry boundary. Verified observations,
        completed actions, artifacts and user turns remain untouched. The trace
        boundary resets the transient Planner failure streak deterministically.
        """

        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)
                ).fetchone()
                if task is None or runtime is None:
                    raise KeyError(task_id)

                status = str(task["status"]).lower()
                block_reason = str(runtime["block_reason"] or "")
                if status in {"completed", "failed", "cancelled"}:
                    raise InvalidPlannerTransitionError("terminal Task cannot be retried")
                if status == "active" and not block_reason:
                    conn.commit()
                    return {"task": self._task_dict(task), "resumed": False}
                if status != "blocked" or block_reason != "planner_runtime_error":
                    raise InvalidPlannerTransitionError(
                        "only planner_runtime_error paused Tasks can be retried"
                    )

                pending_clarification = conn.execute(
                    "SELECT 1 FROM clarifications WHERE task_id = ? AND LOWER(status) = 'pending' LIMIT 1",
                    (task_id,),
                ).fetchone()
                pending_action_input = conn.execute(
                    "SELECT 1 FROM action_input_requests WHERE task_id = ? AND LOWER(status) = 'pending' LIMIT 1",
                    (task_id,),
                ).fetchone()
                open_action = conn.execute(
                    """
                    SELECT 1 FROM actions
                    WHERE task_id = ? AND LOWER(status) IN
                      ('pending','planned','dispatched','executing','verifying','reconciling','retry_wait')
                    LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                if pending_clarification or pending_action_input or open_action:
                    raise InvalidPlannerTransitionError(
                        "paused Task has another live interaction or execution owner"
                    )

                conn.execute(
                    "UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?",
                    (now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'planning', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL,
                        block_reason = NULL, block_payload_json = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "task.operator_resumed", _json({"previous_block_reason": block_reason}), now),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"task:{task_id}:blocked",
                    kind="FAILURE_NOTE",
                    presentation_state="COMPLETE",
                    title="已重新尝试",
                    summary="现有进度已保留，正在继续规划。",
                    payload={"previous_reason": block_reason, "resumed": True},
                    source_type="TASK_RUNTIME",
                    source_id=task_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                return {"task": self._task_dict(row), "resumed": True}
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def recovery_candidates(self, *, now: str) -> Dict[str, List[Dict[str, Any]]]:
        """Return durable work that can be reconstructed after Host restart."""

        with self._lock:
            conn = self._connect()
            try:
                due_rows = conn.execute(
                    """
                    SELECT tr.task_id, tr.wait_id, tr.wait_kind, tr.wait_target_type,
                           tr.wait_target_id, tr.wake_at, tr.phase
                    FROM task_runtime tr
                    JOIN tasks t ON t.id = tr.task_id
                    WHERE LOWER(t.status) = 'waiting'
                      AND tr.wait_id IS NOT NULL
                      AND tr.wake_at IS NOT NULL
                      AND julianday(tr.wake_at) <= julianday(?)
                    ORDER BY tr.wake_at, tr.task_id
                    """,
                    (now,),
                ).fetchall()
                inbox_rows = conn.execute(
                    """
                    SELECT task_id, MIN(seq) AS first_seq, COUNT(*) AS event_count
                    FROM task_inbox_events
                    WHERE UPPER(status) = 'ACCEPTED'
                    GROUP BY task_id
                    ORDER BY first_seq
                    """
                ).fetchall()
                planning_rows = conn.execute(
                    """
                    SELECT t.id AS task_id, tr.runtime_revision
                    FROM tasks t
                    JOIN task_runtime tr ON tr.task_id = t.id
                    WHERE LOWER(t.status) = 'active' AND LOWER(tr.phase) = 'planning'
                      AND NOT EXISTS (
                        SELECT 1 FROM actions a
                        WHERE a.task_id = t.id AND LOWER(a.status) IN
                          ('pending','planned','dispatched','executing','verifying','reconciling','retry_wait')
                      )
                    ORDER BY t.updated_at, t.id
                    """
                ).fetchall()
                attempt_rows = conn.execute(
                    """
                    SELECT aa.*, a.task_id, a.action_type, a.status AS action_status
                    FROM action_attempts aa
                    JOIN actions a ON a.id = aa.action_id
                    JOIN tasks t ON t.id = a.task_id
                    WHERE UPPER(aa.status) = 'IN_FLIGHT'
                      AND LOWER(t.status) NOT IN ('completed','failed','cancelled')
                    ORDER BY aa.started_at, aa.id
                    """
                ).fetchall()
                reconcile_rows = conn.execute(
                    """
                    SELECT a.id AS action_id, a.task_id, a.action_type, a.status
                    FROM actions a JOIN tasks t ON t.id = a.task_id
                    WHERE LOWER(a.status) = 'reconciling'
                      AND LOWER(t.status) NOT IN ('completed','failed','cancelled')
                    ORDER BY a.updated_at, a.id
                    """
                ).fetchall()
            finally:
                self._close(conn)

        return {
            "due_waits": [dict(row) for row in due_rows],
            "accepted_inbox": [dict(row) for row in inbox_rows],
            "active_planning": [dict(row) for row in planning_rows],
            "in_flight_attempts": [
                {
                    **self._attempt_dict(row),
                    "task_id": row["task_id"],
                    "action_type": row["action_type"],
                    "action_status": row["action_status"],
                }
                for row in attempt_rows
            ],
            "reconciling_actions": [dict(row) for row in reconcile_rows],
        }

    def resume_planner_wait_from_timer(
        self,
        *,
        task_id: str,
        wait_id: str,
        event_id: str,
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                runtime = conn.execute("SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)).fetchone()
                event = conn.execute(
                    "SELECT * FROM task_inbox_events WHERE event_id = ? AND task_id = ?",
                    (event_id, task_id),
                ).fetchone()
                if task is None or runtime is None or event is None:
                    raise KeyError(task_id)
                if runtime["wait_id"] != wait_id:
                    raise InvalidPlannerTransitionError("stale wait event")
                if event["target_type"] != "WAIT" or event["target_id"] != wait_id:
                    raise InvalidPlannerTransitionError("timer event does not target current wait")
                if str(event["status"]).upper() == "CONSUMED":
                    conn.commit()
                    return self._task_dict(task)
                if str(event["status"]).upper() != "ACCEPTED":
                    raise InvalidPlannerTransitionError("timer event is not consumable")
                if runtime["wait_kind"] not in {"TIME", "EXTERNAL_CONDITION"}:
                    raise InvalidPlannerTransitionError("wait is not Planner-owned")
                conn.execute(
                    "UPDATE task_inbox_events SET status = 'CONSUMED', consumed_at = ? WHERE event_id = ?",
                    (now, event_id),
                )
                conn.execute("UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'planning', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "wait.resumed", _json({"wait_id": wait_id, "event_id": event_id}), now),
                )
                conn.commit()
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                assert row is not None
                return self._task_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def set_source_operation_wait(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        wait_id: str,
        source_operation_ref: str,
        source_status: str,
        poll_after: Optional[str],
        ttl_at: Optional[str],
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                attempt = conn.execute("SELECT * FROM action_attempts WHERE id = ? AND action_id = ?", (attempt_id, action_id)).fetchone()
                if action is None or attempt is None:
                    raise KeyError(attempt_id)
                if str(attempt["status"]).upper() != "IN_FLIGHT":
                    raise InvalidPlannerTransitionError("source operation requires an IN_FLIGHT Attempt")
                previous_ref = attempt["source_operation_ref"]
                if previous_ref is not None and previous_ref != source_operation_ref:
                    raise InvalidPlannerTransitionError("source operation identity changed within one Attempt")
                conn.execute(
                    """
                    UPDATE action_attempts
                    SET source_operation_ref = ?, source_operation_status = ?,
                        source_poll_after = ?, source_ttl_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (source_operation_ref, source_status, poll_after, ttl_at, now, attempt_id),
                )
                conn.execute("UPDATE actions SET status = 'executing', updated_at = ? WHERE id = ?", (now, action_id))
                conn.execute("UPDATE tasks SET status = 'waiting', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'executing', runtime_revision = runtime_revision + 1,
                        wait_reason = 'source_operation', wait_json = ?, wait_id = ?,
                        wait_kind = 'SOURCE_OPERATION', wait_target_type = 'ATTEMPT',
                        wait_target_id = ?, wake_at = ?, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (
                        _json({"source_operation_ref": source_operation_ref, "source_status": source_status}),
                        wait_id,
                        attempt_id,
                        poll_after,
                        now,
                        task_id,
                    ),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "source.operation.waiting",
                        _json({
                            "action_id": action_id,
                            "attempt_id": attempt_id,
                            "source_operation_ref": source_operation_ref,
                            "source_status": source_status,
                            "wait_id": wait_id,
                            "poll_after": poll_after,
                        }),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="ACTIVE",
                    title=capability_activity_title(str(action["action_type"]), "active"),
                    summary=None,
                    payload={"action_id": action_id, "attempt_id": attempt_id},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                return {
                    "task": self.get_task(task_id),
                    "action": self.get_action(action_id),
                    "attempt": self.get_action_attempt(attempt_id),
                    "wait_id": wait_id,
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def resume_source_operation_from_timer(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        wait_id: str,
        event_id: str,
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                attempt = conn.execute("SELECT * FROM action_attempts WHERE id = ? AND action_id = ?", (attempt_id, action_id)).fetchone()
                runtime = conn.execute("SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)).fetchone()
                event = conn.execute("SELECT * FROM task_inbox_events WHERE event_id = ?", (event_id,)).fetchone()
                if action is None or attempt is None or runtime is None or event is None:
                    raise KeyError(attempt_id)
                if runtime["wait_id"] != wait_id or runtime["wait_kind"] != "SOURCE_OPERATION":
                    raise InvalidPlannerTransitionError("stale source-operation wait")
                if runtime["wait_target_id"] != attempt_id:
                    raise InvalidPlannerTransitionError("source-operation wait targets another Attempt")
                if event["target_type"] != "WAIT" or event["target_id"] != wait_id:
                    raise InvalidPlannerTransitionError("timer event does not target source-operation wait")
                if str(event["status"]).upper() != "ACCEPTED":
                    raise InvalidPlannerTransitionError("timer event is not consumable")
                conn.execute("UPDATE task_inbox_events SET status = 'CONSUMED', consumed_at = ? WHERE event_id = ?", (now, event_id))
                conn.execute(
                    "UPDATE action_attempts SET source_round = source_round + 1, updated_at = ? WHERE id = ?",
                    (now, attempt_id),
                )
                conn.execute("UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'executing', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "source.operation.poll_ready", _json({"action_id": action_id, "attempt_id": attempt_id, "wait_id": wait_id}), now),
                )
                conn.commit()
                return {
                    "task": self.get_task(task_id),
                    "action": self.get_action(action_id),
                    "attempt": self.get_action_attempt(attempt_id),
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def list_tasks(
        self,
        *,
        bucket: str = "all",
        cursor: Optional[str] = None,
        limit: int = 20,
        thread_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        if bucket not in {"all", "running", "needs_user", "history"}:
            raise ValueError("invalid task bucket")
        if limit < 1 or limit > 100:
            raise ValueError("task limit must be between 1 and 100")
        anchor = decode_task_cursor(cursor)

        terminal = "LOWER(t.status) IN ('completed', 'failed', 'cancelled')"
        needs_user = """
            (EXISTS (
                 SELECT 1 FROM clarifications c
                 WHERE c.task_id = t.id AND LOWER(c.status) = 'pending'
             )
             OR EXISTS (
                 SELECT 1 FROM action_input_requests air
                 WHERE air.task_id = t.id AND LOWER(air.status) = 'pending'
             )
             OR (LOWER(t.status) = 'waiting' AND (
                 tr.pending_clarification_id IS NOT NULL
                 OR LOWER(COALESCE(tr.wait_reason, '')) = 'user_input'
             )))
        """
        clauses: List[str] = []
        params: List[Any] = []
        if thread_id is not None:
            normalized_thread_id = thread_id.strip()
            if not normalized_thread_id:
                raise ValueError("thread_id must be non-empty when present")
            clauses.append("t.thread_id = ?")
            params.append(normalized_thread_id)
        if bucket == "history":
            clauses.append(terminal)
        elif bucket == "needs_user":
            clauses.append(f"NOT ({terminal}) AND {needs_user}")
        elif bucket == "running":
            clauses.append(f"NOT ({terminal}) AND NOT {needs_user}")
        if anchor is not None:
            clauses.append("(t.updated_at < ? OR (t.updated_at = ? AND t.id < ?))")
            params.extend([anchor[0], anchor[0], anchor[1]])

        where_sql = " WHERE " + " AND ".join(clauses) if clauses else ""
        sql = f"""
            SELECT
                t.*,
                tr.phase,
                tr.current_task_brief,
                tr.interpreted_goal_summary,
                CASE WHEN {needs_user} THEN 1 ELSE 0 END AS needs_user,
                (SELECT title FROM task_timeline_items ti
                 WHERE ti.task_id = t.id ORDER BY ti.display_order DESC LIMIT 1)
                    AS latest_timeline_title,
                (SELECT summary FROM task_timeline_items ti
                 WHERE ti.task_id = t.id ORDER BY ti.display_order DESC LIMIT 1)
                    AS latest_timeline_summary,
                (SELECT updated_at FROM task_timeline_items ti
                 WHERE ti.task_id = t.id ORDER BY ti.display_order DESC LIMIT 1)
                    AS latest_timeline_at
            FROM tasks t
            LEFT JOIN task_runtime tr ON tr.task_id = t.id
            {where_sql}
            ORDER BY t.updated_at DESC, t.id DESC
            LIMIT ?
        """
        params.append(limit + 1)

        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(sql, params).fetchall()
            finally:
                self._close(conn)

        has_more = len(rows) > limit
        visible = rows[:limit]
        items = []
        for row in visible:
            status = str(row["status"]).lower()
            row_bucket = (
                "history"
                if status in {"completed", "failed", "cancelled"}
                else "needs_user"
                if bool(row["needs_user"])
                else "running"
            )
            items.append(
                {
                    "task_id": row["id"],
                    "submission_id": row["submission_id"],
                    "thread_id": row["thread_id"],
                    "parent_task_id": row["parent_task_id"],
                    "title": row["current_task_brief"]
                    or row["interpreted_goal_summary"]
                    or row["goal"],
                    "goal": row["goal"],
                    "status": row["status"],
                    "phase": row["phase"],
                    "bucket": row_bucket,
                    "needs_user": bool(row["needs_user"]),
                    "latest_timeline": {
                        "title": row["latest_timeline_title"],
                        "summary": row["latest_timeline_summary"],
                        "updated_at": row["latest_timeline_at"],
                    }
                    if row["latest_timeline_title"] is not None
                    else None,
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                }
            )

        next_cursor = None
        if has_more and visible:
            last = visible[-1]
            next_cursor = encode_task_cursor(str(last["updated_at"]), str(last["id"]))
        return {"items": items, "next_cursor": next_cursor}

    def get_task_view(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Return one coherent product snapshot plus a presentation cursor."""

        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN")
                task_row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                if task_row is None:
                    conn.commit()
                    return None
                runtime_row = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                timeline_rows = conn.execute(
                    "SELECT * FROM task_timeline_items WHERE task_id = ? ORDER BY display_order",
                    (task_id,),
                ).fetchall()
                artifact_rows = conn.execute(
                    """
                    SELECT a.*, ar.revision_number AS current_revision_number,
                           ar.content_digest AS current_content_digest
                    FROM artifacts a
                    LEFT JOIN artifact_revisions ar ON ar.id = a.current_revision_id
                    WHERE a.task_id = ?
                    ORDER BY a.created_at, a.id
                    """,
                    (task_id,),
                ).fetchall()
                action_input = conn.execute(
                    """
                    SELECT * FROM action_input_requests
                    WHERE task_id = ? AND LOWER(status) = 'pending'
                    ORDER BY created_at DESC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                clarification = None
                if action_input is None:
                    clarification = conn.execute(
                        """
                        SELECT * FROM clarifications
                        WHERE task_id = ? AND LOWER(status) = 'pending'
                        ORDER BY created_at DESC LIMIT 1
                        """,
                        (task_id,),
                    ).fetchone()
                cursor_row = conn.execute(
                    "SELECT COALESCE(MAX(seq), 0) AS cursor FROM presentation_events WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                presentation_cursor = int(cursor_row["cursor"]) if cursor_row is not None else 0

                task = self._task_dict(task_row)
                runtime = None
                if runtime_row is not None:
                    wait_kind = runtime_row["wait_kind"] or runtime_row["wait_reason"]
                    runtime = {
                        "task_id": runtime_row["task_id"],
                        "phase": runtime_row["phase"],
                        "current_task_brief": runtime_row["current_task_brief"]
                        or runtime_row["interpreted_goal_summary"],
                        "plan": _loads(runtime_row["plan_json"], []),
                        "runtime_revision": runtime_row["runtime_revision"],
                        "wait": {
                            "wait_id": runtime_row["wait_id"],
                            "kind": wait_kind,
                            "target_type": runtime_row["wait_target_type"],
                            "target_id": runtime_row["wait_target_id"],
                            "wake_at": runtime_row["wake_at"],
                            "payload": _loads(runtime_row["wait_json"], None),
                        }
                        if wait_kind is not None
                        else None,
                        "block_reason": runtime_row["block_reason"],
                        "updated_at": runtime_row["updated_at"],
                    }

                artifacts = [
                    {
                        "artifact_id": row["id"],
                        "kind": row["kind"],
                        "title": row["title"],
                        "current_revision_id": row["current_revision_id"],
                        "current_revision_number": row["current_revision_number"],
                        "current_content_digest": row["current_content_digest"],
                        "final_revision_id": row["final_revision_id"],
                        "created_at": row["created_at"],
                        "updated_at": row["updated_at"],
                    }
                    for row in artifact_rows
                ]

                pending_interaction = None
                if action_input is not None:
                    pending_interaction = {
                        "kind": "action_input",
                        "input_request_id": action_input["id"],
                        "attempt_id": action_input["attempt_id"],
                        "prompt": action_input["prompt"],
                        "suggested_options": _loads(action_input["suggested_options_json"], []),
                        "accepts_text": bool(action_input["accepts_text"]),
                        "reason": action_input["reason"],
                        "binding_digest": action_input["binding_digest"],
                    }
                elif clarification is not None:
                    payload = _loads(clarification["payload_json"], {})
                    pending_interaction = {
                        "kind": "clarification",
                        "clarification_id": clarification["id"],
                        "question": clarification["question"],
                        "suggested_options": payload.get("suggested_options", []),
                        "accepts_text": bool(clarification["accepts_text"]),
                        "reason": payload.get("reason"),
                    }

                public_result = project_public_result(_loads(task_row["result_json"], None))
                task = dict(task)
                task["result"] = public_result

                view = {
                    "task": task,
                    "runtime": runtime,
                    "timeline": [timeline_item_dict(row) for row in timeline_rows],
                    "artifacts": artifacts,
                    "pending_interaction": pending_interaction,
                    "result": public_result,
                    "presentation_cursor": presentation_cursor,
                }
                conn.commit()
                return view
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def presentation_events_after(self, task_id: str, after_seq: int) -> List[Dict[str, Any]]:
        if after_seq < 0:
            raise ValueError("after_seq must be non-negative")
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """
                    SELECT * FROM presentation_events
                    WHERE task_id = ? AND seq > ?
                    ORDER BY seq
                    """,
                    (task_id, after_seq),
                ).fetchall()
            finally:
                self._close(conn)
        result = []
        for row in rows:
            stored_payload = _loads(row["public_payload_json"], {})
            if not isinstance(stored_payload, dict):
                stored_payload = {}
            nested_payload = stored_payload.get("payload")
            if not isinstance(nested_payload, dict):
                nested_payload = {}
            public_payload = public_timeline_event_payload(
                timeline_item_id=str(stored_payload.get("timeline_item_id") or row["timeline_item_id"]),
                kind=str(stored_payload.get("kind") or "PUBLIC_WORKLOG"),
                presentation_state=str(stored_payload.get("presentation_state") or "INFO"),
                title=str(stored_payload.get("title") or "任务进展"),
                summary=stored_payload.get("summary") if isinstance(stored_payload.get("summary"), str) else None,
                payload=nested_payload,
                revision=int(stored_payload.get("revision") or 1),
            )
            result.append(
                {
                    "seq": row["seq"],
                    "presentation_event_id": row["id"],
                    "task_id": row["task_id"],
                    "timeline_item_id": row["timeline_item_id"],
                    "operation": row["operation"],
                    "payload": public_payload,
                    "attention_level": row["attention_level"],
                    "created_at": row["created_at"],
                }
            )
        return result

    def get_task(self, task_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
            finally:
                self._close(conn)
        return None if row is None else self._task_dict(row)

    def get_task_by_submission_id(self, submission_id: str) -> Optional[Dict[str, Any]]:
        if not isinstance(submission_id, str) or not submission_id.strip():
            return None
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT * FROM tasks WHERE submission_id = ?",
                    (submission_id.strip(),),
                ).fetchone()
            finally:
                self._close(conn)
        return None if row is None else self._task_dict(row)

    def get_action(self, action_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute("SELECT * FROM actions WHERE id = ?", (action_id,)).fetchone()
            finally:
                self._close(conn)
        if row is None:
            return None
        return self._action_dict(row)

    def get_action_attempt(self, attempt_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT * FROM action_attempts WHERE id = ?",
                    (attempt_id,),
                ).fetchone()
            finally:
                self._close(conn)
        return None if row is None else self._attempt_dict(row)

    def action_attempts(self, action_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    "SELECT * FROM action_attempts WHERE action_id = ? ORDER BY attempt_number",
                    (action_id,),
                ).fetchall()
            finally:
                self._close(conn)
        return [self._attempt_dict(row) for row in rows]

    def current_action_attempt(self, action_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    """
                    SELECT * FROM action_attempts
                    WHERE action_id = ?
                    ORDER BY attempt_number DESC LIMIT 1
                    """,
                    (action_id,),
                ).fetchone()
            finally:
                self._close(conn)
        return None if row is None else self._attempt_dict(row)

    def fail_action_task_denied(
        self,
        *,
        task_id: str,
        action_id: str,
        expected_policy_revision: int,
        detail: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Fail a not-yet-attempted Action under the exact effective policy basis."""

        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if task is None or action is None or runtime is None:
                    raise KeyError(action_id)
                if int(runtime["runtime_revision"]) != int(expected_policy_revision):
                    raise ActionAdmissionSupersededError(
                        "Task policy basis changed before denied Action could be settled"
                    )
                if conn.execute(
                    "SELECT 1 FROM action_attempts WHERE action_id = ? LIMIT 1",
                    (action_id,),
                ).fetchone() is not None:
                    raise InvalidPlannerTransitionError(
                        "TASK_DENIED gate must run before the first ActionAttempt"
                    )
                status = str(action["status"]).lower()
                if status == "failed" and action["failure_code"] == "TASK_DENIED":
                    conn.commit()
                    value = self.get_action(action_id)
                    assert value is not None
                    return value
                if status not in {"pending", "planned", "dispatched"}:
                    raise ActionAdmissionSupersededError(
                        f"Action in state {status} can no longer be denied before dispatch"
                    )
                failure_detail = {
                    "reason_code": "TASK_DENIED",
                    **dict(detail),
                    "policy_revision": int(expected_policy_revision),
                }
                conn.execute(
                    """
                    UPDATE actions
                    SET status = 'failed', failure_code = 'TASK_DENIED', failure_detail_json = ?,
                        error_text = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (_json(failure_detail), "TASK_DENIED: explicit current-Task capability restriction", now, action_id),
                )
                conn.execute(
                    "UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?",
                    (now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'planning', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "action.task_denied",
                        _json({"action_id": action_id, **failure_detail}),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="INFO",
                    title="已按当前任务限制跳过这一步",
                    summary="这项操作被当前任务的明确限制阻止，未开始执行。",
                    payload={"action_id": action_id, "reason_code": "TASK_DENIED"},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                value = self.get_action(action_id)
                assert value is not None
                return value
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def start_action_attempt(
        self,
        *,
        attempt_id: str,
        task_id: str,
        action_id: str,
        source_kind: str,
        execution_profile: Dict[str, Any],
        dispatch_snapshot: Dict[str, Any],
        dispatch_digest: str,
        approved_input_request_id: Optional[str] = None,
        expected_policy_revision: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Persist an IN_FLIGHT Attempt before any external dispatch is returned."""

        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if task is None or action is None or runtime is None:
                    raise KeyError(action_id)
                if expected_policy_revision is not None and int(runtime["runtime_revision"]) != int(expected_policy_revision):
                    raise ActionAdmissionSupersededError(
                        "Task policy basis changed before ActionAttempt admission"
                    )
                if (str(task["status"]).lower() in {"completed", "failed", "cancelled"}
                        or task["cancel_requested_at"] is not None
                        or action["interrupt_requested_at"] is not None):
                    raise ActionAdmissionSupersededError("stopped Task/Action cannot start an ActionAttempt")
                if conn.execute(
                    "SELECT 1 FROM action_input_requests WHERE action_id = ? AND status = 'PENDING'",
                    (action_id,),
                ).fetchone() is not None:
                    raise ActionAdmissionSupersededError("Action is waiting for user input")

                current = conn.execute(
                    "SELECT * FROM action_attempts WHERE action_id = ? ORDER BY attempt_number DESC LIMIT 1",
                    (action_id,),
                ).fetchone()
                if current is not None and str(current["status"]).upper() in {"IN_FLIGHT", "WAITING_INPUT"}:
                    conn.commit()
                    return self._attempt_dict(current)

                action_status = str(action["status"]).lower()
                if action_status not in {"pending", "planned", "dispatched"}:
                    raise InvalidPlannerTransitionError(
                        f"Action in state {action_status} is not ready for a new Attempt"
                    )
                if approved_input_request_id is not None:
                    approval = conn.execute(
                        "SELECT * FROM action_input_requests WHERE id = ? AND action_id = ?",
                        (approved_input_request_id, action_id),
                    ).fetchone()
                    if approval is None or approval["attempt_id"] is not None or str(approval["status"]).upper() != "ANSWERED":
                        raise StaleActionInputError("approved ActionInputRequest is no longer valid")
                    response = _loads(approval["response_json"], {})
                    if response.get("approved") is not True:
                        raise StaleActionInputError("ActionInputRequest did not approve dispatch")
                    binding = _loads(approval["binding_json"], {})
                    if binding.get("action_id") != action_id or binding.get("capability_id") != action["action_type"]:
                        raise StaleActionInputError("approved ActionInput binding no longer matches Action")
                    if binding.get("dispatch_digest") != dispatch_digest:
                        raise StaleActionInputError(
                            "approved ActionInput no longer matches the exact dispatch snapshot"
                        )
                    for revision_id in binding.get("artifact_revisions", []):
                        if conn.execute(
                            "SELECT 1 FROM artifact_revisions WHERE id = ?",
                            (revision_id,),
                        ).fetchone() is None:
                            raise StaleActionInputError("approved ArtifactRevision no longer exists")

                next_number_row = conn.execute(
                    "SELECT COALESCE(MAX(attempt_number), 0) + 1 AS n FROM action_attempts WHERE action_id = ?",
                    (action_id,),
                ).fetchone()
                assert next_number_row is not None
                attempt_number = int(next_number_row["n"])
                conn.execute(
                    """
                    INSERT INTO action_attempts
                    (id, action_id, attempt_number, status, latest_outcome, source_kind,
                     source_request_ref, source_round, result_json, dispatch_snapshot_json,
                     dispatch_digest, approved_input_request_id, policy_revision,
                     started_at, finished_at, updated_at, error_text)
                    VALUES (?, ?, ?, 'IN_FLIGHT', NULL, ?, ?, 0, NULL, ?, ?, ?, ?, ?, NULL, ?, NULL)
                    """,
                    (
                        attempt_id,
                        action_id,
                        attempt_number,
                        source_kind,
                        attempt_id,
                        canonical_json(dispatch_snapshot),
                        dispatch_digest,
                        approved_input_request_id,
                        str(expected_policy_revision) if expected_policy_revision is not None else None,
                        now,
                        now,
                    ),
                )
                conn.execute(
                    """
                    UPDATE actions
                    SET status = 'executing', execution_profile_json = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (canonical_json(execution_profile), now, action_id),
                )
                conn.execute(
                    "UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?",
                    (now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'executing', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "action.attempt.started",
                        _json({
                            "action_id": action_id,
                            "attempt_id": attempt_id,
                            "attempt_number": attempt_number,
                            "dispatch_digest": dispatch_digest,
                            "source_kind": source_kind,
                        }),
                        now,
                    ),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "action.dispatched",
                        _json({
                            "action_id": action_id,
                            "attempt_id": attempt_id,
                            "attempt_number": attempt_number,
                        }),
                        now,
                    ),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="ACTIVE",
                    title=capability_activity_title(str(action["action_type"]), "active"),
                    summary=None,
                    payload={
                        "action_id": action_id,
                        "capability": action["action_type"],
                        "attempt_id": attempt_id,
                    },
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                row = conn.execute("SELECT * FROM action_attempts WHERE id = ?", (attempt_id,)).fetchone()
                assert row is not None
                return self._attempt_dict(row)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def finish_action_attempt_verified(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        capability: str,
        result: Dict[str, Any],
        observation: Dict[str, Any],
        verification_mode: str,
        direct_completion_summary: Optional[str] = None,
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                attempt = conn.execute(
                    "SELECT * FROM action_attempts WHERE id = ? AND action_id = ?",
                    (attempt_id, action_id),
                ).fetchone()
                runtime = conn.execute(
                    "SELECT * FROM task_runtime WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
                if task is None or action is None or attempt is None or runtime is None:
                    raise KeyError(attempt_id)
                if str(attempt["status"]).upper() == "FINISHED" and attempt["latest_outcome"] == "SUCCESS":
                    conn.commit()
                    observation_row = conn.execute(
                        "SELECT * FROM observations WHERE action_id = ?",
                        (action_id,),
                    ).fetchone()
                    return {
                        "task": self.get_task(task_id),
                        "action": self._action_dict(action),
                        "attempt": self._attempt_dict(attempt),
                        "observation": None if observation_row is None else self._observation_dict(observation_row),
                    }
                if str(attempt["status"]).upper() not in {"IN_FLIGHT", "FINISHED"}:
                    raise InvalidPlannerTransitionError("Attempt is not eligible for verification")
                if str(attempt["status"]).upper() == "FINISHED" and attempt["latest_outcome"] != "UNKNOWN":
                    raise InvalidPlannerTransitionError("only UNKNOWN finished Attempt may be reconciled by a late success")

                conn.execute(
                    """
                    UPDATE action_attempts
                    SET status = 'FINISHED', latest_outcome = 'SUCCESS', result_json = ?,
                        error_text = NULL, finished_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (_json(result), now, now, attempt_id),
                )
                conn.execute(
                    """
                    UPDATE actions
                    SET status = 'succeeded', result_json = ?, error_text = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                    (_json(result), now, action_id),
                )
                observation_row = conn.execute(
                    "SELECT * FROM observations WHERE action_id = ?",
                    (action_id,),
                ).fetchone()
                if observation_row is None:
                    cursor = conn.execute(
                        """
                        INSERT INTO observations
                        (task_id, action_id, capability, data_json, verified,
                         source_attempt_id, model_view_json, raw_evidence_json, provenance_json,
                         verification_mode, verified_at, created_at)
                        VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            task_id,
                            action_id,
                            capability,
                            _json(observation),
                            attempt_id,
                            _json(observation),
                            _json(result),
                            _json({"source_attempt_id": attempt_id, "source_kind": attempt["source_kind"]}),
                            verification_mode,
                            now,
                            now,
                        ),
                    )
                    observation_id = int(cursor.lastrowid)
                    observation_row = conn.execute(
                        "SELECT * FROM observations WHERE id = ?",
                        (observation_id,),
                    ).fetchone()

                on_verified = str(action["on_verified"])
                cancellation_pending = task["cancel_requested_at"] is not None
                pending_user_turn = conn.execute(
                    """
                    SELECT 1
                    FROM task_inbox_events
                    WHERE task_id = ? AND event_type = 'USER_TURN' AND status = 'ACCEPTED'
                    ORDER BY seq ASC
                    LIMIT 1
                    """,
                    (task_id,),
                ).fetchone() is not None
                pending_clarification = conn.execute(
                    """
                    SELECT id
                    FROM clarifications
                    WHERE task_id = ? AND LOWER(status) = 'pending'
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                next_wait_reason = None
                next_wait_json = None
                next_wait_id = None
                next_wait_kind = None
                next_wait_target_type = None
                next_wait_target_id = None
                if cancellation_pending:
                    # The side effect really happened and remains a succeeded
                    # Action/Observation. Cancellation only stops future work.
                    next_status = "cancelled"
                    next_phase = "verifying"
                    terminal_reason = task["cancel_reason"] or "cancelled after in-flight action settled"
                    conn.execute(
                        """
                        UPDATE tasks
                        SET result_json = ?, terminal_reason = ?, finished_at = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        (
                            _json({
                                "summary": "current action completed before cancellation settled",
                                "action_id": action_id,
                                "side_effect_verified": True,
                            }),
                            terminal_reason,
                            now,
                            now,
                            task_id,
                        ),
                    )
                elif pending_user_turn:
                    # The side effect is a verified fact, but the Action's old
                    # on_verified=COMPLETE continuation was decided before a
                    # newer user turn arrived. Preserve the successful
                    # Action/Observation and return to planning so the durable
                    # inbox turn cannot be swallowed by stale completion.
                    next_status = "active"
                    next_phase = "planning"
                    conn.execute(
                        "UPDATE tasks SET result_json = NULL, finished_at = NULL, updated_at = ? WHERE id = ?",
                        (now, task_id),
                    )
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "task.replan_after_inflight_user_turn",
                            _json({"action_id": action_id, "attempt_id": attempt_id}),
                            now,
                        ),
                    )
                elif pending_clarification is not None:
                    # A side Action may run while a Planner Clarification remains
                    # pending (for example: "顺便查一下天气"). Finishing that
                    # Action must restore the original wait owner instead of
                    # leaving an ACTIVE Task with a hidden pending question.
                    next_status = "waiting"
                    next_phase = "planning"
                    clarification_id = str(pending_clarification["id"])
                    next_wait_reason = "user_input"
                    next_wait_json = _json({"clarification_id": clarification_id})
                    next_wait_id = str(uuid.uuid4())
                    next_wait_kind = "CLARIFICATION"
                    next_wait_target_type = "CLARIFICATION"
                    next_wait_target_id = clarification_id
                    conn.execute("UPDATE tasks SET result_json = NULL, finished_at = NULL, updated_at = ? WHERE id = ?", (now, task_id))
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "clarification.wait_restored",
                            _json({"clarification_id": clarification_id, "wait_id": next_wait_id, "after_action_id": action_id}),
                            now,
                        ),
                    )
                elif on_verified == "COMPLETE":
                    next_status = "completed"
                    next_phase = "verifying"
                    completion_summary = (
                        direct_completion_summary.strip()
                        if isinstance(direct_completion_summary, str) and direct_completion_summary.strip()
                        else "操作已完成。"
                    )
                    conn.execute(
                        "UPDATE tasks SET result_json = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                        (_json({"summary": completion_summary, "action_id": action_id}), now, now, task_id),
                    )
                else:
                    next_status = "active"
                    next_phase = "planning"
                    conn.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute("UPDATE tasks SET status = ? WHERE id = ?", (next_status, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = ?, runtime_revision = runtime_revision + 1,
                        wait_reason = ?, wait_json = ?, wait_id = ?, wait_kind = ?,
                        wait_target_type = ?, wait_target_id = ?, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (
                        next_phase,
                        next_wait_reason,
                        next_wait_json,
                        next_wait_id,
                        next_wait_kind,
                        next_wait_target_type,
                        next_wait_target_id,
                        now,
                        task_id,
                    ),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.attempt.finished", _json({"action_id": action_id, "attempt_id": attempt_id, "outcome": "SUCCESS"}), now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "observation.verified", _json({"action_id": action_id, "attempt_id": attempt_id, "capability": capability}), now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.verified", _json({"action_id": action_id, "attempt_id": attempt_id}), now),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="COMPLETE",
                    title=capability_activity_title(capability, "complete"),
                    summary=None,
                    payload={"action_id": action_id, "capability": capability, "attempt_id": attempt_id},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                if next_status == "completed":
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="RESULT",
                        presentation_state="COMPLETE",
                        title="任务已完成",
                        summary=(
                            direct_completion_summary.strip()
                            if isinstance(direct_completion_summary, str) and direct_completion_summary.strip()
                            else None
                        ),
                        payload={"task_id": task_id, "status": "completed"},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                elif next_status == "cancelled":
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="FAILURE_NOTE",
                        presentation_state="INFO",
                        title="任务已取消",
                        summary="取消请求到达时当前操作已经执行完成；结果已记录，后续步骤已停止。",
                        payload={
                            "task_id": task_id,
                            "status": "cancelled",
                            "settled_action_id": action_id,
                            "side_effect_verified": True,
                        },
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="IMPORTANT",
                        now=now,
                    )
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "task.cancelled_after_effect_settled",
                            _json({"action_id": action_id, "attempt_id": attempt_id, "side_effect_verified": True}),
                            now,
                        ),
                    )
                conn.commit()
                task_row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action_row = conn.execute("SELECT * FROM actions WHERE id = ?", (action_id,)).fetchone()
                attempt_row = conn.execute("SELECT * FROM action_attempts WHERE id = ?", (attempt_id,)).fetchone()
                assert task_row is not None and action_row is not None and attempt_row is not None
                return {
                    "task": self._task_dict(task_row),
                    "action": self._action_dict(action_row),
                    "attempt": self._attempt_dict(attempt_row),
                    "observation": None if observation_row is None else self._observation_dict(observation_row),
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def finish_action_attempt_model_correctable(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        result: Dict[str, Any],
        error: Optional[str],
    ) -> Dict[str, Any]:
        """Persist a semantic Action failure and return the Task to Planner."""

        now = utc_now()
        reason = error or "action requires a different semantic plan"
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                attempt = conn.execute("SELECT * FROM action_attempts WHERE id = ? AND action_id = ?", (attempt_id, action_id)).fetchone()
                if task is None or action is None or attempt is None:
                    raise KeyError(attempt_id)
                if str(attempt["status"]).upper() == "FINISHED":
                    conn.commit()
                    return {"task": self.get_task(task_id), "action": self.get_action(action_id), "attempt": self.get_action_attempt(attempt_id)}
                conn.execute(
                    "UPDATE action_attempts SET status = 'FINISHED', latest_outcome = 'MODEL_CORRECTABLE_FAILURE', result_json = ?, error_text = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                    (_json(result), reason, now, now, attempt_id),
                )
                conn.execute(
                    "UPDATE actions SET status = 'failed', result_json = ?, error_text = ?, updated_at = ? WHERE id = ?",
                    (_json(result), reason, now, action_id),
                )
                if task["cancel_requested_at"] is not None:
                    task_status = "cancelled"
                    phase = "planning"
                    terminal_reason = task["cancel_reason"] or "cancelled while action settled"
                    finished_at = now
                else:
                    task_status = "active"
                    phase = "planning"
                    terminal_reason = None
                    finished_at = None
                conn.execute(
                    "UPDATE tasks SET status = ?, terminal_reason = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                    (task_status, terminal_reason, finished_at, now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime SET phase = ?, runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (phase, now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.attempt.finished", _json({"action_id": action_id, "attempt_id": attempt_id, "outcome": "MODEL_CORRECTABLE_FAILURE", "error": reason}), now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.model_correctable_failure", _json({"action_id": action_id, "attempt_id": attempt_id, "error": reason}), now),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="INFO",
                    title=capability_activity_title(str(action["action_type"]), "replanning"),
                    summary=reason[:240],
                    payload={"action_id": action_id, "attempt_id": attempt_id, "outcome": "MODEL_CORRECTABLE_FAILURE"},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                if task_status == "cancelled":
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="FAILURE_NOTE",
                        presentation_state="INFO",
                        title="任务已取消",
                        summary=terminal_reason,
                        payload={"task_id": task_id, "status": "cancelled"},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET",
                        now=now,
                    )
                conn.commit()
                return {"task": self.get_task(task_id), "action": self.get_action(action_id), "attempt": self.get_action_attempt(attempt_id)}
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def finish_action_attempt_transient_retry(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        result: Dict[str, Any],
        error: Optional[str],
        wait_id: str,
        wake_at: str,
    ) -> Dict[str, Any]:
        """Persist a transient failure and schedule the same Action for retry."""

        now = utc_now()
        reason = error or "transient execution failure"
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                attempt = conn.execute("SELECT * FROM action_attempts WHERE id = ? AND action_id = ?", (attempt_id, action_id)).fetchone()
                if task is None or action is None or attempt is None:
                    raise KeyError(attempt_id)
                if str(attempt["status"]).upper() == "FINISHED":
                    conn.commit()
                    return {"task": self.get_task(task_id), "action": self.get_action(action_id), "attempt": self.get_action_attempt(attempt_id)}
                conn.execute(
                    "UPDATE action_attempts SET status = 'FINISHED', latest_outcome = 'TRANSIENT_FAILURE', result_json = ?, error_text = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                    (_json(result), reason, now, now, attempt_id),
                )
                action_interrupt_pending = action["interrupt_requested_at"] is not None
                if task["cancel_requested_at"] is not None:
                    conn.execute("UPDATE actions SET status = 'cancelled', error_text = ?, updated_at = ? WHERE id = ?", (reason, now, action_id))
                    conn.execute("UPDATE tasks SET status = 'cancelled', terminal_reason = ?, finished_at = ?, updated_at = ? WHERE id = ?", (task["cancel_reason"] or reason, now, now, task_id))
                    conn.execute("UPDATE task_runtime SET phase = 'executing', runtime_revision = runtime_revision + 1, wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL, wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ? WHERE task_id = ?", (now, task_id))
                elif action_interrupt_pending:
                    conn.execute("UPDATE actions SET status = 'cancelled', error_text = ?, updated_at = ? WHERE id = ?", (reason, now, action_id))
                    conn.execute("UPDATE tasks SET status = 'active', terminal_reason = NULL, finished_at = NULL, updated_at = ? WHERE id = ?", (now, task_id))
                    conn.execute("UPDATE task_runtime SET phase = 'planning', runtime_revision = runtime_revision + 1, wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL, wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ? WHERE task_id = ?", (now, task_id))
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (task_id, "action.interrupt_settled", _json({"action_id": action_id, "attempt_id": attempt_id, "outcome": "TRANSIENT_FAILURE"}), now),
                    )
                else:
                    conn.execute("UPDATE actions SET status = 'retry_wait', error_text = ?, updated_at = ? WHERE id = ?", (reason, now, action_id))
                    conn.execute("UPDATE tasks SET status = 'waiting', terminal_reason = NULL, finished_at = NULL, updated_at = ? WHERE id = ?", (now, task_id))
                    conn.execute(
                        """
                        UPDATE task_runtime SET phase = 'executing', runtime_revision = runtime_revision + 1,
                            wait_reason = 'retry_backoff', wait_json = ?, wait_id = ?, wait_kind = 'RETRY_BACKOFF',
                            wait_target_type = 'ACTION', wait_target_id = ?, wake_at = ?, updated_at = ?
                        WHERE task_id = ?
                        """,
                        (_json({"action_id": action_id}), wait_id, action_id, wake_at, now, task_id),
                    )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.attempt.finished", _json({"action_id": action_id, "attempt_id": attempt_id, "outcome": "TRANSIENT_FAILURE", "error": reason}), now),
                )
                if task["cancel_requested_at"] is None and not action_interrupt_pending:
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (task_id, "action.retry_wait", _json({"action_id": action_id, "attempt_id": attempt_id, "wait_id": wait_id, "wake_at": wake_at, "reason": reason}), now),
                    )
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"action:{action_id}:activity",
                        kind="TOOL_ACTIVITY",
                        presentation_state="ACTIVE",
                        title="暂时失败，稍后重试",
                        summary=reason[:240],
                        payload={"action_id": action_id, "attempt_id": attempt_id, "outcome": "TRANSIENT_FAILURE", "wait_id": wait_id},
                        source_type="ACTION",
                        source_id=action_id,
                        attention_level="QUIET",
                        now=now,
                    )
                conn.commit()
                return {"task": self.get_task(task_id), "action": self.get_action(action_id), "attempt": self.get_action_attempt(attempt_id)}
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def finish_action_attempt_failure(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        outcome: str,
        result: Dict[str, Any],
        error: Optional[str],
    ) -> Dict[str, Any]:
        if outcome not in {"TERMINAL_FAILURE", "CANCELLED"}:
            raise ValueError("this terminal failure path only accepts terminal outcomes")
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                attempt = conn.execute(
                    "SELECT * FROM action_attempts WHERE id = ? AND action_id = ?",
                    (attempt_id, action_id),
                ).fetchone()
                if task is None or action is None or attempt is None:
                    raise KeyError(attempt_id)
                if str(attempt["status"]).upper() == "FINISHED":
                    conn.commit()
                    task = self.get_task(task_id)
                    current_action = self.get_action(action_id)
                    current_attempt = self.get_action_attempt(attempt_id)
                    return {"task": task, "action": current_action, "attempt": current_attempt}
                conn.execute(
                    """
                    UPDATE action_attempts
                    SET status = 'FINISHED', latest_outcome = ?, result_json = ?, error_text = ?,
                        finished_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (outcome, _json(result), error, now, now, attempt_id),
                )
                action_status = "cancelled" if outcome == "CANCELLED" else "failed"
                cancellation_pending = task["cancel_requested_at"] is not None
                pending_user_turn = conn.execute(
                    """
                    SELECT 1 FROM task_inbox_events
                    WHERE task_id = ? AND event_type = 'USER_TURN' AND status = 'ACCEPTED'
                    ORDER BY seq ASC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone() is not None
                pending_clarification = conn.execute(
                    """
                    SELECT id FROM clarifications
                    WHERE task_id = ? AND LOWER(status) = 'pending'
                    ORDER BY created_at DESC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                wait_reason = None
                wait_json = None
                wait_id = None
                wait_kind = None
                wait_target_type = None
                wait_target_id = None
                action_interrupt_pending = action["interrupt_requested_at"] is not None
                if cancellation_pending:
                    task_status = "cancelled"
                    next_phase = "executing"
                    terminal_reason = task["cancel_reason"] or "cancelled while in-flight action settled"
                    finished_at = now
                elif outcome == "CANCELLED" and action_interrupt_pending:
                    task_status = "active"
                    next_phase = "planning"
                    terminal_reason = None
                    finished_at = None
                elif outcome == "CANCELLED":
                    task_status = "cancelled"
                    next_phase = "executing"
                    terminal_reason = error or "action cancelled"
                    finished_at = now
                elif pending_user_turn:
                    task_status = "active"
                    next_phase = "planning"
                    terminal_reason = None
                    finished_at = None
                elif pending_clarification is not None:
                    task_status = "waiting"
                    next_phase = "planning"
                    terminal_reason = None
                    finished_at = None
                    clarification_id = str(pending_clarification["id"])
                    wait_reason = "user_input"
                    wait_json = _json({"clarification_id": clarification_id})
                    wait_id = str(uuid.uuid4())
                    wait_kind = "CLARIFICATION"
                    wait_target_type = "CLARIFICATION"
                    wait_target_id = clarification_id
                else:
                    task_status = "failed"
                    next_phase = "executing"
                    terminal_reason = error
                    finished_at = now
                conn.execute(
                    "UPDATE actions SET status = ?, result_json = ?, error_text = ?, updated_at = ? WHERE id = ?",
                    (action_status, _json(result), error, now, action_id),
                )
                conn.execute(
                    "UPDATE tasks SET status = ?, terminal_reason = ?, finished_at = ?, updated_at = ? WHERE id = ?",
                    (task_status, terminal_reason, finished_at, now, task_id),
                )
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = ?, runtime_revision = runtime_revision + 1,
                        wait_reason = ?, wait_json = ?, wait_id = ?, wait_kind = ?,
                        wait_target_type = ?, wait_target_id = ?, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (
                        next_phase, wait_reason, wait_json, wait_id, wait_kind,
                        wait_target_type, wait_target_id, now, task_id,
                    ),
                )
                if outcome == "CANCELLED" and action_interrupt_pending and not cancellation_pending:
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "action.interrupt_settled",
                            _json({"action_id": action_id, "attempt_id": attempt_id, "outcome": "CANCELLED"}),
                            now,
                        ),
                    )
                if pending_user_turn and task_status == "active":
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "task.replan_after_inflight_failure",
                            _json({"action_id": action_id, "attempt_id": attempt_id, "outcome": outcome}),
                            now,
                        ),
                    )
                elif pending_clarification is not None and task_status == "waiting":
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "clarification.wait_restored",
                            _json({"clarification_id": str(pending_clarification["id"]), "wait_id": wait_id, "after_failed_action_id": action_id}),
                            now,
                        ),
                    )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.attempt.finished", _json({"action_id": action_id, "attempt_id": attempt_id, "outcome": outcome, "error": error}), now),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.failed" if outcome != "CANCELLED" else "action.cancelled", _json({"action_id": action_id, "attempt_id": attempt_id, "error": error}), now),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="FAILED",
                    title=capability_activity_title(
                        str(action["action_type"]),
                        "cancelled" if outcome == "CANCELLED" else "failed",
                    ),
                    summary=error,
                    payload={"action_id": action_id, "attempt_id": attempt_id, "outcome": outcome},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="IMPORTANT",
                    now=now,
                )
                if task_status in {"cancelled", "failed"}:
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"task:{task_id}:terminal",
                        kind="FAILURE_NOTE",
                        presentation_state="INFO" if task_status == "cancelled" else "FAILED",
                        title="任务已取消" if task_status == "cancelled" else "任务失败",
                        summary=(
                            "取消请求到达后当前操作已结束；不会继续后续步骤。"
                            if task_status == "cancelled"
                            else error
                        ),
                        payload={"task_id": task_id, "status": task_status},
                        source_type="TASK",
                        source_id=task_id,
                        attention_level="QUIET" if task_status == "cancelled" else "IMPORTANT",
                        now=now,
                    )
                conn.commit()
                return {
                    "task": self.get_task(task_id),
                    "action": self.get_action(action_id),
                    "attempt": self.get_action_attempt(attempt_id),
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def mark_action_attempt_unknown(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        reason: str,
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                attempt = conn.execute(
                    "SELECT * FROM action_attempts WHERE id = ? AND action_id = ?",
                    (attempt_id, action_id),
                ).fetchone()
                if action is None or attempt is None:
                    raise KeyError(attempt_id)
                if str(attempt["status"]).upper() == "FINISHED":
                    if attempt["latest_outcome"] == "UNKNOWN":
                        conn.commit()
                        return {
                            "task": self.get_task(task_id),
                            "action": self.get_action(action_id),
                            "attempt": self.get_action_attempt(attempt_id),
                        }
                    raise InvalidPlannerTransitionError("finished Attempt cannot become UNKNOWN")
                conn.execute(
                    """
                    UPDATE action_attempts
                    SET status = 'FINISHED', latest_outcome = 'UNKNOWN', error_text = ?,
                        finished_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (reason, now, now, attempt_id),
                )
                conn.execute(
                    "UPDATE actions SET status = 'reconciling', error_text = ?, updated_at = ? WHERE id = ?",
                    (reason, now, action_id),
                )
                conn.execute("UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'reconciling', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.attempt.unknown", _json({"action_id": action_id, "attempt_id": attempt_id, "reason": reason}), now),
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="ACTIVE",
                    title="执行结果不确定，正在确认",
                    summary=reason[:240],
                    payload={"action_id": action_id, "attempt_id": attempt_id, "outcome": "UNKNOWN"},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="QUIET",
                    now=now,
                )
                conn.commit()
                return {
                    "task": self.get_task(task_id),
                    "action": self.get_action(action_id),
                    "attempt": self.get_action_attempt(attempt_id),
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def mark_action_retry_ready(
        self,
        *,
        task_id: str,
        action_id: str,
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                action = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                attempt = conn.execute(
                    "SELECT * FROM action_attempts WHERE action_id = ? ORDER BY attempt_number DESC LIMIT 1",
                    (action_id,),
                ).fetchone()
                if action is None or attempt is None:
                    raise KeyError(action_id)
                if str(action["status"]).lower() != "reconciling" or attempt["latest_outcome"] != "UNKNOWN":
                    raise InvalidPlannerTransitionError("Action is not an UNKNOWN reconciliation candidate")
                conn.execute("UPDATE actions SET status = 'pending', error_text = NULL, updated_at = ? WHERE id = ?", (now, action_id))
                conn.execute("UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'executing', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.reconciled_absent", _json({"action_id": action_id, "attempt_id": attempt["id"], "retry_ready": True}), now),
                )
                conn.commit()
                current = conn.execute("SELECT * FROM actions WHERE id = ?", (action_id,)).fetchone()
                assert current is not None
                return self._action_dict(current)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def mark_action_retry_wait(
        self,
        *,
        task_id: str,
        action_id: str,
        wait_id: str,
        wake_at: Optional[str],
    ) -> Dict[str, Any]:
        if wake_at is None:
            return self.mark_action_retry_ready(task_id=task_id, action_id=action_id)
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                attempt = conn.execute("SELECT * FROM action_attempts WHERE action_id = ? ORDER BY attempt_number DESC LIMIT 1", (action_id,)).fetchone()
                if action is None or attempt is None:
                    raise KeyError(action_id)
                if str(action["status"]).lower() != "reconciling" or attempt["latest_outcome"] != "UNKNOWN":
                    raise InvalidPlannerTransitionError("Action is not an UNKNOWN reconciliation candidate")
                conn.execute("UPDATE actions SET status = 'retry_wait', updated_at = ? WHERE id = ?", (now, action_id))
                conn.execute("UPDATE tasks SET status = 'waiting', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'executing', runtime_revision = runtime_revision + 1,
                        wait_reason = 'retry_backoff', wait_json = ?, wait_id = ?,
                        wait_kind = 'RETRY_BACKOFF', wait_target_type = 'ACTION',
                        wait_target_id = ?, wake_at = ?, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (_json({"action_id": action_id}), wait_id, action_id, wake_at, now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.retry_wait", _json({"action_id": action_id, "wait_id": wait_id, "wake_at": wake_at}), now),
                )
                conn.commit()
                return {
                    "task": self.get_task(task_id),
                    "action": self.get_action(action_id),
                    "attempt": self.get_action_attempt(str(attempt["id"])),
                }
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def resume_action_retry_wait(
        self,
        *,
        task_id: str,
        action_id: str,
        wait_id: str,
        event_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("BEGIN IMMEDIATE")
                action = conn.execute("SELECT * FROM actions WHERE id = ? AND task_id = ?", (action_id, task_id)).fetchone()
                runtime = conn.execute("SELECT * FROM task_runtime WHERE task_id = ?", (task_id,)).fetchone()
                if action is None or runtime is None:
                    raise KeyError(action_id)
                if str(action["status"]).lower() != "retry_wait" or runtime["wait_id"] != wait_id:
                    raise InvalidPlannerTransitionError("stale retry wait")
                if event_id is not None:
                    event = conn.execute(
                        "SELECT * FROM task_inbox_events WHERE event_id = ? AND task_id = ?",
                        (event_id, task_id),
                    ).fetchone()
                    if event is None or event["target_type"] != "WAIT" or event["target_id"] != wait_id:
                        raise InvalidPlannerTransitionError("timer event does not target retry wait")
                    if str(event["status"]).upper() != "ACCEPTED":
                        raise InvalidPlannerTransitionError("timer event is not consumable")
                    conn.execute(
                        "UPDATE task_inbox_events SET status = 'CONSUMED', consumed_at = ? WHERE event_id = ?",
                        (now, event_id),
                    )
                conn.execute("UPDATE actions SET status = 'pending', updated_at = ? WHERE id = ?", (now, action_id))
                conn.execute("UPDATE tasks SET status = 'active', updated_at = ? WHERE id = ?", (now, task_id))
                conn.execute(
                    """
                    UPDATE task_runtime
                    SET phase = 'executing', runtime_revision = runtime_revision + 1,
                        wait_reason = NULL, wait_json = NULL, wait_id = NULL, wait_kind = NULL,
                        wait_target_type = NULL, wait_target_id = NULL, wake_at = NULL, updated_at = ?
                    WHERE task_id = ?
                    """,
                    (now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, "action.retry_ready", _json({"action_id": action_id, "wait_id": wait_id}), now),
                )
                conn.commit()
                current = conn.execute("SELECT * FROM actions WHERE id = ?", (action_id,)).fetchone()
                assert current is not None
                return self._action_dict(current)
            except Exception:
                conn.rollback()
                raise
            finally:
                self._close(conn)

    def get_next_action(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Return the current unfinished action.

        A dispatched action remains retrievable until a terminal result is
        acknowledged. This makes reconnect/retry safe: losing one HTTP
        response does not lose the logical step.
        """
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    """
                    SELECT * FROM actions
                    WHERE task_id = ? AND status IN ('pending', 'dispatched')
                    ORDER BY step_index ASC LIMIT 1
                    """,
                    (task_id,),
                ).fetchone()
                if row is None:
                    return None
                if row["status"] == "pending":
                    now = utc_now()
                    conn.execute(
                        "UPDATE actions SET status = 'dispatched', updated_at = ? WHERE id = ?",
                        (now, row["id"]),
                    )
                    conn.execute(
                        "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                        (
                            task_id,
                            "action.dispatched",
                            _json({"action_id": row["id"], "step_index": row["step_index"]}),
                            now,
                        ),
                    )
                    action_id = str(row["id"])
                    action_type = str(row["action_type"])
                    upsert_timeline_item(
                        conn,
                        task_id=task_id,
                        source_key=f"action:{action_id}:activity",
                        kind="TOOL_ACTIVITY",
                        presentation_state="ACTIVE",
                        title=capability_activity_title(action_type, "active"),
                        summary=None,
                        payload={"action_id": action_id, "capability": action_type},
                        source_type="ACTION",
                        source_id=action_id,
                        attention_level="QUIET",
                        now=now,
                    )
                    conn.commit()
                    row = conn.execute("SELECT * FROM actions WHERE id = ?", (row["id"],)).fetchone()
                assert row is not None
                return self._action_dict(row)
            finally:
                self._close(conn)

    def finish_action(
        self,
        task_id: str,
        action_id: str,
        succeeded: bool,
        result: Dict[str, Any],
        error: Optional[str],
    ) -> Dict[str, Any]:
        """Persist a terminal action exactly once.

        Duplicate result POSTs are idempotent: the already-persisted terminal
        result is returned without advancing the task twice.
        """
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT * FROM actions WHERE id = ? AND task_id = ?",
                    (action_id, task_id),
                ).fetchone()
                if row is None:
                    raise KeyError(action_id)
                if row["status"] in ("succeeded", "failed"):
                    return self._action_dict(row)

                now = utc_now()
                action_status = "succeeded" if succeeded else "failed"
                task_status = "completed" if succeeded else "failed"
                conn.execute(
                    """
                    UPDATE actions
                    SET status = ?, result_json = ?, error_text = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (action_status, _json(result), error, now, action_id),
                )
                conn.execute(
                    "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                    (task_status, now, task_id),
                )
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (
                        task_id,
                        "action.verified" if succeeded else "action.failed",
                        _json({"action_id": action_id, "result": result, "error": error}),
                        now,
                    ),
                )
                action_type = str(row["action_type"])
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"action:{action_id}:activity",
                    kind="TOOL_ACTIVITY",
                    presentation_state="COMPLETE" if succeeded else "FAILED",
                    title=capability_activity_title(action_type, "complete" if succeeded else "failed"),
                    summary=error if not succeeded else None,
                    payload={"action_id": action_id, "capability": action_type},
                    source_type="ACTION",
                    source_id=action_id,
                    attention_level="IMPORTANT" if not succeeded else "QUIET",
                    now=now,
                )
                upsert_timeline_item(
                    conn,
                    task_id=task_id,
                    source_key=f"task:{task_id}:terminal",
                    kind="RESULT" if succeeded else "FAILURE_NOTE",
                    presentation_state="COMPLETE" if succeeded else "FAILED",
                    title="任务已完成" if succeeded else "任务失败",
                    summary=error if not succeeded else None,
                    payload={"task_id": task_id, "status": task_status},
                    source_type="TASK",
                    source_id=task_id,
                    attention_level="IMPORTANT" if not succeeded else "QUIET",
                    now=now,
                )
                conn.commit()
                row = conn.execute("SELECT * FROM actions WHERE id = ?", (action_id,)).fetchone()
                assert row is not None
                return self._action_dict(row)
            finally:
                self._close(conn)

    def record_trace_event(
        self,
        task_id: str,
        event_type: str,
        data: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Append bounded diagnostic/runtime evidence without owning state."""
        if not event_type or not event_type.strip():
            raise ValueError("event_type must not be empty")
        now = utc_now()
        with self._lock:
            conn = self._connect()
            try:
                conn.execute(
                    "INSERT INTO traces (task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
                    (task_id, event_type.strip(), _json(dict(data or {})), now),
                )
                conn.commit()
            finally:
                self._close(conn)

    def trace(self, task_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    "SELECT id, event_type, data_json, created_at FROM traces WHERE task_id = ? ORDER BY id",
                    (task_id,),
                ).fetchall()
            finally:
                self._close(conn)
        return [
            {
                "id": row["id"],
                "event_type": row["event_type"],
                "data": _loads(row["data_json"], {}),
                "created_at": row["created_at"],
            }
            for row in rows
        ]

    @staticmethod
    def _task_dict(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "task_id": row["id"],
            "submission_id": row["submission_id"],
            "thread_id": row["thread_id"],
            "parent_task_id": row["parent_task_id"],
            "goal": row["goal"],
            "invocation_source": row["invocation_source"],
            "policy_snapshot": _loads(row["policy_snapshot_json"], {}),
            "status": row["status"],
            "current_step": row["current_step"],
            "cancel_requested_at": row["cancel_requested_at"],
            "cancel_reason": row["cancel_reason"],
            "result": _loads(row["result_json"], None),
            "terminal_reason": row["terminal_reason"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "finished_at": row["finished_at"],
        }

    @staticmethod
    def _observation_dict(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "observation_id": row["id"],
            "task_id": row["task_id"],
            "action_id": row["action_id"],
            "capability": row["capability"],
            "data": _loads(row["data_json"], {}),
            "verified": bool(row["verified"]),
            "source_attempt_id": row["source_attempt_id"],
            "verification_mode": row["verification_mode"],
            "verified_at": row["verified_at"],
            "created_at": row["created_at"],
        }

    @staticmethod
    def _attempt_dict(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "attempt_id": row["id"],
            "action_id": row["action_id"],
            "attempt_number": int(row["attempt_number"]),
            "status": row["status"],
            "latest_outcome": row["latest_outcome"],
            "source_kind": row["source_kind"],
            "source_request_ref": row["source_request_ref"],
            "source_round": int(row["source_round"]),
            "source_operation_ref": row["source_operation_ref"],
            "source_operation_status": row["source_operation_status"],
            "source_poll_after": row["source_poll_after"],
            "source_ttl_at": row["source_ttl_at"],
            "result": _loads(row["result_json"], None),
            "raw_result_ref": row["raw_result_ref"],
            "dispatch_snapshot": _loads(row["dispatch_snapshot_json"], None),
            "dispatch_snapshot_ref": row["dispatch_snapshot_ref"],
            "dispatch_digest": row["dispatch_digest"],
            "approved_input_request_id": row["approved_input_request_id"],
            "policy_revision": row["policy_revision"],
            "error": row["error_text"],
            "started_at": row["started_at"],
            "finished_at": row["finished_at"],
            "updated_at": row["updated_at"],
        }

    @staticmethod
    def _control_interrupt_dict(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "decision_id": row["id"],
            "task_id": row["task_id"],
            "action_id": row["action_id"],
            "attempt_id": row["attempt_id"],
            "basis_runtime_revision": int(row["basis_runtime_revision"]),
            "basis_inbox_seq": int(row["basis_inbox_seq"]),
            "user_event_ids": _loads(row["user_event_ids_json"], []),
            "intent": row["intent"],
            "confidence": row["confidence"],
            "reason": row["reason"],
            "status": row["status"],
            "created_at": row["created_at"],
        }

    @staticmethod
    def _action_dict(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "action_id": row["id"],
            "task_id": row["task_id"],
            "step_index": row["step_index"],
            "action_type": row["action_type"],
            "payload": _loads(row["payload_json"], {}),
            "expected": _loads(row["expected_json"], {}),
            "status": row["status"],
            "idempotency_key": row["idempotency_key"],
            "on_verified": row["on_verified"],
            "planner_decision_id": row["planner_decision_id"],
            "capability_definition_digest": row["capability_definition_digest"],
            "source_target": _loads(row["source_target_json"], None),
            "execution_profile": _loads(row["execution_profile_json"], None),
            "result": _loads(row["result_json"], None),
            "failure_code": row["failure_code"],
            "failure_detail": _loads(row["failure_detail_json"], None),
            "interrupt_requested_at": row["interrupt_requested_at"],
            "interrupt_reason": row["interrupt_reason"],
            "error": row["error_text"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }
