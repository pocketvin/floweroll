from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
from pathlib import Path

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.host_local_tools import register_host_local_capabilities
from floweroll_host.runtime_supervisor import RuntimeSupervisor
from floweroll_host.server import HostApp
from floweroll_host.storage import Storage


class HostLocalToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.registry = CapabilityRegistry()
        self.executors, self.tools = register_host_local_capabilities(
            self.registry,
            root=self.root,
        )
        self.store = Storage(":memory:")
        self.execution = ExecutionRuntime(self.store, self.registry.execution_adapters())
        self.worker = FunctionExecutionWorker(self.execution, self.registry, self.executors)

    def tearDown(self) -> None:
        self.worker.close()
        self.temp.cleanup()

    def _action(self, *, task_id: str, action_id: str, capability: str, payload: dict) -> None:
        self.store.create_task(task_id, capability, "unit", {}, status="active")
        self.store.create_action(
            action_id=action_id,
            task_id=task_id,
            step_index=1,
            action_type=capability,
            payload=payload,
            expected={},
            idempotency_key=f"{task_id}:1:{capability}",
            on_verified="COMPLETE",
        )

    def test_file_read_runs_through_attempt_and_observation(self) -> None:
        (self.root / "notes.txt").write_text("hello 小卷", encoding="utf-8")
        self._action(
            task_id="local-read-task",
            action_id="local-read-action",
            capability="file.read",
            payload={"path": "notes.txt"},
        )

        result = self.worker.run_once("local-read-task")

        self.assertIsNotNone(result)
        self.assertEqual(self.store.get_task("local-read-task")["status"], "completed")
        attempt = self.store.action_attempts("local-read-action")[0]
        self.assertEqual(attempt["source_kind"], "host_local")
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        observation = self.store.verified_observations("local-read-task")[0]["data"]
        self.assertEqual(observation["path"], "notes.txt")
        self.assertEqual(observation["content"], "hello 小卷")
        self.assertEqual(observation["source_kind"], "host_local")

    def test_write_text_is_read_back_verified_and_idempotent(self) -> None:
        first = self.tools.write_text({"path": "reports/demo.txt", "content": "完成"})
        second = self.tools.write_text({"path": "reports/demo.txt", "content": "完成"})

        self.assertTrue(first["verified"])
        self.assertFalse(first["idempotent_replay"])
        self.assertTrue(second["verified"])
        self.assertTrue(second["idempotent_replay"])
        self.assertEqual((self.root / "reports/demo.txt").read_text(encoding="utf-8"), "完成")

    def test_workspace_rejects_escape(self) -> None:
        with self.assertRaisesRegex(Exception, "escapes"):
            self.tools.file_read({"path": "../outside.txt"})

    def test_data_analyze_returns_bounded_statistics(self) -> None:
        (self.root / "sample.csv").write_text(
            "name,score,age\nA,90,20\nB,80,22\nC,100,24\n",
            encoding="utf-8",
        )

        result = self.tools.data_analyze({"path": "sample.csv"})

        self.assertEqual(result["row_count"], 3)
        self.assertEqual(result["columns"], ["name", "score", "age"])
        self.assertEqual(result["numeric_summary"]["score"]["mean"], 90.0)
        self.assertEqual(result["numeric_summary"]["age"]["median"], 22.0)

    def test_host_app_wires_function_worker_into_execution_supervisor(self) -> None:
        registry = CapabilityRegistry()
        executors, _ = register_host_local_capabilities(registry, root=self.root)
        (self.root / "wired.txt").write_text("through HostApp", encoding="utf-8")
        db_path = str(self.root / "hostapp.sqlite3")
        app = HostApp(
            db_path,
            capability_registry=registry,
            function_executors=executors,
        )
        try:
            task = app.storage.create_task(
                "hostapp-local-task",
                "读取 wired.txt",
                "unit",
                {},
                status="active",
            )
            app.storage.create_action(
                action_id="hostapp-local-action",
                task_id=task["task_id"],
                step_index=1,
                action_type="file.read",
                payload={"path": "wired.txt"},
                expected={},
                idempotency_key="hostapp-local-task:1:file.read",
                on_verified="COMPLETE",
            )
            app.supervisor.wake()
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if app.storage.get_task(task["task_id"])["status"] == "completed":
                    break
                time.sleep(0.01)
            self.assertEqual(app.storage.get_task(task["task_id"])["status"], "completed")
            observation = app.storage.verified_observations(task["task_id"])[0]["data"]
            self.assertEqual(observation["content"], "through HostApp")
            self.assertEqual(observation["source_kind"], "host_local")
        finally:
            app.close()

    def test_runtime_supervisor_executes_host_function_worker(self) -> None:
        (self.root / "data.json").write_text(
            json.dumps([{"value": 1}, {"value": 3}, {"value": 5}]),
            encoding="utf-8",
        )
        self._action(
            task_id="local-supervisor-task",
            action_id="local-supervisor-action",
            capability="data.analyze",
            payload={"path": "data.json"},
        )
        supervisor = RuntimeSupervisor(
            self.store,
            None,
            execution_workers=[self.worker],
            poll_interval_seconds=0.02,
        )
        supervisor.start()
        try:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if self.store.get_task("local-supervisor-task")["status"] == "completed":
                    break
                time.sleep(0.01)
            self.assertEqual(self.store.get_task("local-supervisor-task")["status"], "completed")
            obs = self.store.verified_observations("local-supervisor-task")[0]["data"]
            self.assertEqual(obs["numeric_summary"]["value"]["mean"], 3.0)
        finally:
            supervisor.stop()

    def test_slow_function_does_not_block_or_duplicate_independent_function_work(self) -> None:
        (self.root / "fast.txt").write_text("fast", encoding="utf-8")
        slow_started = threading.Event()
        release_slow = threading.Event()
        slow_calls = 0

        def slow_list(_):
            nonlocal slow_calls
            slow_calls += 1
            slow_started.set()
            if not release_slow.wait(timeout=2):
                raise TimeoutError("test slow function was not released")
            return {"entries": []}

        self.worker.executors["file.list"] = slow_list
        self._action(
            task_id="a-slow-function",
            action_id="a-slow-action",
            capability="file.list",
            payload={"path": "."},
        )
        self._action(
            task_id="b-fast-function",
            action_id="b-fast-action",
            capability="file.read",
            payload={"path": "fast.txt"},
        )

        try:
            started = time.monotonic()
            self.assertEqual(self.worker.sweep_once(), [])
            self.assertLess(time.monotonic() - started, 0.2)
            self.assertTrue(slow_started.wait(timeout=1))

            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                if self.store.get_task("b-fast-function")["status"] == "completed":
                    break
                time.sleep(0.01)
            self.assertEqual(self.store.get_task("b-fast-function")["status"], "completed")
            self.assertNotEqual(self.store.get_task("a-slow-function")["status"], "completed")

            for _ in range(3):
                self.worker.sweep_once()
            self.assertEqual(slow_calls, 1, "in-flight Task must not be redispatched")

            release_slow.set()
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                if self.store.get_task("a-slow-function")["status"] == "completed":
                    break
                time.sleep(0.01)
            self.assertEqual(self.store.get_task("a-slow-function")["status"], "completed")
        finally:
            release_slow.set()

    def test_function_completion_callback_wakes_owner_for_result_harvest(self) -> None:
        (self.root / "wake.txt").write_text("wake", encoding="utf-8")
        self._action(
            task_id="callback-task",
            action_id="callback-action",
            capability="file.read",
            payload={"path": "wake.txt"},
        )
        completed = threading.Event()
        self.worker.set_completion_callback(completed.set)

        self.assertEqual(self.worker.sweep_once(), [])
        self.assertTrue(completed.wait(timeout=1))

        harvested = self.worker.sweep_once()
        self.assertEqual(len(harvested), 1)
        self.assertEqual(
            harvested[0]["task"]["status"],
            "completed",
        )


if __name__ == "__main__":
    unittest.main()
