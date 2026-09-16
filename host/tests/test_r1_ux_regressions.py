from __future__ import annotations

import unittest

from floweroll_host.capability_discovery import CapabilityContextSelector, SEARCH_ID, register_capability_discovery
from floweroll_host.capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from floweroll_host.function_tool_adapter import FunctionToolAdapter
from floweroll_host.planner_contracts import CapabilitySpec, DecisionContext
from floweroll_host.presentation import project_public_result, project_timeline_projection
from floweroll_host.storage import Storage


def add_spec(registry: CapabilityRegistry, name: str, description: str) -> CapabilitySpec:
    spec = CapabilitySpec(
        name=name,
        description=description,
        arguments_schema={"type": "object", "properties": {}, "required": [], "additionalProperties": False},
    )
    registry.register(
        RegisteredCapability(
            spec=spec,
            adapter=FunctionToolAdapter(capability_id=name, source_kind="host_local"),
            source=CapabilitySourceTarget(kind="host_local"),
        )
    )
    return spec


class R1UXRegressionTests(unittest.TestCase):
    def test_calendar_report_goal_surfaces_read_and_report_tools(self) -> None:
        registry = CapabilityRegistry()
        storage = Storage(":memory:")
        specs: list[CapabilitySpec] = []
        register_capability_discovery(registry, storage, lambda: specs)
        search = registry.get(SEARCH_ID).spec
        specs.append(search)
        for index in range(20):
            specs.append(add_spec(registry, f"files.utility_{index}", "通用文件处理"))
        calendar_query = add_spec(registry, "calendar.query", "只读查询指定时间窗口的日程安排")
        calendar_create = add_spec(registry, "calendar.create", "创建新的日历日程")
        publish = add_spec(registry, "deliverables.publish", "生成并发布HTML或报告成果")
        specs.extend([calendar_query, calendar_create, publish])
        goal = "查询我明天、后天和大后天的日程，并生成一个HTML报告，不要创建或者修改日程。"
        context = DecisionContext(
            task_id="r1",
            raw_goal=goal,
            task_status="ACTIVE",
            phase="planning",
            current_time="2026-09-11T12:00:00+00:00",
            timezone="Asia/Shanghai",
            capabilities=specs,
            policy_view={"allowed_capabilities": [spec.name for spec in specs]},
        )
        selected = CapabilityContextSelector(registry).apply(context)
        names = [spec.name for spec in selected.capabilities]
        self.assertIn("calendar.query", names)
        self.assertIn("deliverables.publish", names)
        self.assertNotIn("calendar.create", names)
        self.assertIn(SEARCH_ID, names)
        limit_schema = search.arguments_schema["properties"]["limit"]
        self.assertEqual(limit_schema["minimum"], 1)
        self.assertEqual(limit_schema["maximum"], 6)

    def test_public_projection_hides_runtime_vocabulary(self) -> None:
        title, summary, payload = project_timeline_projection(
            kind="RESULT",
            presentation_state="COMPLETE",
            title="任务已完成",
            summary=(
                "已通过 calendar.query 获取 Observation 23，并依据 source_ids 和 action_id "
                "生成 deliverables.publish 的HTML报告。"
            ),
            payload={"source_ids": ["23"], "action_id": "internal"},
        )
        self.assertEqual(title, "任务已完成")
        self.assertEqual(summary, "任务已完成，具体结果和产物可以在本页查看。")
        self.assertEqual(payload, {})
        public_result = project_public_result({"summary": "booking_status=ready; Observation 23"})
        self.assertEqual(public_result, {"summary": "任务已完成，具体结果和产物可以在本页查看。"})



if __name__ == "__main__":
    unittest.main()
