from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Dict, Optional, Protocol


EXECUTION_OUTCOMES = {
    "SUCCESS",
    "MODEL_CORRECTABLE_FAILURE",
    "TRANSIENT_FAILURE",
    "TERMINAL_FAILURE",
    "UNKNOWN",
    "INPUT_REQUIRED",
    "CANCELLED",
}


@dataclass(frozen=True)
class ExecutionProfile:
    timeout_seconds: int
    idempotency_mode: str
    retry_mode: str
    verification_mode: str
    reconciliation_mode: str
    max_attempts: int
    retry_backoff_seconds: int = 2

    def as_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class ExecutionVerification:
    outcome: str
    observation: Optional[Dict[str, Any]] = None
    error: Optional[str] = None
    direct_completion_summary: Optional[str] = None

    def __post_init__(self) -> None:
        if self.outcome not in EXECUTION_OUTCOMES:
            raise ValueError(f"invalid execution outcome: {self.outcome}")


class CapabilityAdapter(Protocol):
    capability_id: str
    source_kind: str
    execution_profile: ExecutionProfile

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        ...

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        ...
