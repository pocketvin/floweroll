from __future__ import annotations

import argparse
import os
from pathlib import Path

from floweroll_host.exa_search_mcp import create_exa_search_driver, register_exa_search
from floweroll_host.amap_mcp import AMAP_SERVER_ID, amap_driver, register_amap_readonly_tools
from floweroll_host.amap_webservice import register_amap_webservice_capabilities
from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.deterministic_calc_adapter import register_deterministic_calc_capability
from floweroll_host.docx_semantic import GENERATE_ID as DOCX_GENERATE_ID, INSPECT_ID as DOCX_INSPECT_ID
from floweroll_host.context7_mcp import (
    CONTEXT7_SERVER_ID,
    context7_driver,
    register_context7_tools,
)
from floweroll_host.host_local_tools import register_host_local_capabilities
from floweroll_host.image_ops import INSPECT_ID as IMAGE_INSPECT_ID, TRANSFORM_ID as IMAGE_TRANSFORM_ID
from floweroll_host.feishu_cli import register_feishu_cli_capabilities
from floweroll_host.flyai_cli import register_flyai_hotel_capability
from floweroll_host.dingtalk_cli import register_dingtalk_cli_capabilities
from floweroll_host.mac_perception_tools import register_mac_perception_capabilities
from floweroll_host.mcp_catalog import load_catalog_from_env, register_catalog
from floweroll_host.host_secrets import (
    hydrate_amap_key_from_host_secret_store,
    hydrate_flyai_key_from_host_secret_store,
    hydrate_mem0_key_from_host_secret_store,
)
from floweroll_host.public_http_tools import register_public_http_capabilities
from floweroll_host.openai_compatible_chat_adapter import OpenAICompatibleChatPlannerAdapter
from floweroll_host.server import create_server
from floweroll_host.task_runtime import TaskRuntime


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the Floweroll durable Agent Host")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--db",
        default=str(Path(__file__).resolve().parents[1] / "work" / "floweroll-v1.sqlite3"),
    )
    args = parser.parse_args()

    auth_token = os.environ.get("FLOWEROLL_HOST_TOKEN")
    registry = CapabilityRegistry()
    host_workspace = Path(
        os.environ.get(
            "FLOWEROLL_HOST_WORKSPACE",
            str(Path(__file__).resolve().parents[1] / "work" / "host-capabilities"),
        )
    )
    function_executors, _host_tools = register_host_local_capabilities(
        registry,
        root=host_workspace,
    )
    calc_executors, calc_health = register_deterministic_calc_capability(registry)
    function_executors.update(calc_executors)
    http_executors, _http_tools = register_public_http_capabilities(registry)
    function_executors.update(http_executors)
    perception_executors, _perception_tools = register_mac_perception_capabilities(
        registry,
        workspace_root=host_workspace,
        helper_source=Path(__file__).resolve().parent / "native_helpers" / "MacPerceptionHelper.swift",
        runtime_dir=Path(__file__).resolve().parents[1] / "work" / "host-native-tools",
    )
    function_executors.update(perception_executors)
    feishu_executors, feishu_health = register_feishu_cli_capabilities(registry)
    function_executors.update(feishu_executors)
    dingtalk_executors, dingtalk_health = register_dingtalk_cli_capabilities(registry)
    function_executors.update(dingtalk_executors)
    flyai_key_source = hydrate_flyai_key_from_host_secret_store()
    flyai_executors, flyai_health = register_flyai_hotel_capability(registry)
    function_executors.update(flyai_executors)
    mcp_drivers = {}
    if os.environ.get("FLOWEROLL_ENABLE_WEB_SEARCH", "1").strip().lower() not in {"0", "false", "off"}:
        try:
            search_driver = create_exa_search_driver()
            if register_exa_search(registry, search_driver):
                mcp_drivers["exa-search"] = search_driver
                print("Public web search: registered (official Exa MCP)")
        except Exception as exc:
            # Do not advertise search when provider discovery failed; no secret
            # response body is echoed into the launch log.
            print("Public web search: unavailable ({})".format(type(exc).__name__))
    context7_enabled = os.environ.get("FLOWEROLL_ENABLE_CONTEXT7", "").strip().lower() in {
        "1", "true", "yes", "on"
    }
    if context7_enabled:
        driver = context7_driver()
        registered = register_context7_tools(registry, driver, force_refresh=True)
        mcp_drivers[CONTEXT7_SERVER_ID] = driver
        print("Context7 MCP enabled: {} semantic read-only capabilities".format(len(registered)))

    amap_key_source = hydrate_amap_key_from_host_secret_store()
    amap_key_configured = amap_key_source is not None
    if amap_key_configured:
        driver = amap_driver()
        registered = register_amap_readonly_tools(registry, driver, force_refresh=True)
        mcp_drivers[AMAP_SERVER_ID] = driver
        print("Amap MCP enabled: {} semantic read-only capabilities".format(len(registered)))
        amap_web_executors, _amap_web_tools = register_amap_webservice_capabilities(registry)
        function_executors.update(amap_web_executors)

    catalog_entries = load_catalog_from_env()
    catalog_report = {}
    if catalog_entries:
        catalog_drivers, catalog_report = register_catalog(
            registry,
            catalog_entries,
            force_refresh=True,
        )
        duplicate_servers = set(mcp_drivers).intersection(catalog_drivers)
        if duplicate_servers:
            raise SystemExit(
                "duplicate MCP server ids: {}".format(", ".join(sorted(duplicate_servers)))
            )
        mcp_drivers.update(catalog_drivers)
        print(
            "Configured MCP catalog enabled: {} server(s), {} semantic capability/capabilities".format(
                len(catalog_drivers),
                sum(len(items) for items in catalog_report.values()),
            )
        )

    planner_api_key = os.environ.get("FLOWEROLL_PLANNER_API_KEY", "").strip()
    planner_base_url = os.environ.get("FLOWEROLL_PLANNER_BASE_URL", "").strip()
    planner_model = os.environ.get("FLOWEROLL_PLANNER_MODEL", "").strip()
    planner_max_completion_tokens_raw = os.environ.get(
        "FLOWEROLL_PLANNER_MAX_COMPLETION_TOKENS", ""
    ).strip()
    planner_reasoning_effort_raw = os.environ.get(
        "FLOWEROLL_PLANNER_REASONING_EFFORT", ""
    ).strip().lower()
    planner_reasoning_effort = planner_reasoning_effort_raw or None
    if planner_reasoning_effort is None and planner_model.lower() in {"kimi-k3", "k3"}:
        # Floweroll Planner makes one bounded next-step decision per call. K3
        # defaults to max reasoning, which adds large latency without owning the
        # durable multi-step plan. Keep max/high opt-in through the environment.
        planner_reasoning_effort = "low"
    if planner_reasoning_effort is not None:
        if planner_model.lower() not in {"kimi-k3", "k3"}:
            raise SystemExit(
                "FLOWEROLL_PLANNER_REASONING_EFFORT is currently supported only for Kimi K3"
            )
        if planner_reasoning_effort not in {"low", "high", "max"}:
            raise SystemExit(
                "FLOWEROLL_PLANNER_REASONING_EFFORT must be low, high, or max for Kimi K3"
            )

    planner_max_completion_tokens = None
    if planner_max_completion_tokens_raw:
        try:
            planner_max_completion_tokens = int(planner_max_completion_tokens_raw)
        except ValueError as exc:
            raise SystemExit(
                "FLOWEROLL_PLANNER_MAX_COMPLETION_TOKENS must be a positive integer"
            ) from exc
        if planner_max_completion_tokens < 1:
            raise SystemExit(
                "FLOWEROLL_PLANNER_MAX_COMPLETION_TOKENS must be a positive integer"
            )
    planner_capabilities = product_native_capabilities() + registry.planner_capabilities()
    task_runtime_factory = None
    product_policy_snapshot = None
    mem0_memory = None
    mem0_key_source = None
    mem0_user_id = os.environ.get("FLOWEROLL_MEM0_USER_ID", "floweroll-owner").strip() or "floweroll-owner"
    if planner_api_key:
        if not planner_base_url or not planner_model:
            raise SystemExit(
                "FLOWEROLL_PLANNER_BASE_URL and FLOWEROLL_PLANNER_MODEL are required when FLOWEROLL_PLANNER_API_KEY is set"
            )
        mem0_key_source = hydrate_mem0_key_from_host_secret_store()
        mem0_api_key = os.environ.get("MEM0_API_KEY", "").strip()
        if not mem0_api_key:
            raise SystemExit(
                "Mem0 API key is required when the Floweroll Planner is enabled "
                "(MEM0_API_KEY, macOS Keychain, or ~/.mem0/config.json)"
            )
        try:
            from floweroll_host.mem0_memory import Mem0Memory
            mem0_memory = Mem0Memory(api_key=mem0_api_key, user_id=mem0_user_id)
        except Exception as exc:
            raise SystemExit("Mem0 initialization failed: {}".format(type(exc).__name__)) from exc
        planner = OpenAICompatibleChatPlannerAdapter(
            api_key=planner_api_key,
            model=planner_model,
            base_url=planner_base_url,
            max_completion_tokens_override=planner_max_completion_tokens,
            reasoning_effort_override=planner_reasoning_effort,
        )
        task_runtime_factory = lambda store: TaskRuntime(
            store,
            planner,
            product_native_capabilities() + registry.planner_capabilities(),
            memory=mem0_memory,
        )
        product_policy_snapshot = {
            "allowed_capabilities": [cap.name for cap in planner_capabilities] + [IMAGE_INSPECT_ID, IMAGE_TRANSFORM_ID, DOCX_INSPECT_ID, DOCX_GENERATE_ID, "work.execute", "materials.inspect", "document.scan_pdf", "document.pdf_merge", "document.pdf_select", "deliverables.plan", "deliverables.publish", "deliverables.status", "deliverables.verify"],
            "constraints": ["host-authoritative", "iphone-foreground-protected"],
        }

    server = create_server(
        args.host,
        args.port,
        args.db,
        auth_token=auth_token,
        task_runtime_factory=task_runtime_factory,
        product_policy_snapshot=product_policy_snapshot,
        capability_registry=registry,
        mcp_drivers=mcp_drivers,
        function_executors=function_executors,
        task_asset_root=Path(os.environ.get("FLOWEROLL_TASK_ASSET_ROOT", str(host_workspace.parent / "task-materials"))),
        progressive_discovery=True,
    )
    print("小卷 host listening on http://{}:{}".format(args.host, args.port))
    print("SQLite: {}".format(args.db))
    print("Host API authentication: {}".format("enabled" if auth_token else "disabled (loopback development only)"))
    print("Host workspace: {}".format(host_workspace.expanduser().resolve()))
    print("Host function capabilities: {}".format(", ".join(sorted(function_executors))))
    print(
        "Deterministic calculation: {}".format(
            "ready" if calc_health.get("ready") else "unavailable"
        )
    )
    print(
        "Feishu CLI: installed={} authenticated={} ready_capabilities={}".format(
            feishu_health.get("installed", False),
            feishu_health.get("authenticated", False),
            feishu_health.get("ready_capability_count", 0),
        )
    )
    print(
        "DingTalk CLI: installed={} authenticated={} ready_capabilities={}".format(
            dingtalk_health.get("installed", False),
            dingtalk_health.get("authenticated", False),
            dingtalk_health.get("ready_capability_count", 0),
        )
    )
    print(
        "FlyAI Hotel: installed={} configured={} version={} ready_capabilities={} key_source={}".format(
            flyai_health.get("installed", False),
            flyai_health.get("configured", False),
            flyai_health.get("version") or "unknown",
            flyai_health.get("ready_capability_count", 0),
            flyai_key_source or "none",
        )
    )
    print("Context7 MCP: {}".format("enabled" if context7_enabled else "disabled (set FLOWEROLL_ENABLE_CONTEXT7=1)"))
    print(
        "Amap MCP: {}".format(
            "enabled ({})".format(amap_key_source)
            if amap_key_configured
            else "disabled (set AMAP_MAPS_API_KEY or configure the Floweroll Host Keychain item)"
        )
    )
    print("Configured MCP catalog servers: {}".format(len(catalog_report)))
    print("Planner: {}".format(planner_model if task_runtime_factory is not None else "disabled"))
    print(
        "Mem0 memory: {}".format(
            "enabled (user_id={}, key_source={})".format(mem0_user_id, mem0_key_source)
            if mem0_memory is not None
            else "inactive because Planner is disabled"
        )
    )
    print("Planner capabilities: {}".format(", ".join(cap.name for cap in planner_capabilities)))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
