from __future__ import annotations

import ast
import copy
import unittest
from pathlib import Path

from floweroll_host.capability_discovery import (
    CapabilityContextSelector,
    SEARCH_ID,
    register_capability_discovery,
)
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.deterministic_calc import (
    ARGUMENT_SCHEMA,
    CAPABILITY_DESCRIPTION,
    CAPABILITY_ID,
    CalculationError,
    execute,
    execute_safe,
    readiness,
    verify,
)
from floweroll_host.deterministic_calc_adapter import (
    DeterministicCalcAdapter,
    register_deterministic_calc_capability,
)
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.planner_contracts import CapabilitySpec, DecisionContext, PlannerDecision
from floweroll_host.server import HostApp
from floweroll_host.storage import Storage
from floweroll_host.task_capability_policy import EffectiveTaskCapabilityPolicy, capability_semantics


class DeterministicCalcCoreTests(unittest.TestCase):
    def result(self, arguments):
        return execute(arguments)["result"]

    def code(self, arguments):
        value = execute_safe(arguments)
        self.assertFalse(value["ok"], value)
        return value["failure"]["code"]

    def test_readiness_is_local_and_complete(self):
        status = readiness()
        self.assertTrue(status["ready"])
        self.assertTrue(status["requirements"]["iana_zoneinfo"])
        self.assertFalse(status["requires_network"])
        self.assertFalse(status["requires_credentials"])
        self.assertFalse(status["requires_filesystem_side_effect"])

    def test_decimal_arithmetic_preserves_exact_decimal_and_negative_values(self):
        self.assertEqual(self.result({"operation": "add", "left": "0.1", "right": "0.2"})["value"], "0.3")
        self.assertEqual(self.result({"operation": "subtract", "left": "2.5", "right": "10"})["value"], "-7.5")
        self.assertEqual(self.result({"operation": "multiply", "left": "-1.25", "right": "8"})["value"], "-10")

    def test_division_requires_precision_and_rounds_deterministically(self):
        self.assertEqual(self.code({"operation": "divide", "left": "1", "right": "3"}), "PRECISION_REQUIRED")
        result = self.result(
            {"operation": "divide", "left": "1", "right": "3", "scale": 6, "rounding": "HALF_EVEN"}
        )
        self.assertEqual(result["value"], "0.333333")
        even = self.result({"operation": "add", "left": "2.345", "right": "0", "scale": 2, "rounding": "HALF_EVEN"})
        up = self.result({"operation": "add", "left": "2.345", "right": "0", "scale": 2, "rounding": "HALF_UP"})
        self.assertEqual(even["value"], "2.34")
        self.assertEqual(up["value"], "2.35")

    def test_percentage_success_corpus(self):
        percent = self.result({"operation": "percent_of", "value": "200", "percent": "15"})
        self.assertEqual(percent["value"], "30")
        change = self.result(
            {"operation": "percent_change", "from_value": "80", "to_value": "100", "scale": 2}
        )
        self.assertEqual(change["value"], "25.00")
        self.assertEqual(change["unit"], "percent")

    def test_unit_conversion_success_corpus(self):
        distance = self.result(
            {"operation": "unit_convert", "value": "1", "from_unit": "mi", "to_unit": "km", "scale": 6}
        )
        self.assertEqual(distance["value"], "1.609344")
        mass = self.result(
            {"operation": "unit_convert", "value": "1000", "from_unit": "g", "to_unit": "kg", "scale": 3}
        )
        self.assertEqual(mass["value"], "1.000")
        temp = self.result(
            {"operation": "unit_convert", "value": "100", "from_unit": "celsius", "to_unit": "fahrenheit", "scale": 2}
        )
        self.assertEqual(temp["value"], "212.00")

    def test_date_arithmetic_crosses_month_year_and_clamps(self):
        month = self.result({"operation": "date_add", "date": "2026-01-31", "amount": 1, "date_unit": "months"})
        self.assertEqual(month["value"], "2026-02-28")
        self.assertEqual(month["calendar_adjustment"], "clamped_to_last_day")
        self.assertEqual(
            self.result({"operation": "date_add", "date": "2026-12-31", "amount": 1, "date_unit": "days"})["value"],
            "2027-01-01",
        )
        self.assertEqual(
            self.result({"operation": "date_add", "date": "2026-03-01", "amount": -1, "date_unit": "days"})["value"],
            "2026-02-28",
        )
        leap = self.result({"operation": "date_add", "date": "2024-02-29", "amount": 1, "date_unit": "years"})
        self.assertEqual(leap["value"], "2025-02-28")

    def test_elapsed_time_uses_resolved_utc_instants_across_dst(self):
        value = self.result(
            {
                "operation": "time_difference",
                "start_datetime": "2026-03-08T01:30:00",
                "end_datetime": "2026-03-08T03:30:00",
                "timezone": "America/New_York",
            }
        )
        self.assertEqual(value["seconds"], "3600")
        self.assertEqual(value["start_utc"], "2026-03-08T06:30:00+00:00")
        self.assertEqual(value["end_utc"], "2026-03-08T07:30:00+00:00")

    def test_timezone_conversion_and_dst_overlap(self):
        value = self.result(
            {
                "operation": "timezone_convert",
                "datetime": "2026-07-01T09:00:00",
                "from_timezone": "Asia/Shanghai",
                "to_timezone": "America/New_York",
            }
        )
        self.assertEqual(value["value"], "2026-06-30T21:00:00-04:00")
        ambiguous = {
            "operation": "timezone_convert",
            "datetime": "2026-11-01T01:30:00",
            "from_timezone": "America/New_York",
            "to_timezone": "UTC",
        }
        self.assertEqual(self.code(ambiguous), "AMBIGUOUS_LOCAL_TIME")
        self.assertEqual(self.result({**ambiguous, "fold": 0})["value"], "2026-11-01T05:30:00+00:00")
        self.assertEqual(self.result({**ambiguous, "fold": 1})["value"], "2026-11-01T06:30:00+00:00")

    def test_accepted_failure_corpus_remains_distinct(self):
        cases = [
            ({"operation": "divide", "left": "4", "right": "0", "scale": 2}, "DIVIDE_BY_ZERO"),
            ({"operation": "unit_convert", "value": "1", "from_unit": "parsec", "to_unit": "m", "scale": 2}, "UNSUPPORTED_UNIT"),
            ({"operation": "unit_convert", "value": "1", "from_unit": "m", "to_unit": "kg", "scale": 2}, "INCOMPATIBLE_UNITS"),
            ({"operation": "timezone_convert", "datetime": "2026-01-01T12:00:00", "from_timezone": "Asia/Shanghai"}, "TIMEZONE_REQUIRED"),
            ({"operation": "timezone_convert", "datetime": "2026-01-01T12:00:00", "from_timezone": "CST", "to_timezone": "UTC"}, "INVALID_TIMEZONE"),
            ({"operation": "timezone_convert", "datetime": "2026-01-01T12:00:00", "from_timezone": "Mars/Base", "to_timezone": "UTC"}, "INVALID_TIMEZONE"),
            ({"operation": "timezone_convert", "datetime": "2026-03-08T02:30:00", "from_timezone": "America/New_York", "to_timezone": "UTC"}, "NONEXISTENT_LOCAL_TIME"),
            ({"operation": "divide", "left": "1", "right": "3"}, "PRECISION_REQUIRED"),
            ({"operation": "add", "left": "1" * 51, "right": "0"}, "PRECISION_LIMIT"),
            ({"operation": "sqrt", "left": "9"}, "UNSUPPORTED_OPERATION"),
        ]
        for payload, expected in cases:
            with self.subTest(payload=payload):
                self.assertEqual(self.code(payload), expected)

    def test_invalid_datetime_and_numeric_boundaries_are_distinct(self):
        self.assertEqual(
            self.code({"operation": "date_add", "date": "2026-02-30", "amount": 1, "date_unit": "days"}),
            "INVALID_DATETIME",
        )
        self.assertEqual(
            self.code({"operation": "unit_convert", "value": "-1", "from_unit": "kelvin", "to_unit": "celsius", "scale": 2}),
            "NUMERIC_BOUNDARY",
        )
        self.assertEqual(
            self.code({"operation": "add", "left": "1e999", "right": "1"}),
            "INVALID_PAYLOAD",
        )

    def test_direct_payload_type_hardening_never_raises(self):
        malformed = [
            ({"operation": [], "left": "1", "right": "2"}, "operation"),
            ({"operation": "percent_of", "value": [], "percent": "10"}, "value"),
            ({"operation": "unit_convert", "value": "1", "from_unit": [], "to_unit": "m", "scale": 2}, "from_unit"),
            ({"operation": "unit_convert", "value": "1", "from_unit": "m", "to_unit": {}, "scale": 2}, "to_unit"),
            ({"operation": "divide", "left": "1", "right": "3", "scale": 2, "rounding": []}, "rounding"),
            ({"operation": "time_difference", "start_datetime": "2026-01-01T00:00:00", "end_datetime": "2026-01-01T01:00:00", "timezone": {}}, "timezone"),
            ({"operation": "timezone_convert", "datetime": [], "from_timezone": "UTC", "to_timezone": "Asia/Shanghai"}, "datetime"),
        ]
        for payload, field in malformed:
            with self.subTest(field=field):
                envelope = execute_safe(payload)
                self.assertFalse(envelope["ok"])
                self.assertEqual(envelope["failure"]["code"], "INVALID_PAYLOAD")
                self.assertEqual(envelope["failure"]["field"], field)
                self.assertFalse(envelope["failure"]["retryable"])
                self.assertTrue(envelope["failure"]["model_correctable"])

    def test_non_object_direct_payload_is_stable_failure_envelope(self):
        for payload in (None, [], "1+2", 3):
            with self.subTest(payload=payload):
                envelope = execute_safe(payload)
                self.assertFalse(envelope["ok"])
                self.assertEqual(envelope["failure"]["code"], "INVALID_PAYLOAD")

    def test_verifier_recomputes_and_rejects_tampering(self):
        arguments = {"operation": "add", "left": "10.25", "right": "2.75"}
        output = execute(arguments)
        checked = verify(arguments, output)
        self.assertTrue(checked["verified"])
        self.assertEqual(checked["integrity_scope"], "shared_pure_core")
        tampered = copy.deepcopy(output)
        tampered["result"]["value"] = "999"
        rejected = verify(arguments, tampered)
        self.assertFalse(rejected["verified"])
        self.assertEqual(rejected["reason"], "deterministic_recompute_mismatch")

    def test_core_has_no_arbitrary_code_shell_network_or_filesystem_primitive(self):
        source = Path(__file__).parents[1] / "floweroll_host" / "deterministic_calc.py"
        tree = ast.parse(source.read_text(encoding="utf-8"))
        forbidden_imports = {"os", "subprocess", "socket", "urllib", "requests", "httpx", "pathlib", "shutil", "importlib"}
        forbidden_calls = {"eval", "exec", "compile", "open", "__import__"}
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    self.assertNotIn(alias.name.split(".")[0], forbidden_imports)
            elif isinstance(node, ast.ImportFrom) and node.module:
                self.assertNotIn(node.module.split(".")[0], forbidden_imports)
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                self.assertNotIn(node.func.id, forbidden_calls)


class DeterministicCalcProductionIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.registry = CapabilityRegistry()
        self.executors, self.health = register_deterministic_calc_capability(self.registry)
        self.spec = self.registry.get(CAPABILITY_ID).spec

    def runtime(self):
        store = Storage(":memory:")
        execution = ExecutionRuntime(
            store,
            self.registry.execution_adapters(),
            capability_specs=self.registry.planner_capabilities(include_deferred=True),
            capability_registry=self.registry,
        )
        worker = FunctionExecutionWorker(execution, self.registry, self.executors)
        return store, execution, worker

    def planner_decision(self, arguments):
        payload = {
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": "执行确定性计算",
            "plan_update": None,
            "action": {"capability": CAPABILITY_ID, "arguments": arguments},
            "on_verified": "COMPLETE",
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
        }
        return PlannerDecision.from_dict(payload, [self.spec])

    def test_registry_readiness_metadata_and_execution_profile(self):
        self.assertTrue(self.health["ready"])
        self.assertIn(CAPABILITY_ID, self.executors)
        entry = self.registry.get(CAPABILITY_ID)
        self.assertEqual(entry.source.kind, "host_local")
        self.assertEqual(entry.source.tool_name, CAPABILITY_ID)
        self.assertTrue(entry.source.metadata["read_only"])
        self.assertEqual(entry.source.metadata["effect"], "read")
        self.assertEqual(entry.source.metadata["operation"], "read")
        self.assertEqual(entry.source.metadata["domains"], ["work"])
        self.assertEqual(entry.adapter.execution_profile.verification_mode, "DETERMINISTIC_RECOMPUTE")
        self.assertEqual(entry.adapter.execution_profile.max_attempts, 1)

    def test_current_planner_schema_accepts_typed_payload_and_rejects_wrong_types(self):
        decision = self.planner_decision({"operation": "add", "left": "0.1", "right": "0.2"})
        self.assertEqual(decision.action["capability"], CAPABILITY_ID)
        with self.assertRaises(ValueError):
            self.planner_decision({"operation": "unit_convert", "value": "1", "from_unit": [], "to_unit": "m", "scale": 2})
        with self.assertRaises(ValueError):
            self.planner_decision({"operation": "sqrt", "left": "9"})
        with self.assertRaises(ValueError):
            self.planner_decision({"operation": "add", "left": "1", "right": "2", "expression": "1+2"})

    def test_selector_surfaces_calculation_for_calculation_unit_and_timezone_goals(self):
        storage = Storage(":memory:")
        specs = [self.spec]
        register_capability_discovery(self.registry, storage, lambda: specs)
        specs.append(self.registry.get(SEARCH_ID).spec)
        for goal in ("计算 200 的 15%", "Convert 1 mile to kilometers", "上海上午9点换算纽约时间"):
            with self.subTest(goal=goal):
                selected = CapabilityContextSelector(self.registry).apply(
                    DecisionContext(
                        task_id="calc-selector",
                        raw_goal=goal,
                        task_status="ACTIVE",
                        phase="planning",
                        current_time="2026-09-12T03:00:00+08:00",
                        timezone="Asia/Shanghai",
                        policy_view={"allowed_capabilities": [item.name for item in specs]},
                        capabilities=specs,
                    )
                )
                self.assertIn(CAPABILITY_ID, [item.name for item in selected.capabilities])

    def test_task_policy_classifies_calculation_as_read_only(self):
        semantics = capability_semantics(self.spec, self.registry)
        self.assertEqual(semantics.operation, "read")
        self.assertEqual(semantics.effect, "read")
        self.assertEqual(semantics.domains, frozenset({"work"}))
        policy = EffectiveTaskCapabilityPolicy.from_texts(["只读处理，不要修改任何内容"])
        self.assertTrue(policy.decide(self.spec, self.registry).allowed)

    def test_runtime_action_attempt_executor_verifier_observation_complete(self):
        store, _, worker = self.runtime()
        task = store.create_task("calc-success", "计算 200 的 15%", "unit", {}, status="active")
        store.create_action(
            action_id="calc-success-action",
            task_id=task["task_id"],
            step_index=1,
            action_type=CAPABILITY_ID,
            payload={"operation": "percent_of", "value": "200", "percent": "15"},
            expected={},
            idempotency_key="calc-success:1",
            on_verified="COMPLETE",
        )
        result = worker.run_once(task["task_id"])
        self.assertIsNotNone(result)
        completed_task = store.get_task(task["task_id"])
        self.assertEqual(completed_task["status"], "completed")
        self.assertEqual(completed_task["result"]["summary"], "200 的 15% 是 30。")
        attempt = store.action_attempts("calc-success-action")[0]
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        self.assertEqual(attempt["source_kind"], "host_local")
        observation = store.verified_observations(task["task_id"])[0]["data"]
        self.assertEqual(observation["result"]["value"], "30")
        self.assertEqual(observation["verification"]["method"], "deterministic_recompute")
        self.assertEqual(observation["verification"]["integrity_scope"], "shared_pure_core")

    def test_malformed_direct_action_is_model_correctable_and_never_fake_success(self):
        store, _, worker = self.runtime()
        task = store.create_task("calc-invalid", "做单位换算", "unit", {}, status="active")
        store.create_action(
            action_id="calc-invalid-action",
            task_id=task["task_id"],
            step_index=1,
            action_type=CAPABILITY_ID,
            payload={"operation": "unit_convert", "value": "1", "from_unit": [], "to_unit": "m", "scale": 2},
            expected={},
            idempotency_key="calc-invalid:1",
            on_verified="COMPLETE",
        )
        worker.run_once(task["task_id"])
        attempt = store.action_attempts("calc-invalid-action")[0]
        self.assertEqual(attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
        self.assertEqual(attempt["result"]["failure"]["code"], "INVALID_PAYLOAD")
        self.assertEqual(store.verified_observations(task["task_id"]), [])
        self.assertNotEqual(store.get_task(task["task_id"])["status"], "completed")

    def test_task_policy_denial_stops_before_attempt_and_observation(self):
        store, execution, worker = self.runtime()
        task = store.create_task("calc-denied", "不要读取或计算任何内容", "unit", {}, status="active")
        store.create_action(
            action_id="calc-denied-action",
            task_id=task["task_id"],
            step_index=1,
            action_type=CAPABILITY_ID,
            payload={"operation": "add", "left": "1", "right": "2"},
            expected={},
            idempotency_key="calc-denied:1",
            on_verified="COMPLETE",
        )
        self.assertIsNone(worker.run_once(task["task_id"]))
        self.assertEqual(store.action_attempts("calc-denied-action"), [])
        self.assertEqual(store.verified_observations(task["task_id"]), [])
        action = store.get_action("calc-denied-action")
        self.assertEqual(action["status"], "failed")
        self.assertEqual(action["failure_code"], "TASK_DENIED")

    def test_adapter_rejects_tampered_success_result(self):
        adapter = DeterministicCalcAdapter()
        payload = {"operation": "add", "left": "1", "right": "2"}
        good = execute_safe(payload)
        bad = copy.deepcopy(good)
        bad["output"]["result"]["value"] = "999"
        verification = adapter.verify_result(
            {"payload": payload}, success=True, output=bad, error=None
        )
        self.assertEqual(verification.outcome, "TERMINAL_FAILURE")
        self.assertIn("recompute", verification.error)

    def test_capability_status_reports_ready_when_executor_is_present(self):
        app = HostApp(
            ":memory:",
            capability_registry=self.registry,
            function_executors=self.executors,
        )
        try:
            by_id = {item["capability_id"]: item for item in app.capability_status()["capabilities"]}
            self.assertTrue(by_id[CAPABILITY_ID]["ready"])
            self.assertEqual(by_id[CAPABILITY_ID]["source"]["kind"], "host_local")
        finally:
            app.close()

    def test_production_run_host_wires_registration_into_function_executors(self):
        run_host = Path(__file__).parents[1] / "run_host.py"
        source = run_host.read_text(encoding="utf-8")
        self.assertIn("register_deterministic_calc_capability", source)
        self.assertIn("calc_executors, calc_health = register_deterministic_calc_capability(registry)", source)
        self.assertIn("function_executors.update(calc_executors)", source)


if __name__ == "__main__":
    unittest.main()
