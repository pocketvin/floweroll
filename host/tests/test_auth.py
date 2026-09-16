from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.auth import HostAuthConfigurationError, bearer_token_matches, is_loopback_host
from floweroll_host.server import create_server


class AuthPrimitiveTests(unittest.TestCase):
    def test_loopback_detection(self) -> None:
        self.assertTrue(is_loopback_host("127.0.0.1"))
        self.assertTrue(is_loopback_host("::1"))
        self.assertTrue(is_loopback_host("localhost"))
        self.assertFalse(is_loopback_host("0.0.0.0"))
        self.assertFalse(is_loopback_host("192.168.1.5"))

    def test_bearer_matching_is_exact(self) -> None:
        self.assertTrue(bearer_token_matches(None, None))
        self.assertTrue(bearer_token_matches("Bearer secret-token", "secret-token"))
        self.assertTrue(bearer_token_matches("bearer secret-token", "secret-token"))
        self.assertFalse(bearer_token_matches(None, "secret-token"))
        self.assertFalse(bearer_token_matches("Bearer wrong", "secret-token"))
        self.assertFalse(bearer_token_matches("Basic secret-token", "secret-token"))

    def test_plaintext_non_loopback_binding_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "auth.sqlite3")
            with self.assertRaisesRegex(HostAuthConfigurationError, "loopback binding"):
                create_server("0.0.0.0", 0, db, auth_token="still-not-enough")


class AuthenticatedHostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        db = str(Path(self.tmp.name) / "auth-host.sqlite3")
        self.token = "test-host-token-not-a-production-secret"
        self.server = create_server("127.0.0.1", 0, db, auth_token=self.token)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:{}".format(self.server.server_address[1])

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def request(self, path: str, *, token: str | None = None):
        req = urllib.request.Request(self.base + path, method="GET")
        if token is not None:
            req.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode("utf-8")) if raw else None

    def test_health_stays_minimal_and_unauthenticated_for_tunnel_probe(self) -> None:
        status, body = self.request("/health")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"ok": True, "service": "floweroll-host"})

    def test_v1_requires_exact_bearer_when_configured(self) -> None:
        status, problem = self.request("/v1/tasks")
        self.assertEqual(status, 401)
        self.assertEqual(problem["code"], "AUTH_REQUIRED")
        self.assertNotIn(self.token, json.dumps(problem))

        status, problem = self.request("/v1/tasks", token="wrong")
        self.assertEqual(status, 401)
        self.assertEqual(problem["code"], "AUTH_REQUIRED")

        status, body = self.request("/v1/tasks", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(body["items"], [])


if __name__ == "__main__":
    unittest.main()
