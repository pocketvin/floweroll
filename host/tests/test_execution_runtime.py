from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from floweroll_host.agent_loop import AgentLoop
from floweroll_host.device_probe_adapter import DeviceProbeAdapter
from floweroll_host.execution_contracts import ExecutionProfile, ExecutionVerification
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_tool_adapter import FunctionToolAdapter
from floweroll_host.planner_contracts import CapabilitySpec
from floweroll_host.storage import InvalidPlannerTransitionError, Storage
from floweroll_host.task_capability_policy import TASK_DENIED


class ModelCorrectableAdapter:
    capability_id = "test.model_correctable"
    source_kind = "test"
    execution_profile = ExecutionProfile(
        timeout_seconds=10,
        idempotency_mode="CALLER_KEY",
        retry_mode="NEVER_BLIND",
        verification_mode="READ_BACK",
        reconciliation_mode="QUERY_STATUS",
        max_attempts=1,
    )

    def build_dispatch_snapshot(self, action):
        return {"capability": self.capability_id, "idempotency_key": action["idempotency_key"]}

    def verify_result(self, action, *, success, output, error):
        return ExecutionVerification(
            outcome="MODEL_CORRECTABLE_FAILURE",
            error=error or "current provider cannot satisfy this request",
        )


class TransientThenSuccessAdapter:
    capability_id = "test.transient"
    source_kind = "test"
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
        return {"capability": self.capability_id, "value": action["payload"]["value"], "idempotency_key": action["idempotency_key"]}

    def verify_result(self, action, *, success, output, error):
        if not success:
            return ExecutionVerification(outcome="TRANSIENT_FAILURE", error=error or "temporary 503")
        return ExecutionVerification(outcome="SUCCESS", observation={"value": action["payload"]["value"]})


class ExecutionRuntimeTests(unittest.TestCase):
    @staticmethod
    def policy_spec(name: str, description: str) -> CapabilitySpec:
        return CapabilitySpec(
            name, description,
            {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        )

    def test_task_denied_write_fails_before_any_action_attempt(self) -> None:
        store = Storage(":memory:")
        task = store.create_task(
            "task-policy-denied",
            "\u53ea\u8bfb\u67e5\u770b\u9879\u76ee\u8bb0\u5f55",
            "unit", {}, status="active",
        )
        action = store.create_action(
            action_id="denied-write-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="generic.write",
            payload={}, expected={},
            idempotency_key="denied-write-action",
            on_verified="REPLAN",
        )
        spec = self.policy_spec("generic.write", "Write project records")
        runtime = ExecutionRuntime(
            store,
            [FunctionToolAdapter(capability_id="generic.write", source_kind="host_local", read_only=False)],
            capability_specs=[spec],
        )

        self.assertIsNone(runtime.next_action(task["task_id"]))
        self.assertEqual(store.action_attempts(action["action_id"]), [])
        failed = store.get_action(action["action_id"])
        self.assertEqual(failed["status"], "failed")
        self.assertEqual(failed["failure_code"], TASK_DENIED)
        self.assertEqual(failed["failure_detail"]["reason_code"], TASK_DENIED)
        basis = store.planner_basis(task["task_id"])
        self.assertEqual(basis["last_semantic_failure"]["kind"], "ACTION_TASK_DENIED")
        self.assertEqual(basis["last_semantic_failure"]["reason_code"], TASK_DENIED)
        self.assertIn("action.task_denied", [row["event_type"] for row in store.trace(task["task_id"])])

    def test_read_allowed_by_same_read_only_policy_still_creates_attempt_with_policy_revision(self) -> None:
        store = Storage(":memory:")
        task = store.create_task(
            "task-policy-read",
            "\u53ea\u8bfb\u67e5\u770b\u9879\u76ee\u8bb0\u5f55",
            "unit", {}, status="active",
        )
        action = store.create_action(
            action_id="allowed-read-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="generic.read",
            payload={}, expected={},
            idempotency_key="allowed-read-action",
            on_verified="REPLAN",
        )
        spec = self.policy_spec("generic.read", "Read project records")
        runtime = ExecutionRuntime(
            store,
            [FunctionToolAdapter(capability_id="generic.read", source_kind="host_local", read_only=True)],
            capability_specs=[spec],
        )

        dispatch = runtime.next_action(task["task_id"])
        self.assertIsNotNone(dispatch)
        attempts = store.action_attempts(action["action_id"])
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["status"], "IN_FLIGHT")
        self.assertIsNotNone(attempts[0]["policy_revision"])

    def make_probe(self, store: Storage):
        loop = AgentLoop(store)
        task = loop.create_task("验证 ActionAttempt")
        action = store.get_open_action(task["task_id"])
        assert action is not None
        return loop, task, action

    def test_attempt_is_persisted_before_dispatch_and_replayed_after_host_restart(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "attempt.sqlite3")
            first_store = Storage(db)
            first_loop, task, action = self.make_probe(first_store)

            first_dispatch = first_loop.next_action(task["task_id"])
            assert first_dispatch is not None
            self.assertEqual(first_dispatch["attempt_status"], "IN_FLIGHT")
            self.assertEqual(first_dispatch["attempt_number"], 1)
            self.assertEqual(first_dispatch["status"], "dispatched")
            self.assertEqual(first_dispatch["runtime_action_status"], "executing")

            persisted = first_store.get_action_attempt(first_dispatch["attempt_id"])
            assert persisted is not None
            self.assertEqual(persisted["status"], "IN_FLIGHT")
            self.assertEqual(
                persisted["dispatch_snapshot"]["idempotency_key"],
                action["idempotency_key"],
            )
            self.assertEqual(persisted["dispatch_digest"], first_dispatch["dispatch_digest"])

            # Simulate Host death before the iPhone/provider returned any result.
            second_store = Storage(db)
            second_loop = AgentLoop(second_store)
            replay = second_loop.next_action(task["task_id"])
            assert replay is not None
            self.assertEqual(replay["action_id"], first_dispatch["action_id"])
            self.assertEqual(replay["attempt_id"], first_dispatch["attempt_id"])
            self.assertEqual(replay["attempt_number"], 1)
            self.assertEqual(len(second_store.action_attempts(action["action_id"])), 1)

    def test_verified_result_closes_attempt_and_persists_observation_provenance(self) -> None:
        store = Storage(":memory:")
        loop, task, _ = self.make_probe(store)
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None

        result = loop.accept_result(
            task["task_id"],
            dispatch["action_id"],
            True,
            {"echo": dispatch["payload"]["message"]},
            attempt_id=dispatch["attempt_id"],
        )

        self.assertEqual(result["task"]["status"], "completed")
        self.assertEqual(result["attempt"]["status"], "FINISHED")
        self.assertEqual(result["attempt"]["latest_outcome"], "SUCCESS")
        observations = store.verified_observations(task["task_id"])
        self.assertEqual(len(observations), 1)
        raw = store.get_action_attempt(dispatch["attempt_id"])
        assert raw is not None
        self.assertIsNone(raw["error"])

    def test_unknown_never_creates_new_attempt_until_reconciliation_says_absent(self) -> None:
        store = Storage(":memory:")
        loop, task, action = self.make_probe(store)
        first = loop.next_action(task["task_id"])
        assert first is not None

        unknown = loop.execution.mark_current_attempt_unknown(
            task_id=task["task_id"],
            action_id=action["action_id"],
            reason="response lost after dispatch",
        )
        self.assertEqual(unknown["action"]["status"], "reconciling")
        self.assertEqual(unknown["attempt"]["latest_outcome"], "UNKNOWN")
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "reconciling")
        self.assertIsNone(loop.next_action(task["task_id"]))
        self.assertEqual(len(store.action_attempts(action["action_id"])), 1)

        loop.execution.reconcile_definitely_absent_retry_safe(
            task_id=task["task_id"],
            action_id=action["action_id"],
        )
        second = loop.next_action(task["task_id"])
        assert second is not None
        self.assertEqual(second["attempt_number"], 2)
        self.assertNotEqual(second["attempt_id"], first["attempt_id"])
        self.assertEqual(second["idempotency_key"], first["idempotency_key"])
        self.assertEqual(second["dispatch_digest"], first["dispatch_digest"])

    def test_retry_wait_uses_wait_identity_before_attempt_two(self) -> None:
        store = Storage(":memory:")
        loop, task, action = self.make_probe(store)
        first = loop.next_action(task["task_id"])
        assert first is not None
        loop.execution.mark_current_attempt_unknown(
            task_id=task["task_id"],
            action_id=action["action_id"],
            reason="ambiguous timeout",
        )
        waiting = loop.execution.reconcile_definitely_absent_retry_safe(
            task_id=task["task_id"],
            action_id=action["action_id"],
            wake_at="2026-09-10T22:00:00+08:00",
        )
        runtime = store.get_runtime_state(task["task_id"])
        assert runtime is not None
        wait_id = runtime["wait_id"]
        self.assertIsNotNone(wait_id)
        self.assertEqual(waiting["action"]["status"], "retry_wait")
        self.assertEqual(store.get_task(task["task_id"])["status"], "waiting")
        self.assertIsNone(loop.next_action(task["task_id"]))

        with self.assertRaisesRegex(InvalidPlannerTransitionError, "stale retry wait"):
            loop.execution.resume_retry_wait(
                task_id=task["task_id"],
                action_id=action["action_id"],
                wait_id="old-wait-id",
            )

        loop.execution.resume_retry_wait(
            task_id=task["task_id"],
            action_id=action["action_id"],
            wait_id=wait_id,
        )
        second = loop.next_action(task["task_id"])
        assert second is not None
        self.assertEqual(second["attempt_number"], 2)

    def test_late_or_unidentified_old_result_cannot_be_misattributed_to_attempt_two(self) -> None:
        store = Storage(":memory:")
        loop, task, action = self.make_probe(store)
        first = loop.next_action(task["task_id"])
        assert first is not None
        loop.execution.mark_current_attempt_unknown(
            task_id=task["task_id"],
            action_id=action["action_id"],
            reason="lost result",
        )
        loop.execution.reconcile_definitely_absent_retry_safe(
            task_id=task["task_id"],
            action_id=action["action_id"],
        )
        second = loop.next_action(task["task_id"])
        assert second is not None

        with self.assertRaisesRegex(RuntimeError, "non-current Attempt"):
            loop.execution.accept_result(
                task_id=task["task_id"],
                action_id=action["action_id"],
                attempt_id=first["attempt_id"],
                success=True,
                output={"echo": first["payload"]["message"]},
            )
        with self.assertRaisesRegex(RuntimeError, "attempt_id is required"):
            loop.execution.accept_result(
                task_id=task["task_id"],
                action_id=action["action_id"],
                success=True,
                output={"echo": second["payload"]["message"]},
            )

        self.assertEqual(store.current_action_attempt(action["action_id"])["attempt_id"], second["attempt_id"])
        self.assertEqual(store.current_action_attempt(action["action_id"])["status"], "IN_FLIGHT")

    def test_inflight_user_turn_prevents_stale_complete_after_verified_success(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("先完成当前操作")
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None

        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id="turn-arrived-inflight",
            event_type="USER_TURN",
            source="user",
            payload={
                "content": {"kind": "text", "text": "完成以后再处理我的新要求"},
                "reply_context": None,
            },
        )

        result = loop.execution.accept_result(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={"echo": dispatch["payload"]["message"]},
        )

        self.assertEqual(result["action"]["status"], "succeeded")
        self.assertEqual(result["attempt"]["latest_outcome"], "SUCCESS")
        self.assertIsNotNone(result["observation"])
        self.assertEqual(result["task"]["status"], "active")
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "planning")
        event = store.get_inbox_event("turn-arrived-inflight")
        assert event is not None
        self.assertEqual(event["status"], "ACCEPTED")
        trace_types = [item["event_type"] for item in store.trace(task["task_id"])]
        self.assertIn("task.replan_after_inflight_user_turn", trace_types)

        replay = loop.execution.accept_result(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={"echo": dispatch["payload"]["message"]},
        )
        self.assertTrue(replay["duplicate"])
        self.assertEqual(replay["task"]["status"], "active")

    def test_model_correctable_failure_returns_task_to_planner_with_semantic_failure(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("model-correctable", "换一个可行方案", "unit", {}, status="active")
        action = store.create_action(
            action_id="model-correctable-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="test.model_correctable",
            payload={},
            expected={},
            idempotency_key="model-correctable:1",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [ModelCorrectableAdapter()])
        dispatch = runtime.next_action(task["task_id"])
        assert dispatch is not None
        result = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=False,
            error="ride service is outside coverage area",
        )
        self.assertEqual(result["attempt"]["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
        self.assertEqual(result["action"]["status"], "failed")
        self.assertEqual(result["task"]["status"], "active")
        self.assertEqual(store.get_runtime_state(task["task_id"])["phase"], "planning")
        basis = store.planner_basis(task["task_id"])
        self.assertEqual(basis["last_semantic_failure"]["kind"], "ACTION_MODEL_CORRECTABLE_FAILURE")
        self.assertEqual(basis["last_semantic_failure"]["capability"], "test.model_correctable")

    def test_transient_failure_waits_then_retries_same_action_without_planner(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("transient", "temporary provider call", "unit", {}, status="active")
        action = store.create_action(
            action_id="transient-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="test.transient",
            payload={"value": 7},
            expected={},
            idempotency_key="transient:stable-key",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [TransientThenSuccessAdapter()])
        first = runtime.next_action(task["task_id"])
        assert first is not None
        failed = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=first["attempt_id"],
            success=False,
            error="HTTP 503",
        )
        self.assertEqual(failed["attempt"]["latest_outcome"], "TRANSIENT_FAILURE")
        self.assertEqual(failed["action"]["status"], "retry_wait")
        self.assertEqual(failed["task"]["status"], "waiting")
        wait = store.get_runtime_state(task["task_id"])
        self.assertEqual(wait["wait_kind"], "RETRY_BACKOFF")
        self.assertIsNone(runtime.next_action(task["task_id"]))

        runtime.resume_retry_wait(
            task_id=task["task_id"],
            action_id=action["action_id"],
            wait_id=wait["wait_id"],
        )
        second = runtime.next_action(task["task_id"])
        assert second is not None
        self.assertEqual(second["attempt_number"], 2)
        self.assertEqual(second["action_id"], first["action_id"])
        self.assertEqual(second["idempotency_key"], first["idempotency_key"])
        success = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=second["attempt_id"],
            success=True,
            output={"ok": True},
        )
        self.assertEqual(success["task"]["status"], "completed")
        self.assertEqual([a["latest_outcome"] for a in store.action_attempts(action["action_id"])], ["TRANSIENT_FAILURE", "SUCCESS"])

    def test_user_turn_during_retry_backoff_supersedes_old_retry_and_clears_wait(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("retry-steering", "旧操作", "unit", {}, status="active")
        action = store.create_action(
            action_id="retry-steering-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="test.transient",
            payload={"value": 7},
            expected={},
            idempotency_key="retry-steering:stable",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [TransientThenSuccessAdapter()])
        first = runtime.next_action(task["task_id"])
        assert first is not None
        runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=first["attempt_id"],
            success=False,
            error="HTTP 503",
        )
        waiting = store.get_runtime_state(task["task_id"])
        assert waiting is not None
        self.assertEqual(waiting["wait_kind"], "RETRY_BACKOFF")
        old_wait_id = waiting["wait_id"]

        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id="change-during-retry",
            event_type="USER_TURN",
            source="user",
            payload={
                "content": {"kind": "text", "text": "别重试这个了，改做别的"},
                "reply_context": None,
            },
        )

        current_action = store.get_action(action["action_id"])
        current_runtime = store.get_runtime_state(task["task_id"])
        assert current_action is not None and current_runtime is not None
        self.assertEqual(current_action["status"], "cancelled")
        self.assertEqual(store.get_task(task["task_id"])["status"], "active")
        self.assertEqual(current_runtime["phase"], "planning")
        self.assertIsNone(current_runtime["wait_kind"])
        self.assertIsNone(current_runtime["wait_id"])
        self.assertEqual(len(store.action_attempts(action["action_id"])), 1)
        self.assertIsNone(runtime.next_action(task["task_id"]))
        trace_types = [event["event_type"] for event in store.trace(task["task_id"])]
        self.assertIn("action.superseded_before_retry", trace_types)
        self.assertIsNotNone(old_wait_id)

    def test_max_attempts_is_enforced_after_reconciliation(self) -> None:
        store = Storage(":memory:")
        loop, task, action = self.make_probe(store)

        for number in range(1, 4):
            dispatch = loop.next_action(task["task_id"])
            assert dispatch is not None
            self.assertEqual(dispatch["attempt_number"], number)
            loop.execution.mark_current_attempt_unknown(
                task_id=task["task_id"],
                action_id=action["action_id"],
                reason=f"unknown-{number}",
            )
            loop.execution.reconcile_definitely_absent_retry_safe(
                task_id=task["task_id"],
                action_id=action["action_id"],
            )

        with self.assertRaisesRegex(RuntimeError, "exhausted max attempts"):
            loop.next_action(task["task_id"])
        self.assertEqual(len(store.action_attempts(action["action_id"])), 3)


if __name__ == "__main__":
    unittest.main()
