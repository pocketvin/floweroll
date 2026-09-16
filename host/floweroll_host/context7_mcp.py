from __future__ import annotations

from typing import Dict, List, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .mcp_adapter import MCPReadToolAdapter
from .mcp_driver import MCPDriver, MCPServerConfig
from .planner_contracts import CapabilitySpec


CONTEXT7_SERVER_ID = "context7"
CONTEXT7_ENDPOINT = "https://mcp.context7.com/mcp"

CONTEXT7_TOOL_MAP: Dict[str, Tuple[str, str, tuple[str, ...], str]] = {
    "resolve-library-id": (
        "docs.library.resolve",
        "把公开软件库名称解析为 Context7 文档库 ID，供后续精确查询官方/项目文档。",
        ("docs", "developer", "library", "read"),
        "REPLAN_REQUIRED",
    ),
    "query-docs": (
        "docs.query",
        "按 Context7 library ID 查询公开软件库的相关文档和代码片段。",
        ("docs", "developer", "search", "read"),
        "REPLAN_REQUIRED",
    ),
}


def context7_driver() -> MCPDriver:
    # Context7's public remote MCP supports anonymous access at a lower rate
    # limit. Authentication can later be supplied through the generic MCP
    # catalog without changing semantic capability ids.
    return MCPDriver(
        MCPServerConfig(
            server_id=CONTEXT7_SERVER_ID,
            endpoint=CONTEXT7_ENDPOINT,
            timeout_seconds=20,
            protocol_mode="auto",
        )
    )


def register_context7_tools(
    registry: CapabilityRegistry,
    driver: MCPDriver,
    *,
    force_refresh: bool = False,
) -> List[str]:
    listing = driver.list_tools(force_refresh=force_refresh)
    by_name = {tool.name: tool for tool in listing.tools}
    registered: List[str] = []
    for raw_name, (capability_id, description, tags, post_verify_mode) in CONTEXT7_TOOL_MAP.items():
        tool = by_name.get(raw_name)
        if tool is None:
            continue
        spec = CapabilitySpec(
            name=capability_id,
            description=description,
            arguments_schema=tool.input_schema,
            post_verify_mode=post_verify_mode,
        )
        adapter = MCPReadToolAdapter(
            capability_id=capability_id,
            server_id=CONTEXT7_SERVER_ID,
            tool_name=raw_name,
        )
        registry.register(
            RegisteredCapability(
                spec=spec,
                adapter=adapter,
                source=CapabilitySourceTarget(
                    kind="mcp",
                    server_id=CONTEXT7_SERVER_ID,
                    tool_name=raw_name,
                    metadata={"provider": "context7", "read_only": True, "anonymous": True},
                ),
                tags=tags,
                loading="always_visible",
            )
        )
        registered.append(capability_id)
    return registered
