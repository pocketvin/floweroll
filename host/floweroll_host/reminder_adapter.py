from __future__ import annotations

from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification


class ReminderCreateAdapter:
    """Host-side semantic contract for one EventKit reminder creation.

    The iPhone executor performs the native side effect and returns a read-back
    snapshot. The Host trusts neither a bare `success=true` nor the planner's
    arguments as proof that the reminder actually exists.
    """

    capability_id = "reminder.create"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=20,
        idempotency_mode="DEVICE_JOURNAL_AND_MARKER",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="DEVICE_READ_BACK",
        reconciliation_mode="DEVICE_MARKER_READ_BACK",
        max_attempts=3,
    )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        arguments = dict(action["payload"])
        return {
            "capability": self.capability_id,
            "arguments": arguments,
            "idempotency_key": action["idempotency_key"],
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=error or "iPhone reminder executor reported failure",
            )

        expected = action["payload"]
        required = {"reminder_id", "title", "due_at", "idempotency_marker", "verified"}
        if not required.issubset(output):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="reminder result is missing required read-back fields",
            )
        if output.get("verified") is not True:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="reminder result was not read-back verified on device",
            )
        if output.get("title") != expected.get("title"):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="reminder title did not match the dispatched Action",
            )
        if output.get("due_at") != expected.get("due_at"):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="reminder due time did not match the dispatched Action",
            )
        if output.get("idempotency_marker") != action["idempotency_key"]:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="reminder idempotency marker did not match the Action",
            )
        reminder_id = output.get("reminder_id")
        if not isinstance(reminder_id, str) or not reminder_id.strip():
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="reminder read-back did not contain a stable native identifier",
            )

        return ExecutionVerification(
            outcome="SUCCESS",
            observation={
                "reminder_id": reminder_id,
                "title": output["title"],
                "due_at": output["due_at"],
                "idempotency_marker": output["idempotency_marker"],
            },
        )
