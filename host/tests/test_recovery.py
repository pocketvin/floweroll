from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from floweroll_host.agent_loop import AgentLoop
from floweroll_host.capabilities_v0 import REMINDER_CREATE
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.recovery import RecoveryCoordinator
from floweroll_host.server import create_server
from floweroll_host.storage import InvalidPlannerTransitionError, Storage
from floweroll_host.task_runtime import TaskRuntime


class QueuePlanner:
    def __init__(self, decisions):
        self.decisions = list(decisions)

    def decide(self, request_body, capabilities):
        if not self.decisions:
            raise AssertionError("unexpected Planner call")
        decision = self.decisions.pop(0)
        decision.validate(capabilities)
        return decision


def wait_decision(resume_at: str) -> PlannerDecision:
    return PlannerDecision.from_dict(
        {
            "decision_type": "WAIT",
            "interpreted_goal_summary": "等到指定时间继续",
            "plan_update": ["等待", "继续"],
            "action": None,
            "on_verified": None,
            "clarification": None,
            "wait": {"kind": "until_time", "resume_at": resume_at, "condition": None},
            "completion": None,
            "stop_reason": None,
            "state_update": {"pending_clarification": None, "current_task_brief": None},
        },
        [REMINDER_CREATE],
    )


class RecoveryTests(unittest.TestCase):
    def test_due_planner_wait_becomes_timer_event_then_resumes(self) -> None:
        store = Storage(":memory:")
        runtime = TaskRuntime(
            store,
            QueuePlanner([wait_decision("2026-09-10T20:00:00+08:00")]),
            [REMINDER_CREATE],
        )
        task = runtime.create_task("晚上八点继续")
        runtime.decide(
            task["task_id"],
            current_time=datetime(2026, 9, 10, 19, 0, tzinfo=ZoneInfo("Asia/Shanghai")),
        )
        before = store.get_runtime_state(task["task_id"])
        assert before is not None
        wait_id = before["wait_id"]
        self.assertEqual(before["wait_kind"], "TIME")

        # 12:01Z is 20:01 +08. julianday comparison must treat them as the
        # same absolute clock rather than compare ISO strings lexically.
        recovered = RecoveryCoordinator(store).recover_due(
            now=datetime(2026, 9, 10, 12, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0]["owner"], "PLANNER")
        self.assertEqual(recovered[0]["status"], "RECOVERED")

        after = store.get_runtime_state(task["task_id"])
        assert after is not None
        self.assertEqual(store.get_task(task["task_id"])["status"], "active")
        self.assertEqual(after["phase"], "planning")
        self.assertIsNone(after["wait_id"])
        timer_events = [e for e in store.inbox_events(task["task_id"]) if e["event_type"] == "TIMER_FIRED"]
        self.assertEqual(len(timer_events), 1)
        self.assertEqual(timer_events[0]["event_id"], f"timer:{wait_id}")
        self.assertEqual(timer_events[0]["status"], "CONSUMED")

    def test_timer_event_survives_crash_between_fire_and_resume(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "timer.sqlite3")
            first = Storage(db)
            runtime = TaskRuntime(
                first,
                QueuePlanner([wait_decision("2026-09-10T20:00:00+08:00")]),
                [REMINDER_CREATE],
            )
            task = runtime.create_task("八点继续")
            runtime.decide(
                task["task_id"],
                current_time=datetime(2026, 9, 10, 19, 0, tzinfo=ZoneInfo("Asia/Shanghai")),
            )
            state = first.get_runtime_state(task["task_id"])
            assert state is not None
            wait_id = state["wait_id"]
            event_id = f"timer:{wait_id}"
            first.admit_inbox_event(
                task_id=task["task_id"],
                event_id=event_id,
                event_type="TIMER_FIRED",
                source="runtime_scheduler",
                target_type="WAIT",
                target_id=wait_id,
                payload={"wait_id": wait_id, "scheduled_for": state["wait"]["resume_at"]},
            )
            self.assertEqual(first.inbox_events(task["task_id"])[0]["status"], "ACCEPTED")

            # New Storage instance simulates Host restart. Recovery must reuse
            # the already-admitted timer event, not emit a second one.
            second = Storage(db)
            recovered = RecoveryCoordinator(second).recover_due(
                now=datetime(2026, 9, 10, 12, 2, tzinfo=timezone.utc)
            )
            self.assertEqual(recovered[0]["status"], "RECOVERED")
            self.assertTrue(recovered[0]["event_replay"])
            events = second.inbox_events(task["task_id"])
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["status"], "CONSUMED")
            self.assertEqual(second.get_task(task["task_id"])["status"], "active")

    def test_old_wait_id_cannot_wake_replaced_wait(self) -> None:
        store = Storage(":memory:")
        runtime = TaskRuntime(
            store,
            QueuePlanner([wait_decision("2026-09-10T20:00:00+08:00")]),
            [REMINDER_CREATE],
        )
        task = runtime.create_task("八点继续")
        runtime.decide(task["task_id"])
        state = store.get_runtime_state(task["task_id"])
        assert state is not None

        with self.assertRaisesRegex(InvalidPlannerTransitionError, "stale wait event"):
            store.admit_inbox_event(
                task_id=task["task_id"],
                event_id="timer:wrong-wait",
                event_type="TIMER_FIRED",
                source="runtime_scheduler",
                target_type="WAIT",
                target_id="wrong-wait",
                payload={"wait_id": "wrong-wait"},
            )

    def test_due_retry_wait_recovers_without_blind_duplicate(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("retry recovery")
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None
        loop.execution.mark_current_attempt_unknown(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            reason="ambiguous timeout",
        )
        loop.execution.reconcile_definitely_absent_retry_safe(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            wake_at="2026-09-10T20:00:00+08:00",
        )

        recovered = RecoveryCoordinator(store).recover_due(
            now=datetime(2026, 9, 10, 12, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(recovered[0]["owner"], "EXECUTION_RETRY")
        self.assertEqual(store.get_action(dispatch["action_id"])["status"], "pending")
        second = loop.next_action(task["task_id"])
        assert second is not None
        self.assertEqual(second["attempt_number"], 2)

    def test_source_operation_survives_restart_and_resumes_same_attempt_poll_round(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "source-task.sqlite3")
            first_store = Storage(db)
            first_loop = AgentLoop(first_store)
            task = first_loop.create_task("模拟长 Provider Task")
            dispatch = first_loop.next_action(task["task_id"])
            assert dispatch is not None

            waiting = first_loop.execution.defer_to_source_operation(
                task_id=task["task_id"],
                action_id=dispatch["action_id"],
                attempt_id=dispatch["attempt_id"],
                source_operation_ref="mcp-task-123",
                source_status="working",
                poll_after="2026-09-10T20:00:00+08:00",
                ttl_at="2026-09-11T20:00:00+08:00",
            )
            wait_id = waiting["wait_id"]
            self.assertEqual(waiting["attempt"]["source_operation_ref"], "mcp-task-123")
            self.assertEqual(first_store.get_task(task["task_id"])["status"], "waiting")
            self.assertIsNone(first_loop.next_action(task["task_id"]))

            second_store = Storage(db)
            scan = RecoveryCoordinator(second_store).scan(
                now=datetime(2026, 9, 10, 12, 1, tzinfo=timezone.utc)
            )
            self.assertEqual(scan["due_waits"][0]["wait_id"], wait_id)
            self.assertEqual(scan["in_flight_attempts"][0]["source_operation_ref"], "mcp-task-123")

            recovered = RecoveryCoordinator(second_store).recover_due(
                now=datetime(2026, 9, 10, 12, 1, tzinfo=timezone.utc)
            )
            self.assertEqual(recovered[0]["owner"], "SOURCE_OPERATION")
            attempt = second_store.get_action_attempt(dispatch["attempt_id"])
            assert attempt is not None
            self.assertEqual(attempt["attempt_id"], dispatch["attempt_id"])
            self.assertEqual(attempt["source_round"], 1)
            self.assertEqual(attempt["source_operation_ref"], "mcp-task-123")
            self.assertEqual(second_store.get_task(task["task_id"])["status"], "active")
            self.assertIsNone(second_store.get_runtime_state(task["task_id"])["wait_id"])

            # A source operation has its own continuation path. The legacy
            # next-action endpoint must not replay the original invocation.
            second_loop = AgentLoop(second_store)
            self.assertIsNone(second_loop.next_action(task["task_id"]))

            # Final provider result completes the same Attempt, not Attempt #2.
            result = second_loop.execution.accept_result(
                task_id=task["task_id"],
                action_id=dispatch["action_id"],
                attempt_id=dispatch["attempt_id"],
                success=True,
                output={"echo": dispatch["payload"]["message"]},
            )
            self.assertEqual(result["attempt"]["attempt_number"], 1)
            self.assertEqual(result["attempt"]["latest_outcome"], "SUCCESS")
            self.assertEqual(result["task"]["status"], "completed")

    def test_host_startup_runs_due_wait_recovery_without_calling_planner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "startup.sqlite3")
            store = Storage(db)
            runtime = TaskRuntime(
                store,
                QueuePlanner([wait_decision("2000-01-01T00:00:00+00:00")]),
                [REMINDER_CREATE],
            )
            task = runtime.create_task("在 2000-01-01T00:00:00+00:00 到时后继续启动恢复")
            runtime.decide(task["task_id"])
            self.assertEqual(store.get_task(task["task_id"])["status"], "waiting")

            server = create_server("127.0.0.1", 0, db)
            try:
                self.assertEqual(len(server.app.startup_recovery_report), 1)
                self.assertEqual(server.app.startup_recovery_report[0]["owner"], "PLANNER")
                self.assertEqual(server.app.storage.get_task(task["task_id"])["status"], "active")
                self.assertEqual(
                    [e["status"] for e in server.app.storage.inbox_events(task["task_id"]) if e["event_type"] == "TIMER_FIRED"],
                    ["CONSUMED"],
                )
            finally:
                server.server_close()

    def test_source_operation_identity_cannot_change_within_attempt(self) -> None:
        store = Storage(":memory:")
        loop = AgentLoop(store)
        task = loop.create_task("source identity")
        dispatch = loop.next_action(task["task_id"])
        assert dispatch is not None
        first = loop.execution.defer_to_source_operation(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            source_operation_ref="provider-op-A",
            source_status="working",
            poll_after=None,
        )
        # Simulate an external notification bringing the same attempt back to
        # execution, then prove a different operation identity is rejected.
        state = store.get_runtime_state(task["task_id"])
        assert state is not None
        event_id = f"timer:{first['wait_id']}"
        store.admit_inbox_event(
            task_id=task["task_id"],
            event_id=event_id,
            event_type="TIMER_FIRED",
            source="test",
            target_type="WAIT",
            target_id=first["wait_id"],
            payload={"wait_id": first["wait_id"]},
        )
        store.resume_source_operation_from_timer(
            task_id=task["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            wait_id=first["wait_id"],
            event_id=event_id,
        )
        with self.assertRaisesRegex(InvalidPlannerTransitionError, "identity changed"):
            loop.execution.defer_to_source_operation(
                task_id=task["task_id"],
                action_id=dispatch["action_id"],
                attempt_id=dispatch["attempt_id"],
                source_operation_ref="provider-op-B",
                source_status="working",
                poll_after=None,
            )


if __name__ == "__main__":
    unittest.main()
