from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification


MODEL_CORRECTABLE_ALARM_ERRORS = {
    "alarm_invalid_arguments",
    "alarm_authorization_not_determined",
    "alarm_authorization_denied",
    "alarm_authorization_unknown",
    "alarm_unknown_target",
    "alarm_foreign_target",
    "alarm_invalid_native_state",
    "alarm_settings_mutation_pending",
}
TRANSIENT_ALARM_ERRORS = {"alarm_read_failed", "alarm_query_failed"}


def _failure_verification(
    error: Optional[str], output: Dict[str, Any], fallback: str
) -> ExecutionVerification:
    code = output.get("error_code")
    if code in MODEL_CORRECTABLE_ALARM_ERRORS:
        outcome = "MODEL_CORRECTABLE_FAILURE"
    elif code in TRANSIENT_ALARM_ERRORS:
        outcome = "TRANSIENT_FAILURE"
    else:
        outcome = "TERMINAL_FAILURE"
    return ExecutionVerification(outcome=outcome, error=error or (str(code) if code else fallback))


def _parse_instant(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        return None
    raw = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed


def _same_instant(expected: Any, actual: Any) -> bool:
    expected_instant = _parse_instant(expected)
    actual_instant = _parse_instant(actual)
    return (
        expected_instant is not None
        and actual_instant is not None
        and expected_instant == actual_instant
    )


def _schedule_matches(expected: Any, actual: Any) -> bool:
    if not isinstance(expected, dict) or not isinstance(actual, dict):
        return False
    kind = expected.get("kind")
    if actual.get("kind") != kind:
        return False
    if kind == "fixed":
        return _same_instant(expected.get("fire_at"), actual.get("fire_at"))
    if kind == "weekly":
        expected_days = expected.get("weekdays")
        actual_days = actual.get("weekdays")
        return (
            isinstance(expected.get("hour"), int)
            and not isinstance(expected.get("hour"), bool)
            and isinstance(expected.get("minute"), int)
            and not isinstance(expected.get("minute"), bool)
            and actual.get("hour") == expected.get("hour")
            and actual.get("minute") == expected.get("minute")
            and isinstance(expected_days, list)
            and isinstance(actual_days, list)
            and set(actual_days) == set(expected_days)
            and len(actual_days) == len(expected_days)
        )
    return False


def _create_expected_schedule(payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    schedule = payload.get("schedule")
    if isinstance(schedule, dict):
        return schedule
    fire_at = payload.get("fire_at")
    if isinstance(fire_at, str) and fire_at.strip():
        return {"kind": "fixed", "fire_at": fire_at}
    return None


class AlarmCreateAdapter:
    """Host-side semantic contract for one AlarmKit alarm creation."""

    capability_id = "alarm.create"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=20,
        idempotency_mode="DEVICE_JOURNAL_AND_STABLE_NATIVE_ID",
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
            return _failure_verification(error, output, "iPhone AlarmKit executor reported failure")
        expected_schedule = _create_expected_schedule(action["payload"])
        required = {
            "alarm_id", "idempotency_marker", "verified",
            "native_schedule_verified", "title", "sound", "schedule",
        }
        if expected_schedule is None or not required.issubset(output):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="alarm result is missing required read-back fields",
            )
        if output.get("verified") is not True or output.get("native_schedule_verified") is not True:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="alarm result was not read-back verified on device",
            )
        if output.get("idempotency_marker") != action["idempotency_key"]:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="alarm idempotency marker did not match the Action",
            )
        if output.get("title") != action["payload"].get("title"):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm title did not match the Action")
        expected_sound = action["payload"].get("sound", "default")
        if output.get("sound") != expected_sound:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm sound did not match the Action")
        if not _schedule_matches(expected_schedule, output.get("schedule")):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm schedule did not match the Action")
        if "fire_at" in action["payload"] and not _same_instant(
            action["payload"].get("fire_at"), output.get("fire_at")
        ):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm fire time did not match the dispatched Action")
        alarm_id = output.get("alarm_id")
        if not isinstance(alarm_id, str) or not alarm_id.strip():
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="alarm read-back did not contain a stable native identifier",
            )
        observation = {
            "alarm_id": alarm_id,
            "title": output["title"],
            "schedule": output["schedule"],
            "sound": output["sound"],
            "idempotency_marker": output["idempotency_marker"],
            "verified": True,
        }
        if "fire_at" in output:
            observation["fire_at"] = output["fire_at"]
        return ExecutionVerification(outcome="SUCCESS", observation=observation)


class AlarmQueryAdapter:
    capability_id = "alarm.query"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=15,
        idempotency_mode="NATURAL_READ_ONLY",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="DEVICE_READ_BACK",
        reconciliation_mode="NONE",
        max_attempts=2,
    )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {"capability": self.capability_id, "arguments": dict(action["payload"]), "idempotency_key": action["idempotency_key"]}

    def verify_result(self, action: Dict[str, Any], *, success: bool, output: Dict[str, Any], error: Optional[str]) -> ExecutionVerification:
        if not success:
            return _failure_verification(error, output, "AlarmKit query failed")
        alarms = output.get("alarms")
        count = output.get("count")
        if (
            output.get("verified") is not True
            or output.get("ownership_scope") != "floweroll_owned_only"
            or not isinstance(alarms, list)
            or isinstance(count, bool)
            or not isinstance(count, (int, float))
            or int(count) != len(alarms)
        ):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm query read-back was malformed")
        for item in alarms:
            if not isinstance(item, dict) or not isinstance(item.get("alarm_id"), str) or item.get("ownership_ledger_present") is not True:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm query returned an unowned or malformed alarm")
        return ExecutionVerification(
            outcome="SUCCESS",
            observation={"alarms": alarms, "count": len(alarms), "ownership_scope": "floweroll_owned_only"},
        )


class AlarmUpdateAdapter:
    capability_id = "alarm.update"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=20,
        idempotency_mode="SAME_NATIVE_ID_DURABLE_REPLACEMENT",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="DEVICE_READ_BACK",
        reconciliation_mode="DEVICE_NATIVE_ID_READ_BACK",
        max_attempts=3,
    )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {"capability": self.capability_id, "arguments": dict(action["payload"]), "idempotency_key": action["idempotency_key"]}

    def verify_result(self, action: Dict[str, Any], *, success: bool, output: Dict[str, Any], error: Optional[str]) -> ExecutionVerification:
        if not success:
            return _failure_verification(error, output, "AlarmKit update failed")
        args = action["payload"]
        valid = (
            output.get("alarm_id") == args.get("alarm_id")
            and output.get("same_alarm_id") is True
            and output.get("updated") is True
            and output.get("verified") is True
            and output.get("native_schedule_verified") is True
            and output.get("title") == args.get("title")
            and output.get("sound") == args.get("sound")
            and output.get("idempotency_marker") == action["idempotency_key"]
            and _schedule_matches(args.get("schedule"), output.get("schedule"))
        )
        if not valid:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm update did not preserve identity/read back requested fields")
        return ExecutionVerification(
            outcome="SUCCESS",
            observation={
                "alarm_id": output["alarm_id"], "same_alarm_id": True,
                "title": output["title"], "schedule": output["schedule"], "sound": output["sound"],
                "native_state": output.get("native_state"), "verified": True,
            },
        )


class AlarmLifecycleAdapter:
    source_kind = "ios"
    _operation = ""
    execution_profile = ExecutionProfile(
        timeout_seconds=15,
        idempotency_mode="TARGET_NATIVE_STATE",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="DEVICE_READ_BACK",
        reconciliation_mode="DEVICE_NATIVE_ID_READ_BACK",
        max_attempts=3,
    )

    @property
    def capability_id(self) -> str:
        return f"alarm.{self._operation}"

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {"capability": self.capability_id, "arguments": dict(action["payload"]), "idempotency_key": action["idempotency_key"]}

    def verify_result(self, action: Dict[str, Any], *, success: bool, output: Dict[str, Any], error: Optional[str]) -> ExecutionVerification:
        if not success:
            return _failure_verification(error, output, f"AlarmKit {self._operation} failed")
        alarm_id = action["payload"].get("alarm_id")
        state = output.get("native_state")
        if (
            not isinstance(alarm_id, str)
            or output.get("alarm_id") != alarm_id
            or output.get("operation") != self._operation
            or output.get("verified") is not True
        ):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error=f"alarm {self._operation} was not read-back verified")
        if self._operation == "pause" and state != "paused":
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm pause did not reach native paused state")
        if self._operation == "resume" and state not in {"countdown", "scheduled"}:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="alarm resume did not leave native paused state")
        return ExecutionVerification(
            outcome="SUCCESS",
            observation={"alarm_id": alarm_id, "operation": self._operation, "native_state": state, "verified": True},
        )


class AlarmPauseAdapter(AlarmLifecycleAdapter):
    _operation = "pause"
    capability_id = "alarm.pause"


class AlarmResumeAdapter(AlarmLifecycleAdapter):
    _operation = "resume"
    capability_id = "alarm.resume"
