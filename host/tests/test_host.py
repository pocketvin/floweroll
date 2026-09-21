from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.agent_loop import AgentLoop
from floweroll_host.function_tool_adapter import FunctionToolAdapter
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

    def test_generic_action_http_cannot_steal_source_owned_host_function_attempt(self) -> None:
        adapter = FunctionToolAdapter(
            capability_id="host.test.read",
            source_kind="host_function",
            read_only=True,
        )
        self.server.app.execution.adapters[adapter.capability_id] = adapter
        task, _ = self.server.app.storage.create_or_get_task(
            task_id="product-host-function-task",
            goal="source ownership regression",
            invocation_source="ios_new_task",
            policy_snapshot={},
            submission_id="product-host-function-submission",
        )
        action = self.server.app.storage.create_action(
            action_id="product-host-function-action",
            task_id=task["task_id"],
            step_index=1,
            action_type=adapter.capability_id,
            payload={"value": "safe"},
            expected={},
            idempotency_key="product-host-function-action",
            on_verified="REPLAN",
        )
        dispatch = self.server.app.execution.next_action(
            task["task_id"],
            source_kind="host_function",
        )
        self.assertIsNotNone(dispatch)
        assert dispatch is not None
        attempt = self.server.app.storage.get_action_attempt(dispatch["attempt_id"])
        self.assertEqual(attempt["source_kind"], "host_function")
        self.assertEqual(attempt["status"], "IN_FLIGHT")

        status, problem = self.request(
            "GET",
            f"/v1/tasks/{task['task_id']}/next-action",
        )
        self.assertEqual(status, 409)
        self.assertEqual(problem["code"], "GENERIC_ACTION_ROUTE_NOT_ALLOWED")

        status, problem = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/actions/{action['action_id']}/result",
            {
                "attempt_id": dispatch["attempt_id"],
                "success": True,
                "output": {"forged": True},
            },
        )
        self.assertEqual(status, 409)
        self.assertEqual(problem["code"], "ACTION_RESULT_SOURCE_NOT_ALLOWED")

        unchanged = self.server.app.storage.get_action_attempt(dispatch["attempt_id"])
        self.assertEqual(unchanged["status"], "IN_FLIGHT")
        self.assertIsNone(unchanged["latest_outcome"])
        self.assertEqual(
            self.server.app.storage.verified_observations(task["task_id"]),
            [],
        )

    def test_product_ios_attempt_can_still_submit_result_over_http(self) -> None:
        task, _ = self.server.app.storage.create_or_get_task(
            task_id="product-ios-result-task",
            goal="iOS source result regression",
            invocation_source="ios_new_task",
            policy_snapshot={},
            submission_id="product-ios-result-submission",
        )
        action = self.server.app.storage.create_action(
            action_id="product-ios-result-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="device.probe",
            payload={"message": "never executed in this test"},
            expected={"echo": "never executed in this test"},
            idempotency_key="product-ios-result-action",
        )
        attempt = self.server.app.storage.start_action_attempt(
            attempt_id="product-ios-result-attempt",
            task_id=task["task_id"],
            action_id=action["action_id"],
            source_kind="ios",
            execution_profile={},
            dispatch_snapshot={"source": "ios"},
            dispatch_digest="product-ios-result-digest",
        )

        status, result = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/actions/{action['action_id']}/result",
            {
                "attempt_id": attempt["attempt_id"],
                "success": False,
                "output": {},
                "error": "simulated device failure",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(result["task"]["status"], "failed")
        finished = self.server.app.storage.get_action_attempt(attempt["attempt_id"])
        self.assertEqual(finished["status"], "FINISHED")
        self.assertEqual(finished["latest_outcome"], "TERMINAL_FAILURE")


if __name__ == "__main__":
    unittest.main()
