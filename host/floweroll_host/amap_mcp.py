from __future__ import annotations

from typing import Dict, List, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .mcp_adapter import MCPReadToolAdapter
from .mcp_driver import MCPDriver, MCPServerConfig
from .planner_contracts import CapabilitySpec


AMAP_SERVER_ID = "amap"

# Application-owned semantic identities. We intentionally do not expose raw
# `maps_*` names as the Planner's global capability namespace.
AMAP_READONLY_TOOL_MAP: Dict[str, Tuple[str, str, tuple[str, ...]]] = {
    "maps_geo": (
        "geocode.resolve",
        "把中国大陆的结构化地址解析为经纬度。",
        ("maps", "geocode", "location"),
    ),
    "maps_regeocode": (
        "geocode.reverse",
        "把高德经纬度解析为结构化地址信息。",
        ("maps", "geocode", "location"),
    ),
    "maps_weather": (
        "weather.query",
        "查询中国大陆城市的实时/预报天气，用于后续任务判断。",
        ("weather", "maps", "read"),
    ),
    "maps_text_search": (
        "places.search",
        "按关键词搜索地点/POI，可结合城市限定范围。",
        ("places", "poi", "search"),
    ),
    "maps_around_search": (
        "places.search_nearby",
        "以经纬度为中心搜索附近地点/POI。",
        ("places", "poi", "nearby"),
    ),
    "maps_search_detail": (
        "places.detail",
        "根据 POI ID 获取地点详情。",
        ("places", "poi", "detail"),
    ),
    "maps_direction_walking": (
        "routes.walk",
        "根据起终点经纬度规划步行路线。",
        ("routes", "walking", "maps"),
    ),
    "maps_direction_driving": (
        "routes.drive",
        "根据起终点经纬度规划驾车路线。",
        ("routes", "driving", "maps"),
    ),
    "maps_direction_transit_integrated": (
        "routes.transit",
        "根据起终点和城市信息规划公交/地铁等公共交通路线。",
        ("routes", "transit", "maps"),
    ),
    "maps_distance": (
        "routes.distance",
        "测量起终点之间的距离/预计时间。",
        ("routes", "distance", "maps"),
    ),
}


def amap_server_config() -> MCPServerConfig:
    # The Key is resolved only at request time and never enters source_target,
    # Action, Attempt, Trace or repository configuration.
    return MCPServerConfig(
        server_id=AMAP_SERVER_ID,
        endpoint="https://mcp.amap.com/mcp",
        secret_query_env={"key": "AMAP_MAPS_API_KEY"},
        timeout_seconds=30,
        enable_tasks_extension=True,
    )


def amap_driver() -> MCPDriver:
    return MCPDriver(amap_server_config())


def register_amap_readonly_tools(
    registry: CapabilityRegistry,
    driver: MCPDriver,
    *,
    force_refresh: bool = False,
) -> List[str]:
    listing = driver.list_tools(force_refresh=force_refresh)
    by_name = {tool.name: tool for tool in listing.tools}
    registered: List[str] = []
    for raw_name, (capability_id, description, tags) in AMAP_READONLY_TOOL_MAP.items():
        tool = by_name.get(raw_name)
        if tool is None:
            continue
        spec = CapabilitySpec(
            name=capability_id,
            description=description,
            arguments_schema=tool.input_schema,
            post_verify_mode="REPLAN_REQUIRED",
        )
        adapter = MCPReadToolAdapter(
            capability_id=capability_id,
            server_id=AMAP_SERVER_ID,
            tool_name=raw_name,
        )
        registry.register(
            RegisteredCapability(
                spec=spec,
                adapter=adapter,
                source=CapabilitySourceTarget(
                    kind="mcp",
                    server_id=AMAP_SERVER_ID,
                    tool_name=raw_name,
                    metadata={"provider": "amap", "read_only": True},
                ),
                tags=tags,
                loading="always_visible",
            )
        )
        registered.append(capability_id)
    return registered
