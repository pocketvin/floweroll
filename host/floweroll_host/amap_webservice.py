from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, Optional, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .function_execution_worker import FunctionExecutor, FunctionToolError
from .function_tool_adapter import FunctionToolAdapter
from .planner_contracts import CapabilitySpec


COORDINATE_CONVERT_ID = "coords.convert"
_COORDINATE_CONVERT_URL = "https://restapi.amap.com/v3/assistant/coordinate/convert"
_MAX_RESPONSE_BYTES = 32_000


class AmapWebServiceTools:
    """Small official Amap Web Service bridge for gaps not exposed by Amap MCP."""

    def __init__(
        self,
        *,
        api_key_provider: Optional[Callable[[], str]] = None,
        opener: Any = None,
    ) -> None:
        self._api_key_provider = api_key_provider or (
            lambda: os.environ.get("AMAP_MAPS_API_KEY", "")
        )
        self._opener = opener or urllib.request.build_opener()

    def convert_coordinate(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        longitude = _finite_coordinate(arguments.get("longitude"), "longitude", -180.0, 180.0)
        latitude = _finite_coordinate(arguments.get("latitude"), "latitude", -90.0, 90.0)
        source = arguments.get("source_coordinate_system", "WGS84")
        if source != "WGS84":
            raise FunctionToolError(
                "coords.convert currently accepts only WGS84 input",
                error_kind="model_correctable",
            )

        api_key = self._api_key_provider().strip()
        if not api_key:
            raise FunctionToolError("Amap Web Service key is not configured")

        query = urllib.parse.urlencode(
            {
                "locations": f"{longitude:.6f},{latitude:.6f}",
                "coordsys": "gps",
                "output": "JSON",
                "key": api_key,
            }
        )
        request = urllib.request.Request(
            f"{_COORDINATE_CONVERT_URL}?{query}",
            method="GET",
            headers={"Accept": "application/json", "User-Agent": "floweroll-host/0.1"},
        )
        try:
            with self._opener.open(request, timeout=15) as response:
                raw = response.read(_MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exc:
            kind = "transient" if exc.code == 429 or 500 <= exc.code <= 599 else "terminal"
            raise FunctionToolError(
                f"Amap coordinate conversion returned HTTP {exc.code}",
                error_kind=kind,
                output={"status": int(exc.code)},
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise FunctionToolError(
                "Amap coordinate conversion network request failed",
                error_kind="transient",
            ) from exc

        if len(raw) > _MAX_RESPONSE_BYTES:
            raise FunctionToolError("Amap coordinate conversion response was too large")
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise FunctionToolError("Amap coordinate conversion returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise FunctionToolError("Amap coordinate conversion returned an invalid payload")
        if str(payload.get("status")) != "1":
            info = str(payload.get("info") or "provider rejected request")[:200]
            infocode = str(payload.get("infocode") or "")[:40]
            raise FunctionToolError(
                f"Amap coordinate conversion failed: {info}",
                error_kind="terminal",
                output={"provider": "amap", "infocode": infocode},
            )

        converted = payload.get("locations")
        if not isinstance(converted, str) or not converted.strip():
            raise FunctionToolError("Amap coordinate conversion omitted converted coordinates")
        first = converted.split(";", 1)[0]
        lon_text, separator, lat_text = first.partition(",")
        if not separator:
            raise FunctionToolError("Amap coordinate conversion returned malformed coordinates")
        try:
            converted_longitude = float(lon_text)
            converted_latitude = float(lat_text)
        except ValueError as exc:
            raise FunctionToolError("Amap coordinate conversion returned malformed coordinates") from exc
        _finite_coordinate(converted_longitude, "converted longitude", -180.0, 180.0)
        _finite_coordinate(converted_latitude, "converted latitude", -90.0, 90.0)

        return {
            "provider": "amap",
            "source_coordinate_reference": "WGS84",
            "coordinate_reference": "GCJ-02",
            "longitude": converted_longitude,
            "latitude": converted_latitude,
            "location": f"{converted_longitude:.12f},{converted_latitude:.12f}",
            "privacy_class": "precise_location",
            "verified_by_provider": True,
        }


def register_amap_webservice_capabilities(
    registry: CapabilityRegistry,
) -> Tuple[Dict[str, FunctionExecutor], AmapWebServiceTools]:
    tools = AmapWebServiceTools()
    spec = CapabilitySpec(
        name=COORDINATE_CONVERT_ID,
        description=(
            "把 iPhone/GPS 的 WGS84 经纬度转换为高德 GCJ-02 坐标。"
            "仅在需要把当前位置接入高德附近搜索或路线规划时使用。"
        ),
        arguments_schema={
            "type": "object",
            "properties": {
                "longitude": {"type": "number", "minimum": -180, "maximum": 180},
                "latitude": {"type": "number", "minimum": -90, "maximum": 90},
                "source_coordinate_system": {
                    "type": "string",
                    "enum": ["WGS84"],
                    "default": "WGS84",
                },
            },
            "required": ["longitude", "latitude"],
            "additionalProperties": False,
        },
        post_verify_mode="REPLAN_REQUIRED",
    )
    registry.register(
        RegisteredCapability(
            spec=spec,
            adapter=FunctionToolAdapter(
                capability_id=COORDINATE_CONVERT_ID,
                source_kind="http_api",
                read_only=True,
            ),
            source=CapabilitySourceTarget(
                kind="http_api",
                server_id="amap-webservice",
                tool_name="coordinate.convert",
                metadata={
                    "provider": "amap",
                    "read_only": True,
                    "effect": "read",
                    "operation": "read",
                    "domains": ["location"],
                    "network": True,
                    "input_coordinate_reference": "WGS84",
                    "output_coordinate_reference": "GCJ-02",
                },
            ),
            tags=("amap", "maps", "location", "coordinates", "wgs84", "gcj02", "read"),
            loading="always_visible",
        )
    )
    return {COORDINATE_CONVERT_ID: tools.convert_coordinate}, tools


def _finite_coordinate(value: Any, label: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise FunctionToolError(f"{label} must be a number", error_kind="model_correctable")
    number = float(value)
    if number != number or number in {float("inf"), float("-inf")}:
        raise FunctionToolError(f"{label} must be finite", error_kind="model_correctable")
    if number < minimum or number > maximum:
        raise FunctionToolError(
            f"{label} must be between {minimum:g} and {maximum:g}",
            error_kind="model_correctable",
        )
    return number
