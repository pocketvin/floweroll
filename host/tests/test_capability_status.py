from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.host_local_tools import register_host_local_capabilities
from floweroll_host.public_http_tools import register_public_http_capabilities
from floweroll_host.server import create_server


class CapabilityStatusTests(unittest.TestCase):
    def test_authenticated_status_exposes_sources_without_private_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            registry = CapabilityRegistry()
            local_executors, _ = register_host_local_capabilities(registry, root=root / "workspace")
            http_executors, _ = register_public_http_capabilities(registry)
            executors = {**local_executors, **http_executors}
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "status.sqlite3"),
                auth_token="status-token",
                capability_registry=registry,
                function_executors=executors,
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_address[1]}/v1/capabilities"
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    urllib.request.urlopen(url, timeout=2)
                self.assertEqual(denied.exception.code, 401)

                request = urllib.request.Request(
                    url,
                    headers={"Authorization": "Bearer status-token"},
                )
                with urllib.request.urlopen(request, timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))

                by_id = {item["capability_id"]: item for item in payload["capabilities"]}
                self.assertTrue(by_id["file.read"]["ready"])
                self.assertEqual(by_id["file.read"]["source"]["kind"], "host_local")
                self.assertTrue(by_id["web.fetch"]["ready"])
                self.assertEqual(by_id["web.fetch"]["source"]["kind"], "http_api")
                serialized = json.dumps(payload, ensure_ascii=False)
                self.assertNotIn(str(root / "workspace"), serialized)
                self.assertNotIn("status-token", serialized)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
