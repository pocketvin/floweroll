from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from .storage import InvalidPlannerTransitionError, Storage


class RecoveryCoordinator:
    """Deterministic recovery of durable wait boundaries.

    It does not call a model or provider. A due wait first becomes an idempotent
    TIMER_FIRED inbox event; consuming that event only makes the correct owner
    eligible to continue. Actual Planner/source calls remain outside recovery.
    """

    def __init__(self, storage: Storage) -> None:
        self.storage = storage

    def scan(self, *, now: Optional[datetime] = None) -> Dict[str, List[Dict[str, Any]]]:
        current = now or datetime.now(timezone.utc)
        if current.tzinfo is None or current.utcoffset() is None:
            raise ValueError("recovery time must be timezone-aware")
        return self.storage.recovery_candidates(now=current.isoformat())

    def recover_control_events(self) -> List[Dict[str, Any]]:
        """Consume deterministic accepted control inputs left by a crash."""

        recovered: List[Dict[str, Any]] = []
        candidates = self.storage.recovery_candidates(
            now=datetime.now(timezone.utc).isoformat()
        )["accepted_inbox"]
        for candidate in candidates:
            task_id = str(candidate["task_id"])
            for event in self.storage.inbox_events(task_id):
                if str(event["status"]).upper() != "ACCEPTED":
                    continue
                event_type = str(event["event_type"])
                event_id = str(event["event_id"])
                if event_type == "ACTION_INPUT_RESPONSE":
                    self.storage.consume_action_input_response(event_id=event_id)
                    recovered.append({
                        "task_id": task_id,
                        "event_id": event_id,
                        "event_type": event_type,
                        "status": "RECOVERED",
                        "owner": "ACTION_INPUT",
                    })
                elif event_type == "CANCEL_REQUEST":
                    self.storage.consume_cancel_request(event_id=event_id)
                    recovered.append({
                        "task_id": task_id,
                        "event_id": event_id,
                        "event_type": event_type,
                        "status": "RECOVERED",
                        "owner": "CANCELLATION",
                    })
        return recovered

    def recover_startup(self, *, now: Optional[datetime] = None) -> List[Dict[str, Any]]:
        return self.recover_control_events() + self.recover_due(now=now)

    def recover_due(self, *, now: Optional[datetime] = None) -> List[Dict[str, Any]]:
        current = now or datetime.now(timezone.utc)
        if current.tzinfo is None or current.utcoffset() is None:
            raise ValueError("recovery time must be timezone-aware")
        current_iso = current.isoformat()
        recovered: List[Dict[str, Any]] = []

        for wait in self.storage.recovery_candidates(now=current_iso)["due_waits"]:
            task_id = str(wait["task_id"])
            wait_id = str(wait["wait_id"])
            wait_kind = str(wait["wait_kind"])
            event_id = f"timer:{wait_id}"
            try:
                admitted = self.storage.admit_inbox_event(
                    task_id=task_id,
                    event_id=event_id,
                    event_type="TIMER_FIRED",
                    source="runtime_scheduler",
                    target_type="WAIT",
                    target_id=wait_id,
                    payload={"wait_id": wait_id, "scheduled_for": wait["wake_at"]},
                    occurred_at=current_iso,
                )

                if wait_kind in {"TIME", "EXTERNAL_CONDITION"}:
                    self.storage.resume_planner_wait_from_timer(
                        task_id=task_id,
                        wait_id=wait_id,
                        event_id=event_id,
                    )
                    owner = "PLANNER"
                elif wait_kind == "RETRY_BACKOFF":
                    if wait["wait_target_type"] == "ACTION" and wait["wait_target_id"]:
                        self.storage.resume_action_retry_wait(
                            task_id=task_id,
                            action_id=str(wait["wait_target_id"]),
                            wait_id=wait_id,
                            event_id=event_id,
                        )
                        owner = "EXECUTION_RETRY"
                    elif wait["wait_target_type"] == "PLANNER":
                        self.storage.resume_planner_retry_wait(
                            task_id=task_id,
                            wait_id=wait_id,
                            event_id=event_id,
                        )
                        owner = "PLANNER"
                    else:
                        raise InvalidPlannerTransitionError(
                            "retry wait has no supported Action/Planner target"
                        )
                elif wait_kind == "SOURCE_OPERATION":
                    if wait["wait_target_type"] != "ATTEMPT" or not wait["wait_target_id"]:
                        raise InvalidPlannerTransitionError("source-operation wait has no Attempt target")
                    attempt_id = str(wait["wait_target_id"])
                    attempt = self.storage.get_action_attempt(attempt_id)
                    if attempt is None:
                        raise InvalidPlannerTransitionError("source-operation Attempt no longer exists")
                    self.storage.resume_source_operation_from_timer(
                        task_id=task_id,
                        action_id=str(attempt["action_id"]),
                        attempt_id=attempt_id,
                        wait_id=wait_id,
                        event_id=event_id,
                    )
                    owner = "SOURCE_OPERATION"
                else:
                    # Wait kinds with no time-owned resumption (for example a
                    # pure provider callback wait) must not be guessed here.
                    recovered.append(
                        {
                            "task_id": task_id,
                            "wait_id": wait_id,
                            "wait_kind": wait_kind,
                            "status": "UNHANDLED_WAIT_KIND",
                            "event_id": event_id,
                        }
                    )
                    continue

                recovered.append(
                    {
                        "task_id": task_id,
                        "wait_id": wait_id,
                        "wait_kind": wait_kind,
                        "owner": owner,
                        "event_id": event_id,
                        "event_replay": bool(admitted.get("duplicate")),
                        "status": "RECOVERED",
                    }
                )
            except InvalidPlannerTransitionError as exc:
                # The Task may have moved between scan and claim. Treat this as
                # a stale recovery candidate, never as permission to wake the
                # newer wait.
                recovered.append(
                    {
                        "task_id": task_id,
                        "wait_id": wait_id,
                        "wait_kind": wait_kind,
                        "event_id": event_id,
                        "status": "STALE",
                        "reason": str(exc),
                    }
                )

        return recovered
