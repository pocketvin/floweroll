from __future__ import annotations

import unittest

from floweroll_host.alarm_adapter import (
    AlarmCreateAdapter,
    AlarmPauseAdapter,
    AlarmQueryAdapter,
    AlarmResumeAdapter,
    AlarmUpdateAdapter,
)
from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.capability_discovery import rank_capabilities
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.storage import Storage
from floweroll_host.task_capability_policy import capability_semantics


ALARM_ID = "1F82C9B7-3DC5-47A1-9101-31E7647B1B5E"
WEEKLY = {
    "kind": "weekly",
    "hour": 8,
    "minute": 15,
    "weekdays": ["tuesday", "thursday"],
}


class AlarmManagementAdapterTests(unittest.TestCase):
    def action(self, capability: str, payload: dict, key: str = "alarm-key") -> dict:
        return {
            "action_id": f"action-{capability}",
            "task_id": "task-alarm-management",
            "step_index": 1,
            "action_type": capability,
            "payload": payload,
            "expected": {},
            "idempotency_key": key,
            "on_verified": "COMPLETE",
        }

    def test_planner_surface_is_six_management_capabilities_and_read_stays_internal(self) -> None:
        names = [spec.name for spec in product_native_capabilities() if spec.name.startswith("alarm.")]
        self.assertEqual(
            names,
            ["alarm.query", "alarm.create", "alarm.update", "alarm.pause", "alarm.resume", "alarm.cancel"],
        )
        self.assertNotIn("alarm.read", names)

    def test_alarm_capability_policy_semantics_are_read_create_modify_delete(self) -> None:
        specs = {spec.name: spec for spec in product_native_capabilities()}
        self.assertEqual(capability_semantics(specs["alarm.query"]).operation, "read")
        self.assertEqual(capability_semantics(specs["alarm.create"]).operation, "create")
        for name in ("alarm.update", "alarm.pause", "alarm.resume"):
            semantics = capability_semantics(specs[name])
            self.assertEqual(semantics.operation, "modify", name)
            self.assertEqual(semantics.effect, "write", name)
        self.assertEqual(capability_semantics(specs["alarm.cancel"]).operation, "delete")

    def test_alarm_retrieval_prefers_requested_management_operation(self) -> None:
        specs = [spec for spec in product_native_capabilities() if spec.name.startswith("alarm.")]
        registry = CapabilityRegistry()
        cases = [
            ("查询我的小卷闹钟", "alarm.query"),
            ("暂停这个闹钟", "alarm.pause"),
            ("恢复这个闹钟", "alarm.resume"),
            ("修改这个闹钟到八点", "alarm.update"),
            ("取消这个闹钟", "alarm.cancel"),
        ]
        for query, expected in cases:
            with self.subTest(query=query):
                ranked = rank_capabilities(specs, query, registry)
                self.assertEqual(ranked[0].name, expected)

    def test_typed_weekly_create_verifier_accepts_full_readback_and_rejects_mismatch(self) -> None:
        adapter = AlarmCreateAdapter()
        action = self.action(
            "alarm.create",
            {"title": "工作日", "schedule": WEEKLY, "sound": "default"},
            key="create-weekly",
        )
        good = adapter.verify_result(
            action,
            success=True,
            error=None,
            output={
                "alarm_id": ALARM_ID,
                "idempotency_marker": "create-weekly",
                "verified": True,
                "native_schedule_verified": True,
                "title": "工作日",
                "sound": "default",
                "schedule": dict(WEEKLY),
            },
        )
        self.assertEqual(good.outcome, "SUCCESS")
        bad = adapter.verify_result(
            action,
            success=True,
            error=None,
            output={
                "alarm_id": ALARM_ID,
                "idempotency_marker": "create-weekly",
                "verified": True,
                "native_schedule_verified": True,
                "title": "工作日",
                "sound": "default",
                "schedule": {**WEEKLY, "hour": 9},
            },
        )
        self.assertEqual(bad.outcome, "TERMINAL_FAILURE")

    def test_fixed_create_verifier_compares_real_instants_across_iso_spellings(self) -> None:
        adapter = AlarmCreateAdapter()
        cases = [
            ("2030-01-02T07:00:00+08:00", "2030-01-01T23:00:00Z", "SUCCESS"),
            ("2030-01-01T23:00:00Z", "2030-01-01T23:00:00.000Z", "SUCCESS"),
            ("2030-01-02T07:00:00+08:00", "2030-01-01T23:00:01Z", "TERMINAL_FAILURE"),
            ("2030-01-01T23:00:00", "2030-01-01T23:00:00Z", "TERMINAL_FAILURE"),
            ("not-an-instant", "2030-01-01T23:00:00Z", "TERMINAL_FAILURE"),
        ]
        for expected, actual, outcome in cases:
            with self.subTest(expected=expected, actual=actual):
                action = self.action(
                    "alarm.create",
                    {"title": "固定闹钟", "fire_at": expected},
                    key="fixed-create-instant",
                )
                result = adapter.verify_result(
                    action, success=True, error=None,
                    output={
                        "alarm_id": ALARM_ID,
                        "fire_at": actual,
                        "idempotency_marker": "fixed-create-instant",
                        "verified": True,
                        "native_schedule_verified": True,
                        "title": "固定闹钟",
                        "sound": "default",
                        "schedule": {"kind": "fixed", "fire_at": actual},
                    },
                )
                self.assertEqual(result.outcome, outcome)

        non_string = self.action(
            "alarm.create", {"title": "固定闹钟", "fire_at": 123}, key="fixed-create-non-string"
        )
        result = adapter.verify_result(
            non_string, success=True, error=None,
            output={
                "alarm_id": ALARM_ID, "fire_at": "2030-01-01T23:00:00Z",
                "idempotency_marker": "fixed-create-non-string", "verified": True,
                "native_schedule_verified": True, "title": "固定闹钟", "sound": "default",
                "schedule": {"kind": "fixed", "fire_at": "2030-01-01T23:00:00Z"},
            },
        )
        self.assertEqual(result.outcome, "TERMINAL_FAILURE")

    def test_fixed_update_verifier_compares_real_instants_and_fails_closed(self) -> None:
        adapter = AlarmUpdateAdapter()
        cases = [
            ("2030-01-02T07:00:00+08:00", "2030-01-01T23:00:00Z", "SUCCESS"),
            ("2030-01-01T23:00:00Z", "2030-01-01T23:00:00.000Z", "SUCCESS"),
            ("2030-01-02T07:00:00+08:00", "2030-01-01T23:00:01Z", "TERMINAL_FAILURE"),
            ("2030-01-01T23:00:00", "2030-01-01T23:00:00Z", "TERMINAL_FAILURE"),
            ("invalid", "2030-01-01T23:00:00Z", "TERMINAL_FAILURE"),
        ]
        for expected, actual, outcome in cases:
            with self.subTest(expected=expected, actual=actual):
                action = self.action(
                    "alarm.update",
                    {
                        "alarm_id": ALARM_ID, "title": "固定更新", "sound": "default",
                        "schedule": {"kind": "fixed", "fire_at": expected},
                    },
                    key="fixed-update-instant",
                )
                result = adapter.verify_result(
                    action, success=True, error=None,
                    output={
                        "alarm_id": ALARM_ID, "same_alarm_id": True, "updated": True,
                        "verified": True, "native_schedule_verified": True, "title": "固定更新",
                        "sound": "default", "schedule": {"kind": "fixed", "fire_at": actual},
                        "idempotency_marker": "fixed-update-instant", "native_state": "scheduled",
                    },
                )
                self.assertEqual(result.outcome, outcome)

        action = self.action(
            "alarm.update",
            {
                "alarm_id": ALARM_ID, "title": "固定更新", "sound": "default",
                "schedule": {"kind": "fixed", "fire_at": 123},
            },
            key="fixed-update-non-string",
        )
        result = adapter.verify_result(
            action, success=True, error=None,
            output={
                "alarm_id": ALARM_ID, "same_alarm_id": True, "updated": True,
                "verified": True, "native_schedule_verified": True, "title": "固定更新",
                "sound": "default",
                "schedule": {"kind": "fixed", "fire_at": "2030-01-01T23:00:00Z"},
                "idempotency_marker": "fixed-update-non-string", "native_state": "scheduled",
            },
        )
        self.assertEqual(result.outcome, "TERMINAL_FAILURE")

    def test_query_verifier_requires_owned_readback(self) -> None:
        adapter = AlarmQueryAdapter()
        action = self.action("alarm.query", {"max_results": 10})
        good = adapter.verify_result(
            action,
            success=True,
            error=None,
            output={
                "verified": True,
                "ownership_scope": "floweroll_owned_only",
                "count": 1,
                "alarms": [{"alarm_id": ALARM_ID, "ownership_ledger_present": True, "state": "scheduled"}],
            },
        )
        self.assertEqual(good.outcome, "SUCCESS")
        unowned = adapter.verify_result(
            action,
            success=True,
            error=None,
            output={
                "verified": True,
                "ownership_scope": "floweroll_owned_only",
                "count": 1,
                "alarms": [{"alarm_id": ALARM_ID, "ownership_ledger_present": False}],
            },
        )
        self.assertEqual(unowned.outcome, "TERMINAL_FAILURE")

    def test_update_verifier_requires_same_id_and_all_requested_fields(self) -> None:
        adapter = AlarmUpdateAdapter()
        action = self.action(
            "alarm.update",
            {"alarm_id": ALARM_ID, "title": "新标题", "schedule": WEEKLY, "sound": "default"},
            key="update-key",
        )
        output = {
            "alarm_id": ALARM_ID,
            "same_alarm_id": True,
            "updated": True,
            "verified": True,
            "native_schedule_verified": True,
            "title": "新标题",
            "sound": "default",
            "schedule": dict(WEEKLY),
            "idempotency_marker": "update-key",
            "native_state": "scheduled",
        }
        self.assertEqual(adapter.verify_result(action, success=True, output=output, error=None).outcome, "SUCCESS")
        wrong_id = dict(output, alarm_id="00000000-0000-0000-0000-000000000000")
        self.assertEqual(adapter.verify_result(action, success=True, output=wrong_id, error=None).outcome, "TERMINAL_FAILURE")
        wrong_days = dict(output, schedule={**WEEKLY, "weekdays": ["monday"]})
        self.assertEqual(adapter.verify_result(action, success=True, output=wrong_days, error=None).outcome, "TERMINAL_FAILURE")

    def test_pause_resume_verifiers_require_native_target_state(self) -> None:
        pause = AlarmPauseAdapter()
        resume = AlarmResumeAdapter()
        pause_action = self.action("alarm.pause", {"alarm_id": ALARM_ID})
        resume_action = self.action("alarm.resume", {"alarm_id": ALARM_ID})
        self.assertEqual(
            pause.verify_result(
                pause_action,
                success=True,
                error=None,
                output={"alarm_id": ALARM_ID, "operation": "pause", "native_state": "paused", "verified": True},
            ).outcome,
            "SUCCESS",
        )
        self.assertEqual(
            pause.verify_result(
                pause_action,
                success=True,
                error=None,
                output={"alarm_id": ALARM_ID, "operation": "pause", "native_state": "countdown", "verified": True},
            ).outcome,
            "TERMINAL_FAILURE",
        )
        for state in ("countdown", "scheduled"):
            self.assertEqual(
                resume.verify_result(
                    resume_action,
                    success=True,
                    error=None,
                    output={"alarm_id": ALARM_ID, "operation": "resume", "native_state": state, "verified": True},
                ).outcome,
                "SUCCESS",
            )
        self.assertEqual(
            resume.verify_result(
                resume_action,
                success=True,
                error=None,
                output={"alarm_id": ALARM_ID, "operation": "resume", "native_state": "paused", "verified": True},
            ).outcome,
            "TERMINAL_FAILURE",
        )

    def test_alarm_device_failures_are_classified_without_fake_terminal_success(self) -> None:
        create = AlarmCreateAdapter()
        create_action = self.action(
            "alarm.create",
            {"title": "起床", "schedule": {"kind": "fixed", "fire_at": "2030-01-02T07:00:00+08:00"}, "sound": "default"},
        )
        invalid = create.verify_result(
            create_action, success=False, error="alarm_invalid_arguments",
            output={"error_code": "alarm_invalid_arguments"},
        )
        self.assertEqual(invalid.outcome, "MODEL_CORRECTABLE_FAILURE")

        query = AlarmQueryAdapter()
        query_action = self.action("alarm.query", {})
        read_failure = query.verify_result(
            query_action, success=False, error="alarm_query_failed",
            output={"error_code": "alarm_query_failed"},
        )
        self.assertEqual(read_failure.outcome, "TRANSIENT_FAILURE")

        pause = AlarmPauseAdapter()
        pause_action = self.action("alarm.pause", {"alarm_id": ALARM_ID})
        state_failure = pause.verify_result(
            pause_action, success=False, error="alarm_invalid_native_state",
            output={"error_code": "alarm_invalid_native_state"},
        )
        self.assertEqual(state_failure.outcome, "MODEL_CORRECTABLE_FAILURE")

        hard = pause.verify_result(
            pause_action, success=False, error="alarm_readback_mismatch",
            output={"error_code": "alarm_readback_mismatch"},
        )
        self.assertEqual(hard.outcome, "TERMINAL_FAILURE")

        pending = pause.verify_result(
            pause_action, success=False, error="alarm_settings_mutation_pending",
            output={"error_code": "alarm_settings_mutation_pending"},
        )
        self.assertEqual(pending.outcome, "MODEL_CORRECTABLE_FAILURE")

    def test_update_result_completes_runtime_and_persists_verified_observation(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("alarm-update-task", "修改闹钟", "unit", {}, status="active")
        action = self.action(
            "alarm.update",
            {"alarm_id": ALARM_ID, "title": "新标题", "schedule": WEEKLY, "sound": "default"},
            key="runtime-update-key",
        )
        action["task_id"] = task["task_id"]
        store.create_action(**action)
        runtime = ExecutionRuntime(store, [AlarmUpdateAdapter()])
        dispatch = runtime.next_action(task["task_id"], source_kind="ios")
        assert dispatch is not None
        result = runtime.accept_result(
            task_id=task["task_id"],
            action_id=action["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=True,
            output={
                "alarm_id": ALARM_ID,
                "same_alarm_id": True,
                "updated": True,
                "verified": True,
                "native_schedule_verified": True,
                "title": "新标题",
                "sound": "default",
                "schedule": dict(WEEKLY),
                "idempotency_marker": "runtime-update-key",
                "native_state": "scheduled",
            },
        )
        self.assertFalse(result["duplicate"])
        self.assertEqual(store.get_task(task["task_id"])["status"], "completed")
        observation = store.verified_observations(task["task_id"])[0]
        self.assertEqual(observation["capability"], "alarm.update")
        self.assertEqual(observation["data"]["alarm_id"], ALARM_ID)
        self.assertTrue(observation["data"]["same_alarm_id"])


if __name__ == "__main__":
    unittest.main()
