from __future__ import annotations

import hashlib
import json
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Mapping, Optional

from .capability_registry import CapabilityRegistry
from .execution_runtime import ExecutionRuntime
from .mcp_driver import (
    MCPDriver,
    MCPFinalResult,
    MCPHTTPError,
    MCPInputRequiredResult,
    MCPProtocolError,
    MCPTaskResult,
)
from .presentation import canonical_json


def normalize_mcp_final_result(
    result: MCPFinalResult,
    *,
    server_id: str,
    tool_name: str,
) -> tuple[Dict[str, Any], Optional[str]]:
    """Normalize one synchronous MCP read result for Runtime verification.

    This is shared by the ordinary MCP worker and the bounded work-unit batch
    runner so both paths apply the same storage/context size limits.  It does
    not handle MCP tasks or input requests; callers that cannot durably own
    those continuations must fail closed instead of pretending they completed.
    """
    structured_source = result.structured_content
    if structured_source is None:
        structured_source = MCPExecutionWorker._structured_json_from_content(result.content)
    content, content_truncated = MCPExecutionWorker._bounded_content(result.content)
    structured_content, structured_truncated = MCPExecutionWorker._bounded_value(structured_source)
    output = {
        "content": content,
        "structured_content": structured_content,
        "mcp_server_id": server_id,
        "mcp_tool_name": tool_name,
        "truncated": content_truncated or structured_truncated,
    }
    if result.is_error:
        output["mcp_error_kind"] = "tool"
    error = MCPExecutionWorker._tool_error_text(result) if result.is_error else None
    return output, error


class MCPExecutionWorker:
    """Drive MCP-backed Actions through the existing ExecutionRuntime.

    It does not plan or own Task state. It translates MCP protocol outcomes
    into the durable Attempt/Input/SourceOperation contracts already owned by
    ExecutionRuntime/Storage.
    """

    def __init__(
        self,
        execution: ExecutionRuntime,
        registry: CapabilityRegistry,
        drivers: Mapping[str, MCPDriver],
        *,
        max_workers: int = 4,
    ) -> None:
        if max_workers < 1:
            raise ValueError("max_workers must be positive")
        self.execution = execution
        self.registry = registry
        self.drivers = dict(drivers)
        self.max_workers = max_workers

    def sweep_once(self) -> List[Dict[str, Any]]:
        capability_ids = [entry.spec.name for entry in self.registry.source_entries("mcp")]
        task_ids = self.execution.storage.open_action_task_ids(capability_ids)
        if not task_ids:
            return []
        results: List[Dict[str, Any]] = []
        with ThreadPoolExecutor(
            max_workers=min(self.max_workers, len(task_ids)),
            thread_name_prefix="floweroll-mcp",
        ) as pool:
            futures = {pool.submit(self.run_once, task_id): task_id for task_id in task_ids}
            for future in as_completed(futures):
                value = future.result()
                if value is not None:
                    results.append(value)
        return results

    def run_once(self, task_id: str) -> Optional[Dict[str, Any]]:
        action = self.execution.storage.get_open_action(task_id)
        if action is None:
            return None
        try:
            entry = self.registry.get(action["action_type"])
        except KeyError:
            return None
        if entry.source.kind != "mcp" or entry.source.server_id is None or entry.source.tool_name is None:
            return None
        driver = self._driver(entry.source.server_id)
        attempt = self.execution.storage.current_action_attempt(action["action_id"])

        # Durable provider task: poll only after Runtime/Recovery has moved the
        # Task back to ACTIVE and cleared the wait boundary.
        if attempt is not None and attempt.get("source_operation_ref") is not None:
            task = self.execution.storage.get_task(task_id)
            runtime = self.execution.storage.get_runtime_state(task_id)
            if task is None or runtime is None:
                raise KeyError(task_id)
            if str(task["status"]).lower() != "active" or runtime.get("wait_id") is not None:
                return None
            return self._poll_task(action, attempt, driver)

        # MRTR input was answered: continue the exact same Attempt/source round.
        if attempt is not None and attempt.get("approved_input_request_id") is not None:
            if str(attempt["status"]).upper() == "IN_FLIGHT":
                return self._resume_input(action, attempt, driver)

        dispatch = self.execution.next_action(task_id, source_kind="mcp")
        if dispatch is None:
            return None
        return self._invoke(dispatch, entry.source.server_id, entry.source.tool_name, driver)

    def cancel_source_operation_if_requested(self, task_id: str) -> Optional[Dict[str, Any]]:
        interrupt = self.execution.current_interrupt_request(task_id)
        if interrupt is None or interrupt.get("attempt_id") is None:
            return None
        attempt = self.execution.storage.get_action_attempt(str(interrupt["attempt_id"]))
        if attempt is None or attempt.get("source_operation_ref") is None:
            return None
        action = self.execution.storage.get_action(str(interrupt["action_id"]))
        if action is None:
            return None
        entry = self.registry.get(action["action_type"])
        if entry.source.kind != "mcp" or entry.source.server_id is None:
            return None
        result = self._driver(entry.source.server_id).cancel_task(str(attempt["source_operation_ref"]))
        return {
            "task_id": task_id,
            "action_id": action["action_id"],
            "attempt_id": attempt["attempt_id"],
            "source_operation_ref": attempt["source_operation_ref"],
            "cancel_ack": result,
        }

    def _invoke(
        self,
        dispatch: Dict[str, Any],
        server_id: str,
        tool_name: str,
        driver: MCPDriver,
    ) -> Dict[str, Any]:
        try:
            result = driver.call_tool(tool_name, dispatch["payload"])
        except MCPHTTPError as exc:
            transient = exc.status == 0 or exc.status == 429 or 500 <= exc.status <= 599
            return self.execution.accept_result(
                task_id=dispatch["task_id"],
                action_id=dispatch["action_id"],
                attempt_id=dispatch["attempt_id"],
                success=False,
                output={"mcp_error_kind": "transient_transport" if transient else "protocol"},
                error=str(exc),
            )
        except MCPProtocolError as exc:
            return self.execution.accept_result(
                task_id=dispatch["task_id"],
                action_id=dispatch["action_id"],
                attempt_id=dispatch["attempt_id"],
                success=False,
                output={"mcp_error_kind": "protocol", "code": exc.code},
                error=str(exc),
            )
        return self._handle_call_result(dispatch, server_id, tool_name, result)

    def _handle_call_result(
        self,
        dispatch: Dict[str, Any],
        server_id: str,
        tool_name: str,
        result: Any,
    ) -> Dict[str, Any]:
        if isinstance(result, MCPFinalResult):
            output, error = normalize_mcp_final_result(
                result,
                server_id=server_id,
                tool_name=tool_name,
            )
            return self.execution.accept_result(
                task_id=dispatch["task_id"],
                action_id=dispatch["action_id"],
                attempt_id=dispatch["attempt_id"],
                success=not result.is_error,
                output=output,
                error=error,
            )
        if isinstance(result, MCPInputRequiredResult):
            return self._request_input(dispatch, server_id, tool_name, result)
        if isinstance(result, MCPTaskResult):
            poll_after = self._poll_after(result.poll_interval_ms)
            ttl_at = self._ttl_at(result.ttl_ms)
            return self.execution.defer_to_source_operation(
                task_id=dispatch["task_id"],
                action_id=dispatch["action_id"],
                attempt_id=dispatch["attempt_id"],
                source_operation_ref=result.task_id,
                source_status=result.status,
                poll_after=poll_after,
                ttl_at=ttl_at,
            )
        raise TypeError(f"unsupported MCP result: {type(result).__name__}")

    def _poll_task(self, action: Dict[str, Any], attempt: Dict[str, Any], driver: MCPDriver) -> Dict[str, Any]:
        source_task = driver.get_task(str(attempt["source_operation_ref"]))
        if source_task.status == "working":
            return self.execution.defer_to_source_operation(
                task_id=action["task_id"],
                action_id=action["action_id"],
                attempt_id=attempt["attempt_id"],
                source_operation_ref=source_task.task_id,
                source_status=source_task.status,
                poll_after=self._poll_after(source_task.poll_interval_ms),
                ttl_at=self._ttl_at(source_task.ttl_ms),
            )
        if source_task.status == "input_required":
            input_requests = source_task.raw.get("inputRequests")
            if not isinstance(input_requests, dict) or not input_requests:
                raise MCPProtocolError(None, "MCP task input_required missing inputRequests")
            result = MCPInputRequiredResult(input_requests=input_requests, request_state=None)
            dispatch = {**action, "attempt_id": attempt["attempt_id"]}
            return self._request_input(
                dispatch,
                self.registry.get(action["action_type"]).source.server_id or "",
                self.registry.get(action["action_type"]).source.tool_name or "",
                result,
                source_task_id=source_task.task_id,
            )
        if source_task.status == "completed":
            raw_result = source_task.raw.get("result")
            if not isinstance(raw_result, dict):
                raise MCPProtocolError(None, "completed MCP task missing result")
            result = MCPDriver._parse_call_result(raw_result)
            dispatch = {**action, "attempt_id": attempt["attempt_id"]}
            entry = self.registry.get(action["action_type"])
            return self._handle_call_result(
                dispatch,
                entry.source.server_id or "",
                entry.source.tool_name or "",
                result,
            )
        if source_task.status == "cancelled":
            return self.execution.accept_result(
                task_id=action["task_id"],
                action_id=action["action_id"],
                attempt_id=attempt["attempt_id"],
                success=False,
                output={"mcp_source_status": "cancelled"},
                error="MCP provider task was cancelled",
            )
        if source_task.status == "failed":
            return self.execution.accept_result(
                task_id=action["task_id"],
                action_id=action["action_id"],
                attempt_id=attempt["attempt_id"],
                success=False,
                output={"mcp_error_kind": "protocol", "source_error": source_task.raw.get("error")},
                error="MCP provider task failed",
            )
        raise MCPProtocolError(None, f"unsupported MCP task status {source_task.status}")

    def _request_input(
        self,
        dispatch: Dict[str, Any],
        server_id: str,
        tool_name: str,
        result: MCPInputRequiredResult,
        *,
        source_task_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        if len(result.input_requests) != 1:
            raise MCPProtocolError(None, "V1 MCP human input bridge currently requires one input request per round")
        request_key, request_spec = next(iter(result.input_requests.items()))
        prompt, accepts_text, options = self._interaction_shape(request_spec)
        continuation = {
            "mode": "task" if source_task_id else "call",
            "server_id": server_id,
            "tool_name": tool_name,
            "request_key": request_key,
            "request_state": result.request_state,
            "input_request": request_spec,
            "source_task_id": source_task_id,
        }
        binding = {
            "action_id": dispatch["action_id"],
            "capability_id": dispatch["action_type"],
            "artifact_revisions": [],
            "mcp": {
                "server_id": server_id,
                "tool_name": tool_name,
                "request_key": request_key,
                "request_state_digest": self._digest_optional(result.request_state),
                "source_task_id": source_task_id,
            },
        }
        return self.execution.storage.create_action_input_request(
            input_request_id=str(uuid.uuid4()),
            task_id=dispatch["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            prompt=prompt,
            suggested_options=options,
            accepts_text=accepts_text,
            reason="mcp_input_required",
            binding=binding,
            source_continuation_ref=canonical_json(continuation),
        )

    def _resume_input(self, action: Dict[str, Any], attempt: Dict[str, Any], driver: MCPDriver) -> Dict[str, Any]:
        continuation = self.execution.action_input_continuation(attempt_id=attempt["attempt_id"])
        source_ref = continuation.get("source_continuation_ref")
        if not isinstance(source_ref, str):
            raise MCPProtocolError(None, "MCP ActionInput continuation is missing source state")
        try:
            state = json.loads(source_ref)
        except json.JSONDecodeError as exc:
            raise MCPProtocolError(None, "MCP ActionInput continuation state is invalid") from exc
        response = continuation["response"]
        input_responses = self._input_responses(state, response)
        if state.get("mode") == "task":
            task_id = state.get("source_task_id")
            if not isinstance(task_id, str) or not task_id:
                raise MCPProtocolError(None, "MCP task continuation missing task id")
            driver.update_task(task_id, input_responses)
            return self.execution.defer_to_source_operation(
                task_id=action["task_id"],
                action_id=action["action_id"],
                attempt_id=attempt["attempt_id"],
                source_operation_ref=task_id,
                source_status="working",
                poll_after=self._poll_after(250),
            )
        result = driver.call_tool(
            str(state["tool_name"]),
            action["payload"],
            input_responses=input_responses,
            request_state=state.get("request_state"),
        )
        entry = self.registry.get(action["action_type"])
        dispatch = {**action, "attempt_id": attempt["attempt_id"]}
        return self._handle_call_result(
            dispatch,
            entry.source.server_id or "",
            entry.source.tool_name or "",
            result,
        )

    @staticmethod
    def _interaction_shape(spec: Any) -> tuple[str, bool, list[Dict[str, Any]]]:
        if not isinstance(spec, dict):
            return "这个工具需要你补充信息。", True, []
        params = spec.get("params") if isinstance(spec.get("params"), dict) else spec
        message = params.get("message") if isinstance(params, dict) else None
        prompt = message if isinstance(message, str) and message.strip() else "这个工具需要你补充信息。"
        schema = None
        if isinstance(params, dict):
            schema = params.get("requestedSchema") or params.get("schema")
        if isinstance(schema, dict):
            props = schema.get("properties")
            if isinstance(props, dict) and len(props) == 1:
                _, definition = next(iter(props.items()))
                if isinstance(definition, dict) and definition.get("type") == "boolean":
                    return prompt, False, [
                        {"id": "approve", "label": "确认"},
                        {"id": "reject", "label": "取消"},
                    ]
        return prompt, True, []

    @staticmethod
    def _input_responses(state: Dict[str, Any], response: Dict[str, Any]) -> Dict[str, Any]:
        key = state.get("request_key")
        if not isinstance(key, str) or not key:
            raise MCPProtocolError(None, "MCP continuation missing request key")
        spec = state.get("input_request")
        params = spec.get("params") if isinstance(spec, dict) and isinstance(spec.get("params"), dict) else spec
        schema = None
        if isinstance(params, dict):
            schema = params.get("requestedSchema") or params.get("schema")
        content: Dict[str, Any] = {}
        property_name: Optional[str] = None
        if isinstance(schema, dict) and isinstance(schema.get("properties"), dict) and len(schema["properties"]) == 1:
            property_name = next(iter(schema["properties"]))
        if isinstance(response.get("approved"), bool):
            if response["approved"] is False:
                return {key: {"action": "decline"}}
            if property_name is not None:
                content[property_name] = True
        elif isinstance(response.get("text"), str):
            if property_name is not None:
                content[property_name] = response["text"]
            else:
                content["text"] = response["text"]
        elif isinstance(response.get("option_id"), str):
            if property_name is not None:
                content[property_name] = response["option_id"]
            else:
                content["option_id"] = response["option_id"]
        else:
            content = dict(response)
        return {key: {"action": "accept", "content": content}}

    @staticmethod
    def _structured_json_from_content(content: List[Dict[str, Any]]) -> Any:
        """Normalize providers that return JSON only as one MCP text content item."""

        if len(content) != 1:
            return None
        item = content[0]
        if not isinstance(item, dict) or item.get("type") != "text":
            return None
        text = item.get("text")
        if not isinstance(text, str):
            return None
        candidate = text.strip()
        if not candidate or candidate[0] not in "[{":
            return None
        try:
            parsed = json.loads(candidate)
        except (TypeError, ValueError, json.JSONDecodeError):
            return None
        return parsed if isinstance(parsed, (dict, list)) else None

    @staticmethod
    def _bounded_content(content: List[Dict[str, Any]]) -> tuple[List[Dict[str, Any]], bool]:
        max_items = 50
        max_text_chars = 40_000
        remaining = max_text_chars
        bounded: List[Dict[str, Any]] = []
        truncated = len(content) > max_items
        for item in content[:max_items]:
            value = dict(item)
            text = value.get("text")
            if isinstance(text, str):
                if remaining <= 0:
                    truncated = True
                    value["text"] = ""
                elif len(text) > remaining:
                    value["text"] = text[:remaining]
                    remaining = 0
                    truncated = True
                else:
                    remaining -= len(text)
            # Binary/image/resource payloads should not become arbitrary large
            # Runtime/Planner observations. Keep descriptive metadata only.
            for key in ("data", "blob", "bytes"):
                if key in value:
                    value.pop(key, None)
                    truncated = True
            bounded.append(value)
        return bounded, truncated

    @classmethod
    def _bounded_value(
        cls,
        value: Any,
        *,
        depth: int = 0,
    ) -> tuple[Any, bool]:
        if value is None or isinstance(value, (bool, int, float)):
            return value, False
        if isinstance(value, str):
            if len(value) <= 12_000:
                return value, False
            return value[:12_000], True
        if depth >= 5:
            return "[bounded]", True
        if isinstance(value, list):
            truncated = len(value) > 50
            result = []
            for item in value[:50]:
                bounded, item_truncated = cls._bounded_value(item, depth=depth + 1)
                truncated = truncated or item_truncated
                result.append(bounded)
            return result, truncated
        if isinstance(value, dict):
            items = list(value.items())
            truncated = len(items) > 50
            result: Dict[str, Any] = {}
            for key, item in items[:50]:
                bounded, item_truncated = cls._bounded_value(item, depth=depth + 1)
                truncated = truncated or item_truncated
                result[str(key)[:200]] = bounded
            return result, truncated
        text = str(value)
        return (text[:4_000], len(text) > 4_000)

    @staticmethod
    def _tool_error_text(result: MCPFinalResult) -> str:
        texts = [
            str(item.get("text"))
            for item in result.content
            if item.get("type") == "text" and isinstance(item.get("text"), str)
        ]
        return "\n".join(texts)[:1000] or "MCP tool returned isError=true"

    @staticmethod
    def _poll_after(poll_interval_ms: Optional[int]) -> str:
        delay_ms = max(100, int(poll_interval_ms or 1000))
        return (datetime.now(timezone.utc) + timedelta(milliseconds=delay_ms)).isoformat()

    @staticmethod
    def _ttl_at(ttl_ms: Optional[int]) -> Optional[str]:
        if ttl_ms is None:
            return None
        return (datetime.now(timezone.utc) + timedelta(milliseconds=max(0, ttl_ms))).isoformat()

    @staticmethod
    def _digest_optional(value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        return hashlib.sha256(value.encode("utf-8")).hexdigest()

    def _driver(self, server_id: str) -> MCPDriver:
        try:
            return self.drivers[server_id]
        except KeyError as exc:
            raise KeyError(f"no MCPDriver configured for server {server_id}") from exc
