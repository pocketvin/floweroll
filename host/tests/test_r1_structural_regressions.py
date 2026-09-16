from __future__ import annotations

import json
import unittest

from floweroll_host.presentation import project_timeline_projection
from floweroll_host.storage import Storage


class R1StructuralRegressionTests(unittest.TestCase):
    def test_explicit_task_scoped_user_turn_stays_on_task_a(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("task-a", "整理面试资料", "unit", {}, status="active")

        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id="detail-turn-1",
            event_type="USER_TURN",
            source="user",
            target_type="TASK",
            target_id=task["task_id"],
            payload={"content": {"kind": "text", "text": "把重点放到 Runtime"}, "reply_context": None},
        )

        all_tasks = store.list_tasks(bucket="all", limit=100)["items"]
        self.assertEqual([row["task_id"] for row in all_tasks], ["task-a"])
        events = store.inbox_events("task-a")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event_type"], "USER_TURN")
        view = store.get_task_view("task-a")
        self.assertEqual(view["timeline"][-1]["kind"], "USER_INPUT")
        self.assertEqual(view["timeline"][-1]["summary"], "把重点放到 Runtime")

    def test_history_cursor_pagination_reads_more_than_fifty_without_loss(self) -> None:
        store = Storage(":memory:")
        expected = set()
        for index in range(65):
            task_id = f"history-{index:03d}"
            expected.add(task_id)
            store.create_task(task_id, f"历史任务 {index}", "unit", {}, status="completed")

        first = store.list_tasks(bucket="history", limit=50)
        self.assertEqual(len(first["items"]), 50)
        self.assertIsNotNone(first["next_cursor"])

        second = store.list_tasks(bucket="history", cursor=first["next_cursor"], limit=50)
        self.assertEqual(len(second["items"]), 15)
        self.assertIsNone(second["next_cursor"])

        loaded = {row["task_id"] for row in first["items"] + second["items"]}
        self.assertEqual(loaded, expected)

    def test_public_timeline_projection_is_payload_allowlist_not_field_replacement(self) -> None:
        title, summary, payload = project_timeline_projection(
            kind="TOOL_ACTIVITY",
            presentation_state="COMPLETE",
            title="provider.internal.execute",
            summary=(
                'booking_status=ready arguments_json={"source_urls":["https://example.com"],'
                '"action_id":"123e4567-e89b-12d3-a456-426614174000"}'
            ),
            payload={
                "booking_status": "ready",
                "arguments_json": {"foo": "bar"},
                "source_urls": ["https://example.com"],
                "action_id": "123e4567-e89b-12d3-a456-426614174000",
            },
        )
        serialized = json.dumps({"title": title, "summary": summary, "payload": payload}, ensure_ascii=False)
        self.assertEqual(payload, {})
        for forbidden in ("booking_status", "arguments_json", "source_urls", "action_id", "provider.internal.execute"):
            self.assertNotIn(forbidden, serialized)

    def test_completion_keeps_raw_runtime_result_but_projects_safe_public_summary(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("completion-projection", "生成报告", "unit", {}, status="active")
        basis = store.planner_basis(task["task_id"])
        store.reserve_planner_call(task["task_id"], max_calls=10)
        raw_summary = (
            "booking_status ready; Observation 23; arguments_json; source_urls; "
            "action_id=123e4567-e89b-12d3-a456-426614174000"
        )
        decision = {
            "decision_type": "COMPLETE",
            "interpreted_goal_summary": "报告已经准备完成",
            "plan_update": None,
            "action": None,
            "on_verified": None,
            "clarification": None,
            "wait": None,
            "completion": {"summary": raw_summary},
            "stop_reason": None,
            "cancellation": None,
            "state_update": {"pending_clarification": None, "current_task_brief": None},
        }
        store.apply_planner_decision_atomic(
            task_id=task["task_id"],
            expected_runtime_revision=basis["runtime"]["runtime_revision"],
            basis_inbox_seq=basis["basis_inbox_seq"],
            decision_id="completion-projection-decision",
            decision=decision,
        )

        raw = store.get_task(task["task_id"])
        self.assertEqual(raw["result"]["summary"], raw_summary)
        view = store.get_task_view(task["task_id"])
        serialized = json.dumps(view, ensure_ascii=False)
        for forbidden in ("booking_status", "Observation 23", "arguments_json", "source_urls", "action_id"):
            self.assertNotIn(forbidden, serialized)
        self.assertEqual(view["result"]["summary"], "任务已完成，具体结果和产物可以在本页查看。")


if __name__ == "__main__":
    unittest.main()
