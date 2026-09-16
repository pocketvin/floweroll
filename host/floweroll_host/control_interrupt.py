from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, Protocol

from .openai_compatible_chat_adapter import _assistant_text, _finish_reason, _redact_sensitive


CONTROL_INTENTS = {"NONE", "CANCEL_TASK", "INTERRUPT_CURRENT_ACTION"}
CONTROL_CONFIDENCE = {"HIGH", "LOW"}


@dataclass(frozen=True)
class ControlInterruptDecision:
    intent: str
    confidence: str
    reason: str

    def __post_init__(self) -> None:
        if self.intent not in CONTROL_INTENTS:
            raise ValueError(f"invalid control interrupt intent: {self.intent}")
        if self.confidence not in CONTROL_CONFIDENCE:
            raise ValueError(f"invalid control interrupt confidence: {self.confidence}")
        if not isinstance(self.reason, str) or not self.reason.strip():
            raise ValueError("control interrupt reason must be non-empty")


class ControlInterruptClassifier(Protocol):
    def classify(self, basis: Dict[str, Any]) -> ControlInterruptDecision:
        ...


_SYSTEM = """You classify execution-control intent for 小卷 while one real-world Action may already be in flight.

Return exactly one structured decision:
- CANCEL_TASK: the latest user turns clearly withdraw/abandon the whole current Task.
- INTERRUPT_CURRENT_ACTION: the user clearly wants the current in-flight Action stopped/changed, but still wants the Task to continue or be redirected.
- NONE: ordinary additions/questions/confirmations, negated cancellation, or ambiguous text.

Rules:
1. Be conservative. Do not infer cancellation merely because words such as cancel/stop/算了 appear under negation (for example “不要取消，继续”).
2. Interpret the ordered user_turns together; later explicit corrections override earlier ones when they conflict.
3. “等一下/先停一下” during a real-world in-flight Action can be INTERRUPT_CURRENT_ACTION when it clearly asks to pause that Action; if genuinely ambiguous, use NONE with LOW confidence.
4. This classifier cannot call tools, alter arguments, or decide task completion. It only classifies control intent.
5. Use HIGH only when the control intent is explicit enough to safely affect a real-world Action. Otherwise use LOW.
"""

_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {
            "type": "string",
            "enum": ["NONE", "CANCEL_TASK", "INTERRUPT_CURRENT_ACTION"],
        },
        "confidence": {"type": "string", "enum": ["HIGH", "LOW"]},
        "reason": {"type": "string"},
    },
    "required": ["intent", "confidence", "reason"],
    "additionalProperties": False,
}


class OpenAICompatibleControlInterruptClassifier:
    """Narrow no-tool classifier for urgent natural-language control intent."""

    def __init__(
        self,
        *,
        api_key: str,
        base_url: str,
        model: str,
        timeout_seconds: float = 30.0,
        max_completion_tokens: int = 1000,
    ) -> None:
        if not api_key.strip():
            raise ValueError("api_key must not be empty")
        if not base_url.strip():
            raise ValueError("base_url must not be empty")
        if not model.strip():
            raise ValueError("model must not be empty")
        if max_completion_tokens < 64:
            raise ValueError("max_completion_tokens is too small")
        self._api_key = api_key.strip()
        self.base_url = base_url.rstrip("/")
        self.model = model.strip()
        self.timeout_seconds = float(timeout_seconds)
        self.max_completion_tokens = int(max_completion_tokens)

    def classify(self, basis: Dict[str, Any]) -> ControlInterruptDecision:
        action = basis.get("action") or {}
        user_turns = basis.get("user_turns") or []
        user_payload = {
            "task": {
                "goal": basis.get("goal"),
                "current_task_brief": basis.get("current_task_brief"),
            },
            "current_action": {
                "capability": action.get("action_type"),
                "status": action.get("status"),
            },
            "user_turns": [
                {
                    "event_id": turn.get("event_id"),
                    "text": turn.get("text"),
                    "received_at": turn.get("received_at"),
                }
                for turn in user_turns
            ],
        }
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": _SYSTEM},
                {
                    "role": "user",
                    "content": json.dumps(user_payload, ensure_ascii=False, separators=(",", ":")),
                },
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "floweroll_control_interrupt_v1",
                    "strict": True,
                    "schema": _SCHEMA,
                },
            },
            "max_completion_tokens": self.max_completion_tokens,
        }
        request = urllib.request.Request(
            self._chat_completions_url(),
            data=json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": "Bearer " + self._api_key,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                envelope = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = _redact_sensitive(exc.read().decode("utf-8", errors="replace")[:2000])
            raise RuntimeError(f"control classifier HTTP {exc.code}: {body}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"control classifier network error: {exc.reason}") from exc
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError("control classifier returned an invalid JSON envelope") from exc

        finish_reason = _finish_reason(envelope)
        content = _assistant_text(envelope)
        try:
            data = json.loads(content)
        except json.JSONDecodeError as exc:
            suffix = f"; finish_reason={finish_reason}" if finish_reason else ""
            raise RuntimeError("control classifier output was not valid JSON" + suffix) from exc
        if not isinstance(data, dict) or set(data) != {"intent", "confidence", "reason"}:
            raise RuntimeError("control classifier output shape is invalid")
        return ControlInterruptDecision(
            intent=str(data["intent"]),
            confidence=str(data["confidence"]),
            reason=str(data["reason"]),
        )

    def _chat_completions_url(self) -> str:
        if self.base_url.endswith("/v1"):
            return self.base_url + "/chat/completions"
        return self.base_url + "/v1/chat/completions"
