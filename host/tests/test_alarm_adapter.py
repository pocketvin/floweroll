from __future__ import annotations

import unittest

from floweroll_host.alarm_adapter import AlarmCreateAdapter
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.storage import Storage


class AlarmAdapterTests(unittest.TestCase):
    def test_alarm_readback_result_completes_action(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("alarm-task", "七点叫我起床", "unit", {}, status="active")
        store.create_action(
            action_id="alarm-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="alarm.create",
            payload={"title": "起床", "fire_at": "2026-09-12T07:00:00+08:00"},
            expected={},
            idempotency_key="alarm-task:1:alarm.create",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [AlarmCreateAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None

        result = runtime.accept_result(
            task_id=task["task_id"],
            action_id="alarm-action",
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "alarm_id": "1F82C9B7-3DC5-47A1-9101-31E7647B1B5E",
                "fire_at": "2026-09-12T07:00:00+08:00",
                "idempotency_marker": "alarm-task:1:alarm.create",
                "verified": True,
                "native_schedule_verified": True,
                "title": "起床",
                "sound": "default",
                "schedule": {"kind": "fixed", "fire_at": "2026-09-12T07:00:00+08:00"},
            },
        )
        self.assertFalse(result["duplicate"])
        self.assertEqual(store.get_task(task["task_id"])["status"], "completed")
        obs = store.verified_observations(task["task_id"])
        self.assertEqual(obs[0]["data"]["title"], "起床")
        self.assertEqual(obs[0]["data"]["alarm_id"], "1F82C9B7-3DC5-47A1-9101-31E7647B1B5E")

    def test_alarm_fake_success_without_readback_is_rejected(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("alarm-bad-task", "定闹钟", "unit", {}, status="active")
        store.create_action(
            action_id="alarm-bad-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="alarm.create",
            payload={"title": "测试", "fire_at": "2026-09-12T07:00:00+08:00"},
            expected={},
            idempotency_key="alarm-bad-task:1",
            on_verified="COMPLETE",
        )
        runtime = ExecutionRuntime(store, [AlarmCreateAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        runtime.accept_result(
            task_id=task["task_id"],
            action_id="alarm-bad-action",
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={"alarm_id": "fake"},
        )
        self.assertEqual(store.get_task(task["task_id"])["status"], "failed")


if __name__ == "__main__":
    unittest.main()
