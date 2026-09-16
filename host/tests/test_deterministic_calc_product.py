from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from floweroll_host.capability_discovery import CapabilityContextSelector
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.deterministic_calc import ARGUMENT_SCHEMA, CAPABILITY_ID, execute_safe
from floweroll_host.deterministic_calc_adapter import DeterministicCalcAdapter, register_deterministic_calc_capability
from floweroll_host.host_local_tools import register_host_local_capabilities
from floweroll_host.planner_contracts import DecisionContext
from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.public_http_tools import register_public_http_capabilities
from floweroll_host.server import create_server
from floweroll_host.task_runtime import TaskRuntime


class _NoopPlanner:
    pass


class DeterministicCalcProductTests(unittest.TestCase):
    def _working_set(self, prompts: list[str]) -> dict[str, list[str]]:
        with tempfile.TemporaryDirectory(prefix="calc-product-routing-") as td, patch(
            "floweroll_host.runtime_supervisor.RuntimeSupervisor.start"
        ):
            root = Path(td)
            registry = CapabilityRegistry()
            executors = {}
            local, _ = register_host_local_capabilities(registry, root=root / "host-local")
            executors.update(local)
            calc, _ = register_deterministic_calc_capability(registry)
            executors.update(calc)
            http, _ = register_public_http_capabilities(registry)
            executors.update(http)
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "runtime.sqlite3"),
                capability_registry=registry,
                function_executors=executors,
                task_asset_root=root / "materials",
                progressive_discovery=True,
                task_runtime_factory=lambda storage: TaskRuntime(
                    storage, _NoopPlanner(), registry.planner_capabilities()
                ),
            )
            server.app.supervisor.stop()
            try:
                specs = server.app.task_runtime.capabilities
                selector = CapabilityContextSelector(
                    registry,
                    ready_specs=server.app._ready_discovery_capabilities,
                )
                result = {}
                for prompt in prompts:
                    context = DecisionContext(
                        task_id="calc-product-task",
                        raw_goal=prompt,
                        task_status="ACTIVE",
                        phase="planning",
                        current_time=datetime.now(timezone.utc).isoformat(),
                        timezone="Asia/Shanghai",
                        policy_view={
                            "allowed_capabilities": [spec.name for spec in specs],
                            "effective_task_policy_applied": True,
                        },
                        capabilities=specs,
                    )
                    selected = selector.apply(context)
                    result[prompt] = [spec.name for spec in selected.capabilities]
                return result
            finally:
                server.server_close()
                if server.app.task_assets is not None:
                    server.app.task_assets.close()

    def test_supported_natural_language_calculations_surface_calc_first(self) -> None:
        prompts = [
            "200 的 15% 是多少？",
            "1280 / 16",
            "2026-09-12 往后 10 天是哪一天？",
            "东京 2026-09-12 09:00 换算成上海时间",
            "1.25 km 换算成 m",
            "10 kg 等于多少 g？",
            "32 华氏度换算成摄氏度",
            "东京 2026-09-12 09:00 到 10:30 相差多久？",
        ]
        working_sets = self._working_set(prompts)
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                self.assertEqual(working_sets[prompt][0], CAPABILITY_ID)
                self.assertLessEqual(len(working_sets[prompt]), 8)

    def test_external_fuzzy_and_unsupported_date_diff_do_not_surface_calc(self) -> None:
        prompts = [
            "从 2026-09-01 到 2026-09-12 相差多少天？",
            "100 美元现在等于多少人民币？",
            "帮我算一下杭州到上海的驾车距离",
            "工资 20000 元应该交多少税？",
            "明天往后 10 天是哪一天？",
        ]
        working_sets = self._working_set(prompts)
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                self.assertNotIn(CAPABILITY_ID, working_sets[prompt])

    def test_planner_schema_explains_current_production_contract(self) -> None:
        properties = ARGUMENT_SCHEMA["properties"]
        self.assertIn("date_add", properties["operation"]["description"])
        self.assertIn("time_difference", properties["operation"]["description"])
        self.assertIn("timezone_convert", properties["operation"]["description"])
        self.assertIn("必填", properties["scale"]["description"])
        self.assertIn("YYYY-MM-DD", properties["date"]["description"])
        self.assertIn("IANA", properties["timezone"]["description"])
        self.assertIn("celsius/fahrenheit/kelvin", properties["from_unit"]["description"])

    def test_verified_results_have_natural_operation_aware_summaries(self) -> None:
        cases = [
            (
                {"operation": "percent_of", "value": "200", "percent": "15"},
                "200 的 15% 是 30。",
            ),
            (
                {"operation": "divide", "left": "1280", "right": "16", "scale": 0},
                "1280 ÷ 16 = 80。",
            ),
            (
                {"operation": "date_add", "date": "2026-09-12", "amount": 10, "date_unit": "days"},
                "2026-09-12 往后 10 天是 2026-09-22。",
            ),
            (
                {
                    "operation": "time_difference",
                    "start_datetime": "2026-09-12T09:00:00",
                    "end_datetime": "2026-09-12T10:30:00",
                    "timezone": "Asia/Tokyo",
                },
                "东京时间 2026-09-12 09:00 到 2026-09-12 10:30 的时间差是 1 小时 30 分钟。",
            ),
            (
                {
                    "operation": "timezone_convert",
                    "datetime": "2026-09-12T09:00:00",
                    "from_timezone": "Asia/Tokyo",
                    "to_timezone": "Asia/Shanghai",
                },
                "2026-09-12 09:00（东京）换算到上海是 2026-09-12 08:00。",
            ),
            (
                {"operation": "unit_convert", "value": "1.25", "from_unit": "km", "to_unit": "m", "scale": 0},
                "1.25 km 换算为 1250 m。",
            ),
            (
                {
                    "operation": "unit_convert",
                    "value": "32",
                    "from_unit": "fahrenheit",
                    "to_unit": "celsius",
                    "scale": 2,
                },
                "32 ℉ 换算为 0.00 ℃。",
            ),
        ]
        adapter = DeterministicCalcAdapter()
        for arguments, expected in cases:
            with self.subTest(operation=arguments["operation"]):
                output = execute_safe(arguments)
                self.assertTrue(output["ok"], output)
                verified = adapter.verify_result(
                    {"payload": arguments}, success=True, output=output, error=None
                )
                self.assertEqual(verified.outcome, "SUCCESS")
                self.assertEqual(verified.direct_completion_summary, expected)
                self.assertEqual(
                    verified.observation["verification"]["method"],
                    "deterministic_recompute",
                )

    def test_public_progress_copy_is_semantic_and_natural(self) -> None:
        self.assertEqual(capability_label(CAPABILITY_ID), "确定性计算")
        self.assertEqual(
            capability_activity_title(CAPABILITY_ID, "active"),
            "正在计算并核对结果",
        )
        self.assertEqual(
            capability_activity_title(CAPABILITY_ID, "complete"),
            "计算结果已核对",
        )


if __name__ == "__main__":
    unittest.main()
