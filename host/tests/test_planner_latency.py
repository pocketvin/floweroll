from __future__ import annotations

import time
import unittest
from typing import Iterable

from floweroll_host.alarm_adapter import AlarmCreateAdapter
from floweroll_host.calendar_adapter import CalendarQueryAdapter
from floweroll_host.calendar_create_adapter import CalendarCreateAdapter
from floweroll_host.capabilities_v0 import ALARM_CREATE, CALENDAR_CREATE, CALENDAR_QUERY
from floweroll_host.deterministic_calc import (
    ARGUMENT_SCHEMA,
    CAPABILITY_DESCRIPTION,
    CAPABILITY_ID,
    execute_safe,
)
from floweroll_host.deterministic_calc_adapter import DeterministicCalcAdapter
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.latency_report import task_latency_breakdown
from floweroll_host.planner_contracts import CapabilitySpec, PlannerDecision
from floweroll_host.storage import Storage
from floweroll_host.task_runtime import TaskRuntime


CALC_SPEC = CapabilitySpec(
    name=CAPABILITY_ID,
    description=CAPABILITY_DESCRIPTION,
    arguments_schema=ARGUMENT_SCHEMA,
)


class ControlledPlanner:
    """Deterministic Planner with controlled per-call latency for flow tests."""

    def __init__(self, decisions: Iterable[PlannerDecision], *, delay_seconds: float = 0.01):
        self.decisions = list(decisions)
        self.delay_seconds = delay_seconds
        self.calls = 0

    def decide(self, request, capabilities):
        self.calls += 1
        time.sleep(self.delay_seconds)
        if not self.decisions:
            raise AssertionError("unexpected Planner call")
        decision = self.decisions.pop(0)
        decision.validate(capabilities)
        return decision


def execute_decision(
    specs: list[CapabilitySpec],
    capability: str,
    arguments: dict,
    *,
    on_verified: str,
    summary: str,
) -> PlannerDecision:
    return PlannerDecision.from_dict(
        {
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": summary,
            "plan_update": None,
            "action": {"capability": capability, "arguments": arguments},
            "on_verified": on_verified,
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
            "cancellation": None,
            "state_update": None,
        },
        specs,
    )


def complete_decision(specs: list[CapabilitySpec], summary: str) -> PlannerDecision:
    return PlannerDecision.from_dict(
        {
            "decision_type": "COMPLETE",
            "interpreted_goal_summary": summary,
            "plan_update": None,
            "action": None,
            "on_verified": None,
            "clarification": None,
            "wait": None,
            "completion": {"summary": summary},
            "stop_reason": None,
            "cancellation": None,
            "state_update": None,
        },
        specs,
    )


CALENDAR_ARGS = {
    "start_at": "2026-09-13T00:00:00+08:00",
    "end_at": "2026-09-14T00:00:00+08:00",
    "max_results": 20,
}
CALENDAR_OUTPUT = {
    "start_at": CALENDAR_ARGS["start_at"],
    "end_at": CALENDAR_ARGS["end_at"],
    "events": [
        {
            "event_id": "event-1",
            "title": "面试",
            "start_at": "2026-09-13T02:00:00Z",
            "end_at": "2026-09-13T03:00:00Z",
            "all_day": False,
            "location": "杭州",
            # Latency tests must return the same management snapshot as the
            # production EventKit executor, not the earlier read-only shape.
            "revision": "a" * 64,
            "time_zone": "Asia/Shanghai",
            "calendar_id": "calendar-1",
            "calendar_name": "工作",
            "calendar_writable": True,
            "has_recurrence": False,
            "is_detached": False,
            "has_attendees": False,
            "has_organizer": False,
            "last_modified_at": "2026-09-12T05:00:00Z",
            "update_eligible": True,
            "remove_eligible": True,
        }
    ],
    "truncated": False,
    "verified": True,
}


def _run_calendar_action(store: Storage, task_id: str, runtime: ExecutionRuntime) -> None:
    action = store.get_open_action(task_id)
    assert action is not None
    dispatch = runtime.next_action(task_id, source_kind="ios")
    assert dispatch is not None
    runtime.accept_result(
        task_id=task_id,
        action_id=action["action_id"],
        attempt_id=dispatch["attempt_id"],
        success=True,
        output=CALENDAR_OUTPUT,
    )


class PlannerLatencyAcceptanceTests(unittest.TestCase):
    def test_s1_simple_alarm_uses_one_planner_call_and_completes_after_verification(self) -> None:
        specs = [ALARM_CREATE]
        planner = ControlledPlanner([
            execute_decision(
                specs,
                "alarm.create",
                {"title": "测试", "schedule": {"kind": "fixed", "fire_at": "2026-09-12T19:00:20+08:00"}, "sound": "default"},
                on_verified="COMPLETE",
                summary="20秒后设置闹钟",
            )
        ])
        store = Storage(":memory:")
        task_runtime = TaskRuntime(store, planner, specs)
        task = task_runtime.create_task("20秒后提醒我")
        task_runtime.decide(task["task_id"])
        execution = ExecutionRuntime(store, [AlarmCreateAdapter()], capability_specs=specs)
        action = store.get_open_action(task["task_id"])
        assert action is not None
        dispatch = execution.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        execution.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "alarm_id": "controlled-alarm",
                "idempotency_marker": action["idempotency_key"],
                "verified": True,
                "native_schedule_verified": True,
                "title": "测试",
                "sound": "default",
                "schedule": {"kind": "fixed", "fire_at": "2026-09-12T19:00:20+08:00"},
            },
        )
        report = task_latency_breakdown(store, task["task_id"])
        self.assertEqual(planner.calls, 1)
        self.assertEqual(report["planner_calls"], 1)
        self.assertEqual(report["final_status"], "completed")

    def test_s2_single_tool_query_can_complete_in_one_call_without_complete_only_replan(self) -> None:
        specs = [CALENDAR_QUERY]
        planner = ControlledPlanner([
            execute_decision(
                specs,
                "calendar.query",
                CALENDAR_ARGS,
                on_verified="COMPLETE",
                summary="查看明天日程",
            )
        ])
        store = Storage(":memory:")
        task_runtime = TaskRuntime(store, planner, specs)
        task = task_runtime.create_task("看看明天有什么日程")
        task_runtime.decide(task["task_id"])
        execution = ExecutionRuntime(store, [CalendarQueryAdapter()], capability_specs=specs)
        _run_calendar_action(store, task["task_id"], execution)
        report = task_latency_breakdown(store, task["task_id"])
        self.assertLessEqual(planner.calls, 2)
        self.assertEqual(planner.calls, 1)
        self.assertEqual(report["capability_search_count"], 0)
        self.assertEqual(report["final_status"], "completed")

    def test_s3_tool_plus_semantic_summary_uses_exactly_two_planner_calls(self) -> None:
        specs = [CALENDAR_QUERY]
        planner = ControlledPlanner([
            execute_decision(
                specs,
                "calendar.query",
                CALENDAR_ARGS,
                on_verified="REPLAN",
                summary="读取明天日程后再总结",
            ),
            complete_decision(specs, "明天10点有一场杭州面试。"),
        ])
        store = Storage(":memory:")
        task_runtime = TaskRuntime(store, planner, specs)
        task = task_runtime.create_task("查询明天日程然后给我总结")
        task_runtime.decide(task["task_id"])
        execution = ExecutionRuntime(store, [CalendarQueryAdapter()], capability_specs=specs)
        _run_calendar_action(store, task["task_id"], execution)
        task_runtime.decide(task["task_id"])
        report = task_latency_breakdown(store, task["task_id"])
        self.assertEqual(planner.calls, 2)
        self.assertEqual(report["planner_calls"], 2)
        self.assertEqual(report["capability_search_count"], 0)
        self.assertEqual(report["final_status"], "completed")

    def test_s4_deterministic_calculate_is_not_amplified_by_replanning(self) -> None:
        specs = [CALC_SPEC]
        arguments = {"operation": "percent_of", "value": "200", "percent": "15"}
        planner = ControlledPlanner([
            execute_decision(
                specs,
                CAPABILITY_ID,
                arguments,
                on_verified="COMPLETE",
                summary="计算200的15%",
            )
        ])
        store = Storage(":memory:")
        task_runtime = TaskRuntime(store, planner, specs)
        task = task_runtime.create_task("计算 200×15%")
        task_runtime.decide(task["task_id"])
        execution = ExecutionRuntime(store, [DeterministicCalcAdapter()], capability_specs=specs)
        action = store.get_open_action(task["task_id"])
        assert action is not None
        dispatch = execution.next_action(task["task_id"], source_kind="host_local")
        assert dispatch is not None
        execution.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output=execute_safe(arguments),
        )
        report = task_latency_breakdown(store, task["task_id"])
        self.assertEqual(planner.calls, 1)
        self.assertEqual(report["planner_calls"], 1)
        self.assertEqual(report["final_status"], "completed")

    def test_s5_complex_task_still_supports_real_multi_step_loop(self) -> None:
        specs = [CALENDAR_QUERY, CALC_SPEC]
        calc_args = {"operation": "percent_of", "value": "200", "percent": "15"}
        planner = ControlledPlanner([
            execute_decision(
                specs,
                "calendar.query",
                CALENDAR_ARGS,
                on_verified="REPLAN",
                summary="先读取日历",
            ),
            execute_decision(
                specs,
                CAPABILITY_ID,
                calc_args,
                on_verified="REPLAN",
                summary="再做确定性计算",
            ),
            complete_decision(specs, "已完成日历读取、计算和综合结果。"),
        ])
        store = Storage(":memory:")
        task_runtime = TaskRuntime(store, planner, specs)
        execution = ExecutionRuntime(
            store,
            [CalendarQueryAdapter(), DeterministicCalcAdapter()],
            capability_specs=specs,
        )
        task = task_runtime.create_task("查询明天日程，再计算200的15%，最后综合告诉我")
        task_runtime.decide(task["task_id"])
        _run_calendar_action(store, task["task_id"], execution)
        task_runtime.decide(task["task_id"])
        action = store.get_open_action(task["task_id"])
        assert action is not None
        dispatch = execution.next_action(task["task_id"], source_kind="host_local")
        assert dispatch is not None
        execution.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output=execute_safe(calc_args),
        )
        task_runtime.decide(task["task_id"])
        report = task_latency_breakdown(store, task["task_id"])
        self.assertEqual(planner.calls, 3)
        self.assertEqual(report["tool_count"], 2)
        self.assertEqual(report["final_status"], "completed")

    def test_s6_failure_needs_user_and_unknown_never_fake_complete(self) -> None:
        with self.subTest(case="tool_failure"):
            specs = [CALENDAR_QUERY]
            planner = ControlledPlanner([
                execute_decision(
                    specs,
                    "calendar.query",
                    CALENDAR_ARGS,
                    on_verified="COMPLETE",
                    summary="读取日历",
                )
            ])
            store = Storage(":memory:")
            task_runtime = TaskRuntime(store, planner, specs)
            task = task_runtime.create_task("看看明天日程")
            task_runtime.decide(task["task_id"])
            execution = ExecutionRuntime(store, [CalendarQueryAdapter()], capability_specs=specs)
            action = store.get_open_action(task["task_id"])
            assert action is not None
            dispatch = execution.next_action(task["task_id"], source_kind="ios")
            assert dispatch is not None
            execution.accept_result(
                task_id=task["task_id"],
                action_id=action["action_id"],
                attempt_id=dispatch["attempt_id"],
                success=False,
                output={},
                error="calendar unavailable",
            )
            self.assertEqual(planner.calls, 1)
            self.assertNotEqual(store.get_task(task["task_id"])["status"], "completed")

        with self.subTest(case="needs_user"):
            specs = [CALENDAR_CREATE]
            args = {
                "title": "面试",
                "start_at": "2026-09-13T15:00:00+08:00",
                "end_at": "2026-09-13T16:00:00+08:00",
                "time_zone": "Asia/Shanghai",
            }
            planner = ControlledPlanner([
                execute_decision(
                    specs,
                    "calendar.create",
                    args,
                    on_verified="COMPLETE",
                    summary="添加面试日程",
                )
            ])
            store = Storage(":memory:")
            task_runtime = TaskRuntime(store, planner, specs)
            task = task_runtime.create_task("明天下午三点添加面试日程")
            task_runtime.decide(task["task_id"])
            execution = ExecutionRuntime(store, [CalendarCreateAdapter()], capability_specs=specs)
            self.assertIsNone(execution.next_action(task["task_id"], source_kind="ios"))
            self.assertEqual(store.get_task(task["task_id"])["status"], "waiting")
            self.assertIsNotNone(store.pending_action_input_for_action(store.get_open_action(task["task_id"])["action_id"]))
            self.assertEqual(planner.calls, 1)

        with self.subTest(case="unknown"):
            specs = [ALARM_CREATE]
            planner = ControlledPlanner([
                execute_decision(
                    specs,
                    "alarm.create",
                    {"title": "测试", "schedule": {"kind": "fixed", "fire_at": "2026-09-12T19:00:20+08:00"}, "sound": "default"},
                    on_verified="COMPLETE",
                    summary="设置闹钟",
                )
            ])
            store = Storage(":memory:")
            task_runtime = TaskRuntime(store, planner, specs)
            task = task_runtime.create_task("20秒后提醒我")
            task_runtime.decide(task["task_id"])
            execution = ExecutionRuntime(store, [AlarmCreateAdapter()], capability_specs=specs)
            action = store.get_open_action(task["task_id"])
            assert action is not None
            dispatch = execution.next_action(task["task_id"], source_kind="ios")
            assert dispatch is not None
            unknown = execution.mark_current_attempt_unknown(
                task_id=task["task_id"],
                action_id=action["action_id"],
                reason="device response lost",
            )
            self.assertEqual(unknown["attempt"]["latest_outcome"], "UNKNOWN")
            self.assertEqual(store.get_action(action["action_id"])["status"], "reconciling")
            self.assertNotEqual(store.get_task(task["task_id"])["status"], "completed")
            self.assertEqual(planner.calls, 1)


if __name__ == "__main__":
    unittest.main()
