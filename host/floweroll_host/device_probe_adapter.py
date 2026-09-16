from __future__ import annotations

from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification


class DeviceProbeAdapter:
    capability_id = "device.probe"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=15,
        idempotency_mode="CALLER_KEY",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="EXACT_RETURN_MATCH",
        reconciliation_mode="REPLAY_SAME_ATTEMPT",
        max_attempts=3,
    )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": action["payload"],
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
                error=error or "device reported failure",
            )
        if output != action["expected"]:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="result did not match expected probe output",
            )
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=dict(output),
        )
