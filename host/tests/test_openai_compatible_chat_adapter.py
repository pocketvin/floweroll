from __future__ import annotations

import json
import unittest
from io import BytesIO
from unittest.mock import patch
import urllib.error
from datetime import datetime
from zoneinfo import ZoneInfo

from floweroll_host.capabilities_v0 import REMINDER_CREATE
from floweroll_host.context_builder import ContextBuilder
from floweroll_host.openai_compatible_chat_adapter import (
    OpenAICompatibleChatPlannerAdapter,
    _finish_reason,
    _redact_sensitive,
)
from floweroll_host.planner_request import PlannerRequestBuilder


class OpenAICompatibleChatPlannerAdapterTests(unittest.TestCase):
    def request(self) -> dict:
        context = ContextBuilder().build(
            task_id="task-chat-adapter",
            raw_goal="明天十点提醒我交报告",
            current_time=datetime(2026, 9, 10, 23, 35, tzinfo=ZoneInfo("Asia/Shanghai")),
            timezone_name="Asia/Shanghai",
            policy_view={"allowed_capabilities": ["reminder.create"], "constraints": []},
            capabilities=[REMINDER_CREATE],
            runtime_context={"invocation_source": "unit_test"},
        )
        return PlannerRequestBuilder(model="irrelevant-responses-model").build(context)

    def test_translates_same_planner_schema_to_chat_completions(self) -> None:
        adapter = OpenAICompatibleChatPlannerAdapter(
            api_key="test-secret-not-real",
            base_url="https://api.example.test/v1",
            model="kimi-k3",
        )
        request = self.request()
        payload = adapter._chat_payload(request)

        self.assertEqual(payload["model"], "kimi-k3")
        self.assertEqual([item["role"] for item in payload["messages"]], ["system", "user"])
        self.assertEqual(payload["max_completion_tokens"], request["max_output_tokens"])
        self.assertEqual(payload["response_format"]["type"], "json_schema")
        self.assertEqual(
            payload["response_format"]["json_schema"]["schema"],
            request["text"]["format"]["schema"],
        )
        serialized = json.dumps(payload)
        self.assertNotIn("test-secret-not-real", serialized)
        self.assertNotIn("reasoning_effort", serialized)
        self.assertNotIn('"store"', serialized)

    def test_finish_reason_is_extracted_without_exposing_response_content(self) -> None:
        self.assertEqual(_finish_reason({"choices": [{"finish_reason": "length"}]}), "length")
        self.assertIsNone(_finish_reason({"choices": []}))

    def test_provider_account_identifiers_are_redacted_from_errors(self) -> None:
        raw = "org-debde689b97943adb28e4fb3fe34982a <ak-fb3owe5skg7i11hkodi1> Bearer sk-secretsecretsecret"
        redacted = _redact_sensitive(raw)
        self.assertNotIn("org-debde", redacted)
        self.assertNotIn("ak-fb3", redacted)
        self.assertNotIn("sk-secret", redacted)

    def test_provider_can_override_completion_budget_without_changing_runtime_schema(self) -> None:
        adapter = OpenAICompatibleChatPlannerAdapter(
            api_key="test-key",
            base_url="https://example.com/v1",
            model="test-model",
            max_completion_tokens_override=2400,
        )
        body = self.request()
        payload = adapter._chat_payload(body)
        self.assertEqual(payload["max_completion_tokens"], 2400)
        self.assertEqual(payload["response_format"]["type"], "json_schema")

    def test_v1_base_url_does_not_duplicate_v1(self) -> None:
        adapter = OpenAICompatibleChatPlannerAdapter(
            api_key="x",
            base_url="https://api.example.test/v1",
            model="kimi-k3",
        )
        self.assertEqual(
            adapter._chat_completions_url(),
            "https://api.example.test/v1/chat/completions",
        )

    def test_transient_500_retries_once_and_recovers(self) -> None:
        adapter = OpenAICompatibleChatPlannerAdapter(
            api_key="test-key",
            base_url="https://example.com/v1",
            model="kimi-k3",
            transient_http_retries=1,
        )
        request_body = self.request()
        decision_json = json.dumps({
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": "创建提醒",
            "plan_update": ["创建提醒"],
            "action": {
                "capability": "reminder.create",
                "arguments": {
                    "title": "交报告",
                    "due_at": "2026-09-11T10:00:00+08:00",
                },
            },
            "on_verified": "COMPLETE",
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
            "cancellation": None,
            "state_update": None,
        })
        response_payload = json.dumps({
            "choices": [{
                "finish_reason": "stop",
                "message": {"content": decision_json},
            }],
            "usage": {"prompt_tokens": 321, "completion_tokens": 45, "total_tokens": 366},
        }).encode()

        class FakeResponse:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self): return response_payload

        transient = urllib.error.HTTPError(
            "https://example.com/v1/chat/completions",
            500,
            "Internal Server Error",
            {},
            BytesIO(b'{"error":{"message":"InternalServerError"}}'),
        )
        with patch("floweroll_host.openai_compatible_chat_adapter.time.sleep") as sleep, \
             patch("floweroll_host.openai_compatible_chat_adapter.urllib.request.urlopen", side_effect=[transient, FakeResponse()]) as urlopen:
            decision = adapter.decide(request_body, [REMINDER_CREATE])

        self.assertEqual(urlopen.call_count, 2)
        sleep.assert_called_once()
        self.assertEqual(decision.decision_type, "EXECUTE")
        self.assertEqual(decision.action["capability"], "reminder.create")
        metrics = adapter.consume_last_call_metrics()
        self.assertEqual(metrics["provider_model"], "kimi-k3")
        self.assertEqual(metrics["provider_attempts"], 2)
        self.assertEqual(metrics["prompt_tokens"], 321)
        self.assertEqual(metrics["completion_tokens"], 45)
        self.assertEqual(metrics["total_tokens"], 366)
        self.assertEqual(adapter.consume_last_call_metrics(), {})

    def test_non_transient_400_does_not_retry(self) -> None:
        adapter = OpenAICompatibleChatPlannerAdapter(
            api_key="test-key",
            base_url="https://example.com/v1",
            model="kimi-k3",
            transient_http_retries=1,
        )
        bad_request = urllib.error.HTTPError(
            "https://example.com/v1/chat/completions",
            400,
            "Bad Request",
            {},
            BytesIO(b'{"error":{"message":"bad request"}}'),
        )
        with patch("floweroll_host.openai_compatible_chat_adapter.time.sleep") as sleep, \
             patch("floweroll_host.openai_compatible_chat_adapter.urllib.request.urlopen", side_effect=bad_request) as urlopen:
            with self.assertRaises(Exception):
                adapter.decide(self.request(), [REMINDER_CREATE])

        self.assertEqual(urlopen.call_count, 1)
        sleep.assert_not_called()



if __name__ == "__main__":
    unittest.main()
