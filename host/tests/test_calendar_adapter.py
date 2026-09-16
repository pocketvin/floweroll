from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from floweroll_host.calendar_adapter import (
    CalendarFreeBusyAdapter, CalendarQueryAdapter, CalendarRemoveAdapter, CalendarUpdateAdapter,
    normalize_calendar_remove_arguments, normalize_calendar_update_arguments,
)
from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.capability_discovery import rank_capabilities
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.server import HostApp
from floweroll_host.storage import Storage
from floweroll_host.task_capability_policy import capability_semantics


REVISION = "a" * 64


def calendar_snapshot(**overrides):
    value = {
        "event_id": "e1",
        "revision": REVISION,
        "title": "面试",
        "start_at": "2026-09-12T06:00:00Z",
        "end_at": "2026-09-12T07:00:00Z",
        "time_zone": "Asia/Shanghai",
        "location": "杭州",
        "calendar_id": "calendar-1",
        "calendar_name": "工作",
        "calendar_writable": True,
        "all_day": False,
        "has_recurrence": False,
        "is_detached": False,
        "has_attendees": False,
        "has_organizer": False,
        "last_modified_at": "2026-09-12T05:00:00Z",
        "update_eligible": True,
        "remove_eligible": True,
    }
    value.update(overrides)
    return value


def calendar_remove_args(**overrides):
    value = {
        "event_id": "e1",
        "expected_revision": REVISION,
        "expected_calendar_id": "calendar-1",
        "expected_title": "面试",
    }
    value.update(overrides)
    return value


def calendar_update_args(**overrides):
    value = {
        "event_id": "e1",
        "expected_revision": REVISION,
        "expected_calendar_id": "calendar-1",
        "title": "面试二面",
        "start_at": "2026-09-16T15:00:00+08:00",
        "end_at": "2026-09-16T16:00:00+08:00",
        "time_zone": "Asia/Shanghai",
        "location": "上海",
    }
    value.update(overrides)
    return value


class CalendarAdapterTests(unittest.TestCase):
    def test_freebusy_keeps_only_time_occupancy(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("calendar-fb-task", "看看明天下午空不空", "unit", {}, status="active")
        store.create_action(
            action_id="calendar-fb-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="calendar.freebusy",
            payload={"start_at": "2026-09-12T13:00:00+08:00", "end_at": "2026-09-12T18:00:00+08:00"},
            expected={}, idempotency_key="calendar-fb-task:1", on_verified="REPLAN",
        )
        runtime = ExecutionRuntime(store, [CalendarFreeBusyAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        runtime.accept_result(
            task_id=task["task_id"], action_id="calendar-fb-action", attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "start_at": "2026-09-12T13:00:00+08:00", "end_at": "2026-09-12T18:00:00+08:00",
                "is_free": False, "event_count": 2,
                "busy_intervals": [{"start_at": "2026-09-12T14:00:00Z", "end_at": "2026-09-12T15:00:00Z", "all_day": False}],
                "verified": True,
            },
        )
        obs = store.verified_observations(task["task_id"])[0]["data"]
        self.assertEqual(set(obs), {"start_at", "end_at", "is_free", "busy_intervals", "event_count"})
        self.assertNotIn("title", str(obs).lower())
        self.assertEqual(store.get_task(task["task_id"])["status"], "active")

    def test_query_returns_bounded_event_summary(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("calendar-query-task", "明天有什么安排", "unit", {}, status="active")
        store.create_action(
            action_id="calendar-query-action", task_id=task["task_id"], step_index=1,
            action_type="calendar.query",
            payload={"start_at": "2026-09-12T00:00:00+08:00", "end_at": "2026-09-13T00:00:00+08:00", "max_results": 20},
            expected={}, idempotency_key="calendar-query-task:1", on_verified="REPLAN",
        )
        runtime = ExecutionRuntime(store, [CalendarQueryAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        runtime.accept_result(
            task_id=task["task_id"], action_id="calendar-query-action", attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "start_at": "2026-09-12T00:00:00+08:00", "end_at": "2026-09-13T00:00:00+08:00",
                "events": [calendar_snapshot()],
                "truncated": False, "verified": True,
            },
        )
        obs = store.verified_observations(task["task_id"])[0]["data"]
        self.assertEqual(obs["events"][0]["title"], "面试")
        self.assertNotIn("attendees", obs["events"][0])
        self.assertNotIn("notes", obs["events"][0])

    def test_freebusy_can_complete_directly_with_user_summary(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("calendar-fb-direct", "看看明天下午空不空", "unit", {}, status="active")
        store.create_action(
            action_id="calendar-fb-direct-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="calendar.freebusy",
            payload={"start_at": "2026-09-12T13:00:00+08:00", "end_at": "2026-09-12T18:00:00+08:00"},
            expected={}, idempotency_key="calendar-fb-direct:1", on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [CalendarFreeBusyAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        runtime.accept_result(
            task_id=task["task_id"], action_id="calendar-fb-direct-action", attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "start_at": "2026-09-12T13:00:00+08:00", "end_at": "2026-09-12T18:00:00+08:00",
                "is_free": True, "event_count": 0, "busy_intervals": [], "verified": True,
            },
        )
        finished = store.get_task(task["task_id"])
        self.assertEqual(finished["status"], "completed")
        self.assertEqual(finished["result"]["summary"], "9月12日 13:00–18:00有空，没有检测到忙碌安排。")
        view = store.get_task_view(task["task_id"])
        self.assertEqual(view["timeline"][-1]["summary"], finished["result"]["summary"])

    def test_query_direct_summary_uses_requested_timezone(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("calendar-query-direct", "明天有什么安排", "unit", {}, status="active")
        store.create_action(
            action_id="calendar-query-direct-action", task_id=task["task_id"], step_index=1,
            action_type="calendar.query",
            payload={"start_at": "2026-09-12T00:00:00+08:00", "end_at": "2026-09-13T00:00:00+08:00", "max_results": 20},
            expected={}, idempotency_key="calendar-query-direct:1", on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [CalendarQueryAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        runtime.accept_result(
            task_id=task["task_id"], action_id="calendar-query-direct-action", attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "start_at": "2026-09-12T00:00:00+08:00", "end_at": "2026-09-13T00:00:00+08:00",
                "events": [calendar_snapshot()],
                "truncated": False, "verified": True,
            },
        )
        summary = store.get_task(task["task_id"])["result"]["summary"]
        self.assertEqual(summary, "9月12日共有1项日程：14:00–15:00 面试（杭州）。")

    def test_calendar_update_spec_policy_discovery_and_planner_schema(self) -> None:
        specs = {spec.name: spec for spec in product_native_capabilities()}
        self.assertIn("calendar.update", specs)
        semantics = capability_semantics(specs["calendar.update"], CapabilityRegistry())
        self.assertEqual((semantics.operation, semantics.effect), ("modify", "write"))
        self.assertIn("device", semantics.domains)
        ranked = rank_capabilities(
            product_native_capabilities(), "把这个日程改到下午三点", CapabilityRegistry()
        )
        self.assertEqual(ranked[0].name, "calendar.update")
        PlannerDecision.from_dict(
            {
                "decision_type": "EXECUTE", "interpreted_goal_summary": "修改日程",
                "plan_update": None, "action": {"capability": "calendar.update", "arguments": calendar_update_args()},
                "on_verified": "COMPLETE", "clarification": None, "wait": None, "completion": None,
                "stop_reason": None, "cancellation": None, "state_update": None,
            },
            list(specs.values()),
        )

    def test_calendar_update_argument_validation_requires_exact_complete_state(self) -> None:
        self.assertIsNotNone(normalize_calendar_update_arguments(calendar_update_args()))
        for args in (
            calendar_update_args(expected_revision="short"),
            calendar_update_args(title=" "),
            calendar_update_args(end_at="2026-09-16T14:00:00+08:00"),
            calendar_update_args(start_at="2026-09-16T15:00:00Z"),
            calendar_update_args(time_zone="Not/AZone"),
            {**calendar_update_args(), "calendar_name": "工作"},
        ):
            with self.subTest(args=args):
                self.assertIsNone(normalize_calendar_update_arguments(args))

    def test_calendar_update_confirmation_verifier_and_runtime_binding(self) -> None:
        args = calendar_update_args()
        adapter = CalendarUpdateAdapter()
        action = {
            "action_id": "calendar-update-action", "task_id": "task", "payload": args,
            "idempotency_key": "calendar-update:one",
        }
        confirmation = adapter.predispatch_confirmation(action)
        self.assertIsNotNone(confirmation)
        self.assertEqual(confirmation["execution_fields"], args)
        self.assertIn("2026-09-16 15:00", confirmation["prompt"])
        self.assertNotIn(args["event_id"], confirmation["prompt"])
        self.assertNotIn(args["expected_revision"], confirmation["prompt"])

        output = calendar_snapshot(
            revision="b" * 64, title=args["title"],
            start_at="2026-09-16T07:00:00Z", end_at="2026-09-16T08:00:00Z",
            time_zone=args["time_zone"], location=args["location"],
            requested_event_id=args["event_id"], applied=True, verified=True,
        )
        verified = adapter.verify_result(action, success=True, output=output, error=None)
        self.assertEqual(verified.outcome, "SUCCESS")
        self.assertEqual(verified.observation["title"], args["title"] )

        store = Storage(":memory:")
        task = store.create_task("calendar-update-runtime", "修改日程", "unit", {}, status="active")
        created = store.create_action(
            action_id="calendar-update-action", task_id=task["task_id"], step_index=1,
            action_type="calendar.update", payload=args, expected={},
            idempotency_key="calendar-update:one", on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(
            store, [adapter], capability_specs=[next(s for s in product_native_capabilities() if s.name == "calendar.update")]
        )
        self.assertIsNone(runtime.next_action(task["task_id"], source_kind="ios"))
        request = store.pending_action_input_for_action(created["action_id"] )
        self.assertEqual(request["binding"]["execution_fields"], args)
        store.admit_action_input_response(
            task_id=task["task_id"], input_request_id=request["input_request_id"],
            event_id="calendar-update-approve", binding_digest=request["binding_digest"], response={"approved": True},
        )
        store.consume_action_input_response(event_id="calendar-update-approve")
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        self.assertIsNotNone(dispatch)
        accepted = runtime.accept_result(
            task_id=task["task_id"], action_id=created["action_id"], attempt_id=dispatch["attempt_id"],
            success=True, output=output,
        )
        self.assertEqual(accepted["attempt"]["latest_outcome"], "SUCCESS")
        self.assertEqual(accepted["task"]["status"], "completed")

    def test_calendar_update_verifier_fails_closed_and_stale_is_correctable(self) -> None:
        args = calendar_update_args()
        adapter = CalendarUpdateAdapter()
        action = {"payload": args, "idempotency_key": "calendar-update:one"}
        base = calendar_snapshot(
            revision="b" * 64, title=args["title"], start_at="2026-09-16T07:00:00Z",
            end_at="2026-09-16T08:00:00Z", time_zone=args["time_zone"], location=args["location"],
            requested_event_id=args["event_id"], applied=True, verified=True,
        )
        for patch in (
            {"title": "旧标题"}, {"event_id": "other"}, {"calendar_id": "other"},
            {"calendar_writable": False}, {"all_day": True}, {"has_recurrence": True},
            {"has_attendees": True}, {"update_eligible": False},
            {"start_at": "2026-09-16T06:00:00Z"}, {"time_zone": "UTC"},
            {"requested_event_id": "other"}, {"verified": False},
        ):
            with self.subTest(patch=patch):
                output = dict(base); output.update(patch)
                self.assertEqual(adapter.verify_result(action, success=True, output=output, error=None).outcome, "TERMINAL_FAILURE")
        stale = adapter.verify_result(
            action, success=False, output={"error_code": "calendar_update_revision_stale"}, error="日程已变化"
        )
        self.assertEqual(stale.outcome, "MODEL_CORRECTABLE_FAILURE")

    def test_calendar_update_host_ready_and_public_copy_hides_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app = HostApp(str(Path(temp) / "calendar.sqlite3"))
            try:
                status = {row["capability_id"]: row for row in app.capability_status()["capabilities"]}
                self.assertTrue(status["calendar.update"]["ready"] )
                self.assertIn("calendar.update", app.execution.adapters)
            finally:
                app.close()
        self.assertEqual(capability_label("calendar.update"), "修改日程")
        self.assertEqual(capability_activity_title("calendar.update", "complete"), "日程已修改并核对")
        self.assertNotIn("calendar.update", capability_activity_title("calendar.update", "active"))


    def test_calendar_remove_schema_policy_confirmation_and_verifier(self) -> None:
        specs = {spec.name: spec for spec in product_native_capabilities()}
        self.assertIn("calendar.remove", specs)
        semantics = capability_semantics(specs["calendar.remove"], CapabilityRegistry())
        self.assertEqual((semantics.operation, semantics.effect), ("delete", "write"))
        PlannerDecision.from_dict(
            {
                "decision_type": "EXECUTE", "interpreted_goal_summary": "删除日程",
                "plan_update": None,
                "action": {"capability": "calendar.remove", "arguments": calendar_remove_args()},
                "on_verified": "COMPLETE", "clarification": None, "wait": None,
                "completion": None, "stop_reason": None, "cancellation": None, "state_update": None,
            },
            list(specs.values()),
        )
        self.assertIsNotNone(normalize_calendar_remove_arguments(calendar_remove_args()))
        self.assertIsNone(normalize_calendar_remove_arguments(calendar_remove_args(expected_revision="short")))
        self.assertIsNone(normalize_calendar_remove_arguments(calendar_remove_args(expected_title=" ")))

        adapter = CalendarRemoveAdapter()
        action = {
            "action_id": "calendar-remove-action", "task_id": "task",
            "payload": calendar_remove_args(), "idempotency_key": "calendar-remove:one",
        }
        confirmation = adapter.predispatch_confirmation(action)
        self.assertIsNotNone(confirmation)
        self.assertEqual(confirmation["execution_fields"], calendar_remove_args())
        self.assertIn("面试", confirmation["prompt"])
        self.assertNotIn(REVISION, confirmation["prompt"])
        output = {
            "requested_event_id": "e1", "calendar_id": "calendar-1", "title": "面试",
            "deleted": True, "verified": True, "verification": "immediate_exact_id_absence",
        }
        verified = adapter.verify_result(action, success=True, output=output, error=None)
        self.assertEqual(verified.outcome, "SUCCESS")
        self.assertTrue(verified.observation["deleted"])
        for patch in (
            {"verified": False}, {"deleted": False}, {"requested_event_id": "other"},
            {"calendar_id": "other"}, {"title": "别的日程"}, {"verification": "post_crash_absence"},
        ):
            forged = dict(output); forged.update(patch)
            self.assertEqual(
                adapter.verify_result(action, success=True, output=forged, error=None).outcome,
                "TERMINAL_FAILURE",
            )
        stale = adapter.verify_result(
            action, success=False, output={"error_code": "calendar_remove_revision_stale"}, error="已变化"
        )
        self.assertEqual(stale.outcome, "MODEL_CORRECTABLE_FAILURE")

    def test_calendar_remove_runtime_requires_confirmation_and_host_is_ready(self) -> None:
        adapter = CalendarRemoveAdapter()
        args = calendar_remove_args()
        store = Storage(":memory:")
        task = store.create_task("calendar-remove-runtime", "删除日程", "unit", {}, status="active")
        created = store.create_action(
            action_id="calendar-remove-action", task_id=task["task_id"], step_index=1,
            action_type="calendar.remove", payload=args, expected={},
            idempotency_key="calendar-remove:one", on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [adapter], capability_specs=[
            next(s for s in product_native_capabilities() if s.name == "calendar.remove")
        ])
        self.assertIsNone(runtime.next_action(task["task_id"], source_kind="ios"))
        request = store.pending_action_input_for_action(created["action_id"])
        self.assertIsNotNone(request)
        self.assertEqual(request["binding"]["execution_fields"], args)
        store.admit_action_input_response(
            task_id=task["task_id"], input_request_id=request["input_request_id"],
            event_id="calendar-remove-approve", binding_digest=request["binding_digest"],
            response={"approved": True},
        )
        store.consume_action_input_response(event_id="calendar-remove-approve")
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        self.assertIsNotNone(dispatch)
        accepted = runtime.accept_result(
            task_id=task["task_id"], action_id=created["action_id"], attempt_id=dispatch["attempt_id"],
            success=True, output={
                "requested_event_id": "e1", "calendar_id": "calendar-1", "title": "面试",
                "deleted": True, "verified": True, "verification": "immediate_exact_id_absence",
            },
        )
        self.assertEqual(accepted["task"]["status"], "completed")
        with tempfile.TemporaryDirectory() as temp:
            app = HostApp(str(Path(temp) / "calendar-remove.sqlite3"))
            try:
                by_id = {row["capability_id"]: row for row in app.capability_status()["capabilities"]}
                self.assertTrue(by_id["calendar.remove"]["ready"])
                self.assertIn("calendar.remove", app.execution.adapters)
            finally:
                app.close()
        self.assertEqual(capability_label("calendar.remove"), "删除日程")
        self.assertEqual(capability_activity_title("calendar.remove", "complete"), "日程已删除并核对")


if __name__ == "__main__":
    unittest.main()
