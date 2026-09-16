from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone

from floweroll_host.capabilities_v0 import LOCATION_CURRENT, product_native_capabilities
from floweroll_host.capability_discovery import rank_capabilities
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.location_current_adapter import LocationCurrentAdapter
from floweroll_host.task_capability_policy import capability_semantics, domains_for


class LocationCurrentAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.adapter = LocationCurrentAdapter()
        self.action = {
            "task_id": "task-location",
            "action_id": "action-location",
            "action_type": "location.current",
            "payload": {},
            "idempotency_key": "location:1",
            "on_verified": "COMPLETE",
        }

    def good_output(self) -> dict:
        received = datetime.now(timezone.utc)
        sampled = received - timedelta(seconds=2)
        return {
            "status": "COMPLETED",
            "location_observation_id": "loc-1",
            "request_id": "attempt-1",
            "task_id": "task-location",
            "action_id": "action-location",
            "attempt_id": "attempt-1",
            "latitude": 35.681236,
            "longitude": 139.767125,
            "horizontal_accuracy_m": 12.5,
            "timestamp": sampled.isoformat(),
            "received_at": received.isoformat(),
            "age_ms": 2000.0,
            "authorization_status": "authorizedWhenInUse",
            "accuracy_authorization": "fullAccuracy",
            "coordinate_reference": "WGS84",
            "freshness_verified": True,
            "validity_verified": True,
            "privacy_class": "precise_location",
        }

    def test_capability_is_strict_empty_native_read(self) -> None:
        specs = {spec.name: spec for spec in product_native_capabilities()}
        self.assertIs(specs["location.current"], LOCATION_CURRENT)
        self.assertEqual(LOCATION_CURRENT.arguments_schema["properties"], {})
        self.assertFalse(LOCATION_CURRENT.arguments_schema["additionalProperties"])
        semantics = capability_semantics(LOCATION_CURRENT)
        self.assertEqual(semantics.operation, "read")
        self.assertEqual(semantics.effect, "read")
        self.assertIn("location", domains_for(LOCATION_CURRENT))

    def test_success_verifies_correlation_freshness_accuracy_and_summary(self) -> None:
        verified = self.adapter.verify_result(
            self.action,
            success=True,
            output=self.good_output(),
            error=None,
        )
        self.assertEqual(verified.outcome, "SUCCESS")
        self.assertEqual(verified.observation["privacy_class"], "precise_location")
        self.assertIn("纬度", verified.direct_completion_summary)
        self.assertIn("12", verified.direct_completion_summary)

    def test_stale_and_wrong_attempt_are_rejected(self) -> None:
        stale = self.good_output()
        stale["age_ms"] = 60_001
        self.assertEqual(
            self.adapter.verify_result(self.action, success=True, output=stale, error=None).outcome,
            "TERMINAL_FAILURE",
        )
        wrong = self.good_output()
        wrong["request_id"] = "other-attempt"
        self.assertEqual(
            self.adapter.verify_result(self.action, success=True, output=wrong, error=None).outcome,
            "TERMINAL_FAILURE",
        )

        forged_age = self.good_output()
        received = datetime.fromisoformat(forged_age["received_at"])
        forged_age["timestamp"] = (received - timedelta(minutes=5)).isoformat()
        forged_age["age_ms"] = 0.0
        self.assertEqual(
            self.adapter.verify_result(self.action, success=True, output=forged_age, error=None).outcome,
            "TERMINAL_FAILURE",
        )

    def test_permission_failure_is_model_correctable_without_coordinates(self) -> None:
        output = {
            "status": "PERMISSION_REQUIRED",
            "request_id": "attempt-1",
            "authorization_status": "notDetermined",
            "accuracy_authorization": "reducedAccuracy",
            "reason": "需要使用 App 时定位权限",
        }
        verified = self.adapter.verify_result(
            self.action,
            success=False,
            output=output,
            error="需要使用 App 时定位权限",
        )
        self.assertEqual(verified.outcome, "MODEL_CORRECTABLE_FAILURE")
        self.assertNotIn("latitude", output)
        self.assertNotIn("longitude", output)

    def test_timeout_is_not_automatically_retried(self) -> None:
        verified = self.adapter.verify_result(
            self.action,
            success=False,
            output={"status": "TIMEOUT", "reason": "timeout"},
            error="timeout",
        )
        self.assertEqual(verified.outcome, "TERMINAL_FAILURE")
        self.assertEqual(self.adapter.execution_profile.max_attempts, 1)
        self.assertEqual(self.adapter.execution_profile.retry_mode, "NO_BLIND_RETRY")

    def test_discovery_ranks_current_location_phrases_first(self) -> None:
        registry = CapabilityRegistry()
        specs = product_native_capabilities()
        for query in ("我现在在哪？", "获取一下我当前位置", "看看我现在的位置"):
            ranked = rank_capabilities(specs, query, registry)
            self.assertEqual(ranked[0].name, "location.current", query)

    def test_named_place_does_not_look_like_current_location(self) -> None:
        registry = CapabilityRegistry()
        for query in ("查一下西湖天气", "查看杭州明天天气", "weather in Tokyo"):
            with self.subTest(query=query):
                ranked = rank_capabilities(product_native_capabilities(), query, registry)
                self.assertNotEqual(ranked[0].name, "location.current")

    def test_implicit_weather_without_destination_keeps_location_fast_path(self) -> None:
        from floweroll_host.capability_discovery import _implicit_location_bundle
        for query in ("看看明天天气", "今天温度怎么样", "weather tomorrow"):
            with self.subTest(query=query):
                self.assertIn("location.current", _implicit_location_bundle(query))
        for query in ("查一下西湖天气", "查看杭州明天天气", "weather in Tokyo"):
            with self.subTest(query=query):
                self.assertNotIn("location.current", _implicit_location_bundle(query))


if __name__ == "__main__":
    unittest.main()
