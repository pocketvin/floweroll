from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, Iterable, List, Optional

from .storage import Storage


def _dt(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _elapsed_ms(start: Optional[str], end: Optional[str]) -> float:
    left, right = _dt(start), _dt(end)
    if left is None or right is None:
        return 0.0
    return max(0.0, (right - left).total_seconds() * 1000.0)


def _sum_numeric(rows: Iterable[Dict[str, Any]], key: str) -> float:
    total = 0.0
    for row in rows:
        value = row.get("data", {}).get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            total += float(value)
    return total


def task_latency_breakdown(storage: Storage, task_id: str) -> Dict[str, Any]:
    """Build a stable latency attribution from durable Task trace events.

    New traces contain explicit Planner/tool/verifier metrics. Historical traces
    are still useful: model and dispatch intervals are reconstructed from the
    existing planner/action timestamps so Build 1 can be compared with Build 2.
    """
    task = storage.get_task(task_id)
    if task is None:
        raise KeyError(task_id)
    traces = storage.trace(task_id)
    by_type: Dict[str, List[Dict[str, Any]]] = {}
    for row in traces:
        by_type.setdefault(str(row["event_type"]), []).append(row)

    created = next(iter(by_type.get("task.created", [])), None)
    created_at = created["created_at"] if created else task.get("created_at")
    terminal_at = task.get("finished_at") or (traces[-1]["created_at"] if traces else created_at)
    total_ms = _elapsed_ms(created_at, terminal_at)

    planner_starts = by_type.get("planner.call.started", [])
    planner_metrics = by_type.get("planner.call.metrics", [])
    planner_commits = by_type.get("planner.call.committed", [])
    if planner_metrics:
        planner_model_ms = _sum_numeric(planner_metrics, "model_ms")
    else:
        # Historical fallback: pair each call start with the next durable
        # planner decision/failure/stale event.
        planner_ends = sorted(
            by_type.get("planner.decision", [])
            + by_type.get("planner.call.failed", [])
            + by_type.get("planner.result.stale", []),
            key=lambda row: row["created_at"],
        )
        used: set[int] = set()
        planner_model_ms = 0.0
        for start in planner_starts:
            for index, end in enumerate(planner_ends):
                if index in used or end["created_at"] < start["created_at"]:
                    continue
                planner_model_ms += _elapsed_ms(start["created_at"], end["created_at"])
                used.add(index)
                break

    if planner_commits:
        planner_runtime_ms = _sum_numeric(planner_commits, "total_runtime_ms")
        # Failed/stale calls do not have committed events; retain their measured
        # model time rather than silently dropping them.
        committed_numbers = {
            row.get("data", {}).get("call_number") for row in planner_commits
        }
        planner_runtime_ms += sum(
            float(row.get("data", {}).get("model_ms", 0.0))
            for row in planner_metrics
            if row.get("data", {}).get("call_number") not in committed_numbers
        )
    else:
        planner_runtime_ms = planner_model_ms

    action_capability: Dict[str, str] = {}
    for event_type in (
        "action.tool.execution",
        "action.result.received",
        "action.verification.metrics",
    ):
        for row in by_type.get(event_type, []):
            data = row.get("data", {})
            action_id, capability = data.get("action_id"), data.get("capability")
            if isinstance(action_id, str) and isinstance(capability, str):
                action_capability[action_id] = capability
    for row in by_type.get("observation.verified", []):
        data = row.get("data", {})
        action_id, capability = data.get("action_id"), data.get("capability")
        if isinstance(action_id, str) and isinstance(capability, str):
            action_capability[action_id] = capability

    planned_at = {
        row.get("data", {}).get("action_id"): row["created_at"]
        for row in by_type.get("action.planned", [])
        if isinstance(row.get("data", {}).get("action_id"), str)
    }
    result_received = {
        row.get("data", {}).get("attempt_id"): row["created_at"]
        for row in by_type.get("action.result.received", [])
        if isinstance(row.get("data", {}).get("attempt_id"), str)
    }
    finished_at = {
        row.get("data", {}).get("attempt_id"): row["created_at"]
        for row in by_type.get("action.attempt.finished", [])
        if isinstance(row.get("data", {}).get("attempt_id"), str)
    }

    dispatch_wait_ms = 0.0
    device_dispatch_wait_ms = 0.0
    search_ms = 0.0
    tool_ms = 0.0
    search_count = 0
    tool_count = 0
    for row in by_type.get("action.attempt.started", []):
        data = row.get("data", {})
        action_id = data.get("action_id")
        attempt_id = data.get("attempt_id")
        capability = action_capability.get(action_id, "")
        wait_ms = _elapsed_ms(planned_at.get(action_id), row["created_at"])
        dispatch_wait_ms += wait_ms
        if data.get("source_kind") == "ios":
            device_dispatch_wait_ms += wait_ms
        end_at = result_received.get(attempt_id) or finished_at.get(attempt_id)
        execution_ms = _elapsed_ms(row["created_at"], end_at)
        if capability == "capability.search":
            search_count += 1
            search_ms += execution_ms
        elif capability:
            tool_count += 1
            tool_ms += execution_ms

    verifier_ms = _sum_numeric(by_type.get("action.verification.metrics", []), "verifier_ms")
    # Planner decision commit is already included in planner_runtime_ms. Keep
    # it visible as a diagnostic subset, but do not count it twice. This
    # terminal bucket is only the deterministic verifier/result -> durable
    # Task/Action state commit after a tool result.
    planner_commit_ms = _sum_numeric(planner_commits, "commit_ms")
    terminal_commit_ms = _sum_numeric(
        by_type.get("action.verification.metrics", []), "terminal_commit_ms"
    )

    first_planner = None
    worker_started = by_type.get("runtime.planner.worker_started", [])
    if worker_started:
        first_planner = worker_started[0]["created_at"]
    elif planner_starts:
        first_planner = planner_starts[0]["created_at"]
    scheduler_wait_ms = _elapsed_ms(created_at, first_planner)

    accounted = (
        planner_runtime_ms
        + scheduler_wait_ms
        + dispatch_wait_ms
        + search_ms
        + tool_ms
        + verifier_ms
        + terminal_commit_ms
    )
    return {
        "task_id": task_id,
        "goal": task.get("goal"),
        "final_status": task.get("status"),
        "total_ms": round(total_ms, 3),
        "planner_calls": len(planner_starts),
        "planner_model_ms": round(planner_model_ms, 3),
        "planner_runtime_ms": round(planner_runtime_ms, 3),
        "capability_search_count": search_count,
        "capability_search_ms": round(search_ms, 3),
        "tool_count": tool_count,
        "tool_or_device_roundtrip_ms": round(tool_ms, 3),
        "dispatch_wait_ms": round(dispatch_wait_ms, 3),
        "device_dispatch_wait_ms": round(device_dispatch_wait_ms, 3),
        "verifier_ms": round(verifier_ms, 3),
        "planner_commit_ms": round(planner_commit_ms, 3),
        "terminal_commit_ms": round(terminal_commit_ms, 3),
        "scheduler_wait_ms": round(scheduler_wait_ms, 3),
        "runtime_other_ms": round(max(0.0, total_ms - accounted), 3),
        "request_bytes": [
            row.get("data", {}).get("request_bytes") for row in planner_metrics
            if isinstance(row.get("data", {}).get("request_bytes"), int)
        ],
        "context_chars": [
            row.get("data", {}).get("context_chars") for row in planner_metrics
            if isinstance(row.get("data", {}).get("context_chars"), int)
        ],
        "prompt_tokens": int(_sum_numeric(planner_metrics, "prompt_tokens")),
        "completion_tokens": int(_sum_numeric(planner_metrics, "completion_tokens")),
        "total_tokens": int(_sum_numeric(planner_metrics, "total_tokens")),
    }
