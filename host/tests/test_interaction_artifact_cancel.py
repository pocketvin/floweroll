from __future__ import annotations

import unittest

from floweroll_host.agent_loop import AgentLoop
from floweroll_host.device_probe_adapter import DeviceProbeAdapter
from floweroll_host.execution_contracts import ExecutionProfile, ExecutionVerification
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.storage import (
    StaleActionInputError,
    StaleArtifactRevisionError,
    Storage,
)


class FakeEmailAdapter:
    capability_id = "email.send.test"
    source_kind = "test"
    execution_profile = ExecutionProfile(
        timeout_seconds=10,
        idempotency_mode="CALLER_KEY",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="READ_BACK",
        reconciliation_mode="QUERY_STATUS",
        max_attempts=2,
    )

    def build_dispatch_snapshot(self, action):
        return {
            "capability": self.capability_id,
            "artifact_revision_id": action["payload"]["artifact_revision_id"],
            "to": action["payload"]["to"],
            "idempotency_key": action["idempotency_key"],
        }

    def verify_result(self, action, *, success, output, error):
        if not success:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error=error or "send failed")
        return ExecutionVerification(outcome="SUCCESS", observation={"message_id": output.get("message_id")})


class ArtifactApprovalTests(unittest.TestCase):
    def make_email_action(self):
        store = Storage(":memory:")
        task = store.create_task("task-email", "发一封邮件", "unit", {}, status="active")
        artifact = store.create_artifact(
            task_id=task["task_id"],
            artifact_id="artifact-email",
            revision_id="rev-email-1",
            kind="email_draft",
            title="邮件草稿",
            content={"subject": "你好", "body": "第一版"},
            created_by="planner",
        )
        action = store.create_action(
            action_id="action-email",
            task_id=task["task_id"],
            step_index=1,
            action_type="email.send.test",
            payload={"artifact_revision_id": "rev-email-1", "to": "hr@example.com"},
            expected={},
            idempotency_key="task-email:1:email.send.test",
        )
        runtime = ExecutionRuntime(store, [FakeEmailAdapter()])
        return store, task, artifact, action, runtime

    def request_approval(self, runtime, task_id, action_id, revision_id="rev-email-1"):
        return runtime.request_predispatch_input(
            task_id=task_id,
            action_id=action_id,
            input_request_id="approval-email",
            prompt="发送这封邮件？",
            suggested_options=[
                {"id": "send", "label": "发送"},
                {"id": "cancel", "label": "取消"},
            ],
            accepts_text=False,
            reason="side_effect_approval",
            artifact_revision_ids=[revision_id],
            execution_fields={"to": "hr@example.com"},
        )

    def approve(self, store, task_id, request, event_id="approve-email"):
        admitted = store.admit_action_input_response(
            task_id=task_id,
            input_request_id=request["input_request_id"],
            event_id=event_id,
            binding_digest=request["binding_digest"],
            response={"approved": True, "option_id": "send"},
        )
        store.consume_action_input_response(event_id=event_id)
        return admitted

    def test_approval_is_bound_to_exact_dispatch_and_attempt_records_it(self) -> None:
        store, task, _, action, runtime = self.make_email_action()
        request = self.request_approval(runtime, task["task_id"], action["action_id"])
        self.assertIsNone(runtime.next_action(task["task_id"]))

        self.approve(store, task["task_id"], request)
        dispatch = runtime.next_action(task["task_id"])
        assert dispatch is not None
        attempt = store.get_action_attempt(dispatch["attempt_id"])
        assert attempt is not None
        self.assertEqual(attempt["approved_input_request_id"], request["input_request_id"])
        self.assertEqual(attempt["dispatch_snapshot"]["artifact_revision_id"], "rev-email-1")
        self.assertEqual(request["binding"]["dispatch_digest"], attempt["dispatch_digest"])

    def test_edit_after_approval_but_before_dispatch_invalidates_old_path(self) -> None:
        store, task, _, action, runtime = self.make_email_action()
        request = self.request_approval(runtime, task["task_id"], action["action_id"])
        self.approve(store, task["task_id"], request)
        self.assertEqual(store.get_action(action["action_id"])["status"], "pending")

        artifact = store.create_artifact_revision(
            task_id=task["task_id"],
            artifact_id="artifact-email",
            revision_id="rev-email-2",
            expected_revision_id="rev-email-1",
            content={"subject": "你好", "body": "第二版"},
            created_by="user",
            event_id="edit-email-2",
        )

        self.assertEqual(artifact["current_revision_id"], "rev-email-2")
        self.assertEqual(store.get_action_input_request(request["input_request_id"])["status"], "CANCELLED")
        self.assertEqual(store.get_action(action["action_id"])["status"], "cancelled")
        self.assertIsNone(runtime.next_action(task["task_id"]))
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "planning")

    def test_edit_after_dispatch_keeps_historical_approved_revision_on_attempt(self) -> None:
        store, task, _, action, runtime = self.make_email_action()
        request = self.request_approval(runtime, task["task_id"], action["action_id"])
        self.approve(store, task["task_id"], request)
        dispatch = runtime.next_action(task["task_id"])
        assert dispatch is not None

        artifact = store.create_artifact_revision(
            task_id=task["task_id"],
            artifact_id="artifact-email",
            revision_id="rev-email-2",
            expected_revision_id="rev-email-1",
            content={"subject": "你好", "body": "第二版，仅供后续"},
            created_by="user",
            event_id="edit-after-dispatch",
        )
        attempt = store.get_action_attempt(dispatch["attempt_id"])
        assert attempt is not None
        self.assertEqual(artifact["current_revision_id"], "rev-email-2")
        self.assertEqual(store.get_action(action["action_id"])["status"], "executing")
        self.assertEqual(attempt["dispatch_snapshot"]["artifact_revision_id"], "rev-email-1")
        self.assertEqual(attempt["approved_input_request_id"], request["input_request_id"])

    def test_artifact_edit_is_idempotent_by_event_and_stale_base_fails_closed(self) -> None:
        store, task, _, _, _ = self.make_email_action()
        first = store.create_artifact_revision(
            task_id=task["task_id"],
            artifact_id="artifact-email",
            revision_id="rev-email-2",
            expected_revision_id="rev-email-1",
            content={"subject": "你好", "body": "第二版"},
            created_by="user",
            event_id="edit-idempotent",
        )
        replay = store.create_artifact_revision(
            task_id=task["task_id"],
            artifact_id="artifact-email",
            revision_id="rev-email-2",
            expected_revision_id="rev-email-1",
            content={"subject": "你好", "body": "第二版"},
            created_by="user",
            event_id="edit-idempotent",
        )
        self.assertEqual(first["current_revision_id"], replay["current_revision_id"])
        self.assertEqual(len(replay["revisions"]), 2)

        with self.assertRaisesRegex(StaleArtifactRevisionError, "current revision"):
            store.create_artifact_revision(
                task_id=task["task_id"],
                artifact_id="artifact-email",
                revision_id="rev-email-3",
                expected_revision_id="rev-email-1",
                content={"subject": "你好", "body": "冲突编辑"},
                created_by="user",
                event_id="edit-stale",
            )

    def test_pending_approval_event_is_ignored_if_artifact_changes_before_consumption(self) -> None:
        store, task, _, action, runtime = self.make_email_action()
        request = self.request_approval(runtime, task["task_id"], action["action_id"])
        store.admit_action_input_response(
            task_id=task["task_id"],
            input_request_id=request["input_request_id"],
            event_id="approval-arrived",
            binding_digest=request["binding_digest"],
            response={"approved": True},
        )
        self.assertEqual(store.get_inbox_event("approval-arrived")["status"], "ACCEPTED")

        store.create_artifact_revision(
            task_id=task["task_id"],
            artifact_id="artifact-email",
            revision_id="rev-email-2",
            expected_revision_id="rev-email-1",
            content={"subject": "你好", "body": "用户先改了"},
            created_by="user",
            event_id="edit-before-consume",
        )
        self.assertEqual(store.get_inbox_event("approval-arrived")["status"], "IGNORED")
        with self.assertRaises(StaleActionInputError):
            store.consume_action_input_response(event_id="approval-arrived")

    def test_action_input_response_replay_remains_idempotent_after_consumption(self) -> None:
        store, task, _, action, runtime = self.make_email_action()
        request = self.request_approval(runtime, task["task_id"], action["action_id"])
        self.approve(store, task["task_id"], request, event_id="approval-replay")

        replay = store.admit_action_input_response(
            task_id=task["task_id"],
            input_request_id=request["input_request_id"],
            event_id="approval-replay",
            binding_digest=request["binding_digest"],
            response={"approved": True, "option_id": "send"},
        )
        self.assertTrue(replay["duplicate"])
        self.assertEqual(replay["status"], "CONSUMED")


class MidToolInputTests(unittest.TestCase):
    def test_midtool_input_resumes_same_attempt_through_continuation_not_original_dispatch(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("tool 中途确认")
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None

        request = store.create_action_input_request(
            input_request_id="midtool-input",
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            prompt="确认继续？",
            suggested_options=[{"id": "yes", "label": "确认"}],
            accepts_text=False,
            reason="provider_input_required",
            binding={
                "action_id": dispatch["action_id"],
                "capability_id": "device.probe",
                "artifact_revisions": [],
                "provider_request_state": "state-1",
            },
            source_continuation_ref="provider-state-1",
        )
        self.assertEqual(store.get_action_attempt(dispatch["attempt_id"])["status"], "WAITING_INPUT")
        self.assertIsNone(loop.next_action(task["task_id"]))

        store.admit_action_input_response(
            task_id=task["task_id"],
            input_request_id=request["input_request_id"],
            event_id="midtool-answer",
            binding_digest=request["binding_digest"],
            response={"approved": True, "option_id": "yes"},
        )
        store.consume_action_input_response(event_id="midtool-answer")
        attempt = store.get_action_attempt(dispatch["attempt_id"])
        assert attempt is not None
        self.assertEqual(attempt["status"], "IN_FLIGHT")
        self.assertEqual(attempt["source_round"], 1)
        self.assertEqual(attempt["approved_input_request_id"], request["input_request_id"])
        self.assertIsNone(loop.next_action(task["task_id"]))

        continuation = loop.execution.action_input_continuation(attempt_id=dispatch["attempt_id"])
        self.assertEqual(continuation["source_continuation_ref"], "provider-state-1")
        self.assertEqual(continuation["response"]["approved"], True)

        result = loop.execution.accept_result(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={"echo": dispatch["payload"]["message"]},
        )
        self.assertEqual(result["attempt"]["attempt_number"], 1)
        self.assertEqual(result["task"]["status"], "completed")


class CancellationTests(unittest.TestCase):
    def test_cancel_before_dispatch_is_immediately_terminal_and_never_creates_attempt(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("还没执行就取消")
        action = store.get_open_action(task["task_id"])
        assert action is not None

        store.admit_cancel_request(task_id=task["task_id"], event_id="cancel-before", reason="不用了")
        result = store.consume_cancel_request(event_id="cancel-before")

        self.assertEqual(result["status"], "cancelled")
        self.assertFalse(result["cancellation_pending"])
        self.assertEqual(store.get_action(action["action_id"])["status"], "cancelled")
        self.assertEqual(store.action_attempts(action["action_id"]), [])
        self.assertIsNone(loop.next_action(task["task_id"]))

    def test_cancel_while_inflight_waits_for_real_result_then_stops_future_work(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("执行中取消")
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None

        store.admit_cancel_request(task_id=task["task_id"], event_id="cancel-inflight", reason="现在停")
        pending = store.consume_cancel_request(event_id="cancel-inflight")
        self.assertTrue(pending["cancellation_pending"])
        self.assertEqual(pending["status"], "active")
        self.assertIsNotNone(pending["cancel_requested_at"])
        self.assertIsNone(loop.next_action(task["task_id"]))

        settled = loop.execution.accept_result(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={"echo": dispatch["payload"]["message"]},
        )
        self.assertEqual(settled["task"]["status"], "cancelled")
        self.assertEqual(settled["action"]["status"], "succeeded")
        self.assertEqual(settled["attempt"]["latest_outcome"], "SUCCESS")
        self.assertIsNotNone(settled["observation"])
        self.assertTrue(settled["task"]["result"]["side_effect_verified"])

    def test_cancel_plus_unknown_reconciliation_never_retries(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("不确定时取消")
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None
        store.admit_cancel_request(task_id=task["task_id"], event_id="cancel-unknown", reason="停止")
        store.consume_cancel_request(event_id="cancel-unknown")
        loop.execution.mark_current_attempt_unknown(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            reason="response lost",
        )

        result = loop.execution.reconcile_definitely_absent_retry_safe(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
        )
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(len(store.action_attempts(dispatch["action_id"])), 1)
        self.assertIsNone(loop.next_action(task["task_id"]))


if __name__ == "__main__":
    unittest.main()
