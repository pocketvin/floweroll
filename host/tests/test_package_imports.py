"""The read-only inspector must not need a production HTTP-server environment."""
from pathlib import Path
import subprocess
import sys
import unittest


class PackageImportTests(unittest.TestCase):
    def test_capture_and_console_import_without_site_packages_or_server(self):
        root = Path(__file__).resolve().parents[2]
        # -I -S gives an independent interpreter without site-packages. Importing
        # the inspector must not start a Host, open a DB, or require Uvicorn.
        code = """
import sys
sys.path[:0] = [sys.argv[1], sys.argv[1] + '/host']
from floweroll_host.planner_capture import scrub
import dev.observability.console
for name in ('floweroll_host.server', 'floweroll_host.storage',
             'floweroll_host.runtime_supervisor', 'uvicorn', 'fastapi'):
    assert name not in sys.modules, name
assert scrub({'password': 'not-a-real-credential'}) == {'password': '[redacted-secret]'}
"""
        result = subprocess.run(
            [sys.executable, '-I', '-S', '-c', code, str(root)],
            cwd=root, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_public_convenience_exports_still_resolve_same_objects(self):
        from floweroll_host import AgentLoop, HostApp, Storage, create_server
        from floweroll_host.agent_loop import AgentLoop as ExpectedAgent
        from floweroll_host.server import HostApp as ExpectedHost, create_server as expected_create
        from floweroll_host.storage import Storage as ExpectedStorage
        self.assertIs(AgentLoop, ExpectedAgent)
        self.assertIs(HostApp, ExpectedHost)
        self.assertIs(Storage, ExpectedStorage)
        self.assertIs(create_server, expected_create)

    def test_unknown_export_is_attribute_error(self):
        import floweroll_host
        with self.assertRaises(AttributeError):
            getattr(floweroll_host, 'nonexistent_export')


if __name__ == '__main__':
    unittest.main()
