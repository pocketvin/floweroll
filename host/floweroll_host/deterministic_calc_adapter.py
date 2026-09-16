from __future__ import annotations

from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, Optional, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .deterministic_calc import (
    ARGUMENT_SCHEMA,
    CAPABILITY_DESCRIPTION,
    CAPABILITY_ID,
    execute_safe,
    readiness,
    verify,
)
from .execution_contracts import ExecutionProfile, ExecutionVerification
from .function_execution_worker import FunctionExecutor
from .planner_contracts import CapabilitySpec


class DeterministicCalcAdapter:
    capability_id = CAPABILITY_ID
    source_kind = "host_local"
    execution_profile = ExecutionProfile(
        timeout_seconds=2,
        idempotency_mode="NATURAL_READ_ONLY",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="DETERMINISTIC_RECOMPUTE",
        reconciliation_mode="NONE",
        max_attempts=1,
        retry_backoff_seconds=0,
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
        if not success:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=error or "deterministic calculation executor failed unexpectedly",
            )

        if output.get("ok") is False:
            failure = output.get("failure")
            if not isinstance(failure, dict):
                return ExecutionVerification(
                    outcome="TERMINAL_FAILURE",
                    error="deterministic calculation returned malformed failure envelope",
                )
            code = failure.get("code")
            message = failure.get("message")
            model_correctable = failure.get("model_correctable")
            if not isinstance(code, str) or not code or not isinstance(message, str) or not message:
                return ExecutionVerification(
                    outcome="TERMINAL_FAILURE",
                    error="deterministic calculation returned malformed failure envelope",
                )
            if model_correctable is False:
                return ExecutionVerification(
                    outcome="TERMINAL_FAILURE",
                    error=f"{code}: {message}",
                )
            return ExecutionVerification(
                outcome="MODEL_CORRECTABLE_FAILURE",
                error=f"{code}: {message}",
            )

        if output.get("ok") is not True or not isinstance(output.get("output"), dict):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="deterministic calculation returned malformed success envelope",
            )

        checked = verify(action.get("payload", {}), output["output"])
        if checked.get("verified") is not True:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="deterministic calculation recompute verification failed",
            )

        observation = dict(checked["observation"])
        observation["source_kind"] = self.source_kind
        observation["verification"] = {
            "method": checked["verification_method"],
            "integrity_scope": checked["integrity_scope"],
        }
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=_completion_summary(
                action.get("payload", {}), observation.get("result")
            ),
        )


def _unit_label(unit: Any) -> str:
    labels = {
        "celsius": "℃",
        "fahrenheit": "℉",
        "kelvin": "K",
        "cup_us": "cup",
        "tbsp_us": "tbsp",
        "tsp_us": "tsp",
    }
    return labels.get(str(unit), str(unit))


def _zone_label(zone: Any) -> str:
    labels = {
        "Asia/Tokyo": "东京",
        "Asia/Shanghai": "上海",
        "America/New_York": "纽约",
        "UTC": "UTC",
    }
    return labels.get(str(zone), str(zone))


def _pretty_datetime(value: Any) -> str:
    if not isinstance(value, str):
        return str(value)
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return value
    if parsed.second or parsed.microsecond:
        return parsed.strftime("%Y-%m-%d %H:%M:%S")
    return parsed.strftime("%Y-%m-%d %H:%M")


def _human_duration(seconds: str) -> str:
    try:
        value = Decimal(seconds)
    except (InvalidOperation, ValueError):
        return f"{seconds} 秒"
    negative = value < 0
    value = abs(value)
    if value != value.to_integral_value():
        text = f"{format(value, 'f').rstrip('0').rstrip('.')} 秒"
        return ("负 " + text) if negative else text
    total = int(value)
    days, rem = divmod(total, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    parts = []
    if days:
        parts.append(f"{days} 天")
    if hours:
        parts.append(f"{hours} 小时")
    if minutes:
        parts.append(f"{minutes} 分钟")
    if secs or not parts:
        parts.append(f"{secs} 秒")
    text = " ".join(parts)
    return ("负 " + text) if negative else text


def _completion_summary(arguments: Any, result: Any) -> Optional[str]:
    if not isinstance(arguments, dict) or not isinstance(result, dict):
        return None
    operation = arguments.get("operation")
    kind = result.get("kind")
    value = result.get("value")

    if kind == "decimal" and isinstance(value, str):
        if operation == "percent_of":
            base, percent = arguments.get("value"), arguments.get("percent")
            if isinstance(base, str) and isinstance(percent, str):
                return f"{base} 的 {percent}% 是 {value}。"
        if operation == "percent_change":
            start, end = arguments.get("from_value"), arguments.get("to_value")
            if isinstance(start, str) and isinstance(end, str):
                return f"从 {start} 到 {end}，变化 {value}%。"
        symbols = {"add": "+", "subtract": "−", "multiply": "×", "divide": "÷"}
        symbol = symbols.get(str(operation))
        left, right = arguments.get("left"), arguments.get("right")
        if symbol and isinstance(left, str) and isinstance(right, str):
            return f"{left} {symbol} {right} = {value}。"
        suffix = "%" if result.get("unit") == "percent" else ""
        return f"计算结果是 {value}{suffix}。"

    if kind == "quantity" and isinstance(value, str) and isinstance(result.get("unit"), str):
        source = arguments.get("value")
        from_unit = arguments.get("from_unit")
        if isinstance(source, str) and isinstance(from_unit, str):
            return f"{source} {_unit_label(from_unit)} 换算为 {value} {_unit_label(result['unit'])}。"
        return f"换算结果是 {value} {_unit_label(result['unit'])}。"

    if kind == "date" and isinstance(value, str):
        source = arguments.get("date")
        amount = arguments.get("amount")
        unit = arguments.get("date_unit")
        unit_labels = {"days": "天", "weeks": "周", "months": "个月", "years": "年"}
        if isinstance(source, str) and isinstance(amount, int) and not isinstance(amount, bool) and unit in unit_labels:
            direction = "往后" if amount >= 0 else "往前"
            text = f"{source} {direction} {abs(amount)} {unit_labels[unit]}是 {value}。"
            if result.get("calendar_adjustment") == "clamped_to_last_day":
                text = text[:-1] + "（按目标月份月末调整）。"
            return text
        return f"日期结果是 {value}。"

    if kind == "duration" and isinstance(result.get("seconds"), str):
        duration = _human_duration(result["seconds"])
        start = arguments.get("start_datetime")
        end = arguments.get("end_datetime")
        zone = arguments.get("timezone")
        if isinstance(start, str) and isinstance(end, str) and isinstance(zone, str):
            return (
                f"{_zone_label(zone)}时间 {_pretty_datetime(start)} 到 "
                f"{_pretty_datetime(end)} 的时间差是 {duration}。"
            )
        return f"时间差是 {duration}。"

    if kind == "datetime" and isinstance(value, str):
        source = arguments.get("datetime")
        from_zone = arguments.get("from_timezone")
        to_zone = arguments.get("to_timezone")
        if isinstance(source, str) and isinstance(from_zone, str) and isinstance(to_zone, str):
            return (
                f"{_pretty_datetime(source)}（{_zone_label(from_zone)}）换算到"
                f"{_zone_label(to_zone)}是 {_pretty_datetime(value)}。"
            )
        return f"时间换算结果是 {_pretty_datetime(value)}。"
    return None


def register_deterministic_calc_capability(
    registry: CapabilityRegistry,
) -> Tuple[Dict[str, FunctionExecutor], Dict[str, Any]]:
    health = readiness()
    if health.get("ready") is not True:
        return {}, health

    spec = CapabilitySpec(
        name=CAPABILITY_ID,
        description=CAPABILITY_DESCRIPTION,
        arguments_schema=ARGUMENT_SCHEMA,
    )
    registry.register(
        RegisteredCapability(
            spec=spec,
            adapter=DeterministicCalcAdapter(),
            source=CapabilitySourceTarget(
                kind="host_local",
                tool_name=CAPABILITY_ID,
                metadata={
                    "read_only": True,
                    "effect": "read",
                    "operation": "read",
                    "domains": ["work"],
                    "deterministic": True,
                    "network": False,
                    "filesystem_side_effect": False,
                    "arbitrary_code": False,
                    "verification": "deterministic_recompute",
                },
            ),
            tags=(
                "host",
                "calculation",
                "deterministic",
                "read",
                "decimal",
                "unit",
                "date",
                "time",
                "timezone",
            ),
            loading="always_visible",
        )
    )
    return {CAPABILITY_ID: execute_safe}, health
