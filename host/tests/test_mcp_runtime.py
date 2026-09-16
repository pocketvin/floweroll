from __future__ import annotations

import json
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from floweroll_host.amap_mcp import register_amap_readonly_tools
from floweroll_host.capability_registry import (
    CapabilityRegistry,
    CapabilitySourceTarget,
    RegisteredCapability,
)
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.mcp_adapter import MCPReadToolAdapter
from floweroll_host.mcp_driver import MCPDriver, MCPServerConfig
from floweroll_host.mcp_execution_worker import MCPExecutionWorker
from floweroll_host.planner_contracts import CapabilitySpec
from floweroll_host.runtime_supervisor import RuntimeSupervisor
from floweroll_host.storage import Storage


class _MCPFixture:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.list_calls = 0
        self.call_calls = 0
        self.requests: list[dict] = []

    def record(self, headers, body):
        with self.lock:
            self.requests.append(
                {
                    "method_header": headers.get("Mcp-Method"),
                    "name_header": headers.get("Mcp-Name"),
                    "protocol_header": headers.get("MCP-Protocol-Version"),
                    "body": body,
                }
            )


class _Handler(BaseHTTPRequestHandler):
    fixture: _MCPFixture

    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        if self.path != "/mcp":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        self.fixture.record(self.headers, body)
        method = body.get("method")
        request_id = body.get("id")
        params = body.get("params") or {}

        if method == "tools/list":
            with self.fixture.lock:
                self.fixture.list_calls += 1
            result = {
                "tools": [
                    {
                        "name": "maps_text_search",
                        "description": "搜索地点",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "keywords": {"type": "string"},
                                "city": {"type": "string"},
                            },
                            "required": ["keywords"],
                            "additionalProperties": False,
                        },
                    },
                    {
                        "name": "maps_weather",
                        "description": "查询天气",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"city": {"type": "string"}},
                            "required": ["city"],
                            "additionalProperties": False,
                        },
                    },
                ],
                "ttlMs": 60000,
                "cacheScope": "private",
            }
            self._json_rpc(request_id, result)
            return

        if method == "tools/call":
            with self.fixture.lock:
                self.fixture.call_calls += 1
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if arguments.get("need_confirmation") and not params.get("inputResponses"):
                self._json_rpc(
                    request_id,
                    {
                        "resultType": "input_required",
                        "inputRequests": {
                            "confirm": {
                                "type": "elicitation",
                                "params": {
                                    "message": "确认继续这个工具调用吗？",
                                    "requestedSchema": {
                                        "type": "object",
                                        "properties": {"confirmed": {"type": "boolean"}},
                                        "required": ["confirmed"],
                                        "additionalProperties": False,
                                    },
                                },
                            }
                        },
                        "requestState": "opaque-round-state",
                    },
                )
                return
            if name == "maps_text_search":
                self._json_rpc(
                    request_id,
                    {
                        "content": [{"type": "text", "text": "找到 1 家咖啡店"}],
                        "structuredContent": {
                            "pois": [
                                {
                                    "id": "poi-1",
                                    "name": "测试咖啡店",
                                    "city": arguments.get("city", "杭州"),
                                }
                            ]
                        },
                        "isError": False,
                    },
                )
                return
            self._json_rpc(
                request_id,
                {
                    "content": [{"type": "text", "text": "ok"}],
                    "structuredContent": {"ok": True},
                    "isError": False,
                },
            )
            return

        self._json_rpc_error(request_id, -32601, "method not found")

    def _json_rpc(self, request_id, result):
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "result": result},
            ensure_ascii=False,
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _json_rpc_error(self, request_id, code, message):
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class MCPRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = _MCPFixture()
        handler = type("FixtureHandler", (_Handler,), {"fixture": self.fixture})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = f"http://127.0.0.1:{self.server.server_address[1]}/mcp"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def driver(self, server_id: str = "amap") -> MCPDriver:
        return MCPDriver(
            MCPServerConfig(
                server_id=server_id,
                endpoint=self.endpoint,
                timeout_seconds=3,
                protocol_mode="modern",
            )
        )

    def test_modern_mcp_list_uses_required_metadata_and_ttl_cache(self) -> None:
        driver = self.driver()

        first = driver.list_tools()
        second = driver.list_tools()

        self.assertEqual([tool.name for tool in first.tools], ["maps_text_search", "maps_weather"])
        self.assertEqual([tool.name for tool in second.tools], ["maps_text_search", "maps_weather"])
        self.assertEqual(self.fixture.list_calls, 1)
        request = self.fixture.requests[0]
        self.assertEqual(request["method_header"], "tools/list")
        self.assertEqual(request["protocol_header"], "2026-07-28")
        meta = request["body"]["params"]["_meta"]
        self.assertEqual(meta["io.modelcontextprotocol/protocolVersion"], "2026-07-28")
        self.assertIn("io.modelcontextprotocol/clientInfo", meta)
        self.assertIn("io.modelcontextprotocol/tasks", meta["io.modelcontextprotocol/clientCapabilities"]["extensions"])

    def test_amap_raw_tool_maps_to_semantic_capability(self) -> None:
        driver = self.driver()
        registry = CapabilityRegistry()

        registered = register_amap_readonly_tools(registry, driver)

        self.assertIn("places.search", registered)
        self.assertIn("weather.query", registered)
        entry = registry.get("places.search")
        self.assertEqual(entry.source.kind, "mcp")
        self.assertEqual(entry.source.server_id, "amap")
        self.assertEqual(entry.source.tool_name, "maps_text_search")
        self.assertEqual(entry.spec.arguments_schema["required"], ["keywords"])
        self.assertNotIn("maps_text_search", [cap.name for cap in registry.planner_capabilities()])

    def test_json_text_content_is_normalized_as_structured_content(self) -> None:
        normalized = MCPExecutionWorker._structured_json_from_content(
            [{"type": "text", "text": '{"pois":[{"name":"杭州东站"}],"count":1}'}]
        )

        self.assertEqual(normalized["count"], 1)
        self.assertEqual(normalized["pois"][0]["name"], "杭州东站")
        self.assertIsNone(
            MCPExecutionWorker._structured_json_from_content(
                [{"type": "text", "text": "plain provider text"}]
            )
        )

    def test_mcp_action_runs_through_attempt_and_observation(self) -> None:
        driver = self.driver()
        registry = CapabilityRegistry()
        register_amap_readonly_tools(registry, driver)
        store = Storage(":memory:")
        task = store.create_task("mcp-final-task", "找一家咖啡店", "unit", {}, status="active")
        store.create_action(
            action_id="mcp-final-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="places.search",
            payload={"keywords": "咖啡", "city": "杭州"},
            expected={},
            idempotency_key="mcp-final-task:1:places.search",
            on_verified="COMPLETE",
        )
        execution = ExecutionRuntime(store, registry.execution_adapters())
        worker = MCPExecutionWorker(execution, registry, {"amap": driver})

        result = worker.run_once(task["task_id"])

        self.assertIsNotNone(result)
        self.assertEqual(store.get_task(task["task_id"])["status"], "completed")
        attempts = store.action_attempts("mcp-final-action")
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["source_kind"], "mcp")
        self.assertEqual(attempts[0]["latest_outcome"], "SUCCESS")
        observations = store.verified_observations(task["task_id"])
        self.assertEqual(len(observations), 1)
        data = observations[0]["data"]
        self.assertEqual(data["server_id"], "amap")
        self.assertEqual(data["tool_name"], "maps_text_search")
        self.assertEqual(data["structured_content"]["pois"][0]["name"], "测试咖啡店")
        call = next(req for req in self.fixture.requests if req["method_header"] == "tools/call")
        self.assertEqual(call["name_header"], "maps_text_search")

    def test_runtime_supervisor_automatically_executes_mcp_action(self) -> None:
        driver = self.driver()
        registry = CapabilityRegistry()
        register_amap_readonly_tools(registry, driver)
        store = Storage(":memory:")
        task = store.create_task("mcp-supervisor-task", "后台搜索咖啡店", "unit", {}, status="active")
        store.create_action(
            action_id="mcp-supervisor-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="places.search",
            payload={"keywords": "咖啡", "city": "杭州"},
            expected={},
            idempotency_key="mcp-supervisor-task:1",
            on_verified="COMPLETE",
        )
        execution = ExecutionRuntime(store, registry.execution_adapters())
        worker = MCPExecutionWorker(execution, registry, {"amap": driver})
        supervisor = RuntimeSupervisor(
            store,
            None,
            execution_workers=[worker],
            poll_interval_seconds=0.02,
        )
        supervisor.start()
        try:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if store.get_task(task["task_id"])["status"] == "completed":
                    break
                time.sleep(0.01)
            self.assertEqual(store.get_task(task["task_id"])["status"], "completed")
            self.assertEqual(len(store.action_attempts("mcp-supervisor-action")), 1)
        finally:
            supervisor.stop()

    def test_input_required_resumes_same_attempt(self) -> None:
        driver = self.driver(server_id="fixture")
        spec = CapabilitySpec(
            name="test.mcp.confirm",
            description="测试 MCP 输入续跑",
            arguments_schema={
                "type": "object",
                "properties": {"need_confirmation": {"type": "boolean"}},
                "required": ["need_confirmation"],
                "additionalProperties": False,
            },
        )
        adapter = MCPReadToolAdapter(
            capability_id=spec.name,
            server_id="fixture",
            tool_name="confirm_tool",
        )
        registry = CapabilityRegistry(
            [
                RegisteredCapability(
                    spec=spec,
                    adapter=adapter,
                    source=CapabilitySourceTarget(
                        kind="mcp", server_id="fixture", tool_name="confirm_tool"
                    ),
                )
            ]
        )
        store = Storage(":memory:")
        task = store.create_task("mcp-input-task", "需要确认", "unit", {}, status="active")
        store.create_action(
            action_id="mcp-input-action",
            task_id=task["task_id"],
            step_index=1,
            action_type=spec.name,
            payload={"need_confirmation": True},
            expected={},
            idempotency_key="mcp-input-task:1",
            on_verified="COMPLETE",
        )
        execution = ExecutionRuntime(store, registry.execution_adapters())
        worker = MCPExecutionWorker(execution, registry, {"fixture": driver})

        pending = worker.run_once(task["task_id"])
        self.assertIsNotNone(pending)
        attempt = store.current_action_attempt("mcp-input-action")
        assert attempt is not None
        attempt_id = attempt["attempt_id"]
        self.assertEqual(attempt["status"], "WAITING_INPUT")
        request = store.pending_action_input_for_action("mcp-input-action")
        assert request is not None
        self.assertEqual(request["attempt_id"], attempt_id)

        store.admit_action_input_response(
            task_id=task["task_id"],
            input_request_id=request["input_request_id"],
            event_id="mcp-input-response",
            binding_digest=request["binding_digest"],
            response={"approved": True},
        )
        store.consume_action_input_response(event_id="mcp-input-response")
        finished = worker.run_once(task["task_id"])

        self.assertIsNotNone(finished)
        attempts = store.action_attempts("mcp-input-action")
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["attempt_id"], attempt_id)
        self.assertEqual(attempts[0]["attempt_number"], 1)
        self.assertEqual(attempts[0]["source_round"], 1)
        self.assertEqual(attempts[0]["latest_outcome"], "SUCCESS")
        self.assertEqual(store.get_task(task["task_id"])["status"], "completed")
        calls = [req for req in self.fixture.requests if req["method_header"] == "tools/call"]
        self.assertEqual(len(calls), 2)
        self.assertIsNone(calls[0]["body"]["params"].get("inputResponses"))
        self.assertIn("inputResponses", calls[1]["body"]["params"])
        self.assertEqual(calls[1]["body"]["params"]["requestState"], "opaque-round-state")


if __name__ == "__main__":
    unittest.main()
