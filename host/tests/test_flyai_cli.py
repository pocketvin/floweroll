from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path
from unittest.mock import patch

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.flyai_cli import (
    FLYAI_CLI_VERSION,
    FLYAI_HOTEL_SEARCH_ID,
    FlyAIHotelTools,
    flyai_cli_version,
    register_flyai_hotel_capability,
)
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker, FunctionToolError
from floweroll_host.host_secrets import hydrate_flyai_key_from_host_secret_store
from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.planner_request import PLANNER_SYSTEM_INSTRUCTIONS_V0
from floweroll_host.server import create_server
from floweroll_host.storage import Storage
from floweroll_host.task_capability_policy import capability_semantics


class FakeCLI:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def run_json(self, argv):
        self.calls.append(list(argv))
        if not self.responses:
            raise AssertionError("unexpected FlyAI CLI call")
        return self.responses.pop(0)


def future_dates(days: int = 6) -> tuple[str, str]:
    check_in = date.today() + timedelta(days=days)
    return check_in.isoformat(), (check_in + timedelta(days=1)).isoformat()


def hotel_item(
    item_id: str,
    *,
    name: str = "测试酒店",
    price: str = "¥188",
    url: str = "https://a.feizhu.com/test",
    address: str = "杭州市上城区测试路1号",
    nearby: str = "近杭州东站",
):
    return {
        "shId": item_id,
        "name": name,
        "address": address,
        "interestsPoi": nearby,
        "price": price,
        "detailUrl": url,
        "latitude": "30.270000",
        "longitude": "120.180000",
        "star": "舒适型",
        "rate": "4.7",
        "brandName": "测试品牌",
        "mainPic": "https://img.alicdn.com/test.png",
    }


def wrapped_payload(items, *, status=0, message="success", system_message=None):
    payload = {
        "status": status,
        "message": message,
        "data": {"itemList": items},
    }
    if system_message is not None:
        payload["systemMessage"] = system_message
    return {"data": payload, "truncated": False}


class FlyAIHotelTests(unittest.TestCase):
    def test_keychain_hydration_returns_source_not_secret(self) -> None:
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("FLYAI_API_KEY", None)
            with patch(
                "floweroll_host.host_secrets.read_macos_keychain_secret",
                return_value="secret-value",
            ) as lookup:
                source = hydrate_flyai_key_from_host_secret_store()
            self.assertEqual(source, "keychain")
            self.assertEqual(os.environ.get("FLYAI_API_KEY"), "secret-value")
            lookup.assert_called_once()

    def test_registration_is_deferred_without_key_and_ready_with_exact_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            executable = self._fake_install(Path(temp))
            self.assertEqual(flyai_cli_version(executable), FLYAI_CLI_VERSION)

            deferred_registry = CapabilityRegistry()
            deferred_executors, deferred_health = register_flyai_hotel_capability(
                deferred_registry,
                executable=executable,
                api_key="",
            )
            deferred_entry = deferred_registry.get(FLYAI_HOTEL_SEARCH_ID)
            self.assertEqual(deferred_entry.loading, "deferred")
            self.assertEqual(deferred_executors, {})
            self.assertFalse(deferred_health["ready"])
            self.assertEqual(deferred_health["reason"], "api_key_not_configured")

            ready_registry = CapabilityRegistry()
            ready_executors, ready_health = register_flyai_hotel_capability(
                ready_registry,
                executable=executable,
                api_key="test-key",
            )
            ready_entry = ready_registry.get(FLYAI_HOTEL_SEARCH_ID)
            self.assertEqual(ready_entry.loading, "always_visible")
            self.assertIn(FLYAI_HOTEL_SEARCH_ID, ready_executors)
            self.assertTrue(ready_health["ready"])
            semantics = capability_semantics(ready_entry.spec, ready_registry)
            self.assertEqual(semantics.operation, "read")
            self.assertEqual(semantics.domains, frozenset({"travel"}))

            check_in, check_out = future_dates()
            output = ready_executors[FLYAI_HOTEL_SEARCH_ID](
                {
                    "destination": "杭州",
                    "check_in_date": check_in,
                    "check_out_date": check_out,
                    "max_price": 500,
                }
            )
            self.assertEqual(output["provider"], "flyai_fliggy")
            self.assertEqual(output["item_count"], 1)
            self.assertEqual(output["items"][0]["price_amount"], 188.0)

    def test_capability_status_reports_ready_only_when_executor_is_live(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            executable = self._fake_install(root / "cli")
            registry = CapabilityRegistry()
            executors, _ = register_flyai_hotel_capability(
                registry,
                executable=executable,
                api_key="test-key",
            )
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "status.sqlite3"),
                capability_registry=registry,
                function_executors=executors,
            )
            try:
                by_id = {
                    item["capability_id"]: item
                    for item in server.app.capability_status()["capabilities"]
                }
                hotel = by_id[FLYAI_HOTEL_SEARCH_ID]
                self.assertTrue(hotel["ready"])
                self.assertEqual(hotel["loading"], "always_visible")
                self.assertEqual(hotel["source"]["kind"], "managed_cli")
                self.assertEqual(hotel["source"]["server_id"], "flyai-cli")
                self.assertNotIn("test-key", json.dumps(hotel))
            finally:
                server.server_close()

    def test_ready_hotel_search_runs_through_durable_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            executable = self._fake_install(Path(temp))
            registry = CapabilityRegistry()
            executors, health = register_flyai_hotel_capability(
                registry,
                executable=executable,
                api_key="test-key",
            )
            self.assertTrue(health["ready"])
            check_in, check_out = future_dates()
            store = Storage(":memory:")
            task = store.create_task(
                "flyai-task",
                "查询杭州酒店",
                "unit",
                {},
                status="active",
            )
            store.create_action(
                action_id="flyai-action",
                task_id=task["task_id"],
                step_index=1,
                action_type=FLYAI_HOTEL_SEARCH_ID,
                payload={
                    "destination": "杭州",
                    "check_in_date": check_in,
                    "check_out_date": check_out,
                    "max_price": 500,
                },
                expected={},
                idempotency_key="flyai-task:1",
                on_verified="REPLAN",
            )
            execution = ExecutionRuntime(
                store,
                registry.execution_adapters(),
                capability_specs=registry.planner_capabilities(include_deferred=True),
                capability_registry=registry,
            )
            result = FunctionExecutionWorker(execution, registry, executors).run_once(task["task_id"])
            self.assertIsNotNone(result)
            attempt = store.action_attempts("flyai-action")[0]
            self.assertEqual(attempt["source_kind"], "managed_cli")
            self.assertEqual(attempt["latest_outcome"], "SUCCESS")
            observations = store.verified_observations(task["task_id"])
            self.assertEqual(len(observations), 1)
            data = observations[0]["data"]
            self.assertEqual(data["provider"], "flyai_fliggy")
            self.assertEqual(data["item_count"], 1)
            self.assertEqual(data["items"][0]["provider_item_id"], "fake-hotel")
            self.assertEqual(store.get_task(task["task_id"])["status"], "active")

    def test_registration_rejects_cli_version_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            executable = self._fake_install(Path(temp), version="9.9.9")
            registry = CapabilityRegistry()
            executors, health = register_flyai_hotel_capability(
                registry,
                executable=executable,
                api_key="test-key",
            )
            self.assertEqual(executors, {})
            self.assertEqual(registry.get(FLYAI_HOTEL_SEARCH_ID).loading, "deferred")
            self.assertEqual(health["reason"], "unsupported_cli_version")

    def test_search_normalizes_and_reverifies_budget_and_handoff(self) -> None:
        check_in, check_out = future_dates()
        cli = FakeCLI(
            wrapped_payload(
                [
                    hotel_item("ok", price="¥450"),
                    hotel_item("over", price="¥690"),
                    hotel_item("masked", price="¥4x"),
                    hotel_item("bad-url", price="¥300", url="https://evil.example/hotel"),
                ]
            )
        )
        tools = FlyAIHotelTools(cli)
        result = tools.search_hotels(
            {
                "destination": "杭州",
                "check_in_date": check_in,
                "check_out_date": check_out,
                "poi_name": "杭州东站",
                "max_price": 500,
                "sort": "price_asc",
            }
        )
        self.assertEqual(result["raw_item_count"], 4)
        self.assertEqual(result["item_count"], 1)
        self.assertEqual(result["items"][0]["provider_item_id"], "ok")
        self.assertTrue(result["max_price_verified"])
        self.assertEqual(result["dropped_over_budget"], 1)
        self.assertEqual(result["dropped_unverifiable_budget"], 1)
        self.assertEqual(result["dropped_invalid"], 1)
        self.assertTrue(result["poi_filter_requested"])
        self.assertFalse(result["poi_filter_verified"])
        self.assertTrue(result["proximity_verification_required"])
        self.assertEqual(result["booking_semantics"], "handoff_only")
        self.assertIn("--poi-name", cli.calls[0])
        self.assertIn("--max-price", cli.calls[0])

    def test_trial_mode_and_provider_status_fail_closed(self) -> None:
        check_in, check_out = future_dates()
        trial = FlyAIHotelTools(
            FakeCLI(wrapped_payload([hotel_item("trial")], system_message="当前为体验模式"))
        )
        with self.assertRaises(FunctionToolError) as trial_error:
            trial.search_hotels(
                {
                    "destination": "杭州",
                    "check_in_date": check_in,
                    "check_out_date": check_out,
                }
            )
        self.assertIn("trial-mode", str(trial_error.exception))

        rejected = FlyAIHotelTools(
            FakeCLI(wrapped_payload([], status=1, message="invalid date"))
        )
        with self.assertRaises(FunctionToolError) as provider_error:
            rejected.search_hotels(
                {
                    "destination": "杭州",
                    "check_in_date": check_in,
                    "check_out_date": check_out,
                }
            )
        self.assertEqual(provider_error.exception.error_kind, "model_correctable")

    def test_cache_is_bounded_and_force_refresh_bypasses_it(self) -> None:
        check_in, check_out = future_dates()
        response = wrapped_payload([hotel_item("cached")])
        cli = FakeCLI(response, response)
        tools = FlyAIHotelTools(cli, cache_ttl_seconds=180)
        args = {
            "destination": "杭州",
            "check_in_date": check_in,
            "check_out_date": check_out,
        }
        first = tools.search_hotels(args)
        second = tools.search_hotels(args)
        self.assertFalse(first["cached"])
        self.assertTrue(second["cached"])
        self.assertEqual(len(cli.calls), 1)
        refreshed = tools.search_hotels({**args, "force_refresh": True})
        self.assertFalse(refreshed["cached"])
        self.assertEqual(len(cli.calls), 2)

    def test_budget_ceiling_defaults_to_normal_hotels_and_quality_ranking(self) -> None:
        check_in, check_out = future_dates()
        cli = FakeCLI(wrapped_payload([hotel_item("balanced")]))
        tools = FlyAIHotelTools(cli)
        tools.search_hotels({
            "destination": "杭州",
            "check_in_date": check_in,
            "check_out_date": check_out,
            "max_price": 500,
        })
        argv = cli.calls[0]
        self.assertIn("--hotel-types", argv)
        self.assertEqual(argv[argv.index("--hotel-types") + 1], "hotel")
        self.assertIn("--sort", argv)
        self.assertEqual(argv[argv.index("--sort") + 1], "rate_desc")
        self.assertNotEqual(argv[argv.index("--sort") + 1], "price_asc")

    def test_explicit_cheapest_request_can_still_use_price_ascending(self) -> None:
        check_in, check_out = future_dates()
        cli = FakeCLI(wrapped_payload([hotel_item("cheap")]))
        tools = FlyAIHotelTools(cli)
        tools.search_hotels({
            "destination": "杭州",
            "check_in_date": check_in,
            "check_out_date": check_out,
            "max_price": 500,
            "sort": "price_asc",
        })
        argv = cli.calls[0]
        self.assertEqual(argv[argv.index("--sort") + 1], "price_asc")
        self.assertEqual(argv[argv.index("--hotel-types") + 1], "hotel")

    def test_hotel_semantics_live_on_capability_not_global_prompt(self) -> None:
        registry = CapabilityRegistry()
        register_flyai_hotel_capability(registry, executable=None, api_key="")
        spec = registry.get(FLYAI_HOTEL_SEARCH_ID).spec
        self.assertNotIn("price_asc", PLANNER_SYSTEM_INSTRUCTIONS_V0)
        self.assertIn("max_price 只是价格上限", spec.description)
        sort_schema = spec.arguments_schema["properties"]["sort"]
        type_schema = spec.arguments_schema["properties"]["hotel_types"]
        self.assertEqual(sort_schema["default"], "rate_desc")
        self.assertIn("最便宜", sort_schema["description"])
        self.assertEqual(type_schema["default"], ["hotel"])

    def test_argument_validation_rejects_invalid_dates_and_sort(self) -> None:
        check_in, check_out = future_dates()
        tools = FlyAIHotelTools(FakeCLI())
        with self.assertRaises(FunctionToolError):
            tools.search_hotels(
                {
                    "destination": "杭州",
                    "check_in_date": check_out,
                    "check_out_date": check_in,
                }
            )
        with self.assertRaises(FunctionToolError):
            tools.search_hotels(
                {
                    "destination": "杭州",
                    "check_in_date": check_in,
                    "check_out_date": check_out,
                    "sort": "whatever",
                }
            )

    def test_public_copy_never_exposes_internal_capability_id(self) -> None:
        self.assertEqual(capability_label(FLYAI_HOTEL_SEARCH_ID), "查询飞猪酒店")
        self.assertEqual(
            capability_activity_title(FLYAI_HOTEL_SEARCH_ID, "active"),
            "正在查询飞猪酒店和报价",
        )
        self.assertEqual(
            capability_activity_title(FLYAI_HOTEL_SEARCH_ID, "complete"),
            "飞猪酒店候选已查到",
        )

    @staticmethod
    def _fake_install(root: Path, *, version: str = FLYAI_CLI_VERSION) -> Path:
        package = root / "node_modules" / "@fly-ai" / "flyai-cli"
        bundle = package / "dist" / "flyai-bundle.cjs"
        bundle.parent.mkdir(parents=True, exist_ok=True)
        bundle.write_text(
            """#!/usr/bin/env python3
import json, os
if not os.environ.get('FLYAI_API_KEY'):
    print(json.dumps({'status': 1, 'message': 'missing key', 'data': {'itemList': []}}))
else:
    print(json.dumps({'status': 0, 'message': 'success', 'data': {'itemList': [{
        'shId': 'fake-hotel', 'name': 'Fake Hotel', 'address': 'Hangzhou',
        'interestsPoi': 'Near station', 'price': '¥188',
        'detailUrl': 'https://a.feizhu.com/fake', 'latitude': '30.2',
        'longitude': '120.2', 'star': 'Comfort', 'rate': '4.8'
    }]}}))
""",
            encoding="utf-8",
        )
        bundle.chmod(0o755)
        (package / "package.json").write_text(
            json.dumps(
                {
                    "name": "@fly-ai/flyai-cli",
                    "version": version,
                    "bin": {"flyai": "./dist/flyai-bundle.cjs"},
                }
            ),
            encoding="utf-8",
        )
        return bundle


if __name__ == "__main__":
    unittest.main()
