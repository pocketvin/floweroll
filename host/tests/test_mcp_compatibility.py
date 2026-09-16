from __future__ import annotations

import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.mcp_catalog import load_catalog_from_env, register_catalog
from floweroll_host.mcp_driver import MCPDriver, MCPServerConfig


class _LegacyFixture:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[dict] = []

    def record(self, headers, body) -> None:
        with self.lock:
            self.requests.append(
                {
                    "method": body.get("method"),
                    "id": body.get("id"),
                    "protocol": headers.get("MCP-Protocol-Version"),
                    "session": headers.get("Mcp-Session-Id"),
                    "mcp_method": headers.get("Mcp-Method"),
                }
            )


class _LegacyHandler(BaseHTTPRequestHandler):
    fixture: _LegacyFixture

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

        if method == "server/discover":
            self._rpc_error(request_id, -32601, "method not found")
            return
        if method == "initialize":
            self._rpc(
                request_id,
                {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "legacy-fixture", "version": "1"},
                },
                session="legacy-session-1",
            )
            return
        if method == "notifications/initialized":
            if self.headers.get("Mcp-Session-Id") != "legacy-session-1":
                self.send_error(400)
                return
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if method == "tools/list":
            if self.headers.get("Mcp-Session-Id") != "legacy-session-1":
                self.send_error(400)
                return
            if self.headers.get("MCP-Protocol-Version") != "2025-11-25":
                self.send_error(400)
                return
            self._rpc(
                request_id,
                {
                    "tools": [
                        {
                            "name": "legacy_search",
                            "description": "legacy search",
                            "inputSchema": {
                                "type": "object",
                                "properties": {"query": {"type": "string"}},
                                "required": ["query"],
                                "additionalProperties": False,
                            },
                        }
                    ]
                },
            )
            return
        if method == "tools/call":
            self._rpc(
                request_id,
                {
                    "content": [{"type": "text", "text": "legacy ok"}],
                    "structuredContent": {"ok": True},
                    "isError": False,
                },
            )
            return
        self._rpc_error(request_id, -32601, "method not found")

    def _rpc(self, request_id, result, *, session=None):
        payload = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        if session:
            self.send_header("Mcp-Session-Id", session)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _rpc_error(self, request_id, code, message):
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class MCPCompatibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = _LegacyFixture()
        handler = type("LegacyHandler", (_LegacyHandler,), {"fixture": self.fixture})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = f"http://127.0.0.1:{self.server.server_address[1]}/mcp"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_auto_protocol_falls_back_to_legacy_session(self) -> None:
        driver = MCPDriver(
            MCPServerConfig(
                server_id="legacy",
                endpoint=self.endpoint,
                timeout_seconds=3,
                protocol_mode="auto",
            )
        )

        listing = driver.list_tools()
        result = driver.call_tool("legacy_search", {"query": "coffee"})

        self.assertEqual(driver.protocol_era, "legacy")
        self.assertEqual(driver.protocol_version, "2025-11-25")
        self.assertEqual([tool.name for tool in listing.tools], ["legacy_search"])
        self.assertEqual(result.structured_content, {"ok": True})
        methods = [item["method"] for item in self.fixture.requests]
        self.assertEqual(
            methods[:4],
            ["server/discover", "initialize", "notifications/initialized", "tools/list"],
        )
        list_request = next(item for item in self.fixture.requests if item["method"] == "tools/list")
        self.assertEqual(list_request["session"], "legacy-session-1")
        self.assertEqual(list_request["protocol"], "2025-11-25")
        self.assertIsNone(list_request["mcp_method"])

    def test_catalog_registers_explicit_semantic_mapping(self) -> None:
        env = {
            "FLOWEROLL_MCP_SERVERS_JSON": json.dumps(
                [
                    {
                        "server_id": "legacy",
                        "endpoint": self.endpoint,
                        "protocol_mode": "legacy",
                        "tools": [
                            {
                                "tool_name": "legacy_search",
                                "capability_id": "knowledge.search",
                                "description": "搜索测试知识源",
                                "read_only": True,
                                "post_verify_mode": "REPLAN_REQUIRED",
                            }
                        ],
                    }
                ],
                ensure_ascii=False,
            )
        }
        entries = load_catalog_from_env(env)
        registry = CapabilityRegistry()

        drivers, report = register_catalog(registry, entries)

        self.assertIn("legacy", drivers)
        self.assertEqual(report, {"legacy": ["knowledge.search"]})
        capability = registry.get("knowledge.search")
        self.assertEqual(capability.source.kind, "mcp")
        self.assertEqual(capability.source.tool_name, "legacy_search")
        self.assertEqual(capability.spec.arguments_schema["required"], ["query"])


if __name__ == "__main__":
    unittest.main()
