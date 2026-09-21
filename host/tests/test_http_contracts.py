"""Canonical FastAPI wire contracts plus concurrency/lifecycle regressions."""
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import uuid

from fastapi import FastAPI

from floweroll_host.server import create_server
from floweroll_host.task_assets import MAX_UPLOAD_BYTES, MAX_UPLOAD_CHUNK_BYTES

EXPECTED_OPERATIONS = {
    ("GET", "/health"),
    ("GET", "/v1/capabilities"),
    ("GET", "/v1/tasks"),
    ("POST", "/v1/tasks"),
    ("GET", "/v1/submissions/{submission_id}/task"),
    ("GET", "/v1/tasks/{task_id}"),
    ("GET", "/v1/tasks/{task_id}/view"),
    ("GET", "/v1/tasks/{task_id}/artifacts/{artifact_id}"),
    ("GET", "/v1/tasks/{task_id}/trace"),
    ("GET", "/v1/tasks/{task_id}/next-action"),
    ("GET", "/v1/tasks/{task_id}/next-device-action"),
    ("POST", "/v1/tasks/{task_id}/actions/{action_id}/result"),
    ("POST", "/v1/tasks/{task_id}/actions/{action_id}/reconciliations/definitely-not-started"),
    ("GET", "/v1/tasks/{task_id}/stream"),
    ("POST", "/v1/tasks/{task_id}/turns"),
    ("POST", "/v1/tasks/{task_id}/clarifications/{clarification_id}/responses"),
    ("POST", "/v1/tasks/{task_id}/action-inputs/{input_request_id}/responses"),
    ("POST", "/v1/tasks/{task_id}/cancel"),
    ("POST", "/v1/tasks/{task_id}/retry"),
    ("POST", "/v1/tasks/{task_id}/artifacts/{artifact_id}/revisions"),
    ("POST", "/v1/files/uploads"),
    ("POST", "/v1/files"),
    ("GET", "/v1/files/{file_id}"),
    ("HEAD", "/v1/files/uploads/{file_id}"),
    ("PATCH", "/v1/files/uploads/{file_id}"),
    ("GET", "/v1/tasks/{task_id}/materials"),
    ("GET", "/v1/tasks/{task_id}/files/{file_id}"),
    ("GET", "/v1/observations/health"),
    ("POST", "/v1/observations/sessions"),
    ("GET", "/v1/observations/sessions/{session_id}"),
    ("GET", "/v1/observations/sessions/{session_id}/view"),
    ("GET", "/v1/observations/sessions/{session_id}/evidence"),
    ("POST", "/v1/observations/sessions/{session_id}/events"),
    ("POST", "/v1/observations/sessions/{session_id}/event-status"),
    ("POST", "/v1/observations/sessions/{session_id}/finish"),
    ("POST", "/v1/observations/sessions/{session_id}/questions"),
    ("POST", "/v1/observations/sessions/{session_id}/delete"),
    ("POST", "/v1/observations/sessions/{session_id}/retry"),
    ("GET", "/v1/developer/observability/status"),
    ("GET", "/v1/developer/observability/tasks"),
    ("GET", "/v1/developer/observability/tasks/{task_id}"),
    ("GET", "/v1/developer/observability/tasks/{task_id}/planner-calls/{call_number}"),
}


ERROR_CASES = [
    ("GET", "/v1/unknown", None, None, True, 404, "route not found"),
    ("GET", "/v1/tasks/unknown", None, None, True, 404, "task not found"),
    ("GET", "/v1/tasks/unknown/view", None, None, True, 404, "TASK_NOT_FOUND"),
    ("GET", "/v1/submissions/unknown/task", None, None, True, 404, "SUBMISSION_NOT_ADMITTED"),
    ("GET", "/v1/files/unknown", None, None, True, 503, "FILES_DISABLED"),
    ("GET", "/v1/tasks?limit=bad", None, None, True, 400, "INVALID_TASK_INDEX_QUERY"),
    ("GET", "/v1/tasks?limit=0", None, None, True, 400, "INVALID_TASK_INDEX_QUERY"),
    ("GET", "/v1/tasks?bucket=bad", None, None, True, 400, "INVALID_TASK_INDEX_QUERY"),
    ("GET", "/v1/tasks?cursor=bad", None, None, True, 400, "INVALID_TASK_INDEX_QUERY"),
    ("POST", "/v1/tasks", None, "{", True, 400, "INVALID_TASK_INPUT"),
    ("POST", "/v1/tasks", None, "[]", True, 400, "INVALID_TASK_INPUT"),
    ("POST", "/v1/tasks", {"input": {"kind": "text", "text": "x"}}, None, True, 400, "INVALID_SUBMISSION_ID"),
    ("POST", "/v1/tasks", {"submission_id": "s", "input": None}, None, True, 400, "INVALID_TASK_INPUT"),
    ("POST", "/v1/tasks", {"submission_id": "s", "input": {"kind": "image", "text": "x"}}, None, True, 400, "UNSUPPORTED_TASK_INPUT"),
    ("POST", "/v1/tasks", {"submission_id": "s", "input": {"kind": "text", "text": " "}}, None, True, 400, "INVALID_TASK_INPUT"),
    ("POST", "/v1/tasks", {"submission_id": "s", "input": {"kind": "text", "text": "x"}, "parent_task_id": " "}, None, True, 400, "INVALID_PARENT_TASK_ID"),
    ("POST", "/v1/tasks/unknown/turns", {"content": {"kind": "text", "text": "x"}}, None, True, 400, "INVALID_EVENT_ID"),
    ("POST", "/v1/tasks/unknown/turns", {"event_id": "e", "content": None}, None, True, 400, "INVALID_USER_TURN"),
    ("POST", "/v1/tasks/unknown/cancel", {}, None, True, 400, "INVALID_EVENT_ID"),
    ("POST", "/v1/tasks/unknown/cancel", {"event_id": "e", "reason": 1}, None, True, 400, "INVALID_CANCEL_REASON"),
    ("POST", "/v1/tasks/unknown/clarifications/c/responses", {}, None, True, 400, "INVALID_CLARIFICATION_RESPONSE"),
    ("POST", "/v1/tasks/unknown/action-inputs/i/responses", {}, None, True, 400, "INVALID_ACTION_INPUT_RESPONSE"),
    ("POST", "/v1/tasks/unknown/artifacts/a/revisions", {}, None, True, 400, "INVALID_ARTIFACT_EDIT"),
    ("POST", "/v1/tasks/unknown/actions/a/result", {}, None, True, 404, "task/action not found"),
    ("POST", "/v1/observations/sessions", {}, None, True, 400, "INVALID_OBSERVATION"),
    ("GET", "/v1/tasks/wire-known/next-device-action?wait_seconds=bad", None, None, True, 400, "INVALID_DEVICE_ACTION_WAIT"),
    ("GET", "/v1/tasks/wire-known/next-device-action?wait_seconds=NaN", None, None, True, 400, "INVALID_DEVICE_ACTION_WAIT"),
    ("GET", "/v1/tasks/wire-known/next-device-action?wait_seconds=inf", None, None, True, 400, "INVALID_DEVICE_ACTION_WAIT"),
    ("GET", "/v1/tasks/wire-known/next-device-action?wait_seconds=21", None, None, True, 400, "INVALID_DEVICE_ACTION_WAIT"),
    ("GET", "/v1/tasks/wire-known/stream?after_seq=-1", None, None, True, 400, "INVALID_PRESENTATION_CURSOR"),
]


class HTTPContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.server = create_server("127.0.0.1", 0, str(Path(self.tmp.name) / "host.db"), auth_token="wire-test-token")
        self.server.app.supervisor.stop()
        self.server.app.storage.create_task("wire-known", "known", "wire-test", {}, status="active")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(3)
        self.tmp.cleanup()

    def request(self, method, path, body=None, raw=None, auth=True, content_type="application/json", headers=None):
        values = {"Content-Type": content_type, **(headers or {})}
        if auth:
            values["Authorization"] = "Bearer wire-test-token"
        data = raw if raw is not None else json.dumps(body, ensure_ascii=False) if body is not None else None
        req = urllib.request.Request(self.base + path, data=data.encode() if data is not None else None, headers=values, method=method)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            data = response.read()
            return {"status": response.status, "content_type": response.headers.get("Content-Type"),
                    "body": json.loads(data) if data else None}

    def test_canonical_error_contracts(self):
        for method, path, body, raw, auth, status, marker in ERROR_CASES:
            with self.subTest(method=method, path=path, body=body if raw is None else raw):
                response = self.request(method, path, body=body, raw=raw, auth=auth)
                self.assertEqual(response["status"], status, response)
                payload = response["body"]
                self.assertEqual(payload.get("code", payload.get("error")), marker)

    def test_health_and_auth_contracts(self):
        self.assertEqual(self.request("GET", "/health")["body"], {"ok": True, "service": "floweroll-host"})
        for method, path in [("GET", "/v1"), ("GET", "/v1/tasks"), ("POST", "/v1/tasks")]:
            with self.subTest(method=method, path=path):
                response = self.request(method, path, auth=False)
                self.assertEqual(response["status"], 401)
                self.assertEqual(response["body"]["code"], "AUTH_REQUIRED")

    def test_response_validation_preserves_extra_fields_and_missing_vs_null(self):
        store = self.server.app.storage
        original = store.get_task
        def extended(task_id):
            return {**original(task_id), "future_extension": {"x": [None, 7]}, "explicit_null": None}
        with patch.object(store, "get_task", side_effect=extended):
            response = self.request("GET", "/v1/tasks/wire-known")
        self.assertEqual(response["status"], 200)
        self.assertEqual(response["body"]["future_extension"], {"x": [None, 7]})
        self.assertIsNone(response["body"]["explicit_null"])
        self.assertNotIn("idempotent_replay", response["body"])

    def test_invalid_response_is_a_typed_error_without_internal_data(self):
        with patch.object(self.server.app, "capability_status", return_value={"capabilities": "private-invalid-result", "mcp_servers": {}}):
            response = self.request("GET", "/v1/capabilities")
        self.assertEqual(response["status"], 500)
        self.assertEqual(response["body"]["code"], "INVALID_RESPONSE")
        self.assertNotIn("private-invalid-result", json.dumps(response))

    def test_probe_coercion_stays_compatible_and_non_json_body_is_rejected(self):
        response = self.request("POST", "/v1/tasks", body={"goal": 9, "invocation_source": None, "policy_snapshot": []})
        self.assertEqual(response["status"], 201)
        self.assertEqual(response["body"]["goal"], "9")
        self.assertEqual(response["body"]["invocation_source"], "None")
        self.assertEqual(response["body"]["policy_snapshot"], {})
        non_json = self.request("POST", "/v1/tasks", raw='{"goal":"x"}', content_type="text/plain")
        self.assertEqual(non_json["status"], 400)
        empty = self.request("POST", "/v1/tasks")
        self.assertEqual(empty["status"], 400)
        self.assertEqual(empty["body"]["code"], "INVALID_TASK_INPUT")

    def test_auth_and_body_limits_reject_before_waiting_for_body(self):
        cases = [
            ("POST", "/v1/tasks", False, 401, 1_000_000),
            ("POST", "/v1/tasks", True, 400, 2 * 1024 * 1024 + 1),
            ("POST", "/v1/files", True, 413, MAX_UPLOAD_BYTES + 1),
            ("PATCH", "/v1/files/uploads/missing", True, 400, MAX_UPLOAD_CHUNK_BYTES + 1),
        ]
        for method, path, authenticated, expected, size in cases:
            with self.subTest(method=method, path=path, authenticated=authenticated):
                connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
                try:
                    connection.putrequest(method, path)
                    connection.putheader("Content-Length", str(size))
                    if authenticated:
                        connection.putheader("Authorization", "Bearer wire-test-token")
                    connection.endheaders()
                    response = connection.getresponse()
                    self.assertEqual(response.status, expected)
                    response.read()
                finally:
                    connection.close()
        self.assertEqual(len(self.server.app.storage.list_tasks()["items"]), 1)

    def test_noncanonical_leading_slashes_never_reach_api_routes(self):
        for authenticated in (False, True):
            for path in ["//v1/tasks/wire-known", "///v1/tasks/wire-known/view"]:
                with self.subTest(path=path, authenticated=authenticated):
                    connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
                    try:
                        headers = {"Authorization": "Bearer wire-test-token"} if authenticated else {}
                        connection.request("GET", path, headers=headers)
                        response = connection.getresponse()
                        self.assertEqual(response.status, 404)
                        self.assertEqual(json.loads(response.read())["error"], "route not found")
                    finally:
                        connection.close()

    def stream(self):
        req = urllib.request.Request(self.base + "/v1/tasks/wire-known/stream?after_seq=99999999",
            headers={"Authorization": "Bearer wire-test-token"})
        return urllib.request.urlopen(req, timeout=3)

    def test_idle_streams_and_more_than_worker_pool_long_polls_do_not_block_cancel(self):
        streams = [self.stream() for _ in range(4)]
        try:
            ready = threading.Barrier(45)

            def long_poll():
                ready.wait(timeout=3)
                return self.request("GET", "/v1/tasks/wire-known/next-device-action?wait_seconds=20")

            with ThreadPoolExecutor(max_workers=44) as pool:
                pending = [pool.submit(long_poll) for _ in range(44)]
                ready.wait(timeout=3)
                time.sleep(0.2)
                health_started = time.monotonic()
                self.assertEqual(self.request("GET", "/health")["status"], 200)
                self.assertLess(time.monotonic() - health_started, 1)
                start = time.monotonic()
                response = self.request("POST", "/v1/tasks/wire-known/cancel", body={"event_id": "wire-cancel"})
                self.assertEqual(response["status"], 202)
                self.assertLess(time.monotonic() - start, 2)
                for future in pending:
                    self.assertEqual(future.result(timeout=3)["status"], 204)
            for response in streams:
                self.assertEqual(response.read(), b"")
        finally:
            for response in streams:
                response.close()

    def test_shutdown_drains_live_streams_and_closes_host_exactly_once(self):
        response = self.stream()
        try:
            with patch.object(self.server.app, "close", wraps=self.server.app.close) as close:
                started = time.monotonic()
                self.server.shutdown()
                self.server.server_close()
                self.assertLess(time.monotonic() - started, 3)
                self.assertEqual(close.call_count, 1)
            self.assertEqual(response.read(), b"")
            self.assertTrue(self.server.app.observation_service.closed)
            self.thread.join(3)
            self.assertFalse(self.thread.is_alive())
        finally:
            response.close()

    def test_observation_event_status_alias_and_tombstone_over_http(self):
        service = self.server.app.observation_service
        # No external model/provider calls in an HTTP migration regression.
        service.model = type("DisabledModel", (), {"ready": False})()
        sid, eid = str(uuid.uuid4()), str(uuid.uuid4())
        config = {"id": sid, "preset": "meeting", "sources": ["ambientMicrophone"],
                  "consent_version": 1, "created_at": "2026-09-14T00:00:00Z"}
        prefix = "/v1/observations/sessions/" + sid
        self.assertEqual(self.request("POST", "/v1/observations/sessions", body=config)["status"], 200)
        event = {"id": eid, "kind": "transcript", "source": "ambientMicrophone", "text": "测试证据",
                 "captured_at": "2026-09-14T00:00:00Z"}
        self.assertEqual(self.request("POST", prefix + "/events", body={"events": [event]})["status"], 200)
        self.assertEqual(self.request("POST", prefix + "/event-status", body={"ids": [eid]})["body"], {"acknowledged_ids": [eid]})
        self.assertEqual(self.request("GET", prefix + "/view")["body"]["event_count"], 1)
        self.assertEqual(len(self.request("GET", prefix + "/evidence")["body"]["events"]), 1)
        self.assertEqual(self.request("POST", prefix + "/finish", body={"event_count": 1})["status"], 202)
        self.assertEqual(self.request("POST", prefix + "/delete", raw="ignored body")["status"], 200)
        self.assertEqual(self.request("POST", "/v1/observations/sessions", body=config)["status"], 409)

    def test_fastapi_schema_contains_every_endpoint_and_preserves_private_docs(self):
        self.assertIsInstance(self.server.asgi_app, FastAPI)
        document = self.server.asgi_app.openapi()
        operations = {(method.upper(), path) for path, methods in document["paths"].items() for method in methods}
        self.assertEqual(operations, EXPECTED_OPERATIONS)
        for model in ["TaskCreate", "CancelRequest", "TaskView", "UploadState", "ObservationView"]:
            self.assertIn(model, document["components"]["schemas"])
        for operations in document["paths"].values():
            for operation in operations.values():
                self.assertNotIn("422", operation["responses"])
        task_parameters = document["paths"]["/v1/tasks"]["get"]["parameters"]
        self.assertEqual({(item["name"], item["in"]) for item in task_parameters},
                         {("bucket", "query"), ("cursor", "query"), ("thread_id", "query"), ("limit", "query")})
        upload = document["paths"]["/v1/files"]["post"]
        self.assertIn("application/octet-stream", upload["requestBody"]["content"])
        self.assertIn(("content-length", "header"),
                      {(item["name"], item["in"]) for item in upload["parameters"]})
        for path in ["/docs", "/redoc", "/openapi.json"]:
            self.assertEqual(self.request("GET", path)["status"], 404)

    def test_close_before_serve_releases_socket_and_host_once(self):
        other = create_server("127.0.0.1", 0, str(Path(self.tmp.name) / "unstarted.db"))
        with patch.object(other.app, "close", wraps=other.app.close) as close:
            other.server_close()
            other.server_close()
            other.serve_forever()
            self.assertEqual(close.call_count, 1)
        self.assertEqual(other.socket.fileno(), -1)


if __name__ == "__main__":
    unittest.main()
