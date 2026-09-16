from __future__ import annotations

import json
import stat
import tempfile
import unittest
from pathlib import Path

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.feishu_cli import register_feishu_cli_capabilities
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.storage import Storage


class FeishuCLITests(unittest.TestCase):
    def fake_cli(self, root: Path, *, authenticated: bool) -> Path:
        path = root / "lark-cli"
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import json,sys\n"
            "args=sys.argv[1:]\n"
            "if args==['whoami']:\n"
            f"  print(json.dumps({{'ok': {str(authenticated)}}}))\n"
            "  raise SystemExit(0)\n"
            "print(json.dumps({'ok':True,'argv':args,'items':[{'title':'fixture'}]}))\n",
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def test_unauthenticated_cli_is_declared_but_not_planner_visible(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = CapabilityRegistry()
            executors, health = register_feishu_cli_capabilities(
                registry,
                executable=self.fake_cli(Path(tmp), authenticated=False),
            )
            self.assertFalse(health["authenticated"])
            self.assertEqual(executors, {})
            self.assertIn("feishu.calendar.agenda", registry)
            self.assertNotIn(
                "feishu.calendar.agenda",
                [cap.name for cap in registry.planner_capabilities()],
            )
            entry = registry.get("feishu.calendar.agenda")
            self.assertEqual(entry.loading, "deferred")
            self.assertEqual(entry.source.kind, "managed_cli")

    def test_authenticated_read_capability_uses_fixed_argv_and_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = CapabilityRegistry()
            executors, health = register_feishu_cli_capabilities(
                registry,
                executable=self.fake_cli(Path(tmp), authenticated=True),
            )
            self.assertTrue(health["authenticated"])
            self.assertEqual(len(executors), 6)
            store = Storage(":memory:")
            task = store.create_task("feishu-task", "搜索飞书文档", "unit", {}, status="active")
            malicious = 'roadmap; touch /tmp/should-never-run'
            store.create_action(
                action_id="feishu-action",
                task_id=task["task_id"],
                step_index=1,
                action_type="feishu.docs.search",
                payload={"query": malicious, "limit": 5},
                expected={},
                idempotency_key="feishu-task:1",
                on_verified="COMPLETE",
            )
            execution = ExecutionRuntime(store, registry.execution_adapters())
            worker = FunctionExecutionWorker(execution, registry, executors)
            worker.run_once(task["task_id"])

            self.assertEqual(store.get_task(task["task_id"])["status"], "completed")
            attempt = store.action_attempts("feishu-action")[0]
            self.assertEqual(attempt["source_kind"], "managed_cli")
            self.assertEqual(attempt["latest_outcome"], "SUCCESS")
            data = store.verified_observations(task["task_id"])[0]["data"]
            argv = data["data"]["argv"]
            self.assertEqual(argv[:4], ["docs", "+search", "--as", "user"])
            self.assertIn(malicious, argv)
            self.assertFalse(Path("/tmp/should-never-run").exists())

    def test_read_capabilities_are_bounded_semantic_surface(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = CapabilityRegistry()
            executors, _ = register_feishu_cli_capabilities(
                registry,
                executable=self.fake_cli(Path(tmp), authenticated=True),
            )
            self.assertEqual(
                set(executors),
                {
                    "feishu.calendar.agenda",
                    "feishu.contact.search",
                    "feishu.message.search",
                    "feishu.docs.search",
                    "feishu.tasks.list",
                    "feishu.mail.search",
                },
            )
            self.assertFalse(any("send" in name or "create" in name for name in executors))


if __name__ == "__main__":
    unittest.main()
