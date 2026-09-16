from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional

from .planner_contracts import CapabilitySpec, PlannerDecision
from . import planner_capture


class OpenAIPlannerError(RuntimeError):
    pass


class OpenAIPlannerAdapter:
    """Tiny Responses API adapter with no third-party dependency.

    The adapter owns provider HTTP details only. Planner contracts/context remain
    provider-independent so V1 can swap OpenAI for another compatible model.
    """

    def __init__(self, api_key: str, base_url: str = "https://api.openai.com"):
        if not api_key.strip():
            raise ValueError("api_key must not be empty")
        self.api_key = api_key.strip()
        self.base_url = base_url.rstrip("/")

    def decide(
        self,
        request_body: Dict[str, Any],
        capabilities: List[CapabilitySpec],
        timeout_seconds: float = 60.0,
    ) -> PlannerDecision:
        raw = json.dumps(request_body, ensure_ascii=False).encode("utf-8")
        planner_capture.request_ready(request_body, raw, adapter='responses', secret_values=(self.api_key,))
        request = urllib.request.Request(
            self.base_url + "/v1/responses",
            data=raw,
            method="POST",
            headers={
                "Authorization": "Bearer " + self.api_key,
                "Content-Type": "application/json",
            },
        )
        try:
            with planner_capture.http_attempt(1), urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            # Never include request headers/API key. Response bodies from OpenAI
            # should contain provider error metadata only.
            raise OpenAIPlannerError("OpenAI HTTP {}: {}".format(exc.code, body[:2000])) from exc
        except urllib.error.URLError as exc:
            raise OpenAIPlannerError("OpenAI network error: {}".format(exc.reason)) from exc

        if payload.get("status") == "incomplete":
            raise OpenAIPlannerError(
                "OpenAI response incomplete: {}".format(payload.get("incomplete_details"))
            )

        output_text = _extract_output_text(payload)
        planner_capture.response_received(output_text, payload.get('usage'), payload.get('status'))
        if output_text is None:
            refusal = _extract_refusal(payload)
            if refusal:
                raise OpenAIPlannerError("OpenAI refusal: {}".format(refusal))
            raise OpenAIPlannerError("OpenAI response did not contain output_text")

        try:
            decision_data = json.loads(output_text)
        except json.JSONDecodeError as exc:
            raise OpenAIPlannerError("structured output was not valid JSON") from exc
        if not isinstance(decision_data, dict):
            raise OpenAIPlannerError("structured output root must be an object")
        return PlannerDecision.from_dict(decision_data, capabilities)


def _extract_output_text(payload: Dict[str, Any]) -> Optional[str]:
    direct = payload.get("output_text")
    if isinstance(direct, str):
        return direct

    for item in payload.get("output", []):
        if not isinstance(item, dict):
            continue
        if item.get("type") != "message":
            continue
        for content in item.get("content", []):
            if isinstance(content, dict) and content.get("type") == "output_text":
                text = content.get("text")
                if isinstance(text, str):
                    return text
    return None


def _extract_refusal(payload: Dict[str, Any]) -> Optional[str]:
    for item in payload.get("output", []):
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []):
            if isinstance(content, dict) and content.get("type") == "refusal":
                refusal = content.get("refusal")
                if isinstance(refusal, str):
                    return refusal
    return None
