from __future__ import annotations

import stat
import tempfile
import unittest
from pathlib import Path

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.dingtalk_cli import register_dingtalk_cli_capabilities
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.storage import Storage


class DingTalkCLITests(unittest.TestCase):
    def fake_cli(self, root: Path, *, authenticated: bool) -> Path:
        path = root / "dws"
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import json,sys\n"
            "args=sys.argv[1:]\n"
            "if args[:2]==['auth','status']:\n"
            f"  print(json.dumps({{'success':True,'authenticated':{str(authenticated)}}}))\n"
            "  raise SystemExit(0)\n"
            "print(json.dumps({'success':True,'argv':args,'items':[{'title':'fixture'}]}))\n",
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def test_unauthenticated_dws_is_deferred(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = CapabilityRegistry()
            executors, health = register_dingtalk_cli_capabilities(
                registry, executable=self.fake_cli(Path(tmp), authenticated=False)
            )
            self.assertFalse(health["authenticated"])
            self.assertEqual(executors, {})
            self.assertEqual(registry.get("dingtalk.calendar.agenda").loading, "deferred")
            self.assertNotIn(
                "dingtalk.calendar.agenda",
                [cap.name for cap in registry.planner_capabilities()],
            )

    def test_authenticated_read_capability_runs_through_runtime_without_shell(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = CapabilityRegistry()
            executors, health = register_dingtalk_cli_capabilities(
                registry, executable=self.fake_cli(Path(tmp), authenticated=True)
            )
            self.assertTrue(health["authenticated"])
            self.assertEqual(len(executors), 6)
            task_id = "dingtalk-task"
            marker = Path("/tmp/dingtalk-should-never-run")
            marker.unlink(missing_ok=True)
            query = "roadmap; touch /tmp/dingtalk-should-never-run"
            store = Storage(":memory:")
            store.create_task(task_id, "搜索钉钉文档", "unit", {}, status="active")
            store.create_action(
                action_id="dingtalk-action",
                task_id=task_id,
                step_index=1,
                action_type="dingtalk.docs.search",
                payload={"query": query, "limit": 5},
                expected={},
                idempotency_key="dingtalk-task:1",
                on_verified="COMPLETE",
            )
            execution = ExecutionRuntime(store, registry.execution_adapters())
            FunctionExecutionWorker(execution, registry, executors).run_once(task_id)
            self.assertEqual(store.get_task(task_id)["status"], "completed")
            attempt = store.action_attempts("dingtalk-action")[0]
            self.assertEqual(attempt["source_kind"], "managed_cli")
            data = store.verified_observations(task_id)[0]["data"]
            self.assertIn(query, data["data"]["argv"])
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
