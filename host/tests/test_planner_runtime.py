from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from floweroll_host.capabilities_v0 import REMINDER_CREATE, WEATHER_QUERY
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.planner_runtime import PlannerRuntime
from floweroll_host.storage import Storage


NOW = datetime(2026, 9, 10, 3, 40, tzinfo=ZoneInfo("Asia/Shanghai"))


def decision(data):
    return PlannerDecision.from_dict(data, [REMINDER_CREATE, WEATHER_QUERY])


class QueuePlanner:
    def __init__(self, decisions):
        self.decisions = list(decisions)
        self.contexts = []

    def decide(self, request_body, capabilities):
        payload = json.loads(request_body["input"][1]["content"])
        self.contexts.append(payload["decision_context"])
        if not self.decisions:
            raise AssertionError("unexpected Planner call")
        value = self.decisions.pop(0)
        value.validate(capabilities)
        return value


class PlannerRuntimeTests(unittest.TestCase):
    def make_runtime(self, store, decisions):
        planner = QueuePlanner(decisions)
        runtime = PlannerRuntime(
            store,
            planner,
            [REMINDER_CREATE, WEATHER_QUERY],
        )
        return runtime, planner

    def test_execute_decision_is_persisted_and_creates_one_action(self):
        store = Storage(":memory:")
        runtime, _ = self.make_runtime(
            store,
            [
                decision(
                    {
                        "decision_type": "EXECUTE",
                        "interpreted_goal_summary": "明天上午10点提醒面试",
                        "plan_update": ["创建面试提醒"],
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
                    }
                )
            ],
        )
        task = runtime.create_task(
            "明天十点提醒我面试。",
            policy_snapshot={
                "allowed_capabilities": ["reminder.create"],
                "constraints": ["No foreground takeover."],
            },
        )

        result = runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(result["task"]["status"], "active")
        self.assertEqual(result["runtime"]["phase"], "executing")
        self.assertEqual(result["action"]["action_type"], "reminder.create")
        self.assertEqual(len(store.planner_decisions(task["task_id"])), 1)
        self.assertEqual(store.planner_decisions(task["task_id"])[0]["decision_type"], "EXECUTE")
        self.assertEqual(result["runtime"]["plan"], ["创建面试提醒"])

    def test_clarify_moves_task_to_waiting_and_persists_pending_question(self):
        store = Storage(":memory:")
        runtime, _ = self.make_runtime(
            store,
            [
                decision(
                    {
                        "decision_type": "CLARIFY",
                        "interpreted_goal_summary": "用户希望下午收到面试提醒",
                        "plan_update": ["确认具体时间", "创建提醒"],
                        "action": None,
                        "on_verified": None,
                        "clarification": {
                            "question": "今天下午几点提醒你面试？",
                            "suggested_options": [],
                            "accepts_text": True,
                            "reason": "missing_exact_time",
                        },
                        "wait": None,
                        "completion": None,
                        "stop_reason": None,
                    }
                )
            ],
        )
        task = runtime.create_task("下午提醒我面试。")

        result = runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(result["task"]["status"], "waiting")
        self.assertEqual(result["runtime"]["phase"], "planning")
        self.assertEqual(result["runtime"]["wait_reason"], "user_input")
        self.assertEqual(result["runtime"]["wait_kind"], "CLARIFICATION")
        self.assertIsNotNone(result["runtime"]["wait_id"])
        pending = store.pending_clarification(task["task_id"])
        assert pending is not None
        self.assertEqual(pending["payload"]["question"], "今天下午几点提醒你面试？")

    def test_wait_decision_persists_resume_condition(self):
        store = Storage(":memory:")
        runtime, _ = self.make_runtime(
            store,
            [
                decision(
                    {
                        "decision_type": "WAIT",
                        "interpreted_goal_summary": "等到上午9:30再继续",
                        "plan_update": ["等待到指定时间", "继续任务"],
                        "action": None,
                        "on_verified": None,
                        "clarification": None,
                        "wait": {
                            "kind": "until_time",
                            "resume_at": "2026-09-10T09:30:00+08:00",
                            "condition": None,
                        },
                        "completion": None,
                        "stop_reason": None,
                    }
                )
            ],
        )
        task = runtime.create_task("九点半以后再继续。")

        result = runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(result["task"]["status"], "waiting")
        self.assertEqual(result["runtime"]["wait_reason"], "until_time")
        self.assertEqual(result["runtime"]["wait"]["resume_at"], "2026-09-10T09:30:00+08:00")

    def test_ungrounded_periodic_wait_becomes_clarification_instead_of_self_polling(self):
        store = Storage(":memory:")
        runtime, _ = self.make_runtime(
            store,
            [
                decision(
                    {
                        "decision_type": "WAIT",
                        "interpreted_goal_summary": "持续检查当前任务状态",
                        "plan_update": ["每隔一段时间重新检查"],
                        "action": None,
                        "on_verified": None,
                        "clarification": None,
                        "wait": {
                            "kind": "until_time",
                            "resume_at": "2026-09-10T14:00:00+08:00",
                            "condition": "到下一个检查时点再次检查",
                        },
                        "completion": None,
                        "stop_reason": None,
                    }
                )
            ],
        )
        task = runtime.create_task("请持续检查当前任务状态。")

        result = runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(result["decision"]["decision_type"], "CLARIFY")
        self.assertEqual(result["runtime"]["wait_reason"], "user_input")
        pending = store.pending_clarification(task["task_id"])
        self.assertIsNotNone(pending)
        self.assertEqual(pending["payload"]["reason"], "missing_wait_schedule")
        self.assertIn("多久检查一次", pending["payload"]["question"])
        self.assertEqual(len(store.planner_decisions(task["task_id"])), 1)
        self.assertEqual(store.planner_decisions(task["task_id"])[0]["decision_type"], "CLARIFY")

    def test_monitoring_with_only_broad_end_range_still_requires_cadence(self):
        store = Storage(":memory:")
        runtime, _ = self.make_runtime(
            store,
            [decision({
                "decision_type": "WAIT",
                "interpreted_goal_summary": "今天持续检查",
                "plan_update": None,
                "action": None,
                "on_verified": None,
                "clarification": None,
                "wait": {"kind": "until_time", "resume_at": "2026-09-10T14:00:00+08:00", "condition": "下次检查"},
                "completion": None,
                "stop_reason": None,
            })],
        )
        task = runtime.create_task("今天持续检查当前状态。")
        result = runtime.decide(task["task_id"], current_time=NOW)
        self.assertEqual(result["decision"]["decision_type"], "CLARIFY")
        self.assertEqual(store.pending_clarification(task["task_id"])["payload"]["reason"], "missing_wait_schedule")

    def test_user_authorized_periodic_wait_remains_wait(self):
        store = Storage(":memory:")
        runtime, _ = self.make_runtime(
            store,
            [
                decision(
                    {
                        "decision_type": "WAIT",
                        "interpreted_goal_summary": "每小时检查一次直到今晚十点",
                        "plan_update": ["等待下一次检查"],
                        "action": None,
                        "on_verified": None,
                        "clarification": None,
                        "wait": {
                            "kind": "until_time",
                            "resume_at": "2026-09-10T14:00:00+08:00",
                            "condition": "到下一次每小时检查时点",
                        },
                        "completion": None,
                        "stop_reason": None,
                    }
                )
            ],
        )
        task = runtime.create_task("每小时检查一次，直到今晚十点。")

        result = runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(result["decision"]["decision_type"], "WAIT")
        self.assertEqual(result["runtime"]["wait_reason"], "until_time")

    def test_verified_observation_is_in_second_planner_context(self):
        store = Storage(":memory:")
        runtime, planner = self.make_runtime(
            store,
            [
                decision(
                    {
                        "decision_type": "EXECUTE",
                        "interpreted_goal_summary": "若明天杭州下雨则早上8点提醒带伞",
                        "plan_update": ["查询天气", "若有雨则创建8点提醒"],
                        "action": {
                            "capability": "weather.query",
                            "arguments": {"location": "杭州", "date": "2026-09-11"},
                        },
                        "on_verified": "REPLAN",
                        "clarification": None,
                        "wait": None,
                        "completion": None,
                        "stop_reason": None,
                    }
                ),
                decision(
                    {
                        "decision_type": "EXECUTE",
                        "interpreted_goal_summary": "明天杭州有雨，早上8点提醒带伞",
                        "plan_update": ["查询天气", "创建8点带伞提醒"],
                        "action": {
                            "capability": "reminder.create",
                            "arguments": {
                                "title": "带伞",
                                "due_at": "2026-09-11T08:00:00+08:00",
                            },
                        },
                        "on_verified": "COMPLETE",
                        "clarification": None,
                        "wait": None,
                        "completion": None,
                        "stop_reason": None,
                    }
                ),
            ],
        )
        task = runtime.create_task(
            "查明天杭州天气，如果下雨就在明早8点提醒我带伞。",
            policy_snapshot={
                "allowed_capabilities": ["weather.query", "reminder.create"],
            },
        )

        first = runtime.decide(task["task_id"], current_time=NOW)
        action = first["action"]
        runtime.record_verified_observation(
            task["task_id"],
            action["action_id"],
            {
                "location": "杭州",
                "date": "2026-09-11",
                "will_rain": True,
                "summary": "有阵雨",
            },
        )
        second = runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(second["action"]["action_type"], "reminder.create")
        self.assertEqual(len(planner.contexts), 2)
        observations = planner.contexts[1]["verified_observations"]
        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["capability"], "weather.query")
        self.assertTrue(observations[0]["data"]["will_rain"])
        self.assertEqual(len(store.planner_decisions(task["task_id"])), 2)

    def test_planner_state_survives_storage_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "planner.sqlite3")
            first_store = Storage(db)
            runtime, _ = self.make_runtime(
                first_store,
                [
                    decision(
                        {
                            "decision_type": "WAIT",
                            "interpreted_goal_summary": "等待未来时间",
                            "plan_update": ["等待"],
                            "action": None,
                            "on_verified": None,
                            "clarification": None,
                            "wait": {
                                "kind": "until_time",
                                "resume_at": "2026-09-10T09:30:00+08:00",
                                "condition": None,
                            },
                            "completion": None,
                            "stop_reason": None,
                        }
                    )
                ],
            )
            task = runtime.create_task("九点半继续")
            runtime.decide(task["task_id"], current_time=NOW)

            reloaded = Storage(db)
            task_after = reloaded.get_task(task["task_id"])
            state_after = reloaded.get_runtime_state(task["task_id"])
            decisions_after = reloaded.planner_decisions(task["task_id"])

            assert task_after is not None and state_after is not None
            self.assertEqual(task_after["status"], "waiting")
            self.assertEqual(state_after["wait_reason"], "until_time")
            self.assertEqual(len(decisions_after), 1)
            self.assertEqual(decisions_after[0]["decision_type"], "WAIT")


if __name__ == "__main__":
    unittest.main()
