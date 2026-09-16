from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from floweroll_host.capabilities_v0 import NOTIFY_USER, product_native_capabilities
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.notify_user_adapter import (
    NotifyUserAdapter,
    notify_user_arguments_valid,
    stable_notification_id,
)
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.server import HostApp
from floweroll_host.storage import Storage
from floweroll_host.task_capability_policy import EffectiveTaskCapabilityPolicy, capability_semantics


class NotifyUserHostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.adapter = NotifyUserAdapter()

    @staticmethod
    def arguments() -> dict:
        return {
            "title": "需要你确认",
            "body": "酒店候选已经整理好，请回来选择。",
            "attention_level": "USER_REQUIRED",
        }

    @staticmethod
    def action(*, task_id: str = "task-notify", action_id: str = "action-notify") -> dict:
        return {
            "task_id": task_id,
            "action_id": action_id,
            "payload": NotifyUserHostTests.arguments(),
            "idempotency_key": f"{task_id}:1:notify.user:{action_id}",
        }

    def success_output(self, action: dict, **overrides) -> dict:
        value = {
            "notification_id": stable_notification_id(action["idempotency_key"]),
            "task_id": action["task_id"],
            "action_id": action["action_id"],
            "system_accepted": True,
            "correlation_verified": True,
            "authorization_status": "authorized",
            "presentation_state": "accepted_unobserved",
            "durable_acceptance_receipt": True,
            "reconciled": False,
            "readback_source": "acceptance_receipt",
            "duplicate_suppressed": False,
        }
        value.update(overrides)
        return value

    def test_spec_is_bounded_and_requires_explicit_planner_action(self) -> None:
        self.assertEqual(NOTIFY_USER.name, "notify.user")
        schema = NOTIFY_USER.arguments_schema
        self.assertEqual(schema["required"], ["title", "body", "attention_level"])
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(
            schema["properties"]["attention_level"]["enum"],
            ["IMPORTANT", "USER_REQUIRED"],
        )
        self.assertNotIn("task_id", schema["properties"])
        self.assertNotIn("action_id", schema["properties"])
        self.assertNotIn("idempotency_key", schema["properties"])

        payload = {
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": "明确发送一条用户通知",
            "plan_update": None,
            "action": {"capability": "notify.user", "arguments": self.arguments()},
            "on_verified": "COMPLETE",
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
        }
        decision = PlannerDecision.from_dict(payload, [NOTIFY_USER])
        self.assertEqual(decision.action["capability"], "notify.user")

    def test_attention_values_are_arguments_not_automatic_triggers(self) -> None:
        self.assertTrue(notify_user_arguments_valid(self.arguments()))
        important = {**self.arguments(), "attention_level": "IMPORTANT"}
        self.assertTrue(notify_user_arguments_valid(important))
        # There is no Host hook that maps a presentation attention value to an
        # Action. It is only legal inside an explicit notify.user payload.
        self.assertEqual([spec.name for spec in product_native_capabilities()].count("notify.user"), 1)

    def test_stable_notification_identity_is_action_idempotency_scoped(self) -> None:
        first = stable_notification_id("task:action-1:notify.user")
        replay = stable_notification_id("task:action-1:notify.user")
        second = stable_notification_id("task:action-2:notify.user")
        self.assertEqual(first, replay)
        self.assertNotEqual(first, second)
        self.assertRegex(first, r"^floweroll\.notify\.[0-9a-f]{32}$")

    def test_notification_id_cross_language_vector(self) -> None:
        self.assertEqual(
            stable_notification_id("notify-vector-1"),
            "floweroll.notify.a3d9a18f914b430699394b54f94d7023",
        )

    def test_adapter_execution_profile_is_no_blind_retry_with_device_readback(self) -> None:
        profile = self.adapter.execution_profile
        self.assertEqual(profile.idempotency_mode, "DEVICE_JOURNAL_AND_STABLE_NOTIFICATION_ID")
        self.assertEqual(profile.retry_mode, "NO_BLIND_RETRY")
        self.assertEqual(profile.verification_mode, "DEVICE_NOTIFICATION_ACCEPTANCE")
        self.assertEqual(profile.reconciliation_mode, "DEVICE_NOTIFICATION_READ_BACK")
        self.assertEqual(profile.max_attempts, 1)

    def test_verifier_accepts_exact_system_acceptance_without_claiming_human_read(self) -> None:
        action = self.action()
        verified = self.adapter.verify_result(
            action,
            success=True,
            output=self.success_output(action),
            error=None,
        )
        self.assertEqual(verified.outcome, "SUCCESS")
        self.assertEqual(verified.observation["task_id"], action["task_id"])
        self.assertEqual(verified.observation["action_id"], action["action_id"])
        self.assertTrue(verified.observation["system_accepted"])
        self.assertNotIn("human_read", verified.observation)
        self.assertIn("提交给系统", verified.direct_completion_summary)

    def test_verifier_rejects_wrong_action_or_notification_identity(self) -> None:
        action = self.action()
        for override in (
            {"action_id": "other-action"},
            {"notification_id": "floweroll.notify.deadbeef"},
            {"correlation_verified": False},
            {"durable_acceptance_receipt": False},
            {"authorization_status": "provisional"},
            {"presentation_state": "human_read"},
        ):
            with self.subTest(override=override):
                result = self.adapter.verify_result(
                    action,
                    success=True,
                    output=self.success_output(action, **override),
                    error=None,
                )
                self.assertEqual(result.outcome, "TERMINAL_FAILURE")

    def test_permission_and_argument_failures_remain_machine_distinct(self) -> None:
        action = self.action()
        for code in (
            "notify_user_invalid_arguments",
            "notifications_authorization_denied",
            "notifications_authorization_not_determined",
            "notifications_authorization_insufficient",
        ):
            with self.subTest(code=code):
                result = self.adapter.verify_result(
                    action,
                    success=False,
                    output={"error_code": code},
                    error=code,
                )
                self.assertEqual(result.outcome, "MODEL_CORRECTABLE_FAILURE")
        terminal = self.adapter.verify_result(
            action,
            success=False,
            output={"error_code": "notify_user_acceptance_identity_conflict"},
            error="conflict",
        )
        self.assertEqual(terminal.outcome, "TERMINAL_FAILURE")

    def test_task_capability_policy_treats_notify_as_send_in_device_domain(self) -> None:
        semantics = capability_semantics(NOTIFY_USER)
        self.assertEqual(semantics.operation, "send")
        self.assertEqual(semantics.effect, "write")
        self.assertIn("device", semantics.domains)

        denied = EffectiveTaskCapabilityPolicy.from_texts(["不要发送通知"])
        decision = denied.decide(NOTIFY_USER)
        self.assertFalse(decision.allowed)
        self.assertEqual(decision.operation, "send")

        unrelated = EffectiveTaskCapabilityPolicy.from_texts(["不要创建日历"])
        self.assertTrue(unrelated.decide(NOTIFY_USER).allowed)

    def test_runtime_action_attempt_to_verified_observation_and_completion(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("notify-runtime", "明确通知我回来确认", "unit", {}, status="active")
        action = store.create_action(
            action_id="notify-runtime-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="notify.user",
            payload=self.arguments(),
            expected={},
            idempotency_key="notify-runtime:action-1",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(
            store,
            [self.adapter],
            capability_specs=[NOTIFY_USER],
        )
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        self.assertIsNotNone(dispatch)
        result = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output=self.success_output({**action, "idempotency_key": "notify-runtime:action-1"}),
            error=None,
        )
        self.assertFalse(result["duplicate"])
        self.assertEqual(store.get_task(task["task_id"])["status"], "completed")
        attempt = store.action_attempts(action["action_id"])[0]
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        observations = store.verified_observations(task["task_id"])
        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["data"]["action_id"], action["action_id"])

    def test_task_policy_denial_stops_before_notification_attempt(self) -> None:
        store = Storage(":memory:")
        task = store.create_task(
            "notify-denied",
            "不要发送通知，只在任务页显示结果",
            "unit",
            {},
            status="active",
        )
        action = store.create_action(
            action_id="notify-denied-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="notify.user",
            payload=self.arguments(),
            expected={},
            idempotency_key="notify-denied:action-1",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [self.adapter], capability_specs=[NOTIFY_USER])
        self.assertIsNone(runtime.next_action(task["task_id"], source_kind="ios"))
        self.assertEqual(store.action_attempts(action["action_id"]), [])
        self.assertEqual(store.get_action(action["action_id"])["failure_code"], "TASK_DENIED")
        self.assertEqual(store.verified_observations(task["task_id"]), [])

    def test_native_capability_status_reports_notify_host_contract_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app = HostApp(str(Path(temp) / "notify.sqlite3"))
            try:
                by_id = {
                    item["capability_id"]: item
                    for item in app.capability_status()["capabilities"]
                }
                self.assertIn("notify.user", by_id)
                self.assertTrue(by_id["notify.user"]["ready"])
                self.assertEqual(by_id["notify.user"]["source"]["kind"], "ios")
                self.assertEqual(
                    by_id["notify.user"]["source"]["readiness_scope"],
                    "host_adapter_present",
                )
            finally:
                app.close()

    def test_public_copy_is_explicit_and_does_not_claim_delivery_or_read(self) -> None:
        self.assertEqual(capability_label("notify.user"), "发送通知")
        self.assertEqual(
            capability_activity_title("notify.user", "active"),
            "正在发送通知",
        )
        self.assertEqual(
            capability_activity_title("notify.user", "complete"),
            "通知已提交给系统",
        )


if __name__ == "__main__":
    unittest.main()
