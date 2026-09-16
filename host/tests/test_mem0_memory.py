from __future__ import annotations

import threading
import unittest
from unittest.mock import patch

from floweroll_host.mem0_memory import MAX_MEMORY_CHARS, Mem0Memory


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
        transport = object()
        with patch("floweroll_host.mem0_memory.httpx.Client", return_value=transport) as http_client, \
             patch("floweroll_host.mem0_memory.MemoryClient", return_value=fake) as memory_client:
            memory = Mem0Memory(api_key="  test-key  ", user_id="owner", timeout_seconds=3.5)
        http_client.assert_called_once_with(timeout=3.5, trust_env=False)
        memory_client.assert_called_once_with(api_key="test-key", client=transport)
        memory._write_queue.put(None)
        self.assertTrue(memory._writer.join(timeout=1.0) is None)

    def test_search_uses_user_filter_and_returns_bounded_projection(self):
        fake = FakeMem0Client()
        memory = Mem0Memory(api_key="test", user_id="owner", top_k=5, client=fake)

        result = memory.search("帮我找工作")

        self.assertIsNone(result["error_type"])
        self.assertEqual(len(result["items"]), 2)
        self.assertEqual(result["items"][0]["memory"], "用户求职优先杭州")
        self.assertEqual(len(result["items"][1]["memory"]), MAX_MEMORY_CHARS)
        _, kwargs = fake.search_calls[0]
        self.assertEqual(kwargs["filters"], {"user_id": "owner"})
        self.assertEqual(kwargs["top_k"], 5)

    def test_user_write_is_queued_with_provenance(self):
        fake = FakeMem0Client()
        memory = Mem0Memory(api_key="test", user_id="owner", client=fake)

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
        self.assertEqual(
            memory.search("anything"),
            {"items": [], "error_type": "RuntimeError"},
        )


if __name__ == "__main__":
    unittest.main()
