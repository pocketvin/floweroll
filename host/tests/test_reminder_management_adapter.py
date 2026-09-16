from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.capability_discovery import rank_capabilities
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.reminder_management_adapter import (
    ReminderQueryAdapter,
    ReminderRemoveAdapter,
    ReminderSetCompletionAdapter,
    ReminderUpdateAdapter,
    completion_arguments_valid,
    normalize_query_arguments,
    normalize_remove_arguments,
    normalize_update_arguments,
)
from floweroll_host.server import HostApp
from floweroll_host.storage import Storage
from floweroll_host.task_capability_policy import (
    EffectiveTaskCapabilityPolicy,
    capability_semantics,
)


REVISION = "a" * 64


def reminder_snapshot(**overrides):
    value = {
        "reminder_id": "native-reminder-1",
        "revision": REVISION,
        "title": "交报告",
        "completed": False,
        "due_at": "2026-09-15T07:00:00Z",
        "completion_at": None,
        "calendar_id": "list-1",
        "calendar_name": "小卷验收",
        "calendar_writable": True,
        "list_id": "list-1",
        "list_name": "小卷验收",
        "list_writable": True,
        "has_recurrence": False,
        "notes": "准备纸质版",
        "priority": 5,
        "due_mode": "timed",
        "due_time_zone": "UTC",
        "alarm_mode": "at_due",
        "update_eligible": True,
        "remove_eligible": True,
    }
    value.update(overrides)
    return value


def reminder_remove_args(**overrides):
    value = {
        "reminder_id": "native-reminder-1",
        "expected_revision": REVISION,
        "expected_list_id": "list-1",
        "expected_title": "交报告",
    }
    value.update(overrides)
    return value


def reminder_update_args(**overrides):
    value = {
        "reminder_id": "native-reminder-1",
        "expected_revision": REVISION,
        "expected_list_id": "list-1",
        "title": "交最终报告",
        "notes": "打印一份纸质版",
        "priority": 7,
        "due_mode": "timed",
        "due_at": "2026-09-15T08:30:00Z",
        "due_time_zone": "UTC",
        "alarm_mode": "at_due",
    }
    value.update(overrides)
    return value


class ReminderManagementAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.specs = {
            spec.name: spec
            for spec in product_native_capabilities()
            if spec.name.startswith("reminder.")
        }
        self.registry = CapabilityRegistry()

    def action(self, capability: str, payload: dict, *, on_verified: str = "COMPLETE") -> dict:
        return {
            "action_id": f"action-{capability}",
            "task_id": "task-reminder-management",
            "step_index": 1,
            "action_type": capability,
            "payload": payload,
            "expected": {},
            "idempotency_key": f"task-reminder-management:1:{capability}",
            "on_verified": on_verified,
        }

    def test_production_specs_and_planner_schema_are_registered(self) -> None:
        self.assertTrue(
            {"reminder.create", "reminder.query", "reminder.set_completion", "reminder.update", "reminder.remove"}
            .issubset(set(self.specs))
        )
        query_cases = [
            {"reminder_id": "native-reminder-1"},
            {
                "status": "incomplete",
                "start_at": "2026-09-15T00:00:00+08:00",
                "end_at": "2026-09-16T00:00:00+08:00",
                "title_contains": "报告",
                "max_results": 20,
            },
            {"status": "completed", "calendar_id": "list-1", "max_results": 10},
        ]
        for args in query_cases:
            with self.subTest(args=args):
                PlannerDecision.from_dict(
                    {
                        "decision_type": "EXECUTE",
                        "interpreted_goal_summary": "查看提醒",
                        "plan_update": None,
                        "action": {"capability": "reminder.query", "arguments": args},
                        "on_verified": "COMPLETE",
                        "clarification": None,
                        "wait": None,
                        "completion": None,
                        "stop_reason": None,
                        "cancellation": None,
                        "state_update": None,
                    },
                    list(self.specs.values()),
                )
        PlannerDecision.from_dict(
            {
                "decision_type": "EXECUTE",
                "interpreted_goal_summary": "完成提醒",
                "plan_update": None,
                "action": {
                    "capability": "reminder.set_completion",
                    "arguments": {
                        "reminder_id": "native-reminder-1",
                        "expected_revision": REVISION,
                        "completed": True,
                    },
                },
                "on_verified": "COMPLETE",
                "clarification": None,
                "wait": None,
                "completion": None,
                "stop_reason": None,
                "cancellation": None,
                "state_update": None,
            },
            list(self.specs.values()),
        )

        PlannerDecision.from_dict(
            {
                "decision_type": "EXECUTE",
                "interpreted_goal_summary": "修改提醒内容",
                "plan_update": None,
                "action": {"capability": "reminder.update", "arguments": reminder_update_args()},
                "on_verified": "COMPLETE",
                "clarification": None,
                "wait": None,
                "completion": None,
                "stop_reason": None,
                "cancellation": None,
                "state_update": None,
            },
            list(self.specs.values()),
        )
        PlannerDecision.from_dict(
            {
                "decision_type": "EXECUTE", "interpreted_goal_summary": "删除提醒",
                "plan_update": None,
                "action": {"capability": "reminder.remove", "arguments": reminder_remove_args()},
                "on_verified": "COMPLETE", "clarification": None, "wait": None,
                "completion": None, "stop_reason": None, "cancellation": None, "state_update": None,
            },
            list(self.specs.values()),
        )

    def test_query_custom_modes_are_bounded_and_exact_id_never_mixes_filters(self) -> None:
        exact = normalize_query_arguments({"reminder_id": "  id-1  ", "max_results": 50})
        self.assertEqual(exact["mode"], "exact_id")
        self.assertEqual(exact["reminder_id"], "id-1")
        self.assertEqual(exact["max_results"], 1)
        self.assertIsNone(
            normalize_query_arguments({"reminder_id": "id-1", "status": "incomplete"})
        )
        self.assertIsNone(normalize_query_arguments({"status": "incomplete"}))
        self.assertIsNone(
            normalize_query_arguments(
                {
                    "status": "incomplete",
                    "start_at": "2026-01-01T00:00:00+08:00",
                    "end_at": "2027-01-03T00:00:00+08:00",
                }
            )
        )
        self.assertIsNone(
            normalize_query_arguments({"status": "incomplete", "calendar_id": "list", "title_contains": "报"})
        )
        self.assertIsNone(
            normalize_query_arguments({"status": "incomplete", "calendar_id": "list", "max_results": True})
        )

    def test_policy_semantics_and_read_only_task_scope_are_exact(self) -> None:
        query = capability_semantics(self.specs["reminder.query"], self.registry)
        complete = capability_semantics(self.specs["reminder.set_completion"], self.registry)
        update = capability_semantics(self.specs["reminder.update"], self.registry)
        remove = capability_semantics(self.specs["reminder.remove"], self.registry)
        self.assertEqual((query.operation, query.effect, query.operation_is_generic), ("read", "read", False))
        self.assertEqual(query.domains, frozenset({"device"}))
        self.assertEqual((complete.operation, complete.effect, complete.operation_is_generic), ("modify", "write", False))
        self.assertEqual(complete.domains, frozenset({"device"}))
        self.assertEqual((update.operation, update.effect, update.operation_is_generic), ("modify", "write", False))
        self.assertEqual(update.domains, frozenset({"device"}))
        self.assertEqual((remove.operation, remove.effect, remove.operation_is_generic), ("delete", "write", False))
        self.assertEqual(remove.domains, frozenset({"device"}))

        policy = EffectiveTaskCapabilityPolicy.from_texts(["只查看提醒，不要修改提醒"])
        visible = {
            spec.name
            for spec in policy.filter_specs(
                [self.specs["reminder.query"], self.specs["reminder.set_completion"], self.specs["reminder.update"], self.specs["reminder.remove"]],
                self.registry,
            )
        }
        self.assertEqual(visible, {"reminder.query"})

    def test_discovery_prefers_query_and_completion_intent(self) -> None:
        all_specs = product_native_capabilities()
        cases = [
            ("查看我的提醒事项", "reminder.query"),
            ("把这个提醒标记为完成", "reminder.set_completion"),
            ("把这个提醒改回未完成", "reminder.set_completion"),
            ("取消这个提醒的完成状态", "reminder.set_completion"),
            ("把这个提醒的标题改成提交终稿", "reminder.update"),
            ("把这个提醒改到明天下午三点并加到期提醒", "reminder.update"),
            ("删除这个提醒", "reminder.remove"),
        ]
        for goal, expected in cases:
            with self.subTest(goal=goal):
                ranked = rank_capabilities(all_specs, goal, self.registry)
                self.assertEqual(ranked[0].name, expected)

    def test_query_verifier_accepts_exact_and_filtered_readback(self) -> None:
        adapter = ReminderQueryAdapter()
        exact_action = self.action("reminder.query", {"reminder_id": "native-reminder-1"})
        exact = adapter.verify_result(
            exact_action,
            success=True,
            error=None,
            output={
                "query_mode": "exact_id",
                "date_semantics": None,
                "reminders": [reminder_snapshot()],
                "truncated": False,
                "verified": True,
            },
        )
        self.assertEqual(exact.outcome, "SUCCESS")
        self.assertEqual(exact.observation["reminders"][0]["revision"], REVISION)
        self.assertNotIn("external_id", exact.observation["reminders"][0])

        filtered_action = self.action(
            "reminder.query",
            {
                "status": "incomplete",
                "start_at": "2026-09-15T00:00:00+08:00",
                "end_at": "2026-09-16T00:00:00+08:00",
                "title_contains": "报告",
                "max_results": 2,
            },
        )
        filtered = adapter.verify_result(
            filtered_action,
            success=True,
            error=None,
            output={
                "query_mode": "filtered",
                "date_semantics": "due_date",
                "reminders": [reminder_snapshot()],
                "truncated": True,
                "verified": True,
            },
        )
        self.assertEqual(filtered.outcome, "SUCCESS")
        self.assertTrue(filtered.observation["truncated"])

    def test_query_verifier_rejects_forged_or_out_of_scope_rows(self) -> None:
        adapter = ReminderQueryAdapter()
        action = self.action(
            "reminder.query",
            {"status": "completed", "calendar_id": "list-1", "max_results": 1},
        )
        cases = [
            {"verified": False},
            {"query_mode": "exact_id"},
            {"date_semantics": "due_date"},
            {"reminders": [reminder_snapshot(completed=False)]},
            {"reminders": [reminder_snapshot(calendar_id="other-list", completed=True)]},
            {"reminders": [reminder_snapshot(completed=True), reminder_snapshot(reminder_id="second", completed=True)]},
        ]
        base = {
            "query_mode": "filtered",
            "date_semantics": "completion_date",
            "reminders": [reminder_snapshot(completed=True, completion_at="2026-09-15T07:00:00Z")],
            "truncated": False,
            "verified": True,
        }
        for patch in cases:
            with self.subTest(patch=patch):
                output = dict(base)
                output.update(patch)
                self.assertEqual(
                    adapter.verify_result(action, success=True, error=None, output=output).outcome,
                    "TERMINAL_FAILURE",
                )

    def test_completion_verifier_accepts_complete_uncomplete_and_noop(self) -> None:
        adapter = ReminderSetCompletionAdapter()
        for desired, applied in ((True, True), (False, True), (True, False)):
            with self.subTest(desired=desired, applied=applied):
                action = self.action(
                    "reminder.set_completion",
                    {"reminder_id": "native-reminder-1", "expected_revision": REVISION, "completed": desired},
                )
                output = reminder_snapshot(
                    revision="b" * 64,
                    completed=desired,
                    completion_at="2026-09-15T07:10:00Z" if desired else None,
                )
                output.update(
                    {
                        "requested_reminder_id": "native-reminder-1",
                        "applied": applied,
                        "verified": True,
                    }
                )
                result = adapter.verify_result(action, success=True, error=None, output=output)
                self.assertEqual(result.outcome, "SUCCESS")
                self.assertEqual(result.observation["completed"], desired)
                self.assertEqual(result.observation["applied"], applied)

    def test_completion_verifier_rejects_readback_mismatch_and_classifies_stale(self) -> None:
        adapter = ReminderSetCompletionAdapter()
        action = self.action(
            "reminder.set_completion",
            {"reminder_id": "native-reminder-1", "expected_revision": REVISION, "completed": True},
        )
        base = reminder_snapshot(
            revision="b" * 64,
            completed=True,
            completion_at="2026-09-15T07:10:00Z",
            requested_reminder_id="native-reminder-1",
            applied=True,
            verified=True,
        )
        for patch in (
            {"completed": False},
            {"requested_reminder_id": "other"},
            {"has_recurrence": True},
            {"calendar_writable": False},
            {"revision": "bad"},
            {"verified": False},
        ):
            with self.subTest(patch=patch):
                output = dict(base)
                output.update(patch)
                self.assertEqual(
                    adapter.verify_result(action, success=True, error=None, output=output).outcome,
                    "TERMINAL_FAILURE",
                )

        stale = adapter.verify_result(
            action,
            success=False,
            error="提醒事项已发生变化",
            output={"error_code": "reminder_revision_stale"},
        )
        self.assertEqual(stale.outcome, "MODEL_CORRECTABLE_FAILURE")
        permission = adapter.verify_result(
            action,
            success=False,
            error="提醒事项权限已变化",
            output={"error_code": "reminders_full_access_required"},
        )
        self.assertEqual(permission.outcome, "TERMINAL_FAILURE")

    def test_completion_runtime_persists_verified_result(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("reminder-completion-runtime", "把提醒标记完成", "unit", {}, status="active")
        action_data = self.action(
            "reminder.set_completion",
            {"reminder_id": "native-reminder-1", "expected_revision": REVISION, "completed": True},
        )
        action_data["task_id"] = task["task_id"]
        action = store.create_action(**action_data)
        runtime = ExecutionRuntime(
            store,
            [ReminderSetCompletionAdapter()],
            capability_specs=[self.specs["reminder.set_completion"]],
        )
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        self.assertIsNotNone(dispatch)
        output = reminder_snapshot(
            revision="b" * 64,
            completed=True,
            completion_at="2026-09-15T07:10:00Z",
            requested_reminder_id="native-reminder-1",
            applied=True,
            verified=True,
        )
        result = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output=output,
        )
        self.assertEqual(result["attempt"]["latest_outcome"], "SUCCESS")
        self.assertEqual(result["task"]["status"], "completed")
        observation = store.verified_observations(task["task_id"])[0]
        self.assertEqual(observation["capability"], "reminder.set_completion")
        self.assertTrue(observation["data"]["completed"])

    def test_host_runtime_reports_both_new_ios_adapters_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app = HostApp(str(Path(temp) / "reminder.sqlite3"))
            try:
                by_id = {
                    row["capability_id"]: row
                    for row in app.capability_status()["capabilities"]
                }
                for capability in ("reminder.query", "reminder.set_completion", "reminder.update"):
                    self.assertIn(capability, by_id)
                    self.assertTrue(by_id[capability]["ready"])
                    self.assertEqual(by_id[capability]["source"]["kind"], "ios")
                    self.assertIn(capability, app.execution.adapters)
            finally:
                app.close()

    def test_public_copy_never_leaks_capability_id(self) -> None:
        self.assertEqual(capability_label("reminder.query"), "查看提醒事项")
        self.assertEqual(capability_label("reminder.set_completion"), "更新提醒完成状态")
        self.assertEqual(capability_label("reminder.update"), "修改提醒事项")
        self.assertEqual(capability_activity_title("reminder.query", "active"), "正在查看提醒事项")
        self.assertEqual(capability_activity_title("reminder.set_completion", "complete"), "提醒状态已更新")
        self.assertEqual(capability_activity_title("reminder.update", "complete"), "提醒事项已修改并核对")
        for capability in ("reminder.query", "reminder.set_completion", "reminder.update"):
            self.assertNotIn(capability, capability_activity_title(capability, "active"))

    def test_update_schema_confirmation_verifier_and_runtime_are_bound(self) -> None:
        args = reminder_update_args()
        adapter = ReminderUpdateAdapter()
        action = self.action("reminder.update", args)
        confirmation = adapter.predispatch_confirmation(action)
        self.assertIsNotNone(confirmation)
        self.assertEqual(confirmation["execution_fields"], args)
        self.assertIn("修改提醒事项", confirmation["prompt"])
        self.assertNotIn(args["reminder_id"], confirmation["prompt"])
        self.assertNotIn(args["expected_revision"], confirmation["prompt"])

        output = reminder_snapshot(
            revision="b" * 64,
            title=args["title"],
            notes=args["notes"],
            priority=args["priority"],
            due_at=args["due_at"],
            due_mode=args["due_mode"],
            due_time_zone=args["due_time_zone"],
            alarm_mode=args["alarm_mode"],
            requested_reminder_id=args["reminder_id"],
            completion_preserved=True,
            applied=True,
            verified=True,
        )
        verified = adapter.verify_result(action, success=True, output=output, error=None)
        self.assertEqual(verified.outcome, "SUCCESS")
        self.assertEqual(verified.observation["title"], args["title"] )
        self.assertTrue(verified.observation["completion_preserved"])

        store = Storage(":memory:")
        task = store.create_task("reminder-update-runtime", "修改提醒", "unit", {}, status="active")
        action_data = self.action("reminder.update", args)
        action_data["task_id"] = task["task_id"]
        created = store.create_action(**action_data)
        runtime = ExecutionRuntime(store, [adapter], capability_specs=[self.specs["reminder.update"]])
        self.assertIsNone(runtime.next_action(task["task_id"], source_kind="ios"))
        request = store.pending_action_input_for_action(created["action_id"] )
        self.assertIsNotNone(request)
        self.assertEqual(request["binding"]["execution_fields"], args)
        store.admit_action_input_response(
            task_id=task["task_id"], input_request_id=request["input_request_id"],
            event_id="approve-reminder-update", binding_digest=request["binding_digest"],
            response={"approved": True},
        )
        store.consume_action_input_response(event_id="approve-reminder-update")
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        self.assertIsNotNone(dispatch)
        accepted = runtime.accept_result(
            task_id=task["task_id"], action_id=created["action_id"],
            attempt_id=dispatch["attempt_id"], success=True, output=output,
        )
        self.assertEqual(accepted["attempt"]["latest_outcome"], "SUCCESS")
        self.assertEqual(accepted["task"]["status"], "completed")

    def test_update_verifier_rejects_forged_state_and_stale_is_correctable(self) -> None:
        args = reminder_update_args()
        adapter = ReminderUpdateAdapter()
        action = self.action("reminder.update", args)
        base = reminder_snapshot(
            revision="b" * 64, title=args["title"], notes=args["notes"], priority=args["priority"],
            due_at=args["due_at"], due_mode="timed", due_time_zone="UTC", alarm_mode="at_due",
            requested_reminder_id=args["reminder_id"], completion_preserved=True, applied=True, verified=True,
        )
        for patch in (
            {"title": "旧标题"}, {"notes": "旧备注"}, {"priority": 1}, {"calendar_id": "other"},
            {"due_at": "2026-09-15T09:30:00Z"}, {"alarm_mode": "none"},
            {"completion_preserved": False}, {"has_recurrence": True}, {"update_eligible": False},
            {"requested_reminder_id": "other"}, {"verified": False},
        ):
            with self.subTest(patch=patch):
                output = dict(base); output.update(patch)
                self.assertEqual(adapter.verify_result(action, success=True, output=output, error=None).outcome, "TERMINAL_FAILURE")
        stale = adapter.verify_result(
            action, success=False, error="提醒已变化", output={"error_code": "reminder_revision_stale"}
        )
        self.assertEqual(stale.outcome, "MODEL_CORRECTABLE_FAILURE")

    def test_update_argument_validation_enforces_complete_due_alarm_bundle_and_no_completion(self) -> None:
        self.assertIsNotNone(normalize_update_arguments(reminder_update_args()))
        self.assertIsNotNone(normalize_update_arguments(reminder_update_args(
            due_mode="none", due_at="", due_time_zone="", alarm_mode="none"
        )))
        bad = [
            reminder_update_args(expected_revision="short"),
            reminder_update_args(title=" "),
            reminder_update_args(priority=True),
            reminder_update_args(due_mode="none", due_at="2026-09-15T08:30:00Z", due_time_zone="UTC", alarm_mode="none"),
            reminder_update_args(due_mode="timed", due_at="2026-09-15T08:30:00Z", due_time_zone="Asia/Shanghai"),
            {**reminder_update_args(), "completed": True},
        ]
        for args in bad:
            with self.subTest(args=args):
                self.assertIsNone(normalize_update_arguments(args))

    def test_completion_argument_validation_requires_exact_revision_and_boolean(self) -> None:
        self.assertTrue(
            completion_arguments_valid(
                {"reminder_id": "id", "expected_revision": REVISION, "completed": False}
            )
        )
        self.assertFalse(
            completion_arguments_valid(
                {"reminder_id": "id", "expected_revision": "short", "completed": False}
            )
        )
        self.assertFalse(
            completion_arguments_valid(
                {"reminder_id": "id", "expected_revision": REVISION, "completed": 1}
            )
        )

    def test_remove_schema_confirmation_verifier_and_runtime_are_bound(self) -> None:
        args = reminder_remove_args()
        self.assertIsNotNone(normalize_remove_arguments(args))
        self.assertIsNone(normalize_remove_arguments(reminder_remove_args(expected_revision="short")))
        self.assertIsNone(normalize_remove_arguments(reminder_remove_args(expected_title=" ")))
        adapter = ReminderRemoveAdapter()
        action = self.action("reminder.remove", args)
        confirmation = adapter.predispatch_confirmation(action)
        self.assertIsNotNone(confirmation)
        self.assertEqual(confirmation["execution_fields"], args)
        self.assertIn("交报告", confirmation["prompt"])
        self.assertNotIn(REVISION, confirmation["prompt"])
        output = {
            "requested_reminder_id": "native-reminder-1", "list_id": "list-1", "title": "交报告",
            "deleted": True, "verified": True, "verification": "immediate_exact_id_absence",
        }
        result = adapter.verify_result(action, success=True, output=output, error=None)
        self.assertEqual(result.outcome, "SUCCESS")
        for patch in (
            {"verified": False}, {"deleted": False}, {"requested_reminder_id": "other"},
            {"list_id": "other"}, {"title": "别的提醒"}, {"verification": "post_crash_absence"},
        ):
            forged = dict(output); forged.update(patch)
            self.assertEqual(
                adapter.verify_result(action, success=True, output=forged, error=None).outcome,
                "TERMINAL_FAILURE",
            )
        stale = adapter.verify_result(
            action, success=False, output={"error_code": "reminder_revision_stale"}, error="已变化"
        )
        self.assertEqual(stale.outcome, "MODEL_CORRECTABLE_FAILURE")

        store = Storage(":memory:")
        task = store.create_task("reminder-remove-runtime", "删除提醒", "unit", {}, status="active")
        action_data = self.action("reminder.remove", args)
        action_data["task_id"] = task["task_id"]
        created = store.create_action(**action_data)
        runtime = ExecutionRuntime(store, [adapter], capability_specs=[self.specs["reminder.remove"]])
        self.assertIsNone(runtime.next_action(task["task_id"], source_kind="ios"))
        request = store.pending_action_input_for_action(created["action_id"])
        self.assertIsNotNone(request)
        self.assertEqual(request["binding"]["execution_fields"], args)
        store.admit_action_input_response(
            task_id=task["task_id"], input_request_id=request["input_request_id"],
            event_id="approve-reminder-remove", binding_digest=request["binding_digest"],
            response={"approved": True},
        )
        store.consume_action_input_response(event_id="approve-reminder-remove")
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        self.assertIsNotNone(dispatch)
        accepted = runtime.accept_result(
            task_id=task["task_id"], action_id=created["action_id"], attempt_id=dispatch["attempt_id"],
            success=True, output=output,
        )
        self.assertEqual(accepted["task"]["status"], "completed")

    def test_remove_host_ready_and_public_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app = HostApp(str(Path(temp) / "reminder-remove.sqlite3"))
            try:
                by_id = {row["capability_id"]: row for row in app.capability_status()["capabilities"]}
                self.assertTrue(by_id["reminder.remove"]["ready"])
                self.assertIn("reminder.remove", app.execution.adapters)
            finally:
                app.close()
        self.assertEqual(capability_label("reminder.remove"), "删除提醒事项")
        self.assertEqual(capability_activity_title("reminder.remove", "complete"), "提醒事项已删除并核对")


if __name__ == "__main__":
    unittest.main()
