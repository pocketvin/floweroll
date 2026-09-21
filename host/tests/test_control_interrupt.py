from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.request
import uuid
from pathlib import Path

from floweroll_host.execution_contracts import ExecutionProfile, ExecutionVerification
from floweroll_host.control_interrupt import ControlInterruptDecision
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.runtime_supervisor import RuntimeSupervisor
from floweroll_host.server import create_server
from floweroll_host.storage import Storage


class InterruptibleAdapter:
    capability_id = "test.interruptible"
    source_kind = "test_provider"
    execution_profile = ExecutionProfile(
        timeout_seconds=10,
        idempotency_mode="CALLER_KEY",
        retry_mode="SAFE_WITH_SAME_KEY",
        verification_mode="READ_BACK",
        reconciliation_mode="QUERY_STATUS",
        max_attempts=2,
        retry_backoff_seconds=0,
    )

    def build_dispatch_snapshot(self, action):
        return {
            "capability": self.capability_id,
            "value": action["payload"]["value"],
            "idempotency_key": action["idempotency_key"],
        }

    def verify_result(self, action, *, success, output, error):
        if success:
            return ExecutionVerification(
                outcome="SUCCESS",
                observation={"value": action["payload"]["value"], "provider_id": output.get("provider_id")},
            )
        if error == "provider_cancelled":
            return ExecutionVerification(outcome="CANCELLED", error=error)
        if error == "temporary_503":
            return ExecutionVerification(outcome="TRANSIENT_FAILURE", error=error)
        return ExecutionVerification(outcome="TERMINAL_FAILURE", error=error or "failed")


class FixedClassifier:
    def __init__(self, intent="INTERRUPT_CURRENT_ACTION", confidence="HIGH"):
        self.intent = intent
        self.confidence = confidence
        self.calls = 0

    def classify(self, basis):
        self.calls += 1
        return ControlInterruptDecision(self.intent, self.confidence, "test classifier")


class ErrorClassifier:
    def __init__(self):
        self.calls = 0

    def classify(self, basis):
        self.calls += 1
        raise RuntimeError("classifier unavailable")


class BlockingClassifier:
    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = 0

    def classify(self, basis):
        self.calls += 1
        self.started.set()
        if not self.release.wait(timeout=5):
            raise RuntimeError("classifier release timeout")
        return ControlInterruptDecision("INTERRUPT_CURRENT_ACTION", "HIGH", "user asked to stop current action")


class ControlInterruptTests(unittest.TestCase):
    def make_inflight(self):
        store = Storage(":memory:")
        task = store.create_task("control-task", "执行一个真实操作", "unit", {}, status="active")
        action = store.create_action(
            action_id="control-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="test.interruptible",
            payload={"value": 1},
            expected={},
            idempotency_key="control-task:1:test.interruptible",
            on_verified="COMPLETE",
        )
        execution = ExecutionRuntime(store, [InterruptibleAdapter()])
        dispatch = execution.next_action(task["task_id"])
        assert dispatch is not None
        return store, task, action, execution, dispatch

    def admit_turn(self, store: Storage, task_id: str, event_id: str, text: str):
        return store.admit_inbox_event(
            task_id=task_id,
            event_id=event_id,
            event_type="USER_TURN",
            source="user",
            payload={"content": {"kind": "text", "text": text}, "reply_context": None},
        )

    def apply(self, store: Storage, basis, *, intent: str, confidence: str = "HIGH", reason: str = "user control"):
        return store.apply_control_interrupt_decision(
            decision_id=str(uuid.uuid4()),
            task_id=basis["task_id"],
            action_id=basis["action"]["action_id"],
            attempt_id=basis["attempt"]["attempt_id"],
            expected_runtime_revision=basis["runtime_revision"],
            basis_inbox_seq=basis["basis_inbox_seq"],
            user_event_ids=[turn["event_id"] for turn in basis["user_turns"]],
            intent=intent,
            confidence=confidence,
            reason=reason,
        )

    def test_high_action_interrupt_is_durable_and_prevents_redispatch(self) -> None:
        store, task, action, execution, dispatch = self.make_inflight()
        self.admit_turn(store, task["task_id"], "interrupt-turn", "别做这个了，改做别的")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None

        result = self.apply(store, basis, intent="INTERRUPT_CURRENT_ACTION")

        self.assertEqual(result["status"], "APPLIED")
        current = store.get_action(action["action_id"])
        assert current is not None
        self.assertIsNotNone(current["interrupt_requested_at"])
        self.assertIsNotNone(execution.current_interrupt_request(task["task_id"]))
        self.assertIsNone(execution.next_action(task["task_id"]))
        self.assertEqual(store.get_inbox_event("interrupt-turn")["status"], "ACCEPTED")
        self.assertIsNone(store.control_interrupt_basis(task["task_id"]))

    def test_low_confidence_interrupt_fails_closed_to_noop(self) -> None:
        store, task, action, execution, _ = self.make_inflight()
        self.admit_turn(store, task["task_id"], "ambiguous-turn", "嗯……")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None

        result = self.apply(
            store,
            basis,
            intent="INTERRUPT_CURRENT_ACTION",
            confidence="LOW",
            reason="ambiguous",
        )

        self.assertEqual(result["status"], "APPLIED")
        self.assertIsNone(store.get_action(action["action_id"])["interrupt_requested_at"])
        self.assertIsNotNone(execution.next_action(task["task_id"]))
        self.assertEqual(store.get_inbox_event("ambiguous-turn")["status"], "ACCEPTED")

    def test_classifier_result_is_stale_if_new_turn_arrives_before_apply(self) -> None:
        store, task, action, _, _ = self.make_inflight()
        self.admit_turn(store, task["task_id"], "old-turn", "别做了")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None
        self.admit_turn(store, task["task_id"], "new-turn", "不要取消，继续")

        result = self.apply(store, basis, intent="CANCEL_TASK")

        self.assertEqual(result["status"], "STALE")
        self.assertIsNone(store.get_task(task["task_id"])["cancel_requested_at"])
        self.assertIsNone(store.get_action(action["action_id"])["interrupt_requested_at"])
        new_basis = store.control_interrupt_basis(task["task_id"])
        assert new_basis is not None
        self.assertEqual(new_basis["basis_inbox_seq"], store.get_inbox_event("new-turn")["seq"])

    def test_natural_language_task_cancel_marks_task_cancel_pending_and_consumes_turn(self) -> None:
        store, task, action, execution, dispatch = self.make_inflight()
        self.admit_turn(store, task["task_id"], "cancel-turn", "算了，不用了")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None

        self.apply(store, basis, intent="CANCEL_TASK", reason="user abandoned task")

        current_task = store.get_task(task["task_id"])
        self.assertIsNotNone(current_task["cancel_requested_at"])
        self.assertEqual(store.get_inbox_event("cancel-turn")["status"], "CONSUMED")
        self.assertIsNotNone(store.get_action(action["action_id"])["interrupt_requested_at"])
        self.assertIsNotNone(execution.current_interrupt_request(task["task_id"]))

        late = execution.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={"provider_id": "late-success"},
        )
        self.assertEqual(late["task"]["status"], "cancelled")
        self.assertEqual(late["action"]["status"], "succeeded")
        self.assertIsNotNone(late["observation"])

    def test_provider_cancel_of_action_interrupt_returns_task_to_planner(self) -> None:
        store, task, action, execution, dispatch = self.make_inflight()
        self.admit_turn(store, task["task_id"], "switch-turn", "别做这个了，改做下一件")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None
        self.apply(store, basis, intent="INTERRUPT_CURRENT_ACTION")

        settled = execution.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=False,
            error="provider_cancelled",
        )

        self.assertEqual(settled["attempt"]["latest_outcome"], "CANCELLED")
        self.assertEqual(settled["action"]["status"], "cancelled")
        self.assertEqual(settled["task"]["status"], "active")
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "planning")
        self.assertEqual(store.get_inbox_event("switch-turn")["status"], "ACCEPTED")

    def test_transient_after_action_interrupt_does_not_retry_old_action(self) -> None:
        store, task, action, execution, dispatch = self.make_inflight()
        self.admit_turn(store, task["task_id"], "switch-transient", "别做这个了，换一个")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None
        self.apply(store, basis, intent="INTERRUPT_CURRENT_ACTION")

        settled = execution.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=False,
            error="temporary_503",
        )

        self.assertEqual(settled["attempt"]["latest_outcome"], "TRANSIENT_FAILURE")
        self.assertEqual(settled["action"]["status"], "cancelled")
        self.assertEqual(settled["task"]["status"], "active")
        self.assertEqual(len(store.action_attempts(action["action_id"])), 1)
        self.assertIsNone(execution.next_action(task["task_id"]))

    def test_waiting_input_attempt_is_control_interrupt_candidate_and_old_prompt_is_cancelled(self) -> None:
        store, task, action, execution, dispatch = self.make_inflight()
        request = store.create_action_input_request(
            input_request_id="waiting-input-control",
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            prompt="预计42元，是否确认？",
            suggested_options=[{"id": "yes", "label": "确认"}],
            accepts_text=False,
            reason="provider_input_required",
            binding={
                "action_id": action["action_id"],
                "capability_id": "test.interruptible",
                "artifact_revisions": [],
                "provider_request_state": "quote-42",
            },
            source_continuation_ref="quote-42",
        )
        self.admit_turn(store, task["task_id"], "cancel-while-waiting-input", "算了，不用了")
        self.assertIn(task["task_id"], store.control_interrupt_candidate_task_ids())
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None

        self.apply(store, basis, intent="CANCEL_TASK", reason="user cancelled while provider awaited input")

        self.assertEqual(store.get_action_input_request(request["input_request_id"])["status"], "CANCELLED")
        self.assertIsNotNone(store.get_task(task["task_id"])["cancel_requested_at"])
        self.assertEqual(store.get_inbox_event("cancel-while-waiting-input")["status"], "CONSUMED")

    def test_durable_source_operation_can_be_naturally_cancelled_without_new_attempt(self) -> None:
        store, task, action, execution, dispatch = self.make_inflight()
        waiting = execution.defer_to_source_operation(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            source_operation_ref="provider-task-123",
            source_status="working",
            poll_after="2099-01-01T00:00:00+00:00",
        )
        self.assertEqual(waiting["attempt"]["source_operation_ref"], "provider-task-123")
        self.admit_turn(store, task["task_id"], "cancel-source-operation", "算了，把整个任务取消")
        self.assertIn(task["task_id"], store.control_interrupt_candidate_task_ids())
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None

        self.apply(store, basis, intent="CANCEL_TASK", reason="user cancelled long provider task")

        interrupt = execution.current_interrupt_request(task["task_id"])
        assert interrupt is not None
        self.assertEqual(interrupt["attempt_id"], dispatch["attempt_id"])
        self.assertIsNone(execution.next_action(task["task_id"]))
        self.assertEqual(len(store.action_attempts(action["action_id"])), 1)
        self.assertEqual(store.get_action_attempt(dispatch["attempt_id"])["source_operation_ref"], "provider-task-123")

    def test_unknown_interrupted_action_reconciles_absent_without_retry(self) -> None:
        store, task, action, execution, dispatch = self.make_inflight()
        execution.mark_current_attempt_unknown(
            task_id=task["task_id"],
            action_id=action["action_id"],
            reason="response lost",
        )
        self.admit_turn(store, task["task_id"], "switch-after-unknown", "别继续这个了")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None
        self.apply(store, basis, intent="INTERRUPT_CURRENT_ACTION")

        final = execution.reconcile_definitely_absent_retry_safe(
            task_id=task["task_id"],
            action_id=action["action_id"],
        )

        self.assertEqual(final["status"], "active")
        self.assertEqual(store.get_action(action["action_id"])["status"], "cancelled")
        self.assertEqual(len(store.action_attempts(action["action_id"])), 1)
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "planning")
        self.assertEqual(store.get_action_attempt(dispatch["attempt_id"])["latest_outcome"], "CANCELLED")

    def test_device_not_started_proof_finishes_control_interrupt_without_retry(self) -> None:
        from floweroll_host.agent_loop import AgentLoop

        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("执行设备操作")
        action = store.get_open_action(task["task_id"])
        assert action is not None
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None

        self.admit_turn(store, task["task_id"], "stop-device-action", "别继续这个操作了")
        basis = store.control_interrupt_basis(task["task_id"])
        assert basis is not None
        self.apply(store, basis, intent="INTERRUPT_CURRENT_ACTION")

        result = loop.execution.reconcile_device_definitely_not_started(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
        )
        self.assertFalse(result["duplicate"])
        self.assertEqual(result["task"]["status"], "active")
        self.assertEqual(result["action"]["status"], "cancelled")
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "planning")
        self.assertEqual(len(store.action_attempts(action["action_id"])), 1)
        self.assertEqual(
            store.get_action_attempt(dispatch["attempt_id"])["latest_outcome"],
            "CANCELLED",
        )

        replay = loop.execution.reconcile_device_definitely_not_started(
            task_id=task["task_id"], action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
        )
        self.assertTrue(replay["duplicate"])


class ControlInterruptSupervisorTests(unittest.TestCase):
    def make_probe_inflight(self, store: Storage):
        from floweroll_host.agent_loop import AgentLoop

        loop = AgentLoop(store)
        task = loop.create_task("自然语言中断测试")
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None
        return loop, task, dispatch

    def test_supervisor_classifies_each_attempt_basis_once(self) -> None:
        store = Storage(":memory:")
        _, task, _ = self.make_probe_inflight(store)
        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id="supervisor-interrupt",
            event_type="USER_TURN",
            source="user",
            payload={"content": {"kind": "text", "text": "等一下，先别做"}, "reply_context": None},
        )
        classifier = FixedClassifier()
        supervisor = RuntimeSupervisor(store, None, control_interrupt_classifier=classifier)

        first = supervisor.control_sweep_once()
        second = supervisor.control_sweep_once()

        self.assertEqual(classifier.calls, 1)
        self.assertEqual(first[0]["effective_intent"], "INTERRUPT_CURRENT_ACTION")
        self.assertEqual(second, [])

    def test_classifier_failure_is_fail_closed_and_not_tight_retried(self) -> None:
        store = Storage(":memory:")
        _, task, _ = self.make_probe_inflight(store)
        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id="classifier-error-turn",
            event_type="USER_TURN",
            source="user",
            payload={"content": {"kind": "text", "text": "算了"}, "reply_context": None},
        )
        classifier = ErrorClassifier()
        supervisor = RuntimeSupervisor(store, None, control_interrupt_classifier=classifier)

        first = supervisor.control_sweep_once()
        second = supervisor.control_sweep_once()

        self.assertEqual(classifier.calls, 1)
        self.assertEqual(first[0]["effective_intent"] if "effective_intent" in first[0] else first[0]["intent"], "NONE")
        self.assertEqual(first[0]["confidence"], "LOW")
        self.assertEqual(second, [])
        self.assertIsNone(store.get_task(task["task_id"])["cancel_requested_at"])
        self.assertEqual(store.get_inbox_event("classifier-error-turn")["status"], "ACCEPTED")

    def test_http_user_turn_returns_202_before_blocking_control_classifier(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            classifier = BlockingClassifier()
            server = create_server(
                "127.0.0.1",
                0,
                str(Path(tmp) / "control-http.sqlite3"),
                control_interrupt_classifier=classifier,
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = "http://127.0.0.1:{}".format(server.server_address[1])
            try:
                # Legacy probe gives this test a harmless in-flight Attempt.
                request = urllib.request.Request(
                    base + "/v1/tasks",
                    data=json.dumps({"goal": "probe"}).encode(),
                    method="POST",
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(request, timeout=3) as response:
                    task = json.loads(response.read().decode())
                with urllib.request.urlopen(
                    urllib.request.Request(
                        base + f"/v1/tasks/{task['task_id']}/next-action",
                        method="GET",
                    ),
                    timeout=3,
                ) as response:
                    self.assertEqual(response.status, 200)

                body = {
                    "event_id": "http-spoken-interrupt",
                    "content": {"kind": "text", "text": "等一下，先别做"},
                }
                turn_request = urllib.request.Request(
                    base + f"/v1/tasks/{task['task_id']}/turns",
                    data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                    method="POST",
                    headers={"Content-Type": "application/json"},
                )
                started = time.perf_counter()
                with urllib.request.urlopen(turn_request, timeout=3) as response:
                    elapsed = time.perf_counter() - started
                    self.assertEqual(response.status, 202)
                self.assertLess(elapsed, 0.5)
                self.assertTrue(classifier.started.wait(timeout=2))

                classifier.release.set()
                deadline = time.monotonic() + 2
                interrupted = None
                while time.monotonic() < deadline:
                    interrupted = server.app.storage.get_open_action(task["task_id"])
                    if interrupted is not None and interrupted.get("interrupt_requested_at") is not None:
                        break
                    time.sleep(0.02)
                self.assertIsNotNone(interrupted)
                assert interrupted is not None
                self.assertIsNotNone(interrupted["interrupt_requested_at"])
            finally:
                classifier.release.set()
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
