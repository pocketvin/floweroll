from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Mapping, Optional, Union


MCP_PROTOCOL_VERSION = "2026-07-28"
MCP_LEGACY_PROTOCOL_VERSION = "2025-11-25"
_CLIENT_INFO_KEY = "io.modelcontextprotocol/clientInfo"
_PROTOCOL_VERSION_KEY = "io.modelcontextprotocol/protocolVersion"
_CLIENT_CAPABILITIES_KEY = "io.modelcontextprotocol/clientCapabilities"
_TASKS_EXTENSION = "io.modelcontextprotocol/tasks"


class MCPError(RuntimeError):
    pass


class MCPConfigurationError(MCPError):
    pass


class MCPHTTPError(MCPError):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"MCP HTTP {status}: {message}")
        self.status = int(status)


class MCPProtocolError(MCPError):
    def __init__(self, code: Optional[int], message: str, data: Any = None) -> None:
        prefix = f"MCP protocol error {code}" if code is not None else "MCP protocol error"
        super().__init__(f"{prefix}: {message}")
        self.code = code
        self.data = data


@dataclass(frozen=True)
class MCPServerConfig:
    server_id: str
    endpoint: str
    timeout_seconds: float = 30.0
    headers: Mapping[str, str] = field(default_factory=dict)
    secret_query_env: Mapping[str, str] = field(default_factory=dict)
    secret_header_env: Mapping[str, str] = field(default_factory=dict)
    enable_tasks_extension: bool = True
    protocol_mode: str = "auto"

    def resolved_endpoint(self) -> str:
        if not self.server_id.strip():
            raise MCPConfigurationError("MCP server_id must not be empty")
        parsed = urllib.parse.urlsplit(self.endpoint)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise MCPConfigurationError(f"MCP server {self.server_id} has an invalid HTTP endpoint")
        query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        for key, env_name in self.secret_query_env.items():
            value = os.environ.get(env_name)
            if value is None or not value.strip():
                raise MCPConfigurationError(
                    f"MCP server {self.server_id} requires environment variable {env_name}"
                )
            query.append((key, value.strip()))
        return urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode(query), parsed.fragment)
        )

    def resolved_headers(self) -> Dict[str, str]:
        result = dict(self.headers)
        for key, env_name in self.secret_header_env.items():
            value = os.environ.get(env_name)
            if value is None or not value.strip():
                raise MCPConfigurationError(
                    f"MCP server {self.server_id} requires environment variable {env_name}"
                )
            result[key] = value.strip()
        return result

    def public_target(self) -> Dict[str, Any]:
        parsed = urllib.parse.urlsplit(self.endpoint)
        return {
            "kind": "mcp",
            "server_id": self.server_id,
            "origin": f"{parsed.scheme}://{parsed.netloc}",
            "path": parsed.path,
            "protocol_mode": self.protocol_mode,
            "preferred_protocol_version": MCP_PROTOCOL_VERSION,
        }


@dataclass(frozen=True)
class MCPToolDefinition:
    name: str
    description: str
    input_schema: Dict[str, Any]
    title: Optional[str] = None
    output_schema: Optional[Any] = None
    annotations: Optional[Dict[str, Any]] = None
    meta: Optional[Dict[str, Any]] = None


@dataclass(frozen=True)
class MCPToolList:
    tools: List[MCPToolDefinition]
    ttl_ms: int = 0
    cache_scope: str = "private"


@dataclass(frozen=True)
class MCPFinalResult:
    content: List[Dict[str, Any]]
    structured_content: Any
    is_error: bool
    meta: Optional[Dict[str, Any]] = None

    @property
    def result_type(self) -> str:
        return "final"


@dataclass(frozen=True)
class MCPInputRequiredResult:
    input_requests: Dict[str, Any]
    request_state: Optional[str]

    @property
    def result_type(self) -> str:
        return "input_required"


@dataclass(frozen=True)
class MCPTaskResult:
    task_id: str
    status: str
    poll_interval_ms: Optional[int]
    ttl_ms: Optional[int]
    raw: Dict[str, Any]

    @property
    def result_type(self) -> str:
        return "task"


MCPCallResult = Union[MCPFinalResult, MCPInputRequiredResult, MCPTaskResult]


class MCPDriver:
    """Small client-managed MCP 2026-07-28 Streamable HTTP driver.

    The driver owns only MCP transport/protocol mechanics. It never decides
    business retry safety, authorization, task completion or Planner behavior.
    """

    def __init__(
        self,
        config: MCPServerConfig,
        *,
        client_name: str = "floweroll-host",
        client_version: str = "0.1",
    ) -> None:
        self.config = config
        self.client_name = client_name
        self.client_version = client_version
        if config.protocol_mode not in {"auto", "modern", "legacy"}:
            raise MCPConfigurationError("MCP protocol_mode must be auto, modern, or legacy")
        self._request_lock = threading.Lock()
        self._protocol_lock = threading.Lock()
        self._next_request_id = 1
        self._protocol_era: Optional[str] = None
        self._protocol_version: Optional[str] = None
        self._session_id: Optional[str] = None
        self._tool_cache: Optional[MCPToolList] = None
        self._tool_cache_expires_at = 0.0

    @property
    def protocol_era(self) -> Optional[str]:
        return self._protocol_era

    @property
    def protocol_version(self) -> Optional[str]:
        return self._protocol_version

    def list_tools(self, *, force_refresh: bool = False, max_pages: int = 20) -> MCPToolList:
        now = time.monotonic()
        if (
            not force_refresh
            and self._tool_cache is not None
            and now < self._tool_cache_expires_at
        ):
            return self._tool_cache

        cursor: Optional[str] = None
        tools: List[MCPToolDefinition] = []
        ttl_ms: Optional[int] = None
        cache_scope: Optional[str] = None
        pages = 0
        while True:
            pages += 1
            if pages > max_pages:
                raise MCPProtocolError(None, f"tools/list exceeded max_pages={max_pages}")
            params: Dict[str, Any] = {}
            if cursor is not None:
                params["cursor"] = cursor
            result = self._request("tools/list", params=params)
            raw_tools = result.get("tools")
            if not isinstance(raw_tools, list):
                raise MCPProtocolError(None, "tools/list result did not contain a tools array")
            tools.extend(self._parse_tool(item) for item in raw_tools)
            if ttl_ms is None:
                raw_ttl = result.get("ttlMs", 0)
                ttl_ms = int(raw_ttl) if isinstance(raw_ttl, (int, float)) else 0
            if cache_scope is None:
                raw_scope = result.get("cacheScope", "private")
                cache_scope = raw_scope if raw_scope in {"public", "private"} else "private"
            next_cursor = result.get("nextCursor")
            if next_cursor is None:
                break
            if not isinstance(next_cursor, str) or not next_cursor:
                raise MCPProtocolError(None, "tools/list nextCursor must be a non-empty string")
            cursor = next_cursor

        listing = MCPToolList(
            tools=tools,
            ttl_ms=max(0, ttl_ms or 0),
            cache_scope=cache_scope or "private",
        )
        self._tool_cache = listing
        self._tool_cache_expires_at = now + (listing.ttl_ms / 1000.0)
        return listing

    def call_tool(
        self,
        name: str,
        arguments: Mapping[str, Any],
        *,
        input_responses: Optional[Mapping[str, Any]] = None,
        request_state: Optional[str] = None,
    ) -> MCPCallResult:
        if not name.strip():
            raise ValueError("MCP tool name must not be empty")
        params: Dict[str, Any] = {
            "name": name,
            "arguments": dict(arguments),
        }
        if input_responses is not None:
            params["inputResponses"] = dict(input_responses)
        if request_state is not None:
            params["requestState"] = request_state
        result = self._request("tools/call", params=params, name=name)
        return self._parse_call_result(result)

    def get_task(self, task_id: str) -> MCPTaskResult:
        result = self._request("tasks/get", params={"taskId": task_id}, name=task_id)
        return self._parse_task_result(result)

    def cancel_task(self, task_id: str) -> Dict[str, Any]:
        return self._request("tasks/cancel", params={"taskId": task_id}, name=task_id)

    def update_task(self, task_id: str, input_responses: Mapping[str, Any]) -> Dict[str, Any]:
        return self._request(
            "tasks/update",
            params={"taskId": task_id, "inputResponses": dict(input_responses)},
            name=task_id,
        )

    def _request(
        self,
        method: str,
        *,
        params: Optional[Mapping[str, Any]] = None,
        name: Optional[str] = None,
    ) -> Dict[str, Any]:
        self._ensure_protocol()
        if self._protocol_era == "modern":
            return self._request_modern(method, params=params, name=name)
        if self._protocol_era == "legacy":
            return self._request_legacy(method, params=params)
        raise MCPProtocolError(None, "MCP protocol negotiation did not select an era")

    def _ensure_protocol(self) -> None:
        if self._protocol_era is not None:
            return
        with self._protocol_lock:
            if self._protocol_era is not None:
                return
            if self.config.protocol_mode == "modern":
                self._protocol_era = "modern"
                self._protocol_version = MCP_PROTOCOL_VERSION
                return
            if self.config.protocol_mode == "legacy":
                self._initialize_legacy()
                return

            try:
                self._request_modern("server/discover", params={})
            except MCPHTTPError as exc:
                if exc.status not in {400, 404, 405}:
                    raise
                self._initialize_legacy()
            except MCPProtocolError as exc:
                if exc.code not in {-32601, -32022}:
                    raise
                self._initialize_legacy()
            else:
                self._protocol_era = "modern"
                self._protocol_version = MCP_PROTOCOL_VERSION

    def _request_modern(
        self,
        method: str,
        *,
        params: Optional[Mapping[str, Any]] = None,
        name: Optional[str] = None,
    ) -> Dict[str, Any]:
        request_id = self._allocate_request_id()
        payload_params = dict(params or {})
        meta = dict(payload_params.get("_meta") or {})
        meta[_PROTOCOL_VERSION_KEY] = MCP_PROTOCOL_VERSION
        meta[_CLIENT_INFO_KEY] = {
            "name": self.client_name,
            "version": self.client_version,
        }
        capabilities: Dict[str, Any] = {}
        if self.config.enable_tasks_extension:
            capabilities["extensions"] = {_TASKS_EXTENSION: {}}
        meta[_CLIENT_CAPABILITIES_KEY] = capabilities
        payload_params["_meta"] = meta
        envelope = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": payload_params,
        }
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": MCP_PROTOCOL_VERSION,
            "Mcp-Method": method,
            **self.config.resolved_headers(),
        }
        if name is not None:
            headers["Mcp-Name"] = name
        parsed, _ = self._post_envelope(envelope, headers=headers, request_id=request_id)
        return self._result_from_response(parsed, request_id)

    def _initialize_legacy(self) -> None:
        request_id = self._allocate_request_id()
        envelope = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "initialize",
            "params": {
                "protocolVersion": MCP_LEGACY_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": self.client_name, "version": self.client_version},
            },
        }
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            **self.config.resolved_headers(),
        }
        parsed, session_id = self._post_envelope(envelope, headers=headers, request_id=request_id)
        result = self._result_from_response(parsed, request_id)
        version = result.get("protocolVersion")
        if not isinstance(version, str) or not version:
            raise MCPProtocolError(None, "legacy initialize result missing protocolVersion")
        if version not in {"2025-11-25", "2025-06-18", "2025-03-26"}:
            raise MCPProtocolError(None, f"unsupported legacy MCP version {version}")
        self._protocol_era = "legacy"
        self._protocol_version = version
        self._session_id = session_id
        self._send_legacy_initialized()

    def _send_legacy_initialized(self) -> None:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self._protocol_version or MCP_LEGACY_PROTOCOL_VERSION,
            **self.config.resolved_headers(),
        }
        if self._session_id:
            headers["Mcp-Session-Id"] = self._session_id
        envelope = {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {},
        }
        self._post_notification(envelope, headers=headers)

    def _request_legacy(
        self,
        method: str,
        *,
        params: Optional[Mapping[str, Any]] = None,
        _retried_session: bool = False,
    ) -> Dict[str, Any]:
        request_id = self._allocate_request_id()
        envelope = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": dict(params or {}),
        }
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self._protocol_version or MCP_LEGACY_PROTOCOL_VERSION,
            **self.config.resolved_headers(),
        }
        if self._session_id:
            headers["Mcp-Session-Id"] = self._session_id
        try:
            parsed, _ = self._post_envelope(envelope, headers=headers, request_id=request_id)
        except MCPHTTPError as exc:
            if exc.status == 404 and self._session_id and not _retried_session:
                self._protocol_era = None
                self._protocol_version = None
                self._session_id = None
                self._initialize_legacy()
                return self._request_legacy(method, params=params, _retried_session=True)
            raise
        return self._result_from_response(parsed, request_id)

    def _post_envelope(
        self,
        envelope: Mapping[str, Any],
        *,
        headers: Mapping[str, str],
        request_id: int,
    ) -> tuple[Dict[str, Any], Optional[str]]:
        request = urllib.request.Request(
            self.config.resolved_endpoint(),
            data=json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            method="POST",
            headers=dict(headers),
        )
        try:
            with urllib.request.urlopen(request, timeout=self.config.timeout_seconds) as response:
                session_id = response.headers.get("Mcp-Session-Id")
                parsed = self._read_response(response, request_id=request_id)
                return parsed, session_id
        except urllib.error.HTTPError as exc:
            body = exc.read(4096).decode("utf-8", errors="replace")
            safe_body = self._redact_configured_secrets(body.strip())
            raise MCPHTTPError(exc.code, safe_body or str(exc.reason)) from exc
        except urllib.error.URLError as exc:
            raise MCPHTTPError(0, f"network error: {exc.reason}") from exc
        except TimeoutError as exc:
            raise MCPHTTPError(0, "request timed out") from exc

    def _post_notification(
        self,
        envelope: Mapping[str, Any],
        *,
        headers: Mapping[str, str],
    ) -> None:
        request = urllib.request.Request(
            self.config.resolved_endpoint(),
            data=json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            method="POST",
            headers=dict(headers),
        )
        try:
            with urllib.request.urlopen(request, timeout=self.config.timeout_seconds) as response:
                response.read(4096)
        except urllib.error.HTTPError as exc:
            body = exc.read(4096).decode("utf-8", errors="replace")
            safe_body = self._redact_configured_secrets(body.strip())
            raise MCPHTTPError(exc.code, safe_body or str(exc.reason)) from exc
        except urllib.error.URLError as exc:
            raise MCPHTTPError(0, f"network error: {exc.reason}") from exc
        except TimeoutError as exc:
            raise MCPHTTPError(0, "request timed out") from exc

    @staticmethod
    def _result_from_response(parsed: Dict[str, Any], request_id: int) -> Dict[str, Any]:
        if parsed.get("jsonrpc") != "2.0" or parsed.get("id") != request_id:
            raise MCPProtocolError(None, "response did not match the JSON-RPC request")
        if "error" in parsed:
            error = parsed["error"]
            if not isinstance(error, dict):
                raise MCPProtocolError(None, "malformed JSON-RPC error")
            raise MCPProtocolError(
                error.get("code"),
                str(error.get("message") or "unknown error"),
                error.get("data"),
            )
        result = parsed.get("result")
        if not isinstance(result, dict):
            raise MCPProtocolError(None, "JSON-RPC result must be an object")
        return result

    def _read_response(self, response: Any, *, request_id: int) -> Dict[str, Any]:
        content_type = str(response.headers.get("Content-Type", "")).lower()
        if "text/event-stream" not in content_type:
            try:
                parsed = json.loads(response.read().decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise MCPProtocolError(None, "response was not valid JSON") from exc
            if not isinstance(parsed, dict):
                raise MCPProtocolError(None, "JSON-RPC response must be an object")
            return parsed

        data_lines: List[str] = []
        while True:
            raw = response.readline()
            if not raw:
                if data_lines:
                    candidate = self._decode_sse_data(data_lines)
                    if candidate.get("id") == request_id:
                        return candidate
                raise MCPProtocolError(None, "SSE stream ended before the matching JSON-RPC result")
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            if line == "":
                if data_lines:
                    candidate = self._decode_sse_data(data_lines)
                    data_lines = []
                    if candidate.get("id") == request_id:
                        return candidate
                continue
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip())

    @staticmethod
    def _decode_sse_data(lines: Iterable[str]) -> Dict[str, Any]:
        try:
            parsed = json.loads("\n".join(lines))
        except json.JSONDecodeError as exc:
            raise MCPProtocolError(None, "SSE data was not valid JSON") from exc
        if not isinstance(parsed, dict):
            raise MCPProtocolError(None, "SSE JSON-RPC event must be an object")
        return parsed

    def _redact_configured_secrets(self, text: str) -> str:
        safe = text
        env_names = list(self.config.secret_query_env.values()) + list(self.config.secret_header_env.values())
        for env_name in env_names:
            value = os.environ.get(env_name)
            if value:
                safe = safe.replace(value, "[REDACTED]")
        return safe

    def _allocate_request_id(self) -> int:
        with self._request_lock:
            value = self._next_request_id
            self._next_request_id += 1
            return value

    @staticmethod
    def _parse_tool(item: Any) -> MCPToolDefinition:
        if not isinstance(item, dict):
            raise MCPProtocolError(None, "tool descriptor must be an object")
        name = item.get("name")
        input_schema = item.get("inputSchema")
        if not isinstance(name, str) or not name:
            raise MCPProtocolError(None, "tool descriptor is missing name")
        if not isinstance(input_schema, dict) or input_schema.get("type") != "object":
            raise MCPProtocolError(None, f"tool {name} inputSchema must be an object schema")
        description = item.get("description")
        return MCPToolDefinition(
            name=name,
            title=item.get("title") if isinstance(item.get("title"), str) else None,
            description=description if isinstance(description, str) else "",
            input_schema=input_schema,
            output_schema=item.get("outputSchema"),
            annotations=item.get("annotations") if isinstance(item.get("annotations"), dict) else None,
            meta=item.get("_meta") if isinstance(item.get("_meta"), dict) else None,
        )

    @staticmethod
    def _parse_call_result(result: Dict[str, Any]) -> MCPCallResult:
        result_type = result.get("resultType")
        if result_type == "input_required":
            input_requests = result.get("inputRequests")
            if not isinstance(input_requests, dict) or not input_requests:
                raise MCPProtocolError(None, "input_required result must contain inputRequests")
            request_state = result.get("requestState")
            if request_state is not None and not isinstance(request_state, str):
                raise MCPProtocolError(None, "requestState must be a string")
            return MCPInputRequiredResult(dict(input_requests), request_state)
        if result_type == "task":
            return MCPDriver._parse_task_result(result)
        content = result.get("content", [])
        if not isinstance(content, list):
            raise MCPProtocolError(None, "tool result content must be an array")
        normalized_content = [item for item in content if isinstance(item, dict)]
        return MCPFinalResult(
            content=normalized_content,
            structured_content=result.get("structuredContent"),
            is_error=bool(result.get("isError", False)),
            meta=result.get("_meta") if isinstance(result.get("_meta"), dict) else None,
        )

    @staticmethod
    def _parse_task_result(result: Dict[str, Any]) -> MCPTaskResult:
        task_id = result.get("taskId")
        status = result.get("status")
        if not isinstance(task_id, str) or not task_id:
            raise MCPProtocolError(None, "task result missing taskId")
        if not isinstance(status, str) or not status:
            raise MCPProtocolError(None, "task result missing status")
        poll = result.get("pollIntervalMs")
        ttl = result.get("ttlMs")
        return MCPTaskResult(
            task_id=task_id,
            status=status,
            poll_interval_ms=int(poll) if isinstance(poll, (int, float)) else None,
            ttl_ms=int(ttl) if isinstance(ttl, (int, float)) else None,
            raw=dict(result),
        )
