from __future__ import annotations

import math
from datetime import datetime
from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification


class LocationCurrentAdapter:
    """Host verifier for one foreground Core Location observation."""

    capability_id = "location.current"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=20,
        idempotency_mode="ONE_SHOT_DEVICE_OBSERVATION",
        retry_mode="NO_BLIND_RETRY",
        verification_mode="DEVICE_SENSOR_READ_BACK",
        reconciliation_mode="NO_BLIND_REREAD",
        max_attempts=1,
    )

    _MAX_AGE_MS = 60_000
    _FUTURE_TOLERANCE_MS = 5_000
    _MAX_HORIZONTAL_ACCURACY_M = 10_000.0
    _AUTHORIZATION = {"authorizedWhenInUse", "authorizedAlways"}
    _ACCURACY_AUTHORIZATION = {"fullAccuracy", "reducedAccuracy"}
    _USER_CORRECTABLE = {
        "PERMISSION_REQUIRED",
        "DENIED",
        "SERVICES_DISABLED",
    }

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    @staticmethod
    def _parse_datetime(value: Any) -> Optional[datetime]:
        if not isinstance(value, str) or not value.strip():
            return None
        raw = value[:-1] + "+00:00" if value.endswith("Z") else value
        try:
            result = datetime.fromisoformat(raw)
        except ValueError:
            return None
        if result.tzinfo is None or result.utcoffset() is None:
            return None
        return result

    @staticmethod
    def _number(value: Any) -> Optional[float]:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        number = float(value)
        return number if math.isfinite(number) else None

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        status = output.get("status")
        if not success:
            if status in self._USER_CORRECTABLE or (
                status == "TEMPORARILY_UNAVAILABLE" and output.get("reason_code") == "location_foreground_required"
            ):
                return ExecutionVerification(
                    outcome="MODEL_CORRECTABLE_FAILURE",
                    error=error or str(output.get("reason") or status),
                )
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=error or str(output.get("reason") or "location_current_failed"),
            )

        required = {
            "status", "location_observation_id", "request_id", "task_id",
            "action_id", "attempt_id", "latitude", "longitude",
            "horizontal_accuracy_m", "timestamp", "received_at", "age_ms",
            "authorization_status", "accuracy_authorization",
            "coordinate_reference", "freshness_verified", "validity_verified",
            "privacy_class",
        }
        if status != "COMPLETED" or not required.issubset(output):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="location.current result is missing verified observation fields",
            )

        latitude = self._number(output.get("latitude"))
        longitude = self._number(output.get("longitude"))
        accuracy = self._number(output.get("horizontal_accuracy_m"))
        age_ms = self._number(output.get("age_ms"))
        timestamp = self._parse_datetime(output.get("timestamp"))
        received_at = self._parse_datetime(output.get("received_at"))
        observation_id = output.get("location_observation_id")
        authorization = output.get("authorization_status")
        accuracy_authorization = output.get("accuracy_authorization")
        derived_age_ms = (
            (received_at - timestamp).total_seconds() * 1_000.0
            if timestamp is not None and received_at is not None else None
        )

        correlated = (
            output.get("request_id") == output.get("attempt_id")
            and output.get("task_id") == action.get("task_id")
            and output.get("action_id") == action.get("action_id")
            and isinstance(output.get("attempt_id"), str)
            and bool(output.get("attempt_id"))
        )
        valid = (
            correlated
            and isinstance(observation_id, str)
            and bool(observation_id.strip())
            and latitude is not None and -90.0 <= latitude <= 90.0
            and longitude is not None and -180.0 <= longitude <= 180.0
            and accuracy is not None
            and 0.0 <= accuracy <= self._MAX_HORIZONTAL_ACCURACY_M
            and age_ms is not None and 0.0 <= age_ms <= self._MAX_AGE_MS
            and derived_age_ms is not None
            and -self._FUTURE_TOLERANCE_MS <= derived_age_ms <= self._MAX_AGE_MS
            and abs(age_ms - max(0.0, derived_age_ms)) <= 500.0
            and timestamp is not None and received_at is not None
            and authorization in self._AUTHORIZATION
            and accuracy_authorization in self._ACCURACY_AUTHORIZATION
            and output.get("coordinate_reference") == "WGS84"
            and output.get("freshness_verified") is True
            and output.get("validity_verified") is True
            and output.get("privacy_class") == "precise_location"
        )
        if not valid:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="location.current observation failed Host verification",
            )

        observation = {
            "location_observation_id": observation_id,
            "request_id": output["request_id"],
            "task_id": output["task_id"],
            "action_id": output["action_id"],
            "attempt_id": output["attempt_id"],
            "latitude": latitude,
            "longitude": longitude,
            "horizontal_accuracy_m": accuracy,
            "timestamp": output["timestamp"],
            "received_at": output["received_at"],
            "age_ms": age_ms,
            "authorization_status": authorization,
            "accuracy_authorization": accuracy_authorization,
            "coordinate_reference": "WGS84",
            "freshness_verified": True,
            "validity_verified": True,
            "privacy_class": "precise_location",
        }
        precision_note = "精确位置" if accuracy_authorization == "fullAccuracy" else "大概位置"
        summary = (
            f"已获取你当前的位置：纬度 {latitude:.6f}，经度 {longitude:.6f}；"
            f"系统报告水平精度约 {accuracy:.0f} 米（{precision_note}），"
            f"定位时间 {output['timestamp']}。"
        )
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=summary,
        )
