from __future__ import annotations

import json
import unittest
from urllib.parse import parse_qs, urlsplit

from floweroll_host.amap_webservice import (
    AmapWebServiceTools,
    COORDINATE_CONVERT_ID,
    register_amap_webservice_capabilities,
)
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.function_execution_worker import FunctionToolError


class _Response:
    def __init__(self, payload):
        self._raw = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self, size=-1):
        return self._raw[:size] if size >= 0 else self._raw


class _Opener:
    def __init__(self, payload):
        self.payload = payload
        self.request = None

    def open(self, request, timeout):
        self.request = request
        return _Response(self.payload)


class AmapWebServiceTests(unittest.TestCase):
    def test_registers_coordinate_converter_as_location_read(self):
        registry = CapabilityRegistry()
        executors, _ = register_amap_webservice_capabilities(registry)

        entry = registry.get(COORDINATE_CONVERT_ID)
        self.assertIn(COORDINATE_CONVERT_ID, executors)
        self.assertEqual(entry.source.kind, "http_api")
        self.assertEqual(entry.source.server_id, "amap-webservice")
        self.assertEqual(entry.source.metadata["domains"], ["location"])
        self.assertTrue(entry.source.metadata["read_only"])

    def test_converts_wgs84_with_official_api_shape(self):
        opener = _Opener(
            {
                "status": "1",
                "info": "ok",
                "infocode": "10000",
                "locations": "120.123456,30.654321",
            }
        )
        tools = AmapWebServiceTools(api_key_provider=lambda: "test-secret", opener=opener)

        result = tools.convert_coordinate(
            {"longitude": 120.1, "latitude": 30.6, "source_coordinate_system": "WGS84"}
        )

        self.assertEqual(result["coordinate_reference"], "GCJ-02")
        self.assertEqual(result["source_coordinate_reference"], "WGS84")
        self.assertEqual(result["longitude"], 120.123456)
        self.assertEqual(result["latitude"], 30.654321)
        self.assertTrue(result["verified_by_provider"])
        query = parse_qs(urlsplit(opener.request.full_url).query)
        self.assertEqual(query["coordsys"], ["gps"])
        self.assertEqual(query["key"], ["test-secret"])
        self.assertNotIn("test-secret", json.dumps(result))

    def test_rejects_non_wgs84_without_network(self):
        opener = _Opener({"status": "1", "locations": "120,30"})
        tools = AmapWebServiceTools(api_key_provider=lambda: "test-secret", opener=opener)

        with self.assertRaises(FunctionToolError) as caught:
            tools.convert_coordinate(
                {"longitude": 120.1, "latitude": 30.6, "source_coordinate_system": "GCJ-02"}
            )

        self.assertEqual(caught.exception.error_kind, "model_correctable")
        self.assertIsNone(opener.request)


if __name__ == "__main__":
    unittest.main()
