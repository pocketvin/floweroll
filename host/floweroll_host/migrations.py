from __future__ import annotations

import sqlite3
from collections.abc import Callable


LATEST_SCHEMA_VERSION = 5


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def _add_column_if_missing(
    conn: sqlite3.Connection,
    table: str,
    column: str,
    definition: str,
) -> None:
    if column not in _table_columns(conn, table):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


def _create_legacy_compatible_core(conn: sqlite3.Connection) -> None:
    """Create the Planner V0 tables when bootstrapping a brand-new database.

    Existing databases from before schema versioning already contain these
    tables. Keeping the physical legacy column names during migration 1 lets
    the verified Planner/probe path coexist with the new Runtime foundation.
    """

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            goal TEXT NOT NULL,
            invocation_source TEXT NOT NULL,
            policy_snapshot_json TEXT NOT NULL,
            status TEXT NOT NULL,
            current_step INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS task_runtime (
            task_id TEXT PRIMARY KEY,
            phase TEXT NOT NULL,
            plan_json TEXT NOT NULL,
            wait_reason TEXT,
            wait_json TEXT,
            pending_clarification_id TEXT,
            interpreted_goal_summary TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS actions (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            step_index INTEGER NOT NULL,
            action_type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            expected_json TEXT NOT NULL,
            status TEXT NOT NULL,
            idempotency_key TEXT NOT NULL UNIQUE,
            on_verified TEXT NOT NULL DEFAULT 'COMPLETE',
            result_json TEXT,
            error_text TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id)
        )
        """
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_actions_task_step "
        "ON actions(task_id, step_index)"
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS traces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            data_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS planner_decisions (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            decision_type TEXT NOT NULL,
            decision_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            UNIQUE(task_id, sequence)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS observations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            action_id TEXT,
            capability TEXT NOT NULL,
            data_json TEXT NOT NULL,
            verified INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            FOREIGN KEY(action_id) REFERENCES actions(id)
        )
        """
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_observations_action "
        "ON observations(action_id) WHERE action_id IS NOT NULL"
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS clarifications (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            decision_id TEXT NOT NULL,
            question TEXT NOT NULL,
            accepts_text INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            status TEXT NOT NULL,
            response_json TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            FOREIGN KEY(decision_id) REFERENCES planner_decisions(id)
        )
        """
    )


def _migration_1_runtime_foundation(conn: sqlite3.Connection) -> None:
    _create_legacy_compatible_core(conn)

    # Columns that existed in some Planner V0 databases via ad-hoc upgrades.
    _add_column_if_missing(conn, "actions", "on_verified", "TEXT NOT NULL DEFAULT 'COMPLETE'")
    _add_column_if_missing(conn, "clarifications", "accepts_text", "INTEGER NOT NULL DEFAULT 0")

    # Task / TaskRuntime foundations from D-055 through D-060.
    for column, definition in (
        ("submission_id", "TEXT"),
        ("cancel_requested_at", "TEXT"),
        ("cancel_reason", "TEXT"),
        ("result_json", "TEXT"),
        ("terminal_reason", "TEXT"),
        ("finished_at", "TEXT"),
    ):
        _add_column_if_missing(conn, "tasks", column, definition)
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_submission_id "
        "ON tasks(submission_id) WHERE submission_id IS NOT NULL"
    )

    for column, definition in (
        ("current_task_brief", "TEXT"),
        ("runtime_revision", "INTEGER NOT NULL DEFAULT 0"),
        ("wait_id", "TEXT"),
        ("wait_kind", "TEXT"),
        ("wait_target_type", "TEXT"),
        ("wait_target_id", "TEXT"),
        ("wake_at", "TEXT"),
        ("block_reason", "TEXT"),
        ("block_payload_json", "TEXT"),
        ("runtime_contract_version", "INTEGER NOT NULL DEFAULT 1"),
        ("planner_contract_version", "INTEGER NOT NULL DEFAULT 1"),
        ("inbox_watermark", "INTEGER NOT NULL DEFAULT 0"),
        ("revealed_capabilities_json", "TEXT NOT NULL DEFAULT '[]'"),
        ("budget_json", "TEXT NOT NULL DEFAULT '{}'"),
        ("planner_calls", "INTEGER NOT NULL DEFAULT 0"),
        ("semantic_actions", "INTEGER NOT NULL DEFAULT 0"),
        ("capability_searches", "INTEGER NOT NULL DEFAULT 0"),
    ):
        _add_column_if_missing(conn, "task_runtime", column, definition)

    # Preserve legacy semantic columns while adding the exact execution snapshot
    # metadata needed by the new Runtime path.
    for column, definition in (
        ("planner_decision_id", "TEXT"),
        ("capability_definition_digest", "TEXT"),
        ("source_target_json", "TEXT"),
        ("execution_profile_json", "TEXT"),
        ("failure_code", "TEXT"),
        ("failure_detail_json", "TEXT"),
    ):
        _add_column_if_missing(conn, "actions", column, definition)

    for column, definition in (
        ("resolved_by_event_id", "TEXT"),
        ("contract_version", "INTEGER NOT NULL DEFAULT 1"),
    ):
        _add_column_if_missing(conn, "clarifications", column, definition)

    for column, definition in (
        ("source_attempt_id", "TEXT"),
        ("model_view_json", "TEXT"),
        ("raw_evidence_json", "TEXT"),
        ("raw_ref", "TEXT"),
        ("provenance_json", "TEXT"),
        ("verification_mode", "TEXT"),
        ("verified_at", "TEXT"),
    ):
        _add_column_if_missing(conn, "observations", column, definition)

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS action_attempts (
            id TEXT PRIMARY KEY,
            action_id TEXT NOT NULL,
            attempt_number INTEGER NOT NULL,
            status TEXT NOT NULL,
            latest_outcome TEXT,
            source_kind TEXT NOT NULL,
            source_request_ref TEXT,
            source_round INTEGER NOT NULL DEFAULT 0,
            source_operation_ref TEXT,
            source_operation_status TEXT,
            source_poll_after TEXT,
            source_ttl_at TEXT,
            result_json TEXT,
            raw_result_ref TEXT,
            dispatch_snapshot_json TEXT,
            dispatch_snapshot_ref TEXT,
            dispatch_digest TEXT,
            approved_input_request_id TEXT,
            policy_revision TEXT,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(action_id) REFERENCES actions(id),
            UNIQUE(action_id, attempt_number)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_action_attempts_action_status "
        "ON action_attempts(action_id, status)"
    )

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS action_input_requests (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            action_id TEXT NOT NULL,
            attempt_id TEXT,
            prompt TEXT NOT NULL,
            suggested_options_json TEXT NOT NULL DEFAULT '[]',
            response_schema_json TEXT,
            accepts_text INTEGER NOT NULL DEFAULT 0,
            reason TEXT NOT NULL,
            status TEXT NOT NULL,
            response_json TEXT,
            answered_by_event_id TEXT,
            source_continuation_ref TEXT,
            binding_json TEXT NOT NULL DEFAULT '{}',
            binding_digest TEXT NOT NULL,
            contract_version INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            FOREIGN KEY(action_id) REFERENCES actions(id),
            FOREIGN KEY(attempt_id) REFERENCES action_attempts(id)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_action_input_requests_task_status "
        "ON action_input_requests(task_id, status)"
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_action_input_pending_attempt "
        "ON action_input_requests(attempt_id) "
        "WHERE attempt_id IS NOT NULL AND status = 'PENDING'"
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_action_input_pending_predispatch "
        "ON action_input_requests(action_id) "
        "WHERE attempt_id IS NULL AND status = 'PENDING'"
    )

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS task_inbox_events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            task_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            source TEXT NOT NULL,
            target_type TEXT,
            target_id TEXT,
            payload_json TEXT NOT NULL,
            raw_ref TEXT,
            status TEXT NOT NULL,
            ignore_reason TEXT,
            occurred_at TEXT,
            received_at TEXT NOT NULL,
            consumed_at TEXT,
            FOREIGN KEY(task_id) REFERENCES tasks(id)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_task_inbox_pending "
        "ON task_inbox_events(task_id, status, seq)"
    )

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS artifacts (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            current_revision_id TEXT,
            final_revision_id TEXT,
            created_by_action_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            FOREIGN KEY(created_by_action_id) REFERENCES actions(id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS artifact_revisions (
            id TEXT PRIMARY KEY,
            artifact_id TEXT NOT NULL,
            revision_number INTEGER NOT NULL,
            content_json TEXT,
            content_ref TEXT,
            content_digest TEXT NOT NULL,
            created_by TEXT NOT NULL,
            source_event_id TEXT,
            source_action_id TEXT,
            source_decision_id TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(artifact_id) REFERENCES artifacts(id),
            FOREIGN KEY(source_action_id) REFERENCES actions(id),
            FOREIGN KEY(source_decision_id) REFERENCES planner_decisions(id),
            UNIQUE(artifact_id, revision_number)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_artifact_revisions_artifact "
        "ON artifact_revisions(artifact_id, revision_number)"
    )

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS task_timeline_items (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            display_order INTEGER NOT NULL,
            kind TEXT NOT NULL,
            presentation_state TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT,
            payload_json TEXT NOT NULL DEFAULT '{}',
            source_type TEXT NOT NULL,
            source_id TEXT,
            source_key TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            UNIQUE(task_id, display_order),
            UNIQUE(task_id, source_key)
        )
        """
    )

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS presentation_events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            task_id TEXT NOT NULL,
            timeline_item_id TEXT,
            operation TEXT NOT NULL,
            public_payload_json TEXT NOT NULL,
            attention_level TEXT NOT NULL,
            source_key TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            FOREIGN KEY(timeline_item_id) REFERENCES task_timeline_items(id),
            UNIQUE(task_id, source_key)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_presentation_events_task_seq "
        "ON presentation_events(task_id, seq)"
    )


def _migration_2_timeline_revision(conn: sqlite3.Connection) -> None:
    # Public timeline cards are stable while their display state can evolve.
    # Revision provides a durable replay identity for each material UI change.
    _add_column_if_missing(
        conn,
        "task_timeline_items",
        "revision",
        "INTEGER NOT NULL DEFAULT 1",
    )

    # Version-1 databases may already contain Planner/probe history but no
    # public projection. Backfill only safe coarse cards from durable state;
    # low-level technical chronology remains in Trace.
    from .presentation import capability_label, upsert_timeline_item

    task_rows = conn.execute("SELECT * FROM tasks ORDER BY created_at, id").fetchall()
    for task in task_rows:
        task_id = str(task["id"])
        upsert_timeline_item(
            conn,
            task_id=task_id,
            source_key=f"task:{task_id}:accepted",
            kind="PUBLIC_WORKLOG",
            presentation_state="COMPLETE",
            title="任务已交给小卷",
            summary=str(task["goal"]),
            payload={"task_id": task_id},
            source_type="TASK",
            source_id=task_id,
            attention_level="QUIET",
            now=str(task["created_at"]),
        )

        actions = conn.execute(
            "SELECT * FROM actions WHERE task_id = ? ORDER BY step_index, created_at",
            (task_id,),
        ).fetchall()
        for action in actions:
            status = str(action["status"]).lower()
            label = capability_label(str(action["action_type"]))
            if status in {"succeeded", "completed"}:
                state, title = "COMPLETE", f"{label}已完成"
            elif status in {"failed"}:
                state, title = "FAILED", f"{label}失败"
            elif status in {"dispatched", "executing", "in_flight"}:
                state, title = "ACTIVE", f"正在{label}"
            else:
                state, title = "ACTIVE", f"准备{label}"
            upsert_timeline_item(
                conn,
                task_id=task_id,
                source_key=f"action:{action['id']}:activity",
                kind="TOOL_ACTIVITY",
                presentation_state=state,
                title=title,
                summary=action["error_text"] if state == "FAILED" else None,
                payload={"action_id": action["id"], "capability": action["action_type"]},
                source_type="ACTION",
                source_id=str(action["id"]),
                attention_level="IMPORTANT" if state == "FAILED" else "QUIET",
                now=str(action["updated_at"]),
            )

        pending = conn.execute(
            "SELECT * FROM clarifications WHERE task_id = ? AND LOWER(status) = 'pending' "
            "ORDER BY created_at DESC LIMIT 1",
            (task_id,),
        ).fetchone()
        if pending is not None:
            upsert_timeline_item(
                conn,
                task_id=task_id,
                source_key=f"clarification:{pending['id']}:waiting",
                kind="WAITING_FOR_USER",
                presentation_state="NEEDS_USER",
                title=str(pending["question"]),
                summary=None,
                payload={"clarification_id": pending["id"]},
                source_type="CLARIFICATION",
                source_id=str(pending["id"]),
                attention_level="USER_REQUIRED",
                now=str(pending["updated_at"]),
            )

        terminal = str(task["status"]).lower()
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
                attention_level="QUIET",
                now=str(task["updated_at"]),
            )


def _migration_3_attempt_error_evidence(conn: sqlite3.Connection) -> None:
    # Attempt-local failure/UNKNOWN evidence must survive independently from
    # Action summary state so restart/reconciliation can explain the exact
    # invocation that became ambiguous or failed.
    _add_column_if_missing(conn, "action_attempts", "error_text", "TEXT")


def _migration_4_control_interrupts(conn: sqlite3.Connection) -> None:
    # Natural-language control interrupts are durable runtime state. They are
    # intentionally separate from Task cancellation so “stop this action and
    # do something else” can preserve the Task and its pending UserTurn.
    _add_column_if_missing(conn, "actions", "interrupt_requested_at", "TEXT")
    _add_column_if_missing(conn, "actions", "interrupt_reason", "TEXT")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS control_interrupt_decisions (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            action_id TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            basis_runtime_revision INTEGER NOT NULL,
            basis_inbox_seq INTEGER NOT NULL,
            user_event_ids_json TEXT NOT NULL,
            intent TEXT NOT NULL,
            confidence TEXT NOT NULL,
            reason TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id),
            FOREIGN KEY(action_id) REFERENCES actions(id),
            FOREIGN KEY(attempt_id) REFERENCES action_attempts(id),
            UNIQUE(attempt_id, basis_inbox_seq)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_control_interrupt_task_attempt "
        "ON control_interrupt_decisions(task_id, attempt_id, basis_inbox_seq)"
    )


def _migration_5_task_threads(conn: sqlite3.Connection) -> None:
    """Add durable Home-thread / episode lineage without rewriting Task truth.

    Existing Task rows become one-episode threads (`thread_id == task.id`). New
    terminal follow-up Tasks may point at `parent_task_id` while inheriting the
    same thread identity. Keeping this relation on the Host means a recreated
    iPhone UI can recover the continuous history without trusting local caches.
    """

    _add_column_if_missing(conn, "tasks", "thread_id", "TEXT")
    _add_column_if_missing(conn, "tasks", "parent_task_id", "TEXT")
    conn.execute("UPDATE tasks SET thread_id = id WHERE thread_id IS NULL OR thread_id = ''")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_tasks_thread_updated "
        "ON tasks(thread_id, updated_at DESC, id DESC)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_tasks_parent_task "
        "ON tasks(parent_task_id) WHERE parent_task_id IS NOT NULL"
    )


_MIGRATIONS: dict[int, Callable[[sqlite3.Connection], None]] = {
    1: _migration_1_runtime_foundation,
    2: _migration_2_timeline_revision,
    3: _migration_3_attempt_error_evidence,
    4: _migration_4_control_interrupts,
    5: _migration_5_task_threads,
}


def migrate(conn: sqlite3.Connection) -> int:
    current = int(conn.execute("PRAGMA user_version").fetchone()[0])
    if current > LATEST_SCHEMA_VERSION:
        raise RuntimeError(
            f"database schema version {current} is newer than supported {LATEST_SCHEMA_VERSION}"
        )

    for version in range(current + 1, LATEST_SCHEMA_VERSION + 1):
        migration = _MIGRATIONS.get(version)
        if migration is None:
            raise RuntimeError(f"missing database migration {version}")

        conn.execute("BEGIN IMMEDIATE")
        try:
            migration(conn)
            violations = conn.execute("PRAGMA foreign_key_check").fetchall()
            if violations:
                raise RuntimeError(f"foreign key violations after migration {version}: {violations!r}")
            conn.execute(f"PRAGMA user_version = {version}")
            conn.commit()
        except Exception:
            conn.rollback()
            raise

    return current if current == LATEST_SCHEMA_VERSION else LATEST_SCHEMA_VERSION
