from __future__ import annotations

import json
import socket
import ssl
import http.client
import re
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional

from .planner_contracts import CapabilitySpec, PlannerDecision
from . import planner_capture


class OpenAICompatibleChatPlannerError(RuntimeError):
    pass


class OpenAICompatibleChatPlannerTransientError(OpenAICompatibleChatPlannerError):
    """Retryable provider/network failure after the adapter's bounded retry."""


class OpenAICompatibleChatPlannerAdapter:
    """Planner adapter for OpenAI-compatible `/chat/completions` providers.

    The durable Runtime and Planner contracts stay provider-independent. This
    adapter only translates the existing Responses-shaped Planner request into
    Chat Completions messages plus the same strict JSON Schema.
    """

    def __init__(
        self,
        *,
        api_key: str,
        base_url: str,
        model: str,
        timeout_seconds: float = 90.0,
        max_completion_tokens_override: Optional[int] = None,
        reasoning_effort_override: Optional[str] = None,
        transient_http_retries: int = 1,
    ) -> None:
        if not api_key.strip():
            raise ValueError("api_key must not be empty")
        if not base_url.strip():
            raise ValueError("base_url must not be empty")
        if not model.strip():
            raise ValueError("model must not be empty")
        self._api_key = api_key.strip()
        self.base_url = base_url.rstrip("/")
        self.model = model.strip()
        self.timeout_seconds = float(timeout_seconds)
        if max_completion_tokens_override is not None and max_completion_tokens_override < 1:
            raise ValueError("max_completion_tokens_override must be positive")
        if transient_http_retries < 0 or transient_http_retries > 2:
            raise ValueError("transient_http_retries must be between 0 and 2")
        self.max_completion_tokens_override = max_completion_tokens_override
        if reasoning_effort_override is not None:
            normalized_effort = reasoning_effort_override.strip().lower()
            if normalized_effort not in {"low", "high", "max"}:
                raise ValueError("reasoning_effort_override must be low, high, max, or None")
            self.reasoning_effort_override = normalized_effort
        else:
            self.reasoning_effort_override = None
        self.transient_http_retries = int(transient_http_retries)
        self._metrics_local = threading.local()

    def decide(
        self,
        request_body: Dict[str, Any],
        capabilities: List[CapabilitySpec],
        timeout_seconds: Optional[float] = None,
    ) -> PlannerDecision:
        return self._decide_impl(request_body, capabilities, timeout_seconds,
                                 transient_http_retries=self.transient_http_retries)

    def decide_once(
        self,
        request_body: Dict[str, Any],
        capabilities: List[CapabilitySpec],
        timeout_seconds: Optional[float] = None,
    ) -> PlannerDecision:
        """One HTTP attempt; the Planner graph/Runtime boundary owns retries."""
        return self._decide_impl(request_body, capabilities, timeout_seconds,
                                 transient_http_retries=0)

    def _decide_impl(
        self,
        request_body: Dict[str, Any],
        capabilities: List[CapabilitySpec],
        timeout_seconds: Optional[float],
        *,
        transient_http_retries: int,
    ) -> PlannerDecision:
        call_started = time.perf_counter()
        self._metrics_local.last = {"provider_model": self.model, "provider_attempts": 0,
                                    "provider_total_ms": 0.0}
        payload = self._chat_payload(request_body)
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        planner_capture.request_ready(payload, raw, adapter='chat_completions', secret_values=(self._api_key,))
        request = urllib.request.Request(
            self._chat_completions_url(),
            data=raw,
            method="POST",
            headers={
                "Authorization": "Bearer " + self._api_key,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        response_payload = None
        effective_timeout = self.timeout_seconds if timeout_seconds is None else timeout_seconds
        for attempt in range(transient_http_retries + 1):
            try:
                with planner_capture.http_attempt(attempt + 1), urllib.request.urlopen(request, timeout=effective_timeout) as response:
                    response_payload = json.loads(response.read().decode("utf-8"))
                break
            except urllib.error.HTTPError as exc:
                body = _redact_sensitive(exc.read(4096).decode("utf-8", errors="replace").replace(self._api_key, "[redacted-key]")[:2000])
                retryable = exc.code == 429 or 500 <= exc.code <= 504
                if retryable and attempt < transient_http_retries:
                    time.sleep(_transient_retry_delay(exc))
                    continue
                error_type = (
                    OpenAICompatibleChatPlannerTransientError
                    if retryable
                    else OpenAICompatibleChatPlannerError
                )
                raise error_type(
                    "Chat Completions HTTP {}: {}".format(exc.code, body)
                ) from exc
            except urllib.error.URLError as exc:
                retryable_network = not isinstance(exc.reason, ssl.SSLError) and isinstance(
                    exc.reason, (TimeoutError, socket.timeout, ConnectionError, http.client.RemoteDisconnected)
                )
                if retryable_network and attempt < transient_http_retries:
                    time.sleep(0.25)
                    continue
                error_type = (
                    OpenAICompatibleChatPlannerTransientError
                    if retryable_network
                    else OpenAICompatibleChatPlannerError
                )
                raise error_type(
                    "Chat Completions network error: {}".format(
                        _redact_sensitive(str(exc.reason).replace(self._api_key, "[redacted-key]"))
                    )
                ) from exc
            except (TimeoutError, socket.timeout, ConnectionError, http.client.RemoteDisconnected) as exc:
                # This retries only the side-effect-free model request. No
                # Action/Attempt is created until a complete decision is validated.
                if attempt < transient_http_retries:
                    time.sleep(0.25)
                    continue
                raise OpenAICompatibleChatPlannerTransientError(
                    "Chat Completions transport timed out or disconnected after bounded retry"
                ) from exc
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise OpenAICompatibleChatPlannerError(
                    "Chat Completions returned an invalid JSON envelope"
                ) from exc
            finally:
                self._metrics_local.last.update(
                    provider_attempts=attempt + 1,
                    provider_total_ms=round((time.perf_counter() - call_started) * 1000.0, 3),
                )
        assert response_payload is not None

        finish_reason = _finish_reason(response_payload)
        planner_capture.response_received(None, response_payload.get('usage'), finish_reason)
        try:
            content = _assistant_text(response_payload)
        except OpenAICompatibleChatPlannerError as exc:
            if finish_reason not in {None, "stop"}:
                raise OpenAICompatibleChatPlannerError(
                    "structured Planner output was incomplete; finish_reason={}".format(
                        finish_reason
                    )
                ) from exc
            raise
        planner_capture.response_received(content, response_payload.get('usage'), finish_reason)
        try:
            decision_data = json.loads(content)
        except json.JSONDecodeError as exc:
            if finish_reason not in {None, "stop"}:
                raise OpenAICompatibleChatPlannerError(
                    "structured Planner output was incomplete; finish_reason={}".format(
                        finish_reason
                    )
                ) from exc
            raise OpenAICompatibleChatPlannerError(
                "structured Planner output was not valid JSON"
            ) from exc
        if not isinstance(decision_data, dict):
            raise OpenAICompatibleChatPlannerError(
                "structured Planner output root must be an object"
            )
        decision = PlannerDecision.from_dict(decision_data, capabilities)
        usage = response_payload.get("usage") if isinstance(response_payload, dict) else None
        metrics: Dict[str, Any] = {
            "provider_model": self.model,
            "provider_attempts": attempt + 1,
            "provider_total_ms": round((time.perf_counter() - call_started) * 1000.0, 3),
        }
        if isinstance(usage, dict):
            for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
                value = usage.get(key)
                if isinstance(value, int) and value >= 0:
                    metrics[key] = value
        self._metrics_local.last = metrics
        return decision

    def consume_last_call_metrics(self) -> Dict[str, Any]:
        value = getattr(self._metrics_local, "last", None)
        if hasattr(self._metrics_local, "last"):
            del self._metrics_local.last
        return dict(value) if isinstance(value, dict) else {}

    def _chat_payload(self, request_body: Dict[str, Any]) -> Dict[str, Any]:
        messages = []
        for item in request_body.get("input", []):
            if not isinstance(item, dict):
                continue
            role = item.get("role")
            content = item.get("content")
            if role in {"system", "user", "assistant"} and isinstance(content, str):
                messages.append({"role": role, "content": content})
        if not messages:
            raise ValueError("Planner request does not contain chat-compatible messages")

        text_format = request_body.get("text", {}).get("format", {})
        if text_format.get("type") != "json_schema":
            raise ValueError("Planner request must carry a json_schema text format")
        schema = text_format.get("schema")
        name = text_format.get("name")
        if not isinstance(schema, dict) or not isinstance(name, str) or not name:
            raise ValueError("Planner request contains an invalid json_schema format")

        payload: Dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": name,
                    "strict": bool(text_format.get("strict", True)),
                    "schema": schema,
                },
            },
        }
        max_output_tokens = request_body.get("max_output_tokens")
        if self.max_completion_tokens_override is not None:
            payload["max_completion_tokens"] = self.max_completion_tokens_override
        elif isinstance(max_output_tokens, int) and max_output_tokens > 0:
            payload["max_completion_tokens"] = max_output_tokens
        if self.reasoning_effort_override is not None:
            payload["reasoning_effort"] = self.reasoning_effort_override
        return payload

    def _chat_completions_url(self) -> str:
        if self.base_url.endswith("/v1"):
            return self.base_url + "/chat/completions"
        return self.base_url + "/v1/chat/completions"


def _transient_retry_delay(exc: urllib.error.HTTPError) -> float:
    retry_after = None
    try:
        retry_after = exc.headers.get("Retry-After") if exc.headers is not None else None
    except Exception:
        retry_after = None
    if retry_after is not None:
        try:
            return max(0.0, min(2.0, float(retry_after)))
        except (TypeError, ValueError):
            pass
    return 0.25



def _finish_reason(payload: Any) -> Optional[str]:
    if not isinstance(payload, dict):
        return None
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return None
    value = choices[0].get("finish_reason")
    return value if isinstance(value, str) else None


def _assistant_text(payload: Any) -> str:
    if not isinstance(payload, dict):
        raise OpenAICompatibleChatPlannerError("provider response must be an object")
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise OpenAICompatibleChatPlannerError("provider response has no choices")
    first = choices[0]
    if not isinstance(first, dict):
        raise OpenAICompatibleChatPlannerError("provider choice must be an object")
    message = first.get("message")
    if not isinstance(message, dict):
        raise OpenAICompatibleChatPlannerError("provider choice has no message")
    content = message.get("content")
    if isinstance(content, str) and content.strip():
        return content
    if isinstance(content, list):
        parts = [
            str(item.get("text"))
            for item in content
            if isinstance(item, dict) and isinstance(item.get("text"), str)
        ]
        text = "".join(parts)
        if text.strip():
            return text
    raise OpenAICompatibleChatPlannerError("provider returned an empty Planner response")


def _redact_sensitive(text: str) -> str:
    redacted = text.replace("Authorization", "[redacted-header]")
    redacted = redacted.replace("Bearer", "[redacted-prefix]")
    # Cover common OpenAI/Moonshot-like token forms without depending on one
    # exact provider prefix.
    redacted = re.sub(
        r"(?i)(?:sk|ak|ms|moonshot)[-_][A-Za-z0-9._~-]{8,}",
        "[redacted-key]",
        redacted,
    )
    return re.sub(
        r"(?i)org[-_][A-Za-z0-9._~-]{8,}",
        "[redacted-org]",
        redacted,
    )
