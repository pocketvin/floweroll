from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch
import uuid

from floweroll_host.developer_observability import DeveloperObservabilityService, ROOT
from floweroll_host.server import create_server
from floweroll_host.storage import Storage


class DeveloperObservabilityServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / "work", prefix="developer-observability-tests-")
        self.root = Path(self.tmp.name)
        self.db = self.root / "runtime.sqlite3"
        self.capture_dir = self.root / "captures"
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({
            "mode": "local_full",
            "runtime_db": str(self.db),
            "snapshot_dir": str(self.capture_dir),
        }))
        self.env = patch.dict(os.environ, {
            "FLOWEROLL_DEVELOPER_OBSERVABILITY": "1",
            "FLOWEROLL_OBSERVABILITY_CONFIG": str(self.config),
        })
        self.env.start()
        self.store = Storage(str(self.db))
        self.task_id = str(uuid.uuid4())
        self.store.create_or_get_task(
            task_id=self.task_id,
            goal="测试开发者观测",
            invocation_source="unit_test",
            policy_snapshot={},
            submission_id=None,
        )
        self.store.record_trace_event(self.task_id, "planner.call.started", {"call_number": 1})
        self.store.record_trace_event(self.task_id, "planner.call.metrics", {
            "call_number": 1,
            "outcome": "success",
            "provider_model": "test-model",
            "model_ms": 123.0,
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "total_tokens": 15,
        })
        self.service = DeveloperObservabilityService.from_environment(str(self.db))

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    def write_capture(self, *, secret: str = "unit-secret") -> None:
        folder = self.capture_dir / self.task_id
        folder.mkdir(parents=True)
        payload = {
            "task_id": self.task_id,
            "call_number": 1,
            "state": "response_validated",
            "started_at": "2026-09-14T10:00:00+00:00",
            "ended_at": "2026-09-14T10:00:01+00:00",
            "updated_at": "2026-09-14T10:00:01+00:00",
            "request_bytes": 100,
            "request_sha256": "abc",
            "provider_model": "test-model",
            "visible_capabilities": ["calculate.deterministic"],
            "prompt": {"sha256": "prompt-sha"},
            "wire_request": {
                "model": "test-model",
                "messages": [
                    {"role": "system", "content": "SYSTEM_REAL"},
                    {"role": "user", "content": json.dumps({"decision_context": {
                        "task": {"goal": "测试开发者观测"},
                        "available_capabilities": [{"name": "calculate.deterministic"}],
                        "api_key": secret,
                    }}, ensure_ascii=False)},
                ],
            },
            "response_text": json.dumps({"decision_type": "COMPLETE"}),
        }
        (folder / "0001-test.json").write_text(json.dumps(payload, ensure_ascii=False))

    def test_overview_is_bounded_read_model_and_missing_capture_is_truthful(self) -> None:
        result = self.service.task_overview(self.task_id)
        self.assertEqual(result["task"]["task_id"], self.task_id)
        self.assertEqual(result["summary"]["planner_calls"], 1)
        self.assertEqual(result["summary"]["reported_tokens_only"], 15)
        self.assertFalse(result["planner_calls"][0]["capture_available"])
        detail = self.service.planner_call(self.task_id, 1)
        self.assertFalse(detail["available"])
        self.assertNotIn("system_prompt", detail)

    def test_real_capture_exposes_prompt_context_tools_without_secret_or_reasoning(self) -> None:
        self.write_capture()
        result = self.service.planner_call(self.task_id, 1)
        self.assertTrue(result["available"])
        self.assertEqual(result["system_prompt"], "SYSTEM_REAL")
        self.assertEqual(result["decision_context"]["task"]["goal"], "测试开发者观测")
        self.assertEqual(result["tools"]["visible"], ["calculate.deterministic"])
        self.assertEqual(result["decision_context"]["api_key"], "[redacted-secret]")
        encoded = json.dumps(result, ensure_ascii=False)
        self.assertNotIn("unit-secret", encoded)
        self.assertNotIn("chain_of_thought", encoded)

    def test_list_is_limited_and_invalid_identifiers_fail_closed(self) -> None:
        self.assertEqual(self.service.list_tasks(limit=1)["limit"], 1)
        for value in (0, 51):
            with self.assertRaises(ValueError):
                self.service.list_tasks(limit=value)
        with self.assertRaises(ValueError):
            self.service.task_overview("../local.env")
        with self.assertRaises(ValueError):
            self.service.planner_call(self.task_id, 0)

    def test_capture_database_mismatch_does_not_leak_other_database(self) -> None:
        self.write_capture()
        other_db = self.root / "other.sqlite3"
        Storage(str(other_db))
        service = DeveloperObservabilityService.from_environment(str(other_db))
        self.assertTrue(service.enabled)
        self.assertIsNone(service.capture_dir)
        self.assertEqual(service.configuration_note, "capture_runtime_db_mismatch")


class DeveloperObservabilityHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / "work", prefix="developer-observability-http-")
        root = Path(self.tmp.name)
        self.db = root / "runtime.sqlite3"
        self.config = root / "config.json"
        self.config.write_text(json.dumps({
            "mode": "metadata",
            "runtime_db": str(self.db),
            "snapshot_dir": str(root / "captures"),
        }))
        self.env = patch.dict(os.environ, {
            "FLOWEROLL_DEVELOPER_OBSERVABILITY": "1",
            "FLOWEROLL_OBSERVABILITY_CONFIG": str(self.config),
        })
        self.env.start()
        self.server = create_server("127.0.0.1", 0, str(self.db), auth_token="test-token")
        self.task_id = str(uuid.uuid4())
        self.server.app.storage.create_or_get_task(
            task_id=self.task_id,
            goal="HTTP Developer Test",
            invocation_source="unit_test",
            policy_snapshot={},
            submission_id=None,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:{}".format(self.server.server_address[1])

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.env.stop()
        self.tmp.cleanup()

    def request(self, method: str, path: str, *, auth: bool = True, developer: bool = True):
        request = urllib.request.Request(self.base + path, method=method)
        if auth:
            request.add_header("Authorization", "Bearer test-token")
        if developer:
            request.add_header("X-Floweroll-Developer-Mode", "1")
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode()) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode()) if raw else None

    def test_endpoint_requires_existing_host_auth_and_explicit_developer_header(self) -> None:
        path = "/v1/developer/observability/tasks"
        self.assertEqual(self.request("GET", path, auth=False)[0], 401)
        self.assertEqual(self.request("GET", path, developer=False)[0], 403)
        status, body = self.request("GET", path)
        self.assertEqual(status, 200)
        self.assertEqual(body["tasks"][0]["task_id"], self.task_id)

    def test_task_and_call_are_get_only_and_unknown_task_is_not_found(self) -> None:
        status, body = self.request("GET", "/v1/developer/observability/tasks/" + self.task_id)
        self.assertEqual(status, 200)
        self.assertTrue(body["observability"]["read_only"])
        self.assertEqual(self.request("POST", "/v1/developer/observability/tasks")[0], 405)
        missing = str(uuid.uuid4())
        self.assertEqual(self.request("GET", "/v1/developer/observability/tasks/" + missing)[0], 404)


if __name__ == "__main__":
    unittest.main()
