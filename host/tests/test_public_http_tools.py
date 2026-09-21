from __future__ import annotations

import json
import unittest
from unittest.mock import MagicMock, patch

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.public_http_tools import PublicHTTPToolSet, register_public_http_capabilities
from floweroll_host.storage import Storage


class _Transport:
    def __init__(
        self,
        body: bytes,
        *,
        status: int = 200,
        content_type: str = "application/json; charset=utf-8",
    ) -> None:
        self.body = body
        self.status = status
        self.content_type = content_type
        self.requests = []

    def request(self, **kwargs):
        self.requests.append(dict(kwargs))
        return self.status, self.content_type, self.body


def _public_resolver(host, port, type=None):
    return [(2, 1, 6, "", ("93.184.216.34", port))]


def _private_resolver(host, port, type=None):
    return [(2, 1, 6, "", ("127.0.0.1", port))]


class PublicHTTPToolTests(unittest.TestCase):
    def test_fetch_json_pins_validated_address_and_keeps_original_tls_host(self) -> None:
        transport = _Transport(
            json.dumps({"weather": "rain", "temp": 20}).encode()
        )
        tools = PublicHTTPToolSet(
            resolver=_public_resolver,
            transport=transport,
        )

        result = tools.fetch(
            {"url": "https://example.com/api/weather?city=hangzhou"}
        )

        self.assertEqual(result["status"], 200)
        self.assertEqual(result["json"], {"weather": "rain", "temp": 20})
        self.assertFalse(result["truncated"])
        self.assertEqual(
            transport.requests,
            [{
                "address": "93.184.216.34",
                "hostname": "example.com",
                "port": 443,
                "target": "/api/weather?city=hangzhou",
                "host_header": "example.com",
                "timeout": 15,
            }],
        )

    def test_private_network_target_is_rejected_before_transport(self) -> None:
        transport = _Transport(b"{}")
        tools = PublicHTTPToolSet(
            resolver=_private_resolver,
            transport=transport,
        )
        with self.assertRaisesRegex(Exception, "private"):
            tools.fetch({"url": "https://localhost/internal"})
        self.assertEqual(transport.requests, [])

    def test_validation_does_not_allow_second_dns_resolution_to_choose_peer(self) -> None:
        calls = 0

        def changing_resolver(host, port, type=None):
            nonlocal calls
            calls += 1
            address = "93.184.216.34" if calls == 1 else "127.0.0.1"
            return [(2, 1, 6, "", (address, port))]

        transport = _Transport(b'{"ok":true}')
        tools = PublicHTTPToolSet(
            resolver=changing_resolver,
            transport=transport,
        )

        result = tools.fetch({"url": "https://example.com/data"})

        self.assertEqual(result["json"], {"ok": True})
        self.assertEqual(calls, 1)
        self.assertEqual(
            transport.requests[0]["address"],
            "93.184.216.34",
        )

    def test_default_transport_connects_to_ip_with_tls_hostname_verification(self) -> None:
        response = MagicMock()
        response.status = 200
        response.headers = {"Content-Type": "application/json"}
        response.read.return_value = b'{"ok":true}'
        pool = MagicMock()
        pool.urlopen.return_value = response

        with patch(
            "floweroll_host.public_http_tools.urllib3.HTTPSConnectionPool",
            return_value=pool,
        ) as pool_type:
            result = PublicHTTPToolSet(resolver=_public_resolver).fetch(
                {"url": "https://example.com/data"}
            )

        self.assertEqual(result["json"], {"ok": True})
        pool_type.assert_called_once()
        args, kwargs = pool_type.call_args
        self.assertEqual(args[0], "93.184.216.34")
        self.assertEqual(kwargs["server_hostname"], "example.com")
        self.assertEqual(kwargs["assert_hostname"], "example.com")
        self.assertEqual(kwargs["cert_reqs"], "CERT_REQUIRED")
        _, target = pool.urlopen.call_args.args[:2]
        self.assertEqual(target, "/data")
        self.assertEqual(
            pool.urlopen.call_args.kwargs["headers"]["Host"],
            "example.com",
        )
        self.assertFalse(pool.urlopen.call_args.kwargs["redirect"])
        response.release_conn.assert_called_once()
        pool.close.assert_called_once()

    def test_redirect_and_error_statuses_preserve_bounded_failure_semantics(self) -> None:
        for status, error_kind in ((302, "model_correctable"), (404, "model_correctable"), (503, "transient")):
            with self.subTest(status=status):
                tools = PublicHTTPToolSet(
                    resolver=_public_resolver,
                    transport=_Transport(b"", status=status, content_type="text/plain"),
                )
                with self.assertRaises(Exception) as caught:
                    tools.fetch({"url": "https://example.com/status"})
                self.assertEqual(caught.exception.error_kind, error_kind)
                self.assertEqual(caught.exception.output["status"], status)

    def test_web_fetch_runs_through_action_attempt_and_observation(self) -> None:
        registry = CapabilityRegistry()
        executors, _ = register_public_http_capabilities(registry)
        fake = PublicHTTPToolSet(
            resolver=_public_resolver,
            transport=_Transport(b'{"ok":true}'),
        )
        executors["web.fetch"] = fake.fetch
        store = Storage(":memory:")
        task = store.create_task(
            "http-task",
            "读取 API",
            "unit",
            {},
            status="active",
        )
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
        execution = ExecutionRuntime(
            store,
            registry.execution_adapters(),
        )
        worker = FunctionExecutionWorker(
            execution,
            registry,
            executors,
        )
        try:
            result = worker.run_once(task["task_id"])

            self.assertIsNotNone(result)
            attempt = store.action_attempts("http-action")[0]
            self.assertEqual(attempt["source_kind"], "http_api")
            self.assertEqual(attempt["latest_outcome"], "SUCCESS")
            observations = store.verified_observations(task["task_id"])
            self.assertEqual(
                observations[0]["data"]["json"],
                {"ok": True},
            )
            self.assertEqual(
                store.get_task(task["task_id"])["status"],
                "active",
            )
        finally:
            worker.close()


if __name__ == "__main__":
    unittest.main()
