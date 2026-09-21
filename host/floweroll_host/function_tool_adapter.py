from __future__ import annotations

from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification


class FunctionToolAdapter:
    """Execution contract for a bounded in-process Host capability.

    The adapter owns retry/idempotency semantics while a separate execution
    worker invokes the concrete function. This keeps local/API functions on
    the same durable Action -> Attempt -> verification path as MCP/iOS tools.

    A write function must explicitly opt into replay-safe semantics. Host death
    can leave the same durable Attempt IN_FLIGHT, so implicit write replay is
    forbidden unless the implementation is idempotent under the exact Action
    identity/input.
    """

    def __init__(
        self,
        *,
        capability_id: str,
        source_kind: str,
        read_only: bool = True,
        replay_safe: bool = False,
        timeout_seconds: int = 15,
        max_attempts: int = 2,
    ) -> None:
        if not read_only and not replay_safe:
            raise ValueError(
                "non-read-only FunctionToolAdapter requires explicit replay_safe=True"
            )
        self.capability_id = capability_id
        self.source_kind = source_kind
        self.read_only = read_only
        self.replay_safe = read_only or replay_safe
        self.execution_profile = ExecutionProfile(
            timeout_seconds=timeout_seconds,
            idempotency_mode="NATURAL_READ_ONLY" if read_only else "EXACT_INPUT",
            retry_mode="SAFE_WITH_SAME_KEY",
            verification_mode="FUNCTION_RESULT",
            reconciliation_mode="SAFE_REREAD" if read_only else "REPLAY_SAME_ATTEMPT",
            max_attempts=max_attempts,
            retry_backoff_seconds=1,
        )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "source": {"kind": self.source_kind, "capability": self.capability_id},
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
        if success:
            observation = {
                "source_kind": self.source_kind,
                "capability": self.capability_id,
                **{key: value for key, value in output.items() if not key.startswith("_")},
            }
            summary = output.get("_completion_summary")
            return ExecutionVerification(
                outcome="SUCCESS",
                observation=observation,
                direct_completion_summary=summary if isinstance(summary, str) else None,
            )

        kind = output.get("error_kind")
        if kind == "model_correctable":
            outcome = "MODEL_CORRECTABLE_FAILURE"
        elif kind == "transient":
            outcome = "TRANSIENT_FAILURE"
        else:
            outcome = "TERMINAL_FAILURE"
        return ExecutionVerification(outcome=outcome, error=error or "Host function failed")
