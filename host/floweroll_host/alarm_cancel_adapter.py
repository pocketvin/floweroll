from __future__ import annotations

from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification
from .alarm_adapter import _failure_verification


class AlarmCancelAdapter:
    capability_id = "alarm.cancel"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=15,
        idempotency_mode="TARGET_STATE_ABSENT",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="DEVICE_READ_BACK",
        reconciliation_mode="DEVICE_NATIVE_ID_READ_BACK",
        max_attempts=3,
    )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
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
            return _failure_verification(error, output, "iPhone AlarmKit cancel executor reported failure")
        alarm_id = action["payload"].get("alarm_id")
        if (
            not isinstance(alarm_id, str)
            or output.get("alarm_id") != alarm_id
            or output.get("cancelled") is not True
            or output.get("verified_absent") is not True
        ):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="alarm cancellation was not read-back verified",
            )
        return ExecutionVerification(
            outcome="SUCCESS",
            observation={"alarm_id": alarm_id, "cancelled": True, "verified_absent": True},
        )
