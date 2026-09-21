from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import FrozenSet, Optional


class TaskLifecycle(str, Enum):
    ACTIVE = "active"
    WAITING = "waiting"
    BLOCKED = "blocked"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    UNKNOWN = "unknown"

    @classmethod
    def from_status(cls, status: str) -> "TaskLifecycle":
        normalized = status.strip().lower()
        if normalized == "needs_user":
            # Compatibility-only legacy status. User interaction is orthogonal;
            # lifecycle semantics are waiting.
            normalized = "waiting"
        try:
            return cls(normalized)
        except ValueError:
            return cls.UNKNOWN

    @property
    def terminal(self) -> bool:
        return self in {self.COMPLETED, self.FAILED, self.CANCELLED}


class RuntimePhase(str, Enum):
    PLANNING = "planning"
    EXECUTING = "executing"
    RECONCILING = "reconciling"
    UNKNOWN = "unknown"

    @classmethod
    def from_value(cls, phase: str) -> "RuntimePhase":
        try:
            return cls(phase.strip().lower())
        except ValueError:
            return cls.UNKNOWN


class InteractionState(str, Enum):
    NONE = "none"
    CLARIFICATION = "clarification"


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

    @property
    def lifecycle(self) -> TaskLifecycle:
        return TaskLifecycle.from_status(self.task_status)

    @property
    def runtime_phase(self) -> RuntimePhase:
        return RuntimePhase.from_value(self.phase)

    @property
    def interaction(self) -> InteractionState:
        return (
            InteractionState.CLARIFICATION
            if self.pending_clarification_id
            else InteractionState.NONE
        )

    @property
    def has_user_turn(self) -> bool:
        return "USER_TURN" in self.accepted_event_types


@dataclass(frozen=True)
class RuntimeCommand:
    kind: str
    reason: str


class TransitionEngine:
    def next(self, snapshot: RuntimeSnapshot) -> RuntimeCommand:
        lifecycle = snapshot.lifecycle
        phase = snapshot.runtime_phase
        interaction = snapshot.interaction

        if lifecycle.terminal:
            return RuntimeCommand("YIELD", "terminal")
        if snapshot.cancel_requested or "CANCEL_REQUEST" in snapshot.accepted_event_types:
            return RuntimeCommand("HANDLE_CANCELLATION", "cancellation_pending")
        if lifecycle is TaskLifecycle.UNKNOWN:
            return RuntimeCommand("YIELD", "unknown_task_lifecycle")
        if snapshot.has_open_action:
            return RuntimeCommand("YIELD", "action_owned_by_execution")

        non_planner_events = snapshot.accepted_event_types - {"USER_TURN"}
        if non_planner_events:
            return RuntimeCommand("YIELD", "non_planner_inbox_event_pending")

        if interaction is InteractionState.CLARIFICATION and not snapshot.has_user_turn:
            return RuntimeCommand("YIELD", "awaiting_existing_clarification")
        if lifecycle is TaskLifecycle.BLOCKED and not snapshot.has_user_turn:
            return RuntimeCommand("YIELD", "blocked")
        if lifecycle is TaskLifecycle.WAITING and not snapshot.has_user_turn:
            return RuntimeCommand("YIELD", "durable_wait")
        if phase is not RuntimePhase.PLANNING:
            return RuntimeCommand("YIELD", f"phase_owned_by_{phase.value}")
        return RuntimeCommand("CALL_PLANNER", "semantic_decision_needed")
