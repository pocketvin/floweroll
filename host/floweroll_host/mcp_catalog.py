from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .mcp_adapter import MCPReadToolAdapter
from .mcp_driver import MCPDriver, MCPServerConfig
from .planner_contracts import CapabilitySpec


CATALOG_ENV = "FLOWEROLL_MCP_SERVERS_JSON"


@dataclass(frozen=True)
class MCPToolMapping:
    tool_name: str
    capability_id: str
    description: str
    tags: tuple[str, ...] = ()
    loading: str = "always_visible"
    post_verify_mode: str = "REPLAN_REQUIRED"


@dataclass(frozen=True)
class MCPServerCatalogEntry:
    server_id: str
    endpoint: str
    tools: tuple[MCPToolMapping, ...]
    timeout_seconds: float = 30.0
    headers: Mapping[str, str] = field(default_factory=dict)
    secret_query_env: Mapping[str, str] = field(default_factory=dict)
    secret_header_env: Mapping[str, str] = field(default_factory=dict)
    protocol_mode: str = "auto"

    def driver(self) -> MCPDriver:
        return MCPDriver(
            MCPServerConfig(
                server_id=self.server_id,
                endpoint=self.endpoint,
                timeout_seconds=self.timeout_seconds,
                headers=dict(self.headers or {}),
                secret_query_env=dict(self.secret_query_env or {}),
                secret_header_env=dict(self.secret_header_env or {}),
                enable_tasks_extension=True,
                protocol_mode=self.protocol_mode,
            )
        )


def load_catalog_from_env(env: Mapping[str, str] = os.environ) -> List[MCPServerCatalogEntry]:
    raw = env.get(CATALOG_ENV, "").strip()
    if not raw:
        return []
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{CATALOG_ENV} must be valid JSON") from exc
    if not isinstance(value, list):
        raise ValueError(f"{CATALOG_ENV} must be a JSON array")
    return [_parse_server(item) for item in value]


def register_catalog(
    registry: CapabilityRegistry,
    entries: Sequence[MCPServerCatalogEntry],
    *,
    force_refresh: bool = True,
) -> Tuple[Dict[str, MCPDriver], Dict[str, List[str]]]:
    drivers: Dict[str, MCPDriver] = {}
    report: Dict[str, List[str]] = {}
    for entry in entries:
        if entry.server_id in drivers:
            raise ValueError(f"duplicate MCP server_id in catalog: {entry.server_id}")
        driver = entry.driver()
        listing = driver.list_tools(force_refresh=force_refresh)
        by_name = {tool.name: tool for tool in listing.tools}
        registered: List[str] = []
        for mapping in entry.tools:
            tool = by_name.get(mapping.tool_name)
            if tool is None:
                continue
            spec = CapabilitySpec(
                name=mapping.capability_id,
                description=mapping.description,
                arguments_schema=tool.input_schema,
                post_verify_mode=mapping.post_verify_mode,
            )
            adapter = MCPReadToolAdapter(
                capability_id=mapping.capability_id,
                server_id=entry.server_id,
                tool_name=mapping.tool_name,
            )
            registry.register(
                RegisteredCapability(
                    spec=spec,
                    adapter=adapter,
                    source=CapabilitySourceTarget(
                        kind="mcp",
                        server_id=entry.server_id,
                        tool_name=mapping.tool_name,
                        metadata={"configured_catalog": True, "read_only": True},
                    ),
                    tags=mapping.tags,
                    loading=mapping.loading,
                )
            )
            registered.append(mapping.capability_id)
        drivers[entry.server_id] = driver
        report[entry.server_id] = registered
    return drivers, report


def _parse_server(item: Any) -> MCPServerCatalogEntry:
    if not isinstance(item, dict):
        raise ValueError("each MCP catalog server must be an object")
    allowed = {
        "server_id",
        "endpoint",
        "timeout_seconds",
        "headers",
        "secret_query_env",
        "secret_header_env",
        "protocol_mode",
        "tools",
    }
    extra = set(item) - allowed
    if extra:
        raise ValueError("unsupported MCP catalog server fields: {}".format(", ".join(sorted(extra))))
    server_id = _nonempty_string(item.get("server_id"), "server_id")
    endpoint = _nonempty_string(item.get("endpoint"), "endpoint")
    timeout = item.get("timeout_seconds", 30.0)
    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or timeout <= 0:
        raise ValueError("MCP timeout_seconds must be a positive number")
    protocol_mode = item.get("protocol_mode", "auto")
    if protocol_mode not in {"auto", "modern", "legacy"}:
        raise ValueError("MCP protocol_mode must be auto, modern, or legacy")
    raw_tools = item.get("tools")
    if not isinstance(raw_tools, list) or not raw_tools:
        raise ValueError("MCP catalog server requires a non-empty tools array")
    tools = tuple(_parse_tool_mapping(value) for value in raw_tools)
    return MCPServerCatalogEntry(
        server_id=server_id,
        endpoint=endpoint,
        timeout_seconds=float(timeout),
        headers=_string_map(item.get("headers"), "headers"),
        secret_query_env=_string_map(item.get("secret_query_env"), "secret_query_env"),
        secret_header_env=_string_map(item.get("secret_header_env"), "secret_header_env"),
        protocol_mode=protocol_mode,
        tools=tools,
    )


def _parse_tool_mapping(item: Any) -> MCPToolMapping:
    if not isinstance(item, dict):
        raise ValueError("each MCP tool mapping must be an object")
    allowed = {
        "tool_name",
        "capability_id",
        "description",
        "tags",
        "loading",
        "post_verify_mode",
        "read_only",
    }
    extra = set(item) - allowed
    if extra:
        raise ValueError("unsupported MCP tool mapping fields: {}".format(", ".join(sorted(extra))))
    if item.get("read_only", True) is not True:
        raise ValueError(
            "generic MCP catalog currently accepts only explicitly read-only tools; "
            "side-effect tools need provider-specific verification/idempotency semantics"
        )
    tags_raw = item.get("tags", [])
    if not isinstance(tags_raw, list) or not all(isinstance(tag, str) and tag.strip() for tag in tags_raw):
        raise ValueError("MCP tool tags must be strings")
    loading = item.get("loading", "always_visible")
    if loading not in {"always_visible", "deferred"}:
        raise ValueError("MCP tool loading must be always_visible or deferred")
    post_verify_mode = item.get("post_verify_mode", "REPLAN_REQUIRED")
    if post_verify_mode not in {"COMPLETE_ALLOWED", "REPLAN_REQUIRED"}:
        raise ValueError("invalid MCP tool post_verify_mode")
    return MCPToolMapping(
        tool_name=_nonempty_string(item.get("tool_name"), "tool_name"),
        capability_id=_nonempty_string(item.get("capability_id"), "capability_id"),
        description=_nonempty_string(item.get("description"), "description"),
        tags=tuple(tag.strip() for tag in tags_raw),
        loading=loading,
        post_verify_mode=post_verify_mode,
    )


def _string_map(value: Any, field: str) -> Dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"MCP {field} must be an object")
    result: Dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not key.strip() or not isinstance(item, str) or not item.strip():
            raise ValueError(f"MCP {field} keys/values must be non-empty strings")
        result[key.strip()] = item.strip()
    return result


def _nonempty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"MCP {field} must be a non-empty string")
    return value.strip()
