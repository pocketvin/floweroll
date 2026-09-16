from __future__ import annotations

import unittest

from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.reminder_adapter import ReminderCreateAdapter
from floweroll_host.storage import Storage


class ReminderAdapterTests(unittest.TestCase):
    def make_runtime(self):
        store = Storage(":memory:")
        task = store.create_task(
            "reminder-task",
            "明天10点提醒我面试",
            "unit",
            {},
            status="active",
        )
        action = store.create_action(
            action_id="reminder-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="reminder.create",
            payload={
                "title": "面试",
                "due_at": "2026-09-11T10:00:00+08:00",
            },
            expected={},
            idempotency_key="reminder-task:1:reminder.create",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [ReminderCreateAdapter()])
        dispatch = runtime.next_action(task["task_id"])
        assert dispatch is not None
        return store, runtime, task, action, dispatch

    def valid_output(self):
        return {
            "reminder_id": "native-reminder-1",
            "title": "面试",
            "due_at": "2026-09-11T10:00:00+08:00",
            "idempotency_marker": "reminder-task:1:reminder.create",
            "verified": True,
        }

    def test_read_back_verified_reminder_closes_exact_attempt(self) -> None:
        store, runtime, task, action, dispatch = self.make_runtime()
        result = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output=self.valid_output(),
        )

        self.assertEqual(result["task"]["status"], "completed")
        self.assertEqual(result["attempt"]["latest_outcome"], "SUCCESS")
        self.assertEqual(result["observation"]["source_attempt_id"], dispatch["attempt_id"])
        self.assertEqual(result["observation"]["data"]["reminder_id"], "native-reminder-1")
        self.assertEqual(
            store.get_action(action["action_id"])["execution_profile"]["verification_mode"],
            "DEVICE_READ_BACK",
        )

    def test_bare_success_without_device_verification_fails_closed(self) -> None:
        _, runtime, task, action, dispatch = self.make_runtime()
        result = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={"reminder_id": "native-reminder-1"},
        )
        self.assertEqual(result["task"]["status"], "failed")
        self.assertEqual(result["attempt"]["latest_outcome"], "TERMINAL_FAILURE")

    def test_mismatched_due_time_or_marker_is_not_accepted(self) -> None:
        for field, value in [
            ("due_at", "2026-09-11T11:00:00+08:00"),
            ("idempotency_marker", "different-action"),
        ]:
            with self.subTest(field=field):
                _, runtime, task, action, dispatch = self.make_runtime()
                output = self.valid_output()
                output[field] = value
                result = runtime.accept_result(
                    task_id=task["task_id"],
                    action_id=action["action_id"],
                    attempt_id=dispatch["attempt_id"],
                    success=True,
                    output=output,
                )
                self.assertEqual(result["task"]["status"], "failed")
                self.assertEqual(result["attempt"]["latest_outcome"], "TERMINAL_FAILURE")


if __name__ == "__main__":
    unittest.main()
