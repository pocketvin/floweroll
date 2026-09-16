from __future__ import annotations

import unittest

from floweroll_host.alarm_cancel_adapter import AlarmCancelAdapter
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.storage import Storage


class AlarmCancelAdapterTests(unittest.TestCase):
    def test_verified_absence_completes_cancel(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("alarm-cancel-task", "取消闹钟", "unit", {}, status="active")
        store.create_action(
            action_id="alarm-cancel-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="alarm.cancel",
            payload={"alarm_id": "1F82C9B7-3DC5-47A1-9101-31E7647B1B5E"},
            expected={},
            idempotency_key="alarm-cancel-task:1",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [AlarmCancelAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        runtime.accept_result(
            task_id=task["task_id"],
            action_id="alarm-cancel-action",
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "alarm_id": "1F82C9B7-3DC5-47A1-9101-31E7647B1B5E",
                "cancelled": True,
                "verified_absent": True,
            },
        )
        self.assertEqual(store.get_task(task["task_id"])["status"], "completed")

    def test_unverified_cancel_is_rejected(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("alarm-cancel-bad-task", "取消闹钟", "unit", {}, status="active")
        store.create_action(
            action_id="alarm-cancel-bad-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="alarm.cancel",
            payload={"alarm_id": "1F82C9B7-3DC5-47A1-9101-31E7647B1B5E"},
            expected={},
            idempotency_key="alarm-cancel-bad-task:1",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [AlarmCancelAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        runtime.accept_result(
            task_id=task["task_id"],
            action_id="alarm-cancel-bad-action",
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "alarm_id": "1F82C9B7-3DC5-47A1-9101-31E7647B1B5E",
                "cancelled": True,
            },
        )
        self.assertEqual(store.get_task(task["task_id"])["status"], "failed")


if __name__ == "__main__":
    unittest.main()
