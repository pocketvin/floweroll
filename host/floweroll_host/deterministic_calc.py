from __future__ import annotations

import calendar
import hashlib
import json
import re
from collections.abc import Mapping
from dataclasses import dataclass, field as dataclass_field
from datetime import date, datetime, timedelta, timezone
from decimal import (
    Decimal,
    DivisionByZero,
    InvalidOperation,
    ROUND_DOWN,
    ROUND_HALF_EVEN,
    ROUND_HALF_UP,
    ROUND_UP,
    localcontext,
)
from typing import Any, Dict, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


CAPABILITY_ID = "calculate.deterministic"
CAPABILITY_DESCRIPTION = (
    "确定性计算：明确数字的加减乘除与百分比；km/m、kg/g、温度等已列举单位换算；"
    "明确 YYYY-MM-DD 日期加减 N 天/周/月/年；明确 IANA 时区下的两个本地时间差；"
    "以及明确 IANA 时区之间的时间换算。只接受显式结构化输入，不猜模糊日期/时区，"
    "不查询实时数据或套用税务、金融、法律、路线等外部业务规则。"
)

SUPPORTED_OPERATIONS = (
    "add",
    "subtract",
    "multiply",
    "divide",
    "percent_of",
    "percent_change",
    "unit_convert",
    "date_add",
    "time_difference",
    "timezone_convert",
)
ROUNDING_MODES = {
    "HALF_EVEN": ROUND_HALF_EVEN,
    "HALF_UP": ROUND_HALF_UP,
    "DOWN": ROUND_DOWN,
    "UP": ROUND_UP,
}

MAX_INPUT_SIGNIFICANT_DIGITS = 50
MAX_RESULT_SIGNIFICANT_DIGITS = 100
MAX_ABS_ADJUSTED_EXPONENT = 100
MAX_SCALE = 18
MAX_DECIMAL_CHARS = 128
MAX_DATE_AMOUNT = 100_000

UNIT_DIMENSION: Dict[str, str] = {}
UNIT_TO_BASE: Dict[str, Decimal] = {}


def _units(dimension: str, values: Mapping[str, str]) -> None:
    for name, factor in values.items():
        UNIT_DIMENSION[name] = dimension
        UNIT_TO_BASE[name] = Decimal(factor)


_units(
    "length",
    {
        "mm": "0.001",
        "cm": "0.01",
        "m": "1",
        "km": "1000",
        "in": "0.0254",
        "ft": "0.3048",
        "yd": "0.9144",
        "mi": "1609.344",
    },
)
_units(
    "mass",
    {
        "mg": "0.000001",
        "g": "0.001",
        "kg": "1",
        "oz": "0.028349523125",
        "lb": "0.45359237",
    },
)
_units(
    "volume",
    {
        "ml": "0.001",
        "l": "1",
        "m3": "1000",
        "tsp_us": "0.00492892159375",
        "tbsp_us": "0.01478676478125",
        "cup_us": "0.2365882365",
    },
)
_units(
    "time",
    {
        "ms": "0.001",
        "s": "1",
        "min": "60",
        "h": "3600",
        "day": "86400",
    },
)
for _temperature_unit in ("celsius", "fahrenheit", "kelvin"):
    UNIT_DIMENSION[_temperature_unit] = "temperature"

SUPPORTED_UNITS = tuple(sorted(UNIT_DIMENSION))

ARGUMENT_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "operation": {
            "type": "string",
            "enum": list(SUPPORTED_OPERATIONS),
            "description": (
                "add/subtract/multiply/divide=十进制四则运算；percent_of=求某数的百分比；"
                "percent_change=从一个数到另一个数的百分比变化；unit_convert=已列举单位换算；"
                "date_add=明确日期加减 N 天/周/月/年；time_difference=同一明确 IANA 时区中两个本地时间的差；"
                "timezone_convert=明确本地时间从一个 IANA 时区换到另一个 IANA 时区。"
            ),
        },
        "left": {"type": "string", "description": "四则运算左操作数，普通十进制字符串，如 1280 或 12.5。"},
        "right": {"type": "string", "description": "四则运算右操作数，普通十进制字符串。"},
        "value": {"type": "string", "description": "percent_of 的基数或 unit_convert 的源数值，普通十进制字符串。"},
        "percent": {"type": "string", "description": "percent_of 的百分数；15 表示 15%。"},
        "from_value": {"type": "string", "description": "percent_change 的起始数值。"},
        "to_value": {"type": "string", "description": "percent_change 的结束数值。"},
        "from_unit": {
            "type": "string", "enum": list(SUPPORTED_UNITS),
            "description": "unit_convert 源单位；温度必须使用 celsius/fahrenheit/kelvin。",
        },
        "to_unit": {
            "type": "string", "enum": list(SUPPORTED_UNITS),
            "description": "unit_convert 目标单位；必须与源单位同维度。",
        },
        "scale": {
            "type": "integer", "minimum": 0, "maximum": MAX_SCALE,
            "description": "保留小数位数。divide、percent_change、unit_convert 必填；其他数值操作仅需要舍入时传。",
        },
        "rounding": {
            "type": "string", "enum": list(ROUNDING_MODES),
            "description": "仅与 scale 一起使用；默认 HALF_EVEN。",
        },
        "date": {"type": "string", "description": "date_add 的明确 ISO 日期 YYYY-MM-DD；不传明天/下周等模糊表达。"},
        "amount": {
            "type": "integer", "minimum": -MAX_DATE_AMOUNT, "maximum": MAX_DATE_AMOUNT,
            "description": "date_add 的有符号数量；负数表示往前。",
        },
        "date_unit": {
            "type": "string", "enum": ["days", "weeks", "months", "years"],
            "description": "date_add 的数量单位。",
        },
        "start_datetime": {"type": "string", "description": "time_difference 开始本地时间，ISO 格式且不带 UTC offset。"},
        "end_datetime": {"type": "string", "description": "time_difference 结束本地时间，ISO 格式且不带 UTC offset。"},
        "timezone": {"type": "string", "description": "time_difference 的明确 IANA 时区，如 Asia/Tokyo；不接受 JST/CST。"},
        "start_fold": {"type": "integer", "enum": [0, 1], "description": "仅 DST 重复开始时刻需要。"},
        "end_fold": {"type": "integer", "enum": [0, 1], "description": "仅 DST 重复结束时刻需要。"},
        "datetime": {"type": "string", "description": "timezone_convert 源本地时间，ISO 格式且不带 UTC offset。"},
        "from_timezone": {"type": "string", "description": "timezone_convert 源 IANA 时区，如 Asia/Tokyo。"},
        "to_timezone": {"type": "string", "description": "timezone_convert 目标 IANA 时区，如 Asia/Shanghai。"},
        "fold": {"type": "integer", "enum": [0, 1], "description": "仅源时区 DST 重复时刻需要。"},
    },
    "required": ["operation"],
    "additionalProperties": False,
}

_OPERATION_FIELDS = {
    "add": ({"left", "right"}, {"scale", "rounding"}),
    "subtract": ({"left", "right"}, {"scale", "rounding"}),
    "multiply": ({"left", "right"}, {"scale", "rounding"}),
    "divide": ({"left", "right"}, {"scale", "rounding"}),
    "percent_of": ({"value", "percent"}, {"scale", "rounding"}),
    "percent_change": ({"from_value", "to_value"}, {"scale", "rounding"}),
    "unit_convert": ({"value", "from_unit", "to_unit"}, {"scale", "rounding"}),
    "date_add": ({"date", "amount", "date_unit"}, set()),
    "time_difference": (
        {"start_datetime", "end_datetime", "timezone"},
        {"start_fold", "end_fold"},
    ),
    "timezone_convert": ({"datetime", "from_timezone", "to_timezone"}, {"fold"}),
}

_STRING_FIELDS = {
    "left",
    "right",
    "value",
    "percent",
    "from_value",
    "to_value",
    "from_unit",
    "to_unit",
    "rounding",
    "date",
    "date_unit",
    "start_datetime",
    "end_datetime",
    "timezone",
    "datetime",
    "from_timezone",
    "to_timezone",
}
_INTEGER_FIELDS = {"scale", "amount", "start_fold", "end_fold", "fold"}
_TIMEZONE_FIELDS = {"timezone", "from_timezone", "to_timezone"}
_DATETIME_FIELDS = {"start_datetime", "end_datetime", "datetime"}


@dataclass(frozen=True)
class CalculationError(Exception):
    code: str
    message: str
    field: Optional[str] = None
    details: Dict[str, Any] = dataclass_field(default_factory=dict)
    model_correctable: bool = True

    def __str__(self) -> str:
        return self.message

    def as_dict(self) -> Dict[str, Any]:
        value: Dict[str, Any] = {
            "code": self.code,
            "message": self.message,
            "retryable": False,
            "model_correctable": self.model_correctable,
        }
        if self.field is not None:
            value["field"] = self.field
        if self.details:
            value["details"] = dict(self.details)
        return value


def readiness() -> Dict[str, Any]:
    required_zones = ("UTC", "Asia/Shanghai", "America/New_York")
    missing = []
    for key in required_zones:
        try:
            ZoneInfo(key)
        except ZoneInfoNotFoundError:
            missing.append(key)
    return {
        "ready": not missing,
        "requirements": {
            "python_decimal": True,
            "python_datetime": True,
            "iana_zoneinfo": not missing,
        },
        "missing_zoneinfo_keys": missing,
        "requires_network": False,
        "requires_credentials": False,
        "requires_filesystem_side_effect": False,
    }


def execute(arguments: Mapping[str, Any]) -> Dict[str, Any]:
    args = _normalize_payload(arguments)
    operation = args["operation"]
    _validate_fields(operation, args)
    _validate_payload_types(args)

    if operation in {"add", "subtract", "multiply", "divide"}:
        result = _arithmetic(operation, args)
    elif operation == "percent_of":
        result = _percent_of(args)
    elif operation == "percent_change":
        result = _percent_change(args)
    elif operation == "unit_convert":
        result = _unit_convert(args)
    elif operation == "date_add":
        result = _date_add(args)
    elif operation == "time_difference":
        result = _time_difference(args)
    elif operation == "timezone_convert":
        result = _timezone_convert(args)
    else:  # defense in depth
        raise CalculationError(
            "UNSUPPORTED_OPERATION",
            "unsupported deterministic calculation operation",
            "operation",
        )

    fingerprint = hashlib.sha256(
        json.dumps(args, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {
        "capability": CAPABILITY_ID,
        "operation": operation,
        "input_fingerprint": fingerprint,
        "result": result,
    }


def execute_safe(arguments: Any) -> Dict[str, Any]:
    """Executor boundary that never exposes malformed-payload exceptions.

    FunctionExecutionWorker normally supplies a dict, but this boundary remains
    safe even when Planner validation is bypassed in a direct/integration call.
    """
    try:
        return {"ok": True, "output": execute(arguments)}
    except CalculationError as exc:
        return {
            "ok": False,
            "capability": CAPABILITY_ID,
            "failure": exc.as_dict(),
        }
    except Exception:
        # Never leak arbitrary internal exception text into a capability result.
        return {
            "ok": False,
            "capability": CAPABILITY_ID,
            "failure": {
                "code": "INTERNAL_CALCULATION_ERROR",
                "message": "deterministic calculation failed internally",
                "retryable": False,
                "model_correctable": False,
            },
        }


def verify(arguments: Mapping[str, Any], output: Mapping[str, Any]) -> Dict[str, Any]:
    """Integrity verification by deterministic recomputation.

    The verifier shares the pure implementation with the executor; it therefore
    verifies argument/result integrity, not an independent mathematical oracle.
    """
    try:
        expected = execute(arguments)
    except CalculationError as exc:
        return {
            "verified": False,
            "reason": "arguments_do_not_describe_a_successful_calculation",
            "error": exc.as_dict(),
        }
    if not isinstance(output, Mapping) or dict(output) != expected:
        return {
            "verified": False,
            "reason": "deterministic_recompute_mismatch",
            "input_fingerprint": expected["input_fingerprint"],
        }
    return {
        "verified": True,
        "verification_method": "deterministic_recompute",
        "integrity_scope": "shared_pure_core",
        "input_fingerprint": expected["input_fingerprint"],
        "observation": expected,
    }


def _normalize_payload(arguments: Any) -> Dict[str, Any]:
    if not isinstance(arguments, Mapping):
        raise CalculationError(
            "INVALID_PAYLOAD",
            "calculation arguments must be an object",
        )
    args = dict(arguments)
    if any(not isinstance(key, str) for key in args):
        raise CalculationError(
            "INVALID_PAYLOAD",
            "calculation argument names must be strings",
        )
    operation = args.get("operation")
    if not isinstance(operation, str):
        raise CalculationError(
            "INVALID_PAYLOAD",
            "operation must be a string enum",
            "operation",
        )
    if operation not in SUPPORTED_OPERATIONS:
        raise CalculationError(
            "UNSUPPORTED_OPERATION",
            "unsupported deterministic calculation operation",
            "operation",
        )
    return args


def _validate_fields(operation: str, args: Mapping[str, Any]) -> None:
    required, optional = _OPERATION_FIELDS[operation]
    supplied = set(args) - {"operation"}
    missing = required - supplied
    extra = supplied - required - optional
    if missing:
        timezone_missing = sorted(missing & _TIMEZONE_FIELDS)
        if timezone_missing:
            raise CalculationError(
                "TIMEZONE_REQUIRED",
                "an explicit IANA timezone is required",
                timezone_missing[0],
            )
        field_name = sorted(missing)[0]
        raise CalculationError(
            "INVALID_PAYLOAD",
            "missing required calculation argument",
            field_name,
            {"missing": sorted(missing)},
        )
    if extra:
        raise CalculationError(
            "INVALID_PAYLOAD",
            "unexpected arguments for calculation operation",
            details={"unexpected": sorted(extra)},
        )
    if "rounding" in args and "scale" not in args:
        raise CalculationError(
            "INVALID_PAYLOAD",
            "rounding requires an explicit scale",
            "rounding",
        )


def _validate_payload_types(args: Mapping[str, Any]) -> None:
    for field_name, raw in args.items():
        if field_name == "operation":
            continue
        if field_name in _STRING_FIELDS and not isinstance(raw, str):
            raise CalculationError(
                "INVALID_PAYLOAD",
                f"{field_name} must be a string",
                field_name,
            )
        if field_name in _INTEGER_FIELDS and (isinstance(raw, bool) or not isinstance(raw, int)):
            raise CalculationError(
                "INVALID_PAYLOAD",
                f"{field_name} must be an integer",
                field_name,
            )

    if "scale" in args:
        _validate_scale(args["scale"])
    if "rounding" in args and args["rounding"] not in ROUNDING_MODES:
        raise CalculationError(
            "INVALID_PAYLOAD",
            "unsupported rounding enum",
            "rounding",
        )
    for fold_name in ("fold", "start_fold", "end_fold"):
        if fold_name in args and args[fold_name] not in (0, 1):
            raise CalculationError(
                "INVALID_PAYLOAD",
                f"{fold_name} must be 0 or 1",
                fold_name,
            )
    if "date_unit" in args and args["date_unit"] not in {"days", "weeks", "months", "years"}:
        raise CalculationError(
            "INVALID_PAYLOAD",
            "unsupported date_unit enum",
            "date_unit",
        )


def _validate_scale(raw: Any) -> int:
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise CalculationError("INVALID_PAYLOAD", "scale must be an integer", "scale")
    if not 0 <= raw <= MAX_SCALE:
        raise CalculationError(
            "PRECISION_LIMIT",
            f"scale must be from 0 to {MAX_SCALE}",
            "scale",
        )
    return raw


def _decimal(raw: Any, field_name: str) -> Decimal:
    if not isinstance(raw, str):
        raise CalculationError(
            "INVALID_PAYLOAD",
            "decimal values must be strings",
            field_name,
        )
    if not raw or len(raw) > MAX_DECIMAL_CHARS:
        raise CalculationError(
            "NUMERIC_BOUNDARY",
            "decimal input length exceeds bounded range",
            field_name,
        )
    if not re.fullmatch(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)", raw):
        raise CalculationError("INVALID_PAYLOAD", "invalid decimal string", field_name)
    try:
        value = Decimal(raw)
    except InvalidOperation as exc:
        raise CalculationError("INVALID_PAYLOAD", "invalid decimal string", field_name) from exc
    if not value.is_finite():
        raise CalculationError("INVALID_PAYLOAD", "decimal value must be finite", field_name)
    digits = len(value.as_tuple().digits)
    if digits > MAX_INPUT_SIGNIFICANT_DIGITS:
        raise CalculationError(
            "PRECISION_LIMIT",
            f"decimal input exceeds {MAX_INPUT_SIGNIFICANT_DIGITS} significant digits",
            field_name,
        )
    if value != 0 and abs(value.adjusted()) > MAX_ABS_ADJUSTED_EXPONENT:
        raise CalculationError(
            "NUMERIC_BOUNDARY",
            f"decimal input exponent exceeds ±{MAX_ABS_ADJUSTED_EXPONENT}",
            field_name,
        )
    return value


def _quantize(
    value: Decimal,
    args: Mapping[str, Any],
    *,
    required: bool,
) -> tuple[Decimal, Dict[str, Any]]:
    if "scale" not in args:
        if required:
            raise CalculationError(
                "PRECISION_REQUIRED",
                "operation requires explicit scale",
                "scale",
            )
        _check_result_decimal(value)
        return value, {"mode": "exact", "scale": None, "rounding": None}

    scale = _validate_scale(args["scale"])
    rounding_name = args.get("rounding", "HALF_EVEN")
    if not isinstance(rounding_name, str):
        raise CalculationError("INVALID_PAYLOAD", "rounding must be a string enum", "rounding")
    rounding = ROUNDING_MODES.get(rounding_name)
    if rounding is None:
        raise CalculationError("INVALID_PAYLOAD", "unsupported rounding enum", "rounding")
    quantum = Decimal(1).scaleb(-scale)
    try:
        with localcontext() as ctx:
            ctx.prec = 140
            rounded = value.quantize(quantum, rounding=rounding)
    except InvalidOperation as exc:
        raise CalculationError(
            "PRECISION_LIMIT",
            "result cannot be represented at requested scale",
        ) from exc
    _check_result_decimal(rounded)
    return rounded, {"mode": "rounded", "scale": scale, "rounding": rounding_name}


def _check_result_decimal(value: Decimal) -> None:
    if not value.is_finite():
        raise CalculationError("NUMERIC_BOUNDARY", "calculation produced a non-finite result")
    digits = len(value.as_tuple().digits)
    if digits > MAX_RESULT_SIGNIFICANT_DIGITS:
        raise CalculationError(
            "PRECISION_LIMIT",
            f"result exceeds {MAX_RESULT_SIGNIFICANT_DIGITS} significant digits",
        )
    if value != 0 and abs(value.adjusted()) > MAX_ABS_ADJUSTED_EXPONENT * 2:
        raise CalculationError("NUMERIC_BOUNDARY", "result exponent exceeds bounded range")


def _format_decimal(value: Decimal, *, preserve_scale: bool) -> str:
    text = format(value, "f")
    if not preserve_scale and "." in text:
        text = text.rstrip("0").rstrip(".")
    if text in {"-0", "-0.0", ""}:
        return "0"
    return text


def _decimal_result(value: Decimal, precision: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "kind": "decimal",
        "value": _format_decimal(value, preserve_scale=precision["mode"] == "rounded"),
        "precision": precision,
    }


def _arithmetic(operation: str, args: Mapping[str, Any]) -> Dict[str, Any]:
    left = _decimal(args["left"], "left")
    right = _decimal(args["right"], "right")
    try:
        with localcontext() as ctx:
            ctx.prec = 140
            if operation == "add":
                raw = left + right
            elif operation == "subtract":
                raw = left - right
            elif operation == "multiply":
                raw = left * right
            else:
                if right == 0:
                    raise CalculationError("DIVIDE_BY_ZERO", "division by zero", "right")
                raw = left / right
    except CalculationError:
        raise
    except (DivisionByZero, InvalidOperation) as exc:
        raise CalculationError("INVALID_PAYLOAD", "invalid decimal arithmetic") from exc
    value, precision = _quantize(raw, args, required=operation == "divide")
    return _decimal_result(value, precision)


def _percent_of(args: Mapping[str, Any]) -> Dict[str, Any]:
    value = _decimal(args["value"], "value")
    percent = _decimal(args["percent"], "percent")
    with localcontext() as ctx:
        ctx.prec = 140
        raw = value * percent / Decimal("100")
    result, precision = _quantize(raw, args, required=False)
    output = _decimal_result(result, precision)
    output["percent"] = _format_decimal(percent, preserve_scale=False)
    return output


def _percent_change(args: Mapping[str, Any]) -> Dict[str, Any]:
    start = _decimal(args["from_value"], "from_value")
    end = _decimal(args["to_value"], "to_value")
    if start == 0:
        raise CalculationError(
            "DIVIDE_BY_ZERO",
            "percent change baseline cannot be zero",
            "from_value",
        )
    with localcontext() as ctx:
        ctx.prec = 140
        raw = (end - start) / start * Decimal("100")
    result, precision = _quantize(raw, args, required=True)
    output = _decimal_result(result, precision)
    output["unit"] = "percent"
    return output


def _unit_convert(args: Mapping[str, Any]) -> Dict[str, Any]:
    value = _decimal(args["value"], "value")
    from_unit = args["from_unit"]
    to_unit = args["to_unit"]
    # Type guards already ran before dictionary membership.
    assert isinstance(from_unit, str)
    assert isinstance(to_unit, str)
    if from_unit not in UNIT_DIMENSION:
        raise CalculationError("UNSUPPORTED_UNIT", "unsupported source unit", "from_unit")
    if to_unit not in UNIT_DIMENSION:
        raise CalculationError("UNSUPPORTED_UNIT", "unsupported target unit", "to_unit")
    from_dimension = UNIT_DIMENSION[from_unit]
    to_dimension = UNIT_DIMENSION[to_unit]
    if from_dimension != to_dimension:
        raise CalculationError(
            "INCOMPATIBLE_UNITS",
            "source and target units have different dimensions",
        )

    with localcontext() as ctx:
        ctx.prec = 140
        if from_dimension == "temperature":
            raw = _temperature_to_celsius(value, from_unit)
            raw = _celsius_to_temperature(raw, to_unit)
        else:
            raw = value * UNIT_TO_BASE[from_unit] / UNIT_TO_BASE[to_unit]
    result, precision = _quantize(raw, args, required=True)
    if to_unit == "kelvin" and result < 0:
        raise CalculationError(
            "NUMERIC_BOUNDARY",
            "temperature result is below absolute zero",
            "value",
        )
    output = _decimal_result(result, precision)
    output.update({"kind": "quantity", "unit": to_unit, "dimension": from_dimension})
    return output


def _temperature_to_celsius(value: Decimal, unit: str) -> Decimal:
    if unit == "celsius":
        celsius = value
    elif unit == "kelvin":
        if value < 0:
            raise CalculationError(
                "NUMERIC_BOUNDARY",
                "kelvin input cannot be negative",
                "value",
            )
        celsius = value - Decimal("273.15")
    else:
        celsius = (value - Decimal("32")) * Decimal("5") / Decimal("9")
    if celsius < Decimal("-273.15"):
        raise CalculationError(
            "NUMERIC_BOUNDARY",
            "temperature is below absolute zero",
            "value",
        )
    return celsius


def _celsius_to_temperature(celsius: Decimal, unit: str) -> Decimal:
    if unit == "celsius":
        return celsius
    if unit == "kelvin":
        return celsius + Decimal("273.15")
    return celsius * Decimal("9") / Decimal("5") + Decimal("32")


def _date_add(args: Mapping[str, Any]) -> Dict[str, Any]:
    raw_date = args["date"]
    if not isinstance(raw_date, str):
        raise CalculationError("INVALID_PAYLOAD", "date must be a string", "date")
    try:
        current = date.fromisoformat(raw_date)
    except ValueError as exc:
        raise CalculationError(
            "INVALID_DATETIME",
            "date must use valid YYYY-MM-DD form",
            "date",
        ) from exc

    amount = args["amount"]
    if isinstance(amount, bool) or not isinstance(amount, int):
        raise CalculationError("INVALID_PAYLOAD", "amount must be an integer", "amount")
    if abs(amount) > MAX_DATE_AMOUNT:
        raise CalculationError(
            "NUMERIC_BOUNDARY",
            f"amount must be within ±{MAX_DATE_AMOUNT}",
            "amount",
        )
    unit = args["date_unit"]
    if not isinstance(unit, str):
        raise CalculationError("INVALID_PAYLOAD", "date_unit must be a string enum", "date_unit")

    clamped = False
    try:
        if unit == "days":
            result = current + timedelta(days=amount)
        elif unit == "weeks":
            result = current + timedelta(weeks=amount)
        elif unit == "months":
            result, clamped = _add_months(current, amount)
        elif unit == "years":
            result, clamped = _add_months(current, amount * 12)
        else:
            raise CalculationError("INVALID_PAYLOAD", "unsupported date_unit enum", "date_unit")
    except CalculationError:
        raise
    except (OverflowError, ValueError) as exc:
        raise CalculationError(
            "NUMERIC_BOUNDARY",
            "date arithmetic exceeds supported calendar range",
        ) from exc
    return {
        "kind": "date",
        "value": result.isoformat(),
        "calendar_adjustment": "clamped_to_last_day" if clamped else "none",
    }


def _add_months(value: date, months: int) -> tuple[date, bool]:
    absolute = value.year * 12 + (value.month - 1) + months
    year, month_index = divmod(absolute, 12)
    if not 1 <= year <= 9999:
        raise OverflowError("date out of range")
    month = month_index + 1
    last_day = calendar.monthrange(year, month)[1]
    day = min(value.day, last_day)
    return date(year, month, day), day != value.day


def _time_difference(args: Mapping[str, Any]) -> Dict[str, Any]:
    tz = _zone(args["timezone"], "timezone")
    start_local = _local_datetime(args["start_datetime"], "start_datetime")
    end_local = _local_datetime(args["end_datetime"], "end_datetime")
    start = _resolve_local(start_local, tz, args.get("start_fold"), "start_datetime", "start_fold")
    end = _resolve_local(end_local, tz, args.get("end_fold"), "end_datetime", "end_fold")
    delta = end.astimezone(timezone.utc) - start.astimezone(timezone.utc)
    microseconds = delta.days * 86_400_000_000 + delta.seconds * 1_000_000 + delta.microseconds
    seconds = Decimal(microseconds) / Decimal("1000000")
    return {
        "kind": "duration",
        "seconds": _format_decimal(seconds, preserve_scale=False),
        "timezone": args["timezone"],
        "start_utc": start.astimezone(timezone.utc).isoformat(),
        "end_utc": end.astimezone(timezone.utc).isoformat(),
    }


def _timezone_convert(args: Mapping[str, Any]) -> Dict[str, Any]:
    from_tz = _zone(args["from_timezone"], "from_timezone")
    to_tz = _zone(args["to_timezone"], "to_timezone")
    local = _local_datetime(args["datetime"], "datetime")
    source = _resolve_local(local, from_tz, args.get("fold"), "datetime", "fold")
    converted = source.astimezone(to_tz)
    return {
        "kind": "datetime",
        "value": converted.isoformat(),
        "timezone": args["to_timezone"],
        "utc": converted.astimezone(timezone.utc).isoformat(),
        "fold": converted.fold,
    }


def _zone(raw: Any, field_name: str) -> ZoneInfo:
    if not isinstance(raw, str):
        raise CalculationError("INVALID_PAYLOAD", "timezone must be a string", field_name)
    if not raw or len(raw) > 128 or raw.strip() != raw:
        raise CalculationError(
            "INVALID_TIMEZONE",
            "timezone must be a bounded IANA timezone name",
            field_name,
        )
    if raw != "UTC" and "/" not in raw:
        raise CalculationError(
            "INVALID_TIMEZONE",
            "timezone abbreviation is ambiguous; use an IANA name such as Asia/Shanghai",
            field_name,
            {"reason": "ambiguous_abbreviation"},
        )
    try:
        return ZoneInfo(raw)
    except ZoneInfoNotFoundError as exc:
        raise CalculationError(
            "INVALID_TIMEZONE",
            "unknown IANA timezone",
            field_name,
            {"reason": "unknown_iana_timezone"},
        ) from exc


def _local_datetime(raw: Any, field_name: str) -> datetime:
    if not isinstance(raw, str):
        raise CalculationError("INVALID_PAYLOAD", "datetime must be a string", field_name)
    if not raw or len(raw) > 64:
        raise CalculationError(
            "INVALID_DATETIME",
            "datetime must be a bounded ISO local datetime string",
            field_name,
        )
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError as exc:
        raise CalculationError(
            "INVALID_DATETIME",
            "invalid ISO local datetime",
            field_name,
        ) from exc
    if parsed.tzinfo is not None:
        raise CalculationError(
            "INVALID_DATETIME",
            "datetime must be local wall time without offset; timezone is a separate typed argument",
            field_name,
        )
    return parsed


def _resolve_local(
    local: datetime,
    tz: ZoneInfo,
    fold: Any,
    datetime_field: str,
    fold_field: str,
) -> datetime:
    if fold is not None and (isinstance(fold, bool) or not isinstance(fold, int)):
        raise CalculationError("INVALID_PAYLOAD", "fold must be integer 0 or 1", fold_field)
    if fold is not None and fold not in (0, 1):
        raise CalculationError("INVALID_PAYLOAD", "fold must be 0 or 1", fold_field)

    candidates: Dict[str, datetime] = {}
    by_fold: Dict[int, datetime] = {}
    for candidate_fold in (0, 1):
        aware = local.replace(tzinfo=tz, fold=candidate_fold)
        utc = aware.astimezone(timezone.utc)
        back = utc.astimezone(tz)
        if back.replace(tzinfo=None) == local:
            candidates[utc.isoformat()] = aware
            by_fold[candidate_fold] = aware

    if not candidates:
        raise CalculationError(
            "NONEXISTENT_LOCAL_TIME",
            "local datetime does not exist because of a timezone/DST transition",
            datetime_field,
        )
    if len(candidates) > 1:
        if fold is None:
            raise CalculationError(
                "AMBIGUOUS_LOCAL_TIME",
                "local datetime occurs twice because of a timezone/DST transition; supply fold 0 or 1",
                datetime_field,
            )
        selected = by_fold.get(fold)
        if selected is None:
            raise CalculationError(
                "INVALID_DATETIME",
                "requested fold is not valid for local datetime",
                datetime_field,
            )
        return selected
    if fold == 1:
        raise CalculationError(
            "INVALID_DATETIME",
            "fold=1 is only valid for ambiguous local datetimes",
            datetime_field,
        )
    return next(iter(candidates.values()))
