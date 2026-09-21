from __future__ import annotations

import threading
import time
import unittest
from unittest.mock import MagicMock, patch

from floweroll_host.mem0_memory import (
    MAX_MEMORY_CHARS,
    MAX_QUERY_CHARS,
    MAX_WRITE_CHARS,
    Mem0Memory,
)
from floweroll_host.planner_contracts import CapabilitySpec
from floweroll_host.server import HostApp
from floweroll_host.task_runtime import TaskRuntime


class FakeMem0Client:
    def __init__(self):
        self.add_calls = []
        self.search_calls = []
        self.added = threading.Event()

    def add(self, messages, **kwargs):
        self.add_calls.append((messages, kwargs))
        self.added.set()
        return {"results": []}

    def search(self, query, **kwargs):
        self.search_calls.append((query, kwargs))
        return {
            "results": [
                {
                    "id": "m1",
                    "memory": "用户求职优先杭州",
                    "score": 0.88,
                    "categories": ["career"],
                },
                {"id": "empty", "memory": "   ", "score": 0.2},
                {"id": "m2", "memory": "x" * (MAX_MEMORY_CHARS + 50)},
            ]
        }


class Mem0MemoryTests(unittest.TestCase):
    def test_default_platform_client_does_not_inherit_process_network_environment(self):
        fake = FakeMem0Client()
        transport = MagicMock()
        with patch("floweroll_host.mem0_memory.httpx.Client", return_value=transport) as http_client, \
             patch("floweroll_host.mem0_memory.MemoryClient", return_value=fake) as memory_client:
            memory = Mem0Memory(api_key="  test-key  ", user_id="owner", timeout_seconds=3.5)
        http_client.assert_called_once_with(timeout=3.5, trust_env=False)
        memory_client.assert_called_once_with(api_key="test-key", client=transport)
        self.assertTrue(memory.close(timeout_seconds=1.0))
        transport.close.assert_called_once_with()

    def test_search_uses_user_filter_and_returns_bounded_projection(self):
        fake = FakeMem0Client()
        memory = Mem0Memory(api_key="test", user_id="owner", top_k=5, client=fake)
        self.addCleanup(memory.close)

        result = memory.search("帮我找工作")

        self.assertIsNone(result["error_type"])
        self.assertEqual(len(result["items"]), 2)
        self.assertEqual(result["items"][0]["memory"], "用户求职优先杭州")
        self.assertEqual(len(result["items"][1]["memory"]), MAX_MEMORY_CHARS)
        _, kwargs = fake.search_calls[0]
        self.assertEqual(kwargs["filters"], {"user_id": "owner"})
        self.assertEqual(kwargs["top_k"], 5)

    def test_sensitive_or_oversized_search_query_never_leaves_host(self):
        fake = FakeMem0Client()
        memory = Mem0Memory(api_key="test", user_id="owner", client=fake)
        self.addCleanup(memory.close)

        for query in (
            '{"api_key":"secretvalue123"}',
            "Authorization: Bearer " + ("tokenvalue" * 3),
            "x" * (MAX_QUERY_CHARS + 1),
        ):
            with self.subTest(query=query[:24]):
                self.assertEqual(
                    memory.search(query),
                    {
                        "items": [],
                        "error_type": None,
                        "skipped_reason": "sensitive_or_oversized_query",
                    },
                )

        self.assertEqual(fake.search_calls, [])

        normal = memory.search("帮我比较 password manager 的使用习惯")
        self.assertIsNone(normal["error_type"])
        self.assertEqual(len(fake.search_calls), 1)

    def test_user_write_is_queued_with_provenance(self):
        fake = FakeMem0Client()
        memory = Mem0Memory(api_key="test", user_id="owner", client=fake)
        self.addCleanup(memory.close)

        queued = memory.remember_user_text(
            task_id="task-1",
            event_id="turn-1",
            text="以后找工作只考虑杭州",
            source_kind="user_turn",
        )

        self.assertTrue(queued)
        self.assertTrue(fake.added.wait(timeout=1.0))
        messages, kwargs = fake.add_calls[0]
        self.assertEqual(messages, [{"role": "user", "content": "以后找工作只考虑杭州"}])
        self.assertEqual(kwargs["user_id"], "owner")
        self.assertEqual(kwargs["metadata"]["task_id"], "task-1")
        self.assertEqual(kwargs["metadata"]["event_id"], "turn-1")

    def test_search_failure_is_fail_open(self):
        class BrokenClient(FakeMem0Client):
            def search(self, query, **kwargs):
                raise RuntimeError("network down")

        memory = Mem0Memory(api_key="test", user_id="owner", client=BrokenClient())
        self.addCleanup(memory.close)
        self.assertEqual(
            memory.search("anything"),
            {"items": [], "error_type": "RuntimeError"},
        )

    def test_close_is_bounded_drops_queued_writes_and_rejects_new_work(self):
        class BlockingClient(FakeMem0Client):
            def __init__(self):
                super().__init__()
                self.started = threading.Event()
                self.release = threading.Event()

            def add(self, messages, **kwargs):
                self.add_calls.append((messages, kwargs))
                self.started.set()
                if not self.release.wait(timeout=2):
                    raise RuntimeError("test Mem0 write release timed out")
                return {"results": []}

        fake = BlockingClient()
        memory = Mem0Memory(api_key="test", user_id="owner", client=fake)
        self.assertTrue(memory.remember_user_text(
            task_id="task-1", event_id="turn-1", text="first", source_kind="user_turn"
        ))
        self.assertTrue(fake.started.wait(timeout=1.0))
        self.assertTrue(memory.remember_user_text(
            task_id="task-1", event_id="turn-2", text="queued", source_kind="user_turn"
        ))

        started = time.monotonic()
        self.assertFalse(memory.close(timeout_seconds=0.02))
        self.assertLess(time.monotonic() - started, 0.2)
        self.assertFalse(memory.remember_user_text(
            task_id="task-1", event_id="turn-3", text="late", source_kind="user_turn"
        ))
        self.assertEqual(
            memory.search("anything"),
            {"items": [], "error_type": "MemoryClosed"},
        )

        fake.release.set()
        self.assertTrue(memory.close(timeout_seconds=1.0))
        self.assertEqual(
            [call[0][0]["content"] for call in fake.add_calls],
            ["first"],
            "queued personalization writes must be dropped during shutdown",
        )

    def test_sensitive_or_oversized_text_is_not_sent_to_memory_service(self):
        fake = FakeMem0Client()
        memory = Mem0Memory(api_key="test", user_id="owner", client=fake)
        self.addCleanup(memory.close)

        rejected = [
            "MEM0_API_KEY=sk-" + ("A" * 24),
            "Authorization: Bearer " + ("tokenvalue" * 3),
            "密码: supersecret123",
            "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
            '{"api_key":"secretvalue123"}',
            "x" * (MAX_WRITE_CHARS + 1),
        ]
        for index, text in enumerate(rejected):
            with self.subTest(index=index):
                self.assertFalse(
                    memory.remember_user_text(
                        task_id="task-sensitive",
                        event_id=f"turn-{index}",
                        text=text,
                        source_kind="user_turn",
                    )
                )

        self.assertEqual(fake.add_calls, [])
        self.assertTrue(
            memory.remember_user_text(
                task_id="task-normal",
                event_id="turn-normal",
                text="以后酒店优先选择交通方便、安静的地方",
                source_kind="user_turn",
            )
        )
        self.assertTrue(fake.added.wait(timeout=1.0))
        self.assertEqual(len(fake.add_calls), 1)

    def test_host_app_close_reaches_runtime_memory_owner(self):
        class Memory:
            def __init__(self):
                self.close_calls = 0

            def close(self):
                self.close_calls += 1

        memory = Memory()
        capability = CapabilitySpec(
            "test.read",
            "test read",
            {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        )

        def runtime_factory(store):
            return TaskRuntime(
                store,
                object(),
                [capability],
                memory=memory,
            )

        app = HostApp(":memory:", task_runtime_factory=runtime_factory)
        app.close()
        self.assertEqual(memory.close_calls, 1)


if __name__ == "__main__":
    unittest.main()
