from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.agent_loop import AgentLoop
from floweroll_host.server import create_server
from floweroll_host.storage import Storage


class StorageLoopTests(unittest.TestCase):
    def test_task_persists_across_storage_restart(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "brain.sqlite3")
            loop = AgentLoop(Storage(db))
            task = loop.create_task("测试持久化", "unit_test", {"mode": "probe"})
            action = loop.next_action(task["task_id"])
            assert action is not None
            loop.accept_result(
                task["task_id"],
                action["action_id"],
                True,
                {"echo": action["payload"]["message"]},
            )

            reloaded = Storage(db).get_task(task["task_id"])
            assert reloaded is not None
            self.assertEqual(reloaded["status"], "completed")

    def test_duplicate_result_is_idempotent(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("测试幂等")
        action = loop.next_action(task["task_id"])
        assert action is not None
        body = {"echo": action["payload"]["message"]}

        first = loop.accept_result(task["task_id"], action["action_id"], True, body)
        second = loop.accept_result(task["task_id"], action["action_id"], True, body)

        self.assertFalse(first["duplicate"])
        self.assertTrue(second["duplicate"])
        self.assertEqual(second["task"]["status"], "completed")
        event_types = [event["event_type"] for event in store.trace(task["task_id"])]
        self.assertEqual(event_types.count("action.verified"), 1)


class HTTPChainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        db = str(Path(self.tmp.name) / "host.sqlite3")
        self.server = create_server("127.0.0.1", 0, db)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:{}".format(self.server.server_address[1])

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def request(self, method: str, path: str, body=None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode("utf-8")) if raw else None

    def test_full_task_action_result_trace_chain(self) -> None:
        status, task = self.request(
            "POST",
            "/v1/tasks",
            {
                "goal": "验证 Action Button 后半段数据链",
                "invocation_source": "integration_test",
                "policy_snapshot": {"mode": "probe-only"},
            },
        )
        self.assertEqual(status, 201)
        task_id = task["task_id"]

        status, action = self.request("GET", "/v1/tasks/{}/next-action".format(task_id))
        self.assertEqual(status, 200)
        self.assertEqual(action["action_type"], "device.probe")
        self.assertEqual(action["status"], "dispatched")

        # Simulate losing the first HTTP response and reconnecting before the
        # device posts its result. The same logical action must be replayed,
        # not planned twice.
        status, replayed_action = self.request("GET", "/v1/tasks/{}/next-action".format(task_id))
        self.assertEqual(status, 200)
        self.assertEqual(replayed_action["action_id"], action["action_id"])
        self.assertEqual(replayed_action["idempotency_key"], action["idempotency_key"])

        status, result = self.request(
            "POST",
            "/v1/tasks/{}/actions/{}/result".format(task_id, action["action_id"]),
            {"success": True, "output": {"echo": action["payload"]["message"]}},
        )
        self.assertEqual(status, 200)
        self.assertEqual(result["task"]["status"], "completed")

        status, task_after = self.request("GET", "/v1/tasks/{}".format(task_id))
        self.assertEqual(status, 200)
        self.assertEqual(task_after["status"], "completed")

        status, trace = self.request("GET", "/v1/tasks/{}/trace".format(task_id))
        self.assertEqual(status, 200)
        self.assertEqual(
            [event["event_type"] for event in trace["events"]],
            [
                "task.created",
                "action.planned",
                "action.attempt.started",
                "action.dispatched",
                "action.result.received",
                "action.attempt.finished",
                "observation.verified",
                "action.verified",
                "action.verification.metrics",
            ],
        )

    def test_bad_probe_result_fails_verification(self) -> None:
        _, task = self.request("POST", "/v1/tasks", {"goal": "失败校验"})
        _, action = self.request("GET", "/v1/tasks/{}/next-action".format(task["task_id"]))
        status, result = self.request(
            "POST",
            "/v1/tasks/{}/actions/{}/result".format(task["task_id"], action["action_id"]),
            {"success": True, "output": {"echo": "wrong"}},
        )
        self.assertEqual(status, 200)
        self.assertEqual(result["task"]["status"], "failed")
        self.assertIn("did not match", result["action"]["error"])


if __name__ == "__main__":
    unittest.main()
