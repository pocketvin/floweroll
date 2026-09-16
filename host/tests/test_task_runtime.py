from __future__ import annotations

import json
import sqlite3
import threading
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

from floweroll_host.capabilities_v0 import REMINDER_CREATE, WEATHER_QUERY
from floweroll_host.planner_contracts import CapabilitySpec, PlannerDecision
from floweroll_host.storage import (
    InvalidPlannerTransitionError,
    PlannerBudgetExceededError,
    Storage,
)
from floweroll_host.task_capability_policy import TASK_DENIED, TaskCapabilityDeniedError
from floweroll_host.task_runtime import PlannerAlreadyRunningError, TaskRuntime
from floweroll_host.transition_engine import RuntimeSnapshot, TransitionEngine


NOW = datetime(2026, 9, 10, 18, 30, tzinfo=ZoneInfo("Asia/Shanghai"))
CAPABILITIES = [REMINDER_CREATE, WEATHER_QUERY]
GENERIC_READ = CapabilitySpec(
    "generic.read",
    "Read project records without side effects",
    {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
)
GENERIC_WRITE = CapabilitySpec(
    "generic.write",
    "Write project records",
    {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
)
GENERIC_CAPABILITIES = [GENERIC_READ, GENERIC_WRITE]


def generic_execute_decision(capability: str, *, on_verified: str = "REPLAN") -> PlannerDecision:
    return PlannerDecision.from_dict(
        {
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": "process project records",
            "plan_update": None,
            "action": {"capability": capability, "arguments": {}},
            "on_verified": on_verified,
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
            "cancellation": None,
            "state_update": None,
        },
        GENERIC_CAPABILITIES,
    )


def make_decision(**overrides) -> PlannerDecision:
    data = {
        "decision_type": "COMPLETE",
        "interpreted_goal_summary": "任务已满足",
        "plan_update": None,
        "action": None,
        "on_verified": None,
        "clarification": None,
        "wait": None,
        "completion": {"summary": "完成"},
        "stop_reason": None,
        "state_update": None,
    }
    data.update(overrides)
    return PlannerDecision.from_dict(data, CAPABILITIES)


def reminder_decision(hour: int, *, state_update=None) -> PlannerDecision:
    return make_decision(
        decision_type="EXECUTE",
        interpreted_goal_summary=f"明天{hour}点提醒面试",
        plan_update=["创建面试提醒"],
        action={
            "capability": "reminder.create",
            "arguments": {
                "title": "面试",
                "due_at": f"2026-09-11T{hour:02d}:00:00+08:00",
            },
        },
        on_verified="COMPLETE",
        completion=None,
        state_update=state_update,
    )


class QueuePlanner:
    def __init__(self, decisions):
        self.decisions = list(decisions)
        self.contexts = []

    def decide(self, request_body, capabilities):
        payload = json.loads(request_body["input"][1]["content"])
        self.contexts.append(payload["decision_context"])
        if not self.decisions:
            raise AssertionError("unexpected Planner call")
        decision = self.decisions.pop(0)
        decision.validate(capabilities)
        return decision


class BlockingStalePlanner:
    def __init__(self, first, second):
        self.first = first
        self.second = second
        self.started = threading.Event()
        self.release = threading.Event()
        self.contexts = []
        self.calls = 0

    def decide(self, request_body, capabilities):
        payload = json.loads(request_body["input"][1]["content"])
        self.contexts.append(payload["decision_context"])
        self.calls += 1
        if self.calls == 1:
            self.started.set()
            if not self.release.wait(timeout=3):
                raise RuntimeError("test planner release timed out")
            return self.first
        return self.second


class BlockingTwoRoundPlanner:
    def __init__(self, first, second):
        self.first = first
        self.second = second
        self.first_started = threading.Event()
        self.first_release = threading.Event()
        self.second_started = threading.Event()
        self.second_release = threading.Event()
        self.calls = 0

    def decide(self, request_body, capabilities):
        self.calls += 1
        if self.calls == 1:
            self.first_started.set()
            if not self.first_release.wait(timeout=3):
                raise RuntimeError("first planner release timed out")
            self.first.validate(capabilities)
            return self.first
        if self.calls == 2:
            self.second_started.set()
            if not self.second_release.wait(timeout=3):
                raise RuntimeError("second planner release timed out")
            self.second.validate(capabilities)
            return self.second
        raise AssertionError("unexpected Planner call")


class BlockingPlanner:
    def __init__(self, decision):
        self.decision = decision
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = 0

    def decide(self, request_body, capabilities):
        self.calls += 1
        self.started.set()
        if not self.release.wait(timeout=3):
            raise RuntimeError("test planner release timed out")
        return self.decision


class ErrorPlanner:
    def decide(self, request_body, capabilities):
        raise RuntimeError("planner transport unavailable")


class BlockingErrorThenDecisionPlanner:
    def __init__(self, second):
        self.second = second
        self.started = threading.Event()
        self.release = threading.Event()
        self.contexts = []
        self.calls = 0

    def decide(self, request_body, capabilities):
        payload = json.loads(request_body["input"][1]["content"])
        self.contexts.append(payload["decision_context"])
        self.calls += 1
        if self.calls == 1:
            self.started.set()
            if not self.release.wait(timeout=3):
                raise RuntimeError("test planner release timed out")
            raise RuntimeError("obsolete planner output was truncated")
        self.second.validate(capabilities)
        return self.second


class ForcedDeniedPlanner:
    def __init__(self):
        self.calls = 0
        self.visible = []

    def decide(self, request_body, capabilities):
        self.calls += 1
        self.visible.append([spec.name for spec in capabilities])
        # Intentionally bypass normal provider/schema validation to prove the
        # deterministic Planner admission gate is independent from model behavior.
        return generic_execute_decision("generic.write")


class TransitionEngineTests(unittest.TestCase):
    def test_pure_routing_distinguishes_planning_wait_and_cancel(self) -> None:
        engine = TransitionEngine()
        base = dict(
            task_status="active",
            phase="planning",
            runtime_revision=0,
            has_open_action=False,
            pending_clarification_id=None,
            wait_kind=None,
            cancel_requested=False,
            accepted_event_types=frozenset(),
        )
        self.assertEqual(engine.next(RuntimeSnapshot(**base)).kind, "CALL_PLANNER")

        waiting = dict(base)
        waiting.update(task_status="waiting", pending_clarification_id="clar-1")
        self.assertEqual(engine.next(RuntimeSnapshot(**waiting)).reason, "awaiting_existing_clarification")

        resumed = dict(waiting)
        resumed["accepted_event_types"] = frozenset({"USER_TURN"})
        self.assertEqual(engine.next(RuntimeSnapshot(**resumed)).kind, "CALL_PLANNER")

        cancelled = dict(base)
        cancelled["accepted_event_types"] = frozenset({"CANCEL_REQUEST"})
        self.assertEqual(engine.next(RuntimeSnapshot(**cancelled)).kind, "HANDLE_CANCELLATION")


class TaskRuntimeTests(unittest.TestCase):
    def test_task_policy_filters_initial_working_set_and_forced_denied_decision(self) -> None:
        store = Storage(":memory:")
        planner = ForcedDeniedPlanner()
        runtime = TaskRuntime(store, planner, GENERIC_CAPABILITIES)
        runtime.completion_guard = lambda task_id, decision, allowed: decision
        task = runtime.create_task("\u53ea\u8bfb\u67e5\u770b\u9879\u76ee\u8bb0\u5f55")

        with self.assertRaises(TaskCapabilityDeniedError) as captured:
            runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(captured.exception.reason_code, TASK_DENIED)
        self.assertEqual(captured.exception.capability_id, "generic.write")
        self.assertEqual(planner.visible, [["generic.read"]])
        self.assertEqual(store.planner_decisions(task["task_id"]), [])
        self.assertIsNone(store.get_open_action(task["task_id"]))
        traces = store.trace(task["task_id"])
        denied = [row for row in traces if row["event_type"] == "planner.decision.task_denied"]
        self.assertEqual(len(denied), 1)
        self.assertEqual(denied[0]["data"]["reason_code"], TASK_DENIED)
        thinking = [item for item in store.get_task_view(task["task_id"])["timeline"]
                    if item["kind"] == "AGENT_ACTIVITY"]
        self.assertNotEqual(thinking[-1]["presentation_state"], "ACTIVE")

    def test_consumed_user_turn_revocation_remains_effective_on_later_planner_round(self) -> None:
        store = Storage(":memory:")
        planner = QueuePlanner([
            generic_execute_decision("generic.read", on_verified="REPLAN"),
            generic_execute_decision("generic.write", on_verified="COMPLETE"),
        ])
        runtime = TaskRuntime(store, planner, GENERIC_CAPABILITIES)
        task = runtime.create_task("\u67e5\u770b\u9879\u76ee\u8bb0\u5f55\uff0c\u53ea\u8bfb")
        before_revision = store.get_runtime_state(task["task_id"])["runtime_revision"]
        runtime.admit_user_turn(
            task["task_id"], event_id="allow-write",
            text="\u73b0\u5728\u53ef\u4ee5\u5199\u5165\u9879\u76ee\u8bb0\u5f55",
        )
        after_revision = store.get_runtime_state(task["task_id"])["runtime_revision"]
        self.assertGreater(after_revision, before_revision)

        first = runtime.decide(task["task_id"], current_time=NOW)
        self.assertIn("generic.write", [spec["name"] for spec in planner.contexts[0]["available_capabilities"]])
        runtime.record_verified_observation(
            task["task_id"], first["action"]["action_id"], {"verified": True}
        )
        self.assertEqual(store.inbox_events(task["task_id"])[0]["status"], "CONSUMED")

        second = runtime.decide(task["task_id"], current_time=NOW)
        self.assertEqual(second["action"]["action_type"], "generic.write")
        self.assertIn("generic.write", [spec["name"] for spec in planner.contexts[1]["available_capabilities"]])

    def test_atomic_planner_apply_rolls_back_decision_if_action_insert_fails(self) -> None:
        store = Storage(":memory:")
        target = store.create_task("target", "目标任务", "unit", {}, status="active")
        other = store.create_task("other", "其他任务", "unit", {}, status="active")
        store.create_action(
            action_id="collision-action",
            task_id=other["task_id"],
            step_index=1,
            action_type="reminder.create",
            payload={"title": "x", "due_at": "2026-09-11T10:00:00+08:00"},
            expected={},
            idempotency_key="other:1:reminder.create",
        )
        decision = reminder_decision(10)

        with self.assertRaises(sqlite3.IntegrityError):
            store.apply_planner_decision_atomic(
                task_id=target["task_id"],
                expected_runtime_revision=0,
                basis_inbox_seq=0,
                decision_id="pd-rollback",
                decision=decision.__dict__,
                action_id="collision-action",
            )

        self.assertEqual(store.planner_decisions(target["task_id"]), [])
        task_after = store.get_task(target["task_id"])
        runtime_after = store.get_runtime_state(target["task_id"])
        assert task_after is not None and runtime_after is not None
        self.assertEqual(task_after["current_step"], 0)
        self.assertEqual(runtime_after["runtime_revision"], 0)

    def test_user_turns_are_ordered_and_consumed_with_decision(self) -> None:
        store = Storage(":memory:")
        planner = QueuePlanner(
            [
                reminder_decision(
                    11,
                    state_update={
                        "pending_clarification": None,
                        "current_task_brief": "先改成11点，并补充只提醒一次",
                    },
                )
            ]
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("明天十点提醒我面试")

        runtime.admit_user_turn(task["task_id"], event_id="turn-1", text="改成11点")
        runtime.admit_user_turn(task["task_id"], event_id="turn-2", text="而且只提醒一次")
        result = runtime.decide(task["task_id"], current_time=NOW)

        turns = planner.contexts[0]["user_turns"]
        self.assertEqual([turn["event_id"] for turn in turns], ["turn-1", "turn-2"])
        self.assertEqual(
            [turn["content"]["text"] for turn in turns],
            ["改成11点", "而且只提醒一次"],
        )
        self.assertEqual([event["status"] for event in store.inbox_events(task["task_id"])], ["CONSUMED", "CONSUMED"])
        self.assertEqual(result["runtime"]["current_task_brief"], "先改成11点，并补充只提醒一次")
        self.assertEqual(result["runtime"]["inbox_watermark"], store.inbox_events(task["task_id"])[-1]["seq"])

    def test_stale_planner_result_is_never_applied_and_runtime_replans(self) -> None:
        store = Storage(":memory:")
        planner = BlockingStalePlanner(
            reminder_decision(10),
            reminder_decision(
                11,
                state_update={
                    "pending_clarification": None,
                    "current_task_brief": "改成明天11点提醒面试",
                },
            ),
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("明天十点提醒我面试")
        output = {}
        errors = []

        def run_planner() -> None:
            try:
                output["result"] = runtime.decide(task["task_id"], current_time=NOW)
            except Exception as exc:  # pragma: no cover - asserted below
                errors.append(exc)

        thread = threading.Thread(target=run_planner)
        thread.start()
        self.assertTrue(planner.started.wait(timeout=2))

        admitted = runtime.admit_user_turn(
            task["task_id"],
            event_id="turn-during-model",
            text="改成11点",
        )
        self.assertFalse(admitted["duplicate"])
        planner.release.set()
        thread.join(timeout=3)

        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        result = output["result"]
        self.assertEqual(planner.calls, 2)
        self.assertEqual(planner.contexts[0]["user_turns"], [])
        self.assertEqual(planner.contexts[1]["user_turns"][0]["content"]["text"], "改成11点")
        self.assertEqual(result["action"]["payload"]["due_at"], "2026-09-11T11:00:00+08:00")
        self.assertEqual(len(store.planner_decisions(task["task_id"])), 1)
        self.assertEqual(store.inbox_events(task["task_id"])[0]["status"], "CONSUMED")
        trace_types = [event["event_type"] for event in store.trace(task["task_id"])]
        self.assertIn("planner.result.stale", trace_types)
        self.assertEqual(trace_types.count("planner.call.started"), 2)
        stale_trace = next(
            event for event in store.trace(task["task_id"])
            if event["event_type"] == "planner.result.stale"
        )
        self.assertEqual(stale_trace["data"]["call_number"], 1)
        activities = [
            item for item in store.get_task_view(task["task_id"])["timeline"]
            if item["kind"] == "AGENT_ACTIVITY"
        ]
        self.assertEqual([item["presentation_state"] for item in activities], ["INFO", "COMPLETE"])

    def test_pending_clarification_is_reused_after_freeform_turn_keep(self) -> None:
        store = Storage(":memory:")
        first = make_decision(
            decision_type="CLARIFY",
            interpreted_goal_summary="需要确认具体提醒时间",
            plan_update=["确认时间", "创建提醒"],
            clarification={
                "question": "你希望几点提醒？",
                "suggested_options": [{"id": "ten", "label": "10:00"}],
                "accepts_text": True,
                "reason": "missing_exact_time",
            },
            completion=None,
        )
        second = make_decision(
            decision_type="WAIT",
            interpreted_goal_summary="仍需确认时间，同时记住用户的新补充",
            plan_update=["确认时间", "创建提醒"],
            wait={"kind": "user_input", "resume_at": None, "condition": None},
            completion=None,
            state_update={
                "pending_clarification": "KEEP",
                "current_task_brief": "提醒面试，同时不要发声音；具体时间仍待确认",
            },
        )
        planner = QueuePlanner([first, second])
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("提醒我面试")

        first_result = runtime.decide(task["task_id"], current_time=NOW)
        original_id = first_result["clarification"]["clarification_id"]
        self.assertEqual(runtime.next_command(task["task_id"]).reason, "awaiting_existing_clarification")

        runtime.admit_user_turn(
            task["task_id"],
            event_id="turn-side-note",
            text="顺便不要发声音",
            reply_clarification_id=original_id,
        )
        second_result = runtime.decide(task["task_id"], current_time=NOW)

        pending = store.pending_clarification(task["task_id"])
        assert pending is not None
        self.assertEqual(pending["clarification_id"], original_id)
        self.assertEqual(second_result["runtime"]["phase"], "planning")
        self.assertEqual(second_result["runtime"]["wait_kind"], "CLARIFICATION")
        self.assertEqual(planner.contexts[1]["pending_clarification"]["clarification_id"], original_id)
        self.assertEqual(len(store.planner_decisions(task["task_id"])), 2)
        self.assertEqual(store.inbox_events(task["task_id"])[0]["status"], "CONSUMED")

    def test_natural_language_cancel_decision_closes_pending_clarification_as_cancelled_task(self) -> None:
        store = Storage(":memory:")
        planner = QueuePlanner(
            [
                make_decision(
                    decision_type="CLARIFY",
                    interpreted_goal_summary="还需要配送地址",
                    clarification={
                        "question": "送到哪里？",
                        "suggested_options": [],
                        "accepts_text": True,
                        "reason": "missing_delivery_address",
                    },
                    completion=None,
                ),
                make_decision(
                    decision_type="CANCEL",
                    interpreted_goal_summary="用户取消下单",
                    completion=None,
                    cancellation={"reason": "用户说不用了"},
                    state_update={
                        "pending_clarification": "CANCEL",
                        "current_task_brief": "用户取消下单",
                    },
                ),
            ]
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("帮我点餐")
        first = runtime.decide(task["task_id"], current_time=NOW)
        cid = first["clarification"]["clarification_id"]
        runtime.admit_user_turn(
            task["task_id"],
            event_id="natural-cancel",
            text="算了，不用了",
            reply_clarification_id=cid,
        )
        second = runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(second["decision"]["decision_type"], "CANCEL")
        self.assertEqual(second["task"]["status"], "cancelled")
        self.assertIsNone(store.pending_clarification(task["task_id"]))
        self.assertEqual(store.get_inbox_event("natural-cancel")["status"], "CONSUMED")
        self.assertEqual(store.get_task(task["task_id"])["terminal_reason"], "用户说不用了")
        timeline = store.get_task_view(task["task_id"])["timeline"]
        self.assertEqual(timeline[-1]["title"], "任务已取消")

    def test_planner_claim_prevents_duplicate_model_calls_for_same_task(self) -> None:
        store = Storage(":memory:")
        planner = BlockingPlanner(make_decision())
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("已经完成了吗")
        errors = []

        def first_call() -> None:
            try:
                runtime.decide(task["task_id"], current_time=NOW)
            except Exception as exc:  # pragma: no cover - asserted below
                errors.append(exc)

        thread = threading.Thread(target=first_call)
        thread.start()
        self.assertTrue(planner.started.wait(timeout=2))
        with self.assertRaises(PlannerAlreadyRunningError):
            runtime.decide(task["task_id"], current_time=NOW)
        planner.release.set()
        thread.join(timeout=3)

        self.assertEqual(errors, [])
        self.assertEqual(planner.calls, 1)
        self.assertEqual(len(store.planner_decisions(task["task_id"])), 1)

    def test_duplicate_user_turn_replay_after_terminal_task_is_idempotent(self) -> None:
        store = Storage(":memory:")
        planner = QueuePlanner(
            [
                make_decision(
                    state_update={
                        "pending_clarification": None,
                        "current_task_brief": "用户补充后任务已经满足",
                    }
                )
            ]
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("已经处理好了")
        runtime.admit_user_turn(task["task_id"], event_id="turn-terminal", text="好的")
        runtime.decide(task["task_id"], current_time=NOW)
        self.assertEqual(store.get_task(task["task_id"])["status"], "completed")

        replay = runtime.admit_user_turn(
            task["task_id"],
            event_id="turn-terminal",
            text="好的",
        )
        self.assertTrue(replay["duplicate"])
        self.assertEqual(replay["status"], "CONSUMED")

    def test_reply_clarification_correlation_must_belong_to_same_task(self) -> None:
        store = Storage(":memory:")
        planner = QueuePlanner(
            [
                make_decision(
                    decision_type="CLARIFY",
                    interpreted_goal_summary="需要时间",
                    clarification={
                        "question": "几点？",
                        "suggested_options": [],
                        "accepts_text": True,
                        "reason": "missing_time",
                    },
                    completion=None,
                )
            ]
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task_a = runtime.create_task("提醒 A")
        task_b = runtime.create_task("提醒 B")
        result = runtime.decide(task_a["task_id"], current_time=NOW)
        clarification_id = result["clarification"]["clarification_id"]

        with self.assertRaisesRegex(InvalidPlannerTransitionError, "does not belong"):
            runtime.admit_user_turn(
                task_b["task_id"],
                event_id="wrong-correlation",
                text="十点",
                reply_clarification_id=clarification_id,
            )

    def test_resolved_clarification_closes_same_public_timeline_item(self) -> None:
        store = Storage(":memory:")
        planner = QueuePlanner(
            [
                make_decision(
                    decision_type="CLARIFY",
                    interpreted_goal_summary="需要时间",
                    clarification={
                        "question": "几点？",
                        "suggested_options": [],
                        "accepts_text": True,
                        "reason": "missing_time",
                    },
                    completion=None,
                ),
                reminder_decision(10, state_update={
                    "pending_clarification": "RESOLVED",
                    "current_task_brief": "明天10点提醒",
                }),
            ]
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("提醒我")
        first = runtime.decide(task["task_id"], current_time=NOW)
        clarification_id = first["clarification"]["clarification_id"]
        runtime.admit_user_turn(
            task["task_id"],
            event_id="answer-time",
            text="明天十点",
            reply_clarification_id=clarification_id,
        )
        runtime.decide(task["task_id"], current_time=NOW)

        view = store.get_task_view(task["task_id"])
        assert view is not None
        clarification_items = [
            item for item in view["timeline"]
            if item["kind"] == "WAITING_FOR_USER" and item["title"] == "几点？"
        ]
        self.assertTrue(all("source_type" not in item and "source_id" not in item for item in view["timeline"]))
        self.assertEqual(len(clarification_items), 1)
        self.assertEqual(clarification_items[0]["presentation_state"], "COMPLETE")
        self.assertEqual(clarification_items[0]["revision"], 2)

    def test_user_turn_after_planner_action_but_before_dispatch_supersedes_old_action(self) -> None:
        store = Storage(":memory:")
        planner = QueuePlanner(
            [
                reminder_decision(9),
                reminder_decision(10, state_update={
                    "pending_clarification": None,
                    "current_task_brief": "改成明天10点提醒",
                }),
            ]
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("明天9点提醒")
        first = runtime.decide(task["task_id"], current_time=NOW)
        old_action = first["action"]
        self.assertEqual(old_action["status"], "pending")
        self.assertEqual(store.action_attempts(old_action["action_id"]), [])

        runtime.admit_user_turn(
            task["task_id"],
            event_id="turn-before-dispatch",
            text="改成十点",
        )
        self.assertEqual(store.get_action(old_action["action_id"])["status"], "cancelled")
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "planning")

        second = runtime.decide(task["task_id"], current_time=NOW)
        self.assertNotEqual(second["action"]["action_id"], old_action["action_id"])
        self.assertEqual(second["action"]["payload"]["due_at"], "2026-09-11T10:00:00+08:00")
        self.assertEqual(store.inbox_events(task["task_id"])[0]["status"], "CONSUMED")

    def test_planner_failure_becomes_stale_when_user_turn_arrives_during_call(self) -> None:
        store = Storage(":memory:")
        planner = BlockingErrorThenDecisionPlanner(
            reminder_decision(11, state_update={
                "pending_clarification": None,
                "current_task_brief": "改成明天11点提醒面试",
            })
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("明天十点提醒我面试")
        output = {}
        errors = []

        def run_planner() -> None:
            try:
                output["result"] = runtime.decide(task["task_id"], current_time=NOW)
            except Exception as exc:  # pragma: no cover - asserted below
                errors.append(exc)

        thread = threading.Thread(target=run_planner)
        thread.start()
        self.assertTrue(planner.started.wait(timeout=2))
        runtime.admit_user_turn(
            task["task_id"],
            event_id="turn-during-failing-model",
            text="改成11点",
        )
        planner.release.set()
        thread.join(timeout=3)

        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(output["result"]["action"]["payload"]["due_at"], "2026-09-11T11:00:00+08:00")
        self.assertEqual(store.get_task(task["task_id"])["status"], "active")
        self.assertEqual(store.inbox_events(task["task_id"])[0]["status"], "CONSUMED")
        self.assertEqual(planner.calls, 2)
        trace_types = [event["event_type"] for event in store.trace(task["task_id"])]
        self.assertIn("planner.failure.stale", trace_types)
        self.assertNotIn("planner.call.failed", trace_types)
        stale_trace = next(
            event for event in store.trace(task["task_id"])
            if event["event_type"] == "planner.failure.stale"
        )
        self.assertEqual(stale_trace["data"]["call_number"], 1)
        activities = [
            item for item in store.get_task_view(task["task_id"])["timeline"]
            if item["kind"] == "AGENT_ACTIVITY"
        ]
        self.assertEqual([item["presentation_state"] for item in activities], ["INFO", "COMPLETE"])

    def test_mid_planner_turn_supersedes_exact_old_activity_while_fresh_call_stays_active(self) -> None:
        store = Storage(":memory:")
        planner = BlockingTwoRoundPlanner(
            reminder_decision(10),
            reminder_decision(11, state_update={
                "pending_clarification": None,
                "current_task_brief": "改成明天11点提醒面试",
            }),
        )
        runtime = TaskRuntime(store, planner, CAPABILITIES)
        task = runtime.create_task("明天十点提醒我面试")
        output = {}
        errors = []

        def run_planner() -> None:
            try:
                output["result"] = runtime.decide(task["task_id"], current_time=NOW)
            except Exception as exc:  # pragma: no cover - asserted below
                errors.append(exc)

        thread = threading.Thread(target=run_planner)
        thread.start()
        self.assertTrue(planner.first_started.wait(timeout=2))
        runtime.admit_user_turn(
            task["task_id"], event_id="turn-between-planner-rounds", text="改成11点"
        )
        planner.first_release.set()
        self.assertTrue(planner.second_started.wait(timeout=2))

        in_flight = [
            item for item in store.get_task_view(task["task_id"])["timeline"]
            if item["kind"] == "AGENT_ACTIVITY"
        ]
        self.assertEqual(len(in_flight), 2)
        self.assertEqual(in_flight[0]["presentation_state"], "INFO")
        self.assertEqual(in_flight[0]["title"], "已根据最新要求重新调整")
        self.assertEqual(in_flight[1]["presentation_state"], "ACTIVE")

        planner.second_release.set()
        thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(output["result"]["action"]["payload"]["due_at"], "2026-09-11T11:00:00+08:00")
        settled = [
            item for item in store.get_task_view(task["task_id"])["timeline"]
            if item["kind"] == "AGENT_ACTIVITY"
        ]
        self.assertEqual([item["presentation_state"] for item in settled], ["INFO", "COMPLETE"])

    def test_normal_complete_and_execute_planner_activities_still_complete(self) -> None:
        for index, decision in enumerate((make_decision(), reminder_decision(10))):
            with self.subTest(decision_type=decision.decision_type):
                store = Storage(":memory:")
                runtime = TaskRuntime(store, QueuePlanner([decision]), CAPABILITIES)
                task = runtime.create_task(f"normal planner {index}")
                runtime.decide(task["task_id"], current_time=NOW)
                activities = [
                    item for item in store.get_task_view(task["task_id"])["timeline"]
                    if item["kind"] == "AGENT_ACTIVITY"
                ]
                self.assertEqual(len(activities), 1)
                self.assertEqual(activities[0]["presentation_state"], "COMPLETE")
                self.assertEqual(activities[0]["title"], "小卷已完成这轮思考")

    def test_planner_call_latency_and_context_metrics_are_durable(self) -> None:
        store = Storage(":memory:")
        runtime = TaskRuntime(store, QueuePlanner([reminder_decision(9)]), CAPABILITIES)
        task = runtime.create_task("明天9点提醒我面试")

        runtime.decide(task["task_id"], current_time=NOW)

        traces = store.trace(task["task_id"])
        metrics = [row for row in traces if row["event_type"] == "planner.call.metrics"]
        committed = [row for row in traces if row["event_type"] == "planner.call.committed"]
        self.assertEqual(len(metrics), 1)
        self.assertEqual(len(committed), 1)
        payload = metrics[0]["data"]
        self.assertEqual(payload["call_number"], 1)
        self.assertEqual(payload["outcome"], "success")
        self.assertGreater(payload["context_chars"], 0)
        self.assertGreater(payload["request_bytes"], 0)
        self.assertGreaterEqual(payload["model_ms"], 0)
        self.assertGreaterEqual(payload["working_set_ms"], 0)
        self.assertEqual(committed[0]["data"]["decision_type"], "EXECUTE")
        self.assertGreaterEqual(committed[0]["data"]["commit_ms"], 0)
        self.assertGreaterEqual(committed[0]["data"]["total_runtime_ms"], 0)

    def test_planner_failures_are_durable_and_budget_eventually_blocks(self) -> None:
        store = Storage(":memory:")
        runtime = TaskRuntime(store, ErrorPlanner(), CAPABILITIES, max_planner_calls=1)
        task = runtime.create_task("测试模型失败")

        with self.assertRaisesRegex(RuntimeError, "planner transport unavailable"):
            runtime.decide(task["task_id"], current_time=NOW)
        self.assertEqual(store.get_task(task["task_id"])["status"], "active")

        with self.assertRaises(PlannerBudgetExceededError):
            runtime.decide(task["task_id"], current_time=NOW)
        task_after = store.get_task(task["task_id"])
        runtime_after = store.get_runtime_state(task["task_id"])
        assert task_after is not None and runtime_after is not None
        self.assertEqual(task_after["status"], "blocked")
        self.assertEqual(runtime_after["block_reason"], "planner_budget_exhausted")
        trace_types = [event["event_type"] for event in store.trace(task["task_id"])]
        self.assertIn("planner.call.failed", trace_types)
        self.assertIn("planner.budget_exhausted", trace_types)
        activities = [
            item for item in store.get_task_view(task["task_id"])["timeline"]
            if item["kind"] == "AGENT_ACTIVITY"
        ]
        self.assertEqual(len(activities), 1)
        self.assertEqual(activities[0]["presentation_state"], "FAILED")


if __name__ == "__main__":
    unittest.main()
