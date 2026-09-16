from __future__ import annotations

import json
import unittest

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.public_http_tools import PublicHTTPToolSet, register_public_http_capabilities
from floweroll_host.storage import Storage


class _Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)


class _Response:
    def __init__(self, body: bytes, *, content_type: str = "application/json; charset=utf-8") -> None:
        self.status = 200
        self.headers = _Headers({"Content-Type": content_type})
        self._body = body

    def read(self, limit: int = -1) -> bytes:
        if limit < 0:
            return self._body
        return self._body[:limit]

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class _Opener:
    def __init__(self, response: _Response) -> None:
        self.response = response
        self.requests = []

    def open(self, request, timeout=0):
        self.requests.append((request, timeout))
        return self.response


def _public_resolver(host, port, type=None):
    return [(2, 1, 6, "", ("93.184.216.34", port))]


def _private_resolver(host, port, type=None):
    return [(2, 1, 6, "", ("127.0.0.1", port))]


class PublicHTTPToolTests(unittest.TestCase):
    def test_fetch_json_returns_bounded_structured_result(self) -> None:
        opener = _Opener(_Response(json.dumps({"weather": "rain", "temp": 20}).encode()))
        tools = PublicHTTPToolSet(resolver=_public_resolver, opener=opener)

        result = tools.fetch({"url": "https://example.com/api/weather?city=hangzhou"})

        self.assertEqual(result["status"], 200)
        self.assertEqual(result["json"], {"weather": "rain", "temp": 20})
        self.assertFalse(result["truncated"])
        self.assertEqual(len(opener.requests), 1)
        request, timeout = opener.requests[0]
        self.assertEqual(request.full_url, "https://example.com/api/weather?city=hangzhou")
        self.assertEqual(timeout, 15)

    def test_private_network_target_is_rejected(self) -> None:
        tools = PublicHTTPToolSet(
            resolver=_private_resolver,
            opener=_Opener(_Response(b"{}")),
        )
        with self.assertRaisesRegex(Exception, "private"):
            tools.fetch({"url": "https://localhost/internal"})

    def test_web_fetch_runs_through_action_attempt_and_observation(self) -> None:
        registry = CapabilityRegistry()
        executors, _ = register_public_http_capabilities(registry)
        fake = PublicHTTPToolSet(
            resolver=_public_resolver,
            opener=_Opener(_Response(b'{"ok":true}')),
        )
        executors["web.fetch"] = fake.fetch
        store = Storage(":memory:")
        task = store.create_task("http-task", "读取 API", "unit", {}, status="active")
        store.create_action(
            action_id="http-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="web.fetch",
            payload={"url": "https://example.com/api"},
            expected={},
            idempotency_key="http-task:1:web.fetch",
            on_verified="REPLAN",
        )
        execution = ExecutionRuntime(store, registry.execution_adapters())
        worker = FunctionExecutionWorker(execution, registry, executors)

        result = worker.run_once(task["task_id"])

        self.assertIsNotNone(result)
        attempt = store.action_attempts("http-action")[0]
        self.assertEqual(attempt["source_kind"], "http_api")
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        observations = store.verified_observations(task["task_id"])
        self.assertEqual(observations[0]["data"]["json"], {"ok": True})
        self.assertEqual(store.get_task(task["task_id"])["status"], "active")


if __name__ == "__main__":
    unittest.main()
