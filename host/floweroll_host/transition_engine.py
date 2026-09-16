from __future__ import annotations

from dataclasses import dataclass
from typing import FrozenSet, Optional


@dataclass(frozen=True)
class RuntimeSnapshot:
    task_status: str
    phase: str
    runtime_revision: int
    has_open_action: bool
    pending_clarification_id: Optional[str]
    wait_kind: Optional[str]
    cancel_requested: bool
    accepted_event_types: FrozenSet[str]


@dataclass(frozen=True)
class RuntimeCommand:
    kind: str
    reason: str


class TransitionEngine:
    def next(self, snapshot: RuntimeSnapshot) -> RuntimeCommand:
        status = snapshot.task_status.lower()
        phase = snapshot.phase.lower()

        if status in {"completed", "failed", "cancelled"}:
            return RuntimeCommand("YIELD", "terminal")
        if snapshot.cancel_requested or "CANCEL_REQUEST" in snapshot.accepted_event_types:
            return RuntimeCommand("HANDLE_CANCELLATION", "cancellation_pending")
        if snapshot.has_open_action:
            return RuntimeCommand("YIELD", "action_owned_by_execution")

        non_planner_events = snapshot.accepted_event_types - {"USER_TURN"}
        if non_planner_events:
            return RuntimeCommand("YIELD", "non_planner_inbox_event_pending")

        has_user_turn = "USER_TURN" in snapshot.accepted_event_types
        if snapshot.pending_clarification_id and not has_user_turn:
            return RuntimeCommand("YIELD", "awaiting_existing_clarification")
        if status == "blocked" and not has_user_turn:
            return RuntimeCommand("YIELD", "blocked")
        if status == "waiting" and not has_user_turn:
            return RuntimeCommand("YIELD", "durable_wait")
        if phase != "planning":
            return RuntimeCommand("YIELD", f"phase_owned_by_{phase}")
        return RuntimeCommand("CALL_PLANNER", "semantic_decision_needed")
