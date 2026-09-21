from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path
from unittest.mock import patch

from floweroll_host.capabilities_v0 import REMINDER_CREATE
from floweroll_host.openai_compatible_chat_adapter import OpenAICompatibleChatPlannerTransientError
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.server import create_server
from floweroll_host.storage import Storage
from floweroll_host.task_runtime import TaskRuntime
from floweroll_host.runtime_supervisor import RuntimeSupervisor


def reminder_decision() -> PlannerDecision:
    return PlannerDecision.from_dict(
        {
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": "明天10点提醒用户",
            "plan_update": ["创建提醒"],
            "action": {
                "capability": "reminder.create",
                "arguments": {
                    "title": "面试",
                    "due_at": "2026-09-11T10:00:00+08:00",
                },
            },
            "on_verified": "COMPLETE",
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
            "state_update": {
                "pending_clarification": None,
                "current_task_brief": "明天10点提醒面试",
            },
        },
        [REMINDER_CREATE],
    )


class BlockingPlanner:
    def __init__(self) -> None:
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = 0

    def decide(self, request, capabilities):
        self.calls += 1
        self.started.set()
        if not self.release.wait(timeout=5):
            raise RuntimeError("test planner release timed out")
        return reminder_decision()


class CloseTrackingMemory:
    def __init__(self) -> None:
        self.close_calls = 0
        self.closed = False

    def remember_user_text(self, **kwargs):
        if self.closed:
            raise RuntimeError("memory used after close")
        return True

    def search(self, query):
        if self.closed:
            raise RuntimeError("memory used after close")
        return {"items": [], "error_type": None}

    def close(self) -> None:
        self.close_calls += 1
        self.closed = True


class BlockingByGoalPlanner:
    def __init__(self) -> None:
        self.slow_started = threading.Event()
        self.fast_started = threading.Event()
        self.release_slow = threading.Event()
        self.calls = 0
        self._lock = threading.Lock()

    def decide(self, request, capabilities):
        body = json.dumps(request, ensure_ascii=False)
        with self._lock:
            self.calls += 1
        if "慢任务" in body:
            self.slow_started.set()
            if not self.release_slow.wait(timeout=5):
                raise RuntimeError("slow planner release timed out")
        elif "快任务" in body:
            self.fast_started.set()
        return reminder_decision()


class FailingPlanner:
    def __init__(self) -> None:
        self.calls = 0

    def decide(self, request, capabilities):
        self.calls += 1
        raise RuntimeError("provider unavailable")


class FlakyTransientPlanner:
    def __init__(self, failures: int = 1) -> None:
        self.calls = 0
        self.failures = failures

    def decide(self, request, capabilities):
        self.calls += 1
        if self.calls <= self.failures:
            raise OpenAICompatibleChatPlannerTransientError(
                "Chat Completions transport timed out or disconnected after bounded retry"
            )
        return reminder_decision()


class AlwaysTransientPlanner:
    def __init__(self) -> None:
        self.calls = 0

    def decide(self, request, capabilities):
        self.calls += 1
        raise OpenAICompatibleChatPlannerTransientError(
            "Chat Completions transport timed out or disconnected after bounded retry"
        )


class FailingThenIdleExecutionWorker:
    def __init__(self) -> None:
        self.calls = 0
        self.recovered = threading.Event()

    def sweep_once(self):
        self.calls += 1
        if self.calls == 1:
            raise RuntimeError("fixture execution scheduler failure")
        self.recovered.set()
        return []


class SupervisorHTTPTests(unittest.TestCase):
    def request(self, base: str, method: str, path: str, body=None):
        raw = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(base + path, data=raw, method=method)
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=3) as response:
            payload = response.read()
            return response.status, json.loads(payload.decode("utf-8")) if payload else None

    def test_product_submission_returns_before_blocking_planner_and_uses_host_policy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            planner = BlockingPlanner()
            db = str(Path(tmp) / "supervisor.sqlite3")
            server = create_server(
                "127.0.0.1",
                0,
                db,
                task_runtime_factory=lambda store: TaskRuntime(store, planner, [REMINDER_CREATE]),
                product_policy_snapshot={
                    "allowed_capabilities": ["reminder.create"],
                    "constraints": ["host-authoritative"],
                },
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = "http://127.0.0.1:{}".format(server.server_address[1])
            try:
                started_at = time.monotonic()
                status, task = self.request(
                    base,
                    "POST",
                    "/v1/tasks",
                    {
                        "submission_id": "supervisor-submit",
                        "input": {"kind": "text", "text": "明天十点提醒我面试"},
                        "invocation_source": "ios_new_task",
                        # Must be ignored for product tasks.
                        "policy_snapshot": {"allowed_capabilities": ["evil.capability"]},
                    },
                )
                elapsed = time.monotonic() - started_at
                self.assertEqual(status, 201)
                self.assertLess(elapsed, 1.0)
                self.assertEqual(task["current_step"], 0)
                self.assertEqual(
                    task["policy_snapshot"],
                    {
                        "allowed_capabilities": ["reminder.create"],
                        "constraints": ["host-authoritative"],
                    },
                )
                self.assertTrue(planner.started.wait(timeout=2))
                self.assertIsNone(server.app.storage.get_open_action(task["task_id"]))

                planner.release.set()
                deadline = time.monotonic() + 2
                action = None
                while time.monotonic() < deadline:
                    action = server.app.storage.get_open_action(task["task_id"])
                    if action is not None:
                        break
                    time.sleep(0.02)
                self.assertIsNotNone(action)
                assert action is not None
                self.assertEqual(action["action_type"], "reminder.create")
                self.assertEqual(planner.calls, 1)
            finally:
                planner.release.set()
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_supervisor_stop_is_bounded_while_planner_future_finishes_naturally(self) -> None:
        store = Storage(":memory:")
        planner = BlockingPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        runtime.create_task("明天十点提醒我面试")
        supervisor = RuntimeSupervisor(
            store,
            runtime,
            poll_interval_seconds=0.01,
        )
        supervisor.start()
        drained = threading.Event()
        try:
            self.assertTrue(planner.started.wait(timeout=1))
            started = time.monotonic()
            self.assertFalse(
                supervisor.stop(
                    timeout_seconds=0.1,
                    planner_drain_seconds=0.02,
                )
            )
            self.assertLess(time.monotonic() - started, 0.5)

            supervisor.when_planner_drained(drained.set)
            planner.release.set()
            self.assertTrue(drained.wait(timeout=1))
            self.assertTrue(
                supervisor.stop(
                    timeout_seconds=0.1,
                    planner_drain_seconds=0.2,
                )
            )
        finally:
            planner.release.set()

    def test_host_close_defers_runtime_and_assets_until_running_planner_drains(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            planner = BlockingPlanner()
            memory = CloseTrackingMemory()
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "planner-close.sqlite3"),
                task_runtime_factory=lambda store: TaskRuntime(
                    store,
                    planner,
                    [REMINDER_CREATE],
                    memory=memory,
                ),
                product_policy_snapshot={
                    "allowed_capabilities": ["reminder.create"],
                    "constraints": ["host-authoritative"],
                },
                task_asset_root=root / "assets",
            )
            app = server.app
            task = app.accept_product_task(
                goal="明天十点提醒我面试",
                invocation_source="ios_new_task",
                submission_id="planner-close-submission",
            )
            self.assertTrue(planner.started.wait(timeout=2))
            self.assertIsNotNone(app.task_assets)
            assert app.task_assets is not None

            try:
                with patch.object(
                    app.task_assets,
                    "close",
                    wraps=app.task_assets.close,
                ) as close_assets:
                    started = time.monotonic()
                    app.close()
                    self.assertLess(time.monotonic() - started, 2.0)
                    self.assertEqual(memory.close_calls, 0)
                    self.assertEqual(close_assets.call_count, 0)

                    planner.release.set()
                    deadline = time.monotonic() + 2
                    while time.monotonic() < deadline:
                        action = app.storage.get_open_action(task["task_id"])
                        if (
                            action is not None
                            and memory.close_calls == 1
                            and close_assets.call_count == 1
                        ):
                            break
                        time.sleep(0.02)

                    action = app.storage.get_open_action(task["task_id"])
                    self.assertIsNotNone(action)
                    self.assertEqual(memory.close_calls, 1)
                    self.assertEqual(close_assets.call_count, 1)
            finally:
                planner.release.set()
                server.server_close()

    def test_slow_task_does_not_head_of_line_block_independent_task(self) -> None:
        store = Storage(":memory:")
        planner = BlockingByGoalPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        slow = runtime.create_task("慢任务：明天十点提醒我面试")
        fast = runtime.create_task("快任务：明天十点提醒我面试")
        supervisor = RuntimeSupervisor(
            store,
            runtime,
            poll_interval_seconds=0.01,
            planner_max_workers=2,
        )
        supervisor.start()
        try:
            self.assertTrue(planner.slow_started.wait(timeout=1))
            self.assertTrue(
                planner.fast_started.wait(timeout=1),
                "independent Task was serialized behind the slow Planner call",
            )
            deadline = time.monotonic() + 1
            fast_action = None
            while time.monotonic() < deadline:
                fast_action = store.get_open_action(fast["task_id"])
                if fast_action is not None:
                    break
                time.sleep(0.01)
            self.assertIsNotNone(fast_action)
            self.assertIsNone(store.get_open_action(slow["task_id"]))
            fast_trace = [row["event_type"] for row in store.trace(fast["task_id"])]
            self.assertIn("runtime.planner.scheduled", fast_trace)
            self.assertIn("runtime.planner.worker_started", fast_trace)
        finally:
            planner.release_slow.set()
            supervisor.stop()

    def test_product_without_runtime_stays_durably_accepted_without_fake_probe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            server = create_server("127.0.0.1", 0, str(Path(tmp) / "no-planner.sqlite3"))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = "http://127.0.0.1:{}".format(server.server_address[1])
            try:
                status, task = self.request(
                    base,
                    "POST",
                    "/v1/tasks",
                    {
                        "submission_id": "no-runtime",
                        "input": {"kind": "text", "text": "这是产品任务"},
                        "invocation_source": "ios_new_task",
                    },
                )
                self.assertEqual(status, 201)
                self.assertEqual(task["current_step"], 0)
                self.assertIsNone(server.app.storage.get_open_action(task["task_id"]))

                req = urllib.request.Request(
                    base + f"/v1/tasks/{task['task_id']}/next-action",
                    method="GET",
                )
                try:
                    with urllib.request.urlopen(req, timeout=3) as response:
                        self.assertEqual(response.status, 204)
                except Exception as exc:  # pragma: no cover - clearer failure
                    self.fail(str(exc))
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_legacy_goal_probe_remains_compatible(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            server = create_server("127.0.0.1", 0, str(Path(tmp) / "legacy.sqlite3"))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = "http://127.0.0.1:{}".format(server.server_address[1])
            try:
                status, task = self.request(base, "POST", "/v1/tasks", {"goal": "probe"})
                self.assertEqual(status, 201)
                _, action = self.request(
                    base,
                    "GET",
                    f"/v1/tasks/{task['task_id']}/next-action",
                )
                self.assertEqual(action["action_type"], "device.probe")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


class SupervisorFailureTests(unittest.TestCase):
    def test_task_denied_is_distinct_from_planner_runtime_failure(self) -> None:
        store = Storage(":memory:")
        planner = FailingPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        task = runtime.create_task("\u53ea\u8bfb\uff0c\u4e0d\u8981\u521b\u5efa\u63d0\u9192")
        supervisor = RuntimeSupervisor(store, runtime)

        result = supervisor.advance_task(task["task_id"])
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(result["reason"], "task_capability_denied")
        self.assertEqual(result["reason_code"], "TASK_DENIED")
        self.assertEqual(planner.calls, 0)
        self.assertEqual(store.get_runtime_state(task["task_id"])["block_reason"], "task_capability_denied")

    def test_cancel_during_planner_yields_instead_of_becoming_runtime_error(self) -> None:
        store = Storage(":memory:")
        planner = BlockingPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        task = runtime.create_task("明天上午9点提醒我开会")
        supervisor = RuntimeSupervisor(store, runtime)
        box = {}

        def run() -> None:
            box["result"] = supervisor.advance_task(task["task_id"])

        thread = threading.Thread(target=run)
        thread.start()
        self.assertTrue(planner.started.wait(timeout=2))
        store.admit_cancel_request(
            task_id=task["task_id"],
            event_id="cancel-during-planner",
            reason="不用提醒了",
        )
        store.consume_cancel_request(event_id="cancel-during-planner")
        planner.release.set()
        thread.join(timeout=3)

        self.assertFalse(thread.is_alive())
        self.assertEqual(box["result"]["status"], "YIELDED")
        self.assertEqual(box["result"]["reason"], "terminal")
        self.assertEqual(store.get_task(task["task_id"])["status"], "cancelled")
        self.assertEqual(len(store.planner_decisions(task["task_id"])), 0)
        trace_types = [row["event_type"] for row in store.trace(task["task_id"])]
        self.assertIn("planner.result.stale", trace_types)
        self.assertNotIn("task.blocked", trace_types)

    def test_planner_failure_blocks_task_instead_of_tight_retry_loop(self) -> None:
        store = Storage(":memory:")
        planner = FailingPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        task = runtime.create_task("明天提醒我")
        supervisor = RuntimeSupervisor(store, runtime, poll_interval_seconds=0.01)

        result = supervisor.advance_task(task["task_id"])
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(planner.calls, 1)
        self.assertEqual(store.get_task(task["task_id"])["status"], "blocked")
        self.assertEqual(store.get_runtime_state(task["task_id"])["block_reason"], "planner_runtime_error")

        # BLOCKED tasks are not active-planning sweep candidates, so repeated
        # supervisor ticks do not hammer a broken provider.
        self.assertEqual(supervisor.sweep_once(), [])
        self.assertEqual(planner.calls, 1)

    def test_transient_planner_failure_enters_durable_retry_then_recovers(self) -> None:
        store = Storage(":memory:")
        planner = FlakyTransientPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        task = runtime.create_task("明天提醒我")
        supervisor = RuntimeSupervisor(
            store,
            runtime,
            poll_interval_seconds=0.005,
            planner_transient_auto_retries=1,
            planner_retry_base_seconds=0.02,
        )

        supervisor.start()
        try:
            deadline = time.monotonic() + 2
            action = None
            while time.monotonic() < deadline:
                action = store.get_open_action(task["task_id"])
                if action is not None:
                    break
                time.sleep(0.01)
            self.assertIsNotNone(action)
            self.assertEqual(planner.calls, 2)
            self.assertEqual(store.get_task(task["task_id"])["status"], "active")
            runtime_state = store.get_runtime_state(task["task_id"])
            assert runtime_state is not None
            self.assertIsNone(runtime_state["block_reason"])
            self.assertIsNone(runtime_state["wait_kind"])
            trace_types = [row["event_type"] for row in store.trace(task["task_id"])]
            self.assertIn("planner.retry_wait", trace_types)
            self.assertIn("planner.retry_resumed", trace_types)
            self.assertNotIn("task.blocked", trace_types)
        finally:
            supervisor.stop()

    def test_repeated_transient_planner_failure_blocks_after_one_auto_retry(self) -> None:
        store = Storage(":memory:")
        planner = AlwaysTransientPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        task = runtime.create_task("明天提醒我")
        supervisor = RuntimeSupervisor(
            store,
            runtime,
            poll_interval_seconds=0.005,
            planner_transient_auto_retries=1,
            planner_retry_base_seconds=0.02,
        )

        supervisor.start()
        try:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if store.get_task(task["task_id"])["status"] == "blocked":
                    break
                time.sleep(0.01)
            self.assertEqual(planner.calls, 2)
            self.assertEqual(store.get_task(task["task_id"])["status"], "blocked")
            runtime_state = store.get_runtime_state(task["task_id"])
            assert runtime_state is not None
            self.assertEqual(runtime_state["block_reason"], "planner_runtime_error")
            trace_types = [row["event_type"] for row in store.trace(task["task_id"])]
            self.assertEqual(trace_types.count("planner.retry_wait"), 1)
            self.assertEqual(trace_types.count("planner.call.failed"), 2)
            self.assertIn("task.blocked", trace_types)
        finally:
            supervisor.stop()

    def test_new_user_turn_interrupts_planner_retry_backoff_and_replans_now(self) -> None:
        store = Storage(":memory:")
        planner = FlakyTransientPlanner()
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        task = runtime.create_task("明天提醒我")
        supervisor = RuntimeSupervisor(
            store,
            runtime,
            planner_transient_auto_retries=1,
            planner_retry_base_seconds=60.0,
        )

        first = supervisor.advance_task(task["task_id"])
        self.assertEqual(first["status"], "WAITING")
        waiting = store.get_runtime_state(task["task_id"])
        assert waiting is not None
        self.assertEqual(waiting["wait_kind"], "RETRY_BACKOFF")
        self.assertEqual(store.get_task(task["task_id"])["status"], "waiting")

        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id="resume-with-new-material",
            event_type="USER_TURN",
            source="user",
            payload={"content": {"kind": "text", "text": "这个是简历"}},
        )
        interrupted = store.get_runtime_state(task["task_id"])
        assert interrupted is not None
        self.assertEqual(store.get_task(task["task_id"])["status"], "active")
        self.assertIsNone(interrupted["wait_kind"])
        self.assertIsNone(interrupted["wait_id"])

        second = supervisor.advance_task(task["task_id"])
        self.assertEqual(second["status"], "ADVANCED")
        self.assertEqual(planner.calls, 2)
        trace_types = [row["event_type"] for row in store.trace(task["task_id"])]
        self.assertIn("planner.retry_superseded_by_user_turn", trace_types)

    def test_new_user_turn_resets_transient_failure_streak(self) -> None:
        store = Storage(":memory:")
        planner = FlakyTransientPlanner(failures=2)
        runtime = TaskRuntime(store, planner, [REMINDER_CREATE])
        task = runtime.create_task("明天提醒我")
        supervisor = RuntimeSupervisor(
            store,
            runtime,
            planner_transient_auto_retries=1,
            planner_retry_base_seconds=60.0,
        )

        first = supervisor.advance_task(task["task_id"])
        self.assertEqual(first["status"], "WAITING")
        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id="new-user-context",
            event_type="USER_TURN",
            source="user",
            payload={"content": {"kind": "text", "text": "补充新的材料信息"}},
        )

        second = supervisor.advance_task(task["task_id"])
        self.assertEqual(second["status"], "WAITING")
        self.assertEqual(second["retry_index"], 1)
        self.assertEqual(store.get_task(task["task_id"])["status"], "waiting")
        runtime_state = store.get_runtime_state(task["task_id"])
        assert runtime_state is not None
        self.assertIsNone(runtime_state["block_reason"])
        self.assertEqual(runtime_state["wait_kind"], "RETRY_BACKOFF")
        self.assertEqual(store.consecutive_planner_failures(task["task_id"]), 1)

    def test_execution_scheduler_failure_is_logged_and_loop_keeps_running(self) -> None:
        store = Storage(":memory:")
        worker = FailingThenIdleExecutionWorker()
        supervisor = RuntimeSupervisor(
            store,
            None,
            execution_workers=[worker],
            poll_interval_seconds=0.005,
        )

        with self.assertLogs("floweroll_host.runtime_supervisor", level="ERROR") as captured:
            supervisor.start()
            try:
                self.assertTrue(worker.recovered.wait(timeout=1))
            finally:
                supervisor.stop()

        self.assertGreaterEqual(worker.calls, 2)
        combined = "\n".join(captured.output)
        self.assertIn("runtime supervisor execution loop failed", combined)
        self.assertIn("error_type=RuntimeError", combined)
        self.assertIn("origin=test_runtime_supervisor.py", combined)
        self.assertNotIn("fixture execution scheduler failure", combined)


if __name__ == "__main__":
    unittest.main()
