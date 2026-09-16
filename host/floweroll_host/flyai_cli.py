from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .function_execution_worker import FunctionExecutor, FunctionToolError
from .function_tool_adapter import FunctionToolAdapter
from .managed_cli import ManagedJSONCLI
from .planner_contracts import CapabilitySpec


FLYAI_PROVIDER_ID = "flyai-cli"
FLYAI_HOTEL_SEARCH_ID = "travel.hotel.search"
FLYAI_CLI_VERSION = "1.0.16"
FLYAI_CACHE_TTL_SECONDS = 180.0
_MAX_ITEMS = 20
_ALLOWED_SORTS = {"distance_asc", "rate_desc", "price_asc", "price_desc", "no_rank"}
_ALLOWED_HOTEL_TYPES = {"hotel", "homestay", "inn"}
_ALLOWED_BED_TYPES = {"king", "twin", "multi"}
_ALLOWED_HANDOFF_SUFFIXES = (".feizhu.com", ".fliggy.com")
_PRICE_RE = re.compile(r"^\s*[¥￥]?\s*([0-9]+(?:\.[0-9]+)?)\s*$")


def _default_flyai_cli() -> Path:
    project_root = Path(__file__).resolve().parents[2]
    return (
        project_root
        / "work"
        / "provider-cli"
        / f"flyai-{FLYAI_CLI_VERSION}"
        / "node_modules"
        / ".bin"
        / "flyai"
    )


def locate_flyai_cli() -> Optional[Path]:
    explicit = os.environ.get("FLOWEROLL_FLYAI_CLI", "").strip()
    if explicit:
        candidate = Path(explicit).expanduser()
        return candidate.resolve() if candidate.is_file() else None
    candidate = _default_flyai_cli()
    if candidate.is_file():
        return candidate.resolve()
    found = shutil.which("flyai")
    return Path(found).resolve() if found else None


def flyai_cli_version(executable: Path) -> Optional[str]:
    """Read the package identity surrounding the pinned FlyAI bundle."""

    try:
        resolved = executable.expanduser().resolve()
    except OSError:
        return None
    # The official npm executable resolves to @fly-ai/flyai-cli/dist/flyai-bundle.cjs.
    candidates = [resolved.parent.parent / "package.json"]
    for parent in list(resolved.parents)[:6]:
        candidates.append(parent / "package.json")
    seen: set[Path] = set()
    for package in candidates:
        if package in seen or not package.is_file():
            continue
        seen.add(package)
        try:
            payload = json.loads(package.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if payload.get("name") == "@fly-ai/flyai-cli":
            value = payload.get("version")
            return value if isinstance(value, str) else None
    return None


class FlyAIHotelTools:
    def __init__(self, cli: ManagedJSONCLI, *, cache_ttl_seconds: float = FLYAI_CACHE_TTL_SECONDS) -> None:
        self.cli = cli
        self.cache_ttl_seconds = float(cache_ttl_seconds)
        self._cache: Dict[str, Tuple[float, Dict[str, Any]]] = {}
        self._cache_lock = threading.Lock()

    def search_hotels(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        normalized = _validate_arguments(arguments)
        cache_key = json.dumps(
            {key: value for key, value in normalized.items() if key != "force_refresh"},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        if normalized.get("force_refresh") is not True:
            cached = self._cached(cache_key)
            if cached is not None:
                return cached

        argv = ["search-hotel", "--dest-name", normalized["destination"]]
        _flag(argv, "--key-words", normalized.get("keywords"))
        _flag(argv, "--poi-name", normalized.get("poi_name"))
        if normalized.get("hotel_types"):
            argv.extend(["--hotel-types", ",".join(normalized["hotel_types"])])
        argv.extend(["--sort", normalized["sort"]])
        argv.extend(["--check-in-date", normalized["check_in_date"]])
        argv.extend(["--check-out-date", normalized["check_out_date"]])
        if normalized.get("hotel_stars"):
            argv.extend(["--hotel-stars", ",".join(str(value) for value in normalized["hotel_stars"])])
        if normalized.get("hotel_bed_types"):
            argv.extend(["--hotel-bed-types", ",".join(normalized["hotel_bed_types"])])
        if normalized.get("max_price") is not None:
            argv.extend(["--max-price", _number_text(normalized["max_price"])])

        wrapped = self.cli.run_json(argv)
        if wrapped.get("truncated") is True:
            raise FunctionToolError(
                "FlyAI hotel response exceeded the safe output bound",
                error_kind="terminal",
                output={"provider": "flyai_fliggy"},
            )
        payload = wrapped.get("data")
        result = _normalize_provider_payload(payload, normalized)
        result["cached"] = False
        result["cache_age_seconds"] = 0
        result["_completion_summary"] = "已查询飞猪酒店候选。"
        with self._cache_lock:
            self._cache[cache_key] = (time.monotonic(), dict(result))
        return result

    def _cached(self, key: str) -> Optional[Dict[str, Any]]:
        with self._cache_lock:
            item = self._cache.get(key)
            if item is None:
                return None
            stored_at, value = item
            age = max(0.0, time.monotonic() - stored_at)
            if age > self.cache_ttl_seconds:
                self._cache.pop(key, None)
                return None
            result = dict(value)
        result["cached"] = True
        result["cache_age_seconds"] = round(age, 3)
        return result


def register_flyai_hotel_capability(
    registry: CapabilityRegistry,
    *,
    executable: Optional[Path] = None,
    api_key: Optional[str] = None,
) -> Tuple[Dict[str, FunctionExecutor], Dict[str, Any]]:
    path = executable or locate_flyai_cli()
    configured_key = api_key if api_key is not None else os.environ.get("FLYAI_API_KEY", "")
    configured_key = configured_key.strip()
    version = flyai_cli_version(path) if path is not None else None
    installed = path is not None and path.is_file()
    ready = bool(installed and configured_key and version == FLYAI_CLI_VERSION)
    if not installed:
        reason = "cli_not_found"
    elif version != FLYAI_CLI_VERSION:
        reason = "unsupported_cli_version"
    elif not configured_key:
        reason = "api_key_not_configured"
    else:
        reason = None

    tools: Optional[FlyAIHotelTools] = None
    if ready and path is not None:
        tools = FlyAIHotelTools(
            ManagedJSONCLI(
                path,
                timeout_seconds=20.0,
                max_output_bytes=512_000,
                extra_env={"FLYAI_API_KEY": configured_key},
            )
        )

    spec = CapabilitySpec(
        name=FLYAI_HOTEL_SEARCH_ID,
        description=(
            "使用飞猪 FlyAI 查询真实酒店候选和当前报价。"
            "必须提供目的地、入住日期和退房日期；可限定预算、关键词、星级、床型和附近地点。"
            "普通“找酒店”默认只查 hotel 类型并优先质量/口碑（rate_desc）；预算 max_price 只是价格上限，"
            "绝不能仅因为用户说“500元以内/不超过500”就改成 price_asc。"
            "只有用户明确要求“最便宜/低价优先/从低到高”时才使用 price_asc；"
            "明确要求民宿/客栈时再传 homestay/inn。"
            "返回的飞猪链接只代表查看/预订交接，不代表已经创建订单。"
            "当指定 poi_name 时，FlyAI 的附近筛选不能单独证明真实距离；"
            "如需声称离某地点近，必须再用地图/路线能力独立核对 shortlisted 酒店。"
        ),
        arguments_schema={
            "type": "object",
            "properties": {
                "destination": {"type": "string", "minLength": 1, "maxLength": 80},
                "check_in_date": {"type": "string", "format": "date"},
                "check_out_date": {"type": "string", "format": "date"},
                "keywords": {"type": "string", "minLength": 1, "maxLength": 100},
                "poi_name": {"type": "string", "minLength": 1, "maxLength": 100},
                "hotel_types": {
                    "type": "array",
                    "items": {"type": "string", "enum": sorted(_ALLOWED_HOTEL_TYPES)},
                    "maxItems": 3,
                    "uniqueItems": True,
                    "default": ["hotel"],
                    "description": "普通酒店查询保持默认 hotel；只有用户明确要民宿/客栈时才选择 homestay/inn。",
                },
                "sort": {
                    "type": "string",
                    "enum": sorted(_ALLOWED_SORTS),
                    "default": "rate_desc",
                    "description": (
                        "普通酒店查询使用 rate_desc。max_price 只是预算上限，不代表最便宜优先；"
                        "只有用户明确说最便宜/低价优先/从低到高时才能用 price_asc。"
                        "FlyAI 的 distance_asc 也不能替代后续地图距离核验。"
                    ),
                },
                "hotel_stars": {
                    "type": "array",
                    "items": {"type": "integer", "minimum": 1, "maximum": 5},
                    "maxItems": 5,
                    "uniqueItems": True,
                },
                "hotel_bed_types": {
                    "type": "array",
                    "items": {"type": "string", "enum": sorted(_ALLOWED_BED_TYPES)},
                    "maxItems": 3,
                    "uniqueItems": True,
                },
                "max_price": {"type": "number", "exclusiveMinimum": 0, "maximum": 100000},
                "force_refresh": {"type": "boolean", "default": False},
            },
            "required": ["destination", "check_in_date", "check_out_date"],
            "additionalProperties": False,
        },
        post_verify_mode="REPLAN_REQUIRED",
    )
    registry.register(
        RegisteredCapability(
            spec=spec,
            adapter=FunctionToolAdapter(
                capability_id=FLYAI_HOTEL_SEARCH_ID,
                source_kind="managed_cli",
                read_only=True,
                timeout_seconds=20,
                max_attempts=2,
            ),
            source=CapabilitySourceTarget(
                kind="managed_cli",
                server_id=FLYAI_PROVIDER_ID,
                tool_name="search-hotel",
                metadata={
                    "provider": "flyai_fliggy",
                    "read_only": True,
                    "effect": "read",
                    "operation": "read",
                    "domains": ["travel"],
                    "cli_version": FLYAI_CLI_VERSION,
                    "booking_semantics": "handoff_only",
                },
            ),
            tags=("flyai", "fliggy", "飞猪", "travel", "hotel", "酒店", "price", "read"),
            loading="always_visible" if ready else "deferred",
        )
    )
    executors: Dict[str, FunctionExecutor] = {}
    if tools is not None:
        executors[FLYAI_HOTEL_SEARCH_ID] = tools.search_hotels
    return executors, {
        "installed": installed,
        "configured": bool(configured_key),
        "version": version,
        "expected_version": FLYAI_CLI_VERSION,
        "ready": ready,
        "reason": reason,
        "ready_capability_count": len(executors),
        "declared_capability_count": 1,
    }


def _validate_arguments(arguments: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {
        "destination",
        "check_in_date",
        "check_out_date",
        "keywords",
        "poi_name",
        "hotel_types",
        "sort",
        "hotel_stars",
        "hotel_bed_types",
        "max_price",
        "force_refresh",
    }
    if set(arguments) - allowed:
        raise FunctionToolError("hotel search contains unsupported arguments", error_kind="model_correctable")
    destination = _clean_string(arguments.get("destination"), "destination", maximum=80, required=True)
    check_in = _parse_date(arguments.get("check_in_date"), "check_in_date")
    check_out = _parse_date(arguments.get("check_out_date"), "check_out_date")
    if check_out <= check_in:
        raise FunctionToolError("check_out_date must be later than check_in_date", error_kind="model_correctable")
    if check_in < date.today():
        raise FunctionToolError("check_in_date cannot be in the past", error_kind="model_correctable")

    normalized: Dict[str, Any] = {
        "destination": destination,
        "check_in_date": check_in.isoformat(),
        "check_out_date": check_out.isoformat(),
        "sort": arguments.get("sort", "rate_desc"),
        "force_refresh": arguments.get("force_refresh") is True,
    }
    if normalized["sort"] not in _ALLOWED_SORTS:
        raise FunctionToolError("hotel sort mode is invalid", error_kind="model_correctable")
    for key in ("keywords", "poi_name"):
        value = _clean_string(arguments.get(key), key, maximum=100, required=False)
        if value is not None:
            normalized[key] = value
    hotel_types = _enum_list(arguments.get("hotel_types"), _ALLOWED_HOTEL_TYPES, "hotel_types", 3)
    normalized["hotel_types"] = hotel_types or ["hotel"]
    bed_types = _enum_list(arguments.get("hotel_bed_types"), _ALLOWED_BED_TYPES, "hotel_bed_types", 3)
    if bed_types:
        normalized["hotel_bed_types"] = bed_types
    stars = arguments.get("hotel_stars")
    if stars is not None:
        if not isinstance(stars, list) or len(stars) > 5 or any(
            isinstance(value, bool) or not isinstance(value, int) or value < 1 or value > 5 for value in stars
        ):
            raise FunctionToolError("hotel_stars must contain integers from 1 to 5", error_kind="model_correctable")
        if len(set(stars)) != len(stars):
            raise FunctionToolError("hotel_stars must not contain duplicates", error_kind="model_correctable")
        if stars:
            normalized["hotel_stars"] = stars
    max_price = arguments.get("max_price")
    if max_price is not None:
        if isinstance(max_price, bool) or not isinstance(max_price, (int, float)):
            raise FunctionToolError("max_price must be a number", error_kind="model_correctable")
        max_price = float(max_price)
        if not (0 < max_price <= 100000):
            raise FunctionToolError("max_price is outside the supported range", error_kind="model_correctable")
        normalized["max_price"] = max_price
    return normalized


def _normalize_provider_payload(payload: Any, query: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(payload, dict):
        raise FunctionToolError("FlyAI hotel search returned an invalid payload")
    status = payload.get("status")
    if status not in (0, "0"):
        message = str(payload.get("message") or "provider rejected hotel search")[:300]
        raise FunctionToolError(
            f"FlyAI hotel search failed: {message}",
            error_kind=_provider_error_kind(message),
            output={"provider": "flyai_fliggy", "provider_status": status},
        )
    encoded = json.dumps(payload, ensure_ascii=False).lower()
    if "体验模式" in encoded or "experience mode" in encoded or "trial mode" in encoded:
        raise FunctionToolError(
            "FlyAI hotel search unexpectedly returned trial-mode data; formal-key readiness is not valid",
            error_kind="terminal",
            output={"provider": "flyai_fliggy", "provider_status": status},
        )
    data = payload.get("data")
    items = data.get("itemList") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise FunctionToolError("FlyAI hotel search omitted data.itemList")

    max_price = query.get("max_price")
    normalized_items: List[Dict[str, Any]] = []
    dropped_invalid = 0
    dropped_over_budget = 0
    dropped_unverifiable_budget = 0
    for raw in items[: max(_MAX_ITEMS * 2, _MAX_ITEMS)]:
        if not isinstance(raw, dict):
            dropped_invalid += 1
            continue
        item = _normalize_item(raw, query.get("poi_name"))
        if item is None:
            dropped_invalid += 1
            continue
        if max_price is not None:
            if not item["price_exact"]:
                dropped_unverifiable_budget += 1
                continue
            if item["price_amount"] > float(max_price):
                dropped_over_budget += 1
                continue
        normalized_items.append(item)
        if len(normalized_items) >= _MAX_ITEMS:
            break

    if not normalized_items and items:
        raise FunctionToolError(
            "FlyAI returned hotel rows, but none passed Floweroll verification",
            error_kind="terminal",
            output={
                "provider": "flyai_fliggy",
                "raw_item_count": len(items),
                "dropped_invalid": dropped_invalid,
                "dropped_over_budget": dropped_over_budget,
                "dropped_unverifiable_budget": dropped_unverifiable_budget,
            },
        )

    exact_price_count = sum(1 for item in normalized_items if item["price_exact"])
    poi_requested = bool(query.get("poi_name"))
    return {
        "provider": "flyai_fliggy",
        "provider_cli_version": FLYAI_CLI_VERSION,
        "query": {key: value for key, value in query.items() if key != "force_refresh"},
        "queried_at": datetime.now(timezone.utc).isoformat(),
        "currency": "CNY",
        "raw_item_count": len(items),
        "item_count": len(normalized_items),
        "exact_price_count": exact_price_count,
        "price_data_complete": exact_price_count == len(normalized_items),
        "max_price_verified": max_price is None or all(
            item["price_exact"] and item["price_amount"] <= float(max_price)
            for item in normalized_items
        ),
        "poi_filter_requested": poi_requested,
        "poi_filter_verified": False if poi_requested else None,
        "proximity_verification_required": poi_requested,
        "coordinate_reference": "provider_unspecified",
        "booking_semantics": "handoff_only",
        "dropped_invalid": dropped_invalid,
        "dropped_over_budget": dropped_over_budget,
        "dropped_unverifiable_budget": dropped_unverifiable_budget,
        "items": normalized_items,
    }


def _normalize_item(raw: Dict[str, Any], poi_name: Any) -> Optional[Dict[str, Any]]:
    provider_id = str(raw.get("shId") or raw.get("id") or "").strip()
    name = str(raw.get("name") or "").strip()
    address = str(raw.get("address") or "").strip()
    nearby = str(raw.get("interestsPoi") or raw.get("nearby") or "").strip()
    detail_url = str(raw.get("detailUrl") or raw.get("jumpUrl") or "").strip()
    if not provider_id or not name or not _approved_handoff_url(detail_url):
        return None
    try:
        latitude = float(raw.get("latitude"))
        longitude = float(raw.get("longitude"))
    except (TypeError, ValueError):
        return None
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    price_amount, price_exact, price_raw = _parse_price(raw.get("price"))
    rating = _optional_float(raw.get("rate"))
    poi = str(poi_name or "").strip()
    provider_poi_text_match = bool(poi and poi in " ".join((name, address, nearby)))
    return {
        "provider_item_id": provider_id,
        "name": name[:200],
        "address": address[:300],
        "nearby": nearby[:200],
        "brand": _optional_text(raw.get("brandName"), 120),
        "star": _optional_text(raw.get("star"), 80),
        "rating": rating,
        "price_amount": price_amount,
        "price_raw": price_raw,
        "price_exact": price_exact,
        "currency": "CNY",
        "latitude": latitude,
        "longitude": longitude,
        "coordinate_reference": "provider_unspecified",
        "provider_poi_text_match": provider_poi_text_match,
        "detail_url": detail_url,
        "main_image_url": _optional_https(raw.get("mainPic")),
    }


def _parse_price(value: Any) -> Tuple[Optional[float], bool, Optional[str]]:
    if isinstance(value, bool):
        return None, False, None
    if isinstance(value, (int, float)):
        number = float(value)
        return (number, True, str(value)) if number >= 0 else (None, False, str(value))
    if not isinstance(value, str):
        return None, False, None
    raw = value.strip()[:80]
    match = _PRICE_RE.fullmatch(raw.replace(",", ""))
    if match is None:
        return None, False, raw or None
    return float(match.group(1)), True, raw


def _approved_handoff_url(value: str) -> bool:
    try:
        parsed = urlparse(value)
    except ValueError:
        return False
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or not host:
        return False
    return host in {"feizhu.com", "fliggy.com"} or any(host.endswith(suffix) for suffix in _ALLOWED_HANDOFF_SUFFIXES)


def _optional_https(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip()[:1000]
    try:
        parsed = urlparse(raw)
    except ValueError:
        return None
    return raw if parsed.scheme == "https" and parsed.hostname else None


def _provider_error_kind(message: str) -> str:
    lowered = message.lower()
    if any(token in lowered for token in ("timeout", "temporar", "429", "502", "503", "504")):
        return "transient"
    if any(token in lowered for token in ("invalid", "missing", "required", "参数", "日期")):
        return "model_correctable"
    return "terminal"


def _parse_date(value: Any, label: str) -> date:
    if not isinstance(value, str):
        raise FunctionToolError(f"{label} must be YYYY-MM-DD", error_kind="model_correctable")
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise FunctionToolError(f"{label} must be YYYY-MM-DD", error_kind="model_correctable") from exc


def _clean_string(value: Any, label: str, *, maximum: int, required: bool) -> Optional[str]:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value.strip():
        if required:
            raise FunctionToolError(f"{label} is required", error_kind="model_correctable")
        return None
    cleaned = value.strip()
    if len(cleaned) > maximum or any(ord(character) < 32 for character in cleaned):
        raise FunctionToolError(f"{label} is invalid", error_kind="model_correctable")
    return cleaned


def _enum_list(value: Any, allowed: set[str], label: str, maximum: int) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > maximum:
        raise FunctionToolError(f"{label} is invalid", error_kind="model_correctable")
    result: List[str] = []
    for item in value:
        if not isinstance(item, str) or item not in allowed:
            raise FunctionToolError(f"{label} contains an unsupported value", error_kind="model_correctable")
        if item in result:
            raise FunctionToolError(f"{label} must not contain duplicates", error_kind="model_correctable")
        result.append(item)
    return result


def _flag(argv: List[str], flag: str, value: Any) -> None:
    if isinstance(value, str) and value:
        argv.extend([flag, value])


def _number_text(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else format(value, ".2f").rstrip("0").rstrip(".")


def _optional_text(value: Any, maximum: int) -> Optional[str]:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    return cleaned[:maximum] if cleaned else None


def _optional_float(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None
