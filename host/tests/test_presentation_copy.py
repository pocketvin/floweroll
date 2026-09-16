from __future__ import annotations

import json
import unittest

from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.storage import Storage


class PresentationCopyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.store = Storage(":memory:")

    def create_task(self, task_id: str = "presentation-copy-task") -> dict:
        return self.store.create_task(
            task_id,
            "看一下我明天下午13点到18点空不空",
            "unit",
            {"allowed_capabilities": ["calendar.freebusy"]},
            status="active",
        )

    def test_unknown_capability_never_falls_back_to_internal_identifier(self) -> None:
        self.assertEqual(capability_label("provider.internal_name"), "处理下一步")
        self.assertEqual(
            capability_activity_title("provider.internal_name", "active"),
            "正在处理下一步",
        )

    def test_new_host_and_external_capabilities_have_product_copy(self) -> None:
        expected = {
            "file.read": ("读取文件", "正在读取文件"),
            "image.inspect": ("查看图片信息", "正在查看图片信息"),
            "image.transform": ("处理图片", "正在处理图片"),
            "document.parse": ("解析文档", "正在解析文档"),
            "data.analyze": ("分析数据", "正在分析数据"),
            "web.fetch": ("读取网络资料", "正在读取网络资料"),
            "image.ocr": ("识别图片文字", "正在识别图片文字"),
            "pdf.extract_text": ("提取 PDF 文本", "正在提取 PDF 文本"),
            "docs.query": ("查询技术文档", "正在查询技术文档"),
            "feishu.docs.search": ("搜索飞书文档", "正在搜索飞书文档"),
            "dingtalk.docs.search": ("搜索钉钉文档", "正在搜索钉钉文档"),
        }
        for capability, (label, active) in expected.items():
            with self.subTest(capability=capability):
                self.assertEqual(capability_label(capability), label)
                self.assertEqual(capability_activity_title(capability, "active"), active)

    def test_planner_call_has_live_public_thinking_activity(self) -> None:
        task = self.create_task()
        cursor_before = self.store.get_task_view(task["task_id"])["presentation_cursor"]

        call_number = self.store.reserve_planner_call(task["task_id"], max_calls=10)
        self.assertEqual(call_number, 1)

        view = self.store.get_task_view(task["task_id"])
        thinking = [item for item in view["timeline"] if item["kind"] == "AGENT_ACTIVITY"]
        self.assertEqual(len(thinking), 1)
        self.assertEqual(thinking[0]["presentation_state"], "ACTIVE")
        self.assertEqual(thinking[0]["title"], "小卷正在思考")

        events = self.store.presentation_events_after(task["task_id"], cursor_before)
        self.assertEqual(events[-1]["payload"]["kind"], "AGENT_ACTIVITY")
        self.assertEqual(events[-1]["payload"]["presentation_state"], "ACTIVE")
        self.assertEqual(events[-1]["payload"]["title"], "小卷正在思考")

    def test_calendar_action_uses_product_copy_and_public_projection_hides_capability_id(self) -> None:
        task = self.create_task("calendar-copy-task")
        basis = self.store.planner_basis(task["task_id"])
        self.store.reserve_planner_call(task["task_id"], max_calls=10)

        decision = {
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": "检查明天下午是否空闲",
            "plan_update": ["查看日历空闲情况"],
            "action": {
                "capability": "calendar.freebusy",
                "arguments": {
                    "start_at": "2026-09-12T13:00:00+08:00",
                    "end_at": "2026-09-12T18:00:00+08:00",
                },
            },
            "on_verified": "REPLAN",
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
            "cancellation": None,
            "state_update": {
                "pending_clarification": None,
                "current_task_brief": None,
            },
        }
        self.store.apply_planner_decision_atomic(
            task_id=task["task_id"],
            expected_runtime_revision=basis["runtime"]["runtime_revision"],
            basis_inbox_seq=basis["basis_inbox_seq"],
            decision_id="calendar-copy-decision",
            decision=decision,
            action_id="calendar-copy-action",
        )

        view = self.store.get_task_view(task["task_id"])
        titles = [item["title"] for item in view["timeline"]]
        self.assertIn("正在准备查看你的日历", titles)
        self.assertFalse(any("calendar.freebusy" in title for title in titles))

        thinking = [item for item in view["timeline"] if item["kind"] == "AGENT_ACTIVITY"]
        self.assertEqual(thinking[0]["presentation_state"], "COMPLETE")

        public_steps = [item for item in view["timeline"] if item["kind"] == "PUBLIC_WORKLOG" and item["title"].startswith("下一步：")]
        self.assertEqual(len(public_steps), 1)
        self.assertIn("查看你的日历", public_steps[0]["title"])
        self.assertNotIn("calendar.freebusy", public_steps[0]["title"] + (public_steps[0].get("summary") or ""))
        self.assertIn("不展示模型私有推理", public_steps[0]["summary"])

        tool = next(item for item in view["timeline"] if item["kind"] == "TOOL_ACTIVITY")
        self.assertNotIn("capability", tool["payload"])

        events = self.store.presentation_events_after(task["task_id"], 0)
        serialized = json.dumps(events, ensure_ascii=False)
        self.assertNotIn('"capability":"calendar.freebusy"', serialized)
        self.assertNotIn("calendar.freebusy已完成", serialized)


if __name__ == "__main__":
    unittest.main()
