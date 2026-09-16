import contextlib
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from publication_files import source_files
from verify_repository import _NAMES, inspect, old_brand
from export_public_snapshot import export


class PublicationTests(unittest.TestCase):
    def test_historical_brand_is_rejected_even_inside_identifiers(self):
        for name in _NAMES:
            for text in [name, name.upper(), name + 'Runtime', 'assets/' + name + '/image.png']:
                self.assertTrue(old_brand(text))

    def test_prefix_gate_does_not_corrupt_normal_english(self):
        for text in ['hours', 'hourly', 'house', 'FlowerollActivity', '花卷 / 小卷', 'Host']:
            self.assertFalse(old_brand(text))
        old = ''.join(map(chr, [72, 111, 117]))
        self.assertTrue(old_brand(old + 'ActivityAttributes'))

    def test_snapshot_preserves_untracked_source_but_excludes_local_state(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'source'; root.mkdir()
            for name, content in [('host/floweroll_host/new.py', 'value = 1\n'),
                                  ('ios/Config/Local.xcconfig', 'local signing settings'),
                                  ('.env', 'private'), ('work/private.txt', 'private'),
                                  ('.git/config', 'private'), ('README.md', '# 花卷\n')]:
                p = root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(content)
            out = Path(d) / 'export'
            with contextlib.redirect_stdout(io.StringIO()):
                count = export(root, out)
            self.assertEqual(count, 2)
            self.assertTrue((out / 'host/floweroll_host/new.py').is_file())
            self.assertFalse((out / 'ios/Config/Local.xcconfig').exists())
            self.assertFalse((out / 'work').exists())
            self.assertFalse((out / '.git').exists())
            self.assertFalse((out / '.env').exists())
            for line in (out / 'SOURCE-MANIFEST.sha256').read_text().splitlines():
                digest, path = line.split('  ', 1)
                self.assertEqual(hashlib.sha256((out / path).read_bytes()).hexdigest(), digest)

    def test_excluded_dependency_symlink_is_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d).resolve()
            (root / 'dev/observability/web/node_modules/.bin').mkdir(parents=True)
            target = root / 'dev/observability/web/node_modules/playwright'
            target.write_text('dependency')
            (root / 'dev/observability/web/node_modules/.bin/playwright').symlink_to(target)
            (root / 'dev/observability/web/index.html').write_text('ok')
            files = source_files(root)
            self.assertEqual([p.relative_to(root).as_posix() for p in files], ['dev/observability/web/index.html'])

    def test_generated_web_build_is_excluded_but_source_dist_is_not(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d).resolve()
            for name in ['dev/observability/web/dist/bundle.js',
                         'dev/observability/web/src/main.ts', 'host/dist/real_source.py']:
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('source-or-build')
            self.assertEqual(
                [str(p.relative_to(root)) for p in source_files(root)],
                ['dev/observability/web/src/main.ts', 'host/dist/real_source.py'],
            )

    def test_symlinks_are_rejected_not_followed(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root / 'host').mkdir(); (root / 'host/external').symlink_to('/etc')
            with self.assertRaises(ValueError):
                source_files(root)

    def test_dangerous_runtime_file_in_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root / 'host').mkdir(); (root / 'host/private.sqlite3').write_bytes(b'private')
            with self.assertRaises(ValueError):
                source_files(root)

    def test_database_sidecars_in_source_fail_closed(self):
        for suffix in ['.db', '.db-wal', '.db-shm', '.db-journal',
                       '.sqlite-wal', '.sqlite-shm', '.sqlite-journal',
                       '.sqlite3-wal', '.sqlite3-shm', '.sqlite3-journal']:
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                (root / 'host').mkdir()
                (root / ('host/private' + suffix)).write_bytes(b'test runtime data')
                with self.assertRaises(ValueError):
                    source_files(root)

    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'src'; root.mkdir(); out = Path(d) / 'out'; out.mkdir()
            with self.assertRaises(ValueError):
                export(root, out)

    def test_catalog_must_reference_real_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); p = root / 'ios/Floweroll/Assets.xcassets/Sprite.imageset/Contents.json'
            p.parent.mkdir(parents=True); p.write_text('{"images":[{"filename":"missing.png"}]}')
            errors, _ = inspect(root)
            self.assertEqual(len(errors), 1)
            self.assertIn('missing catalog image', errors[0])


if __name__ == '__main__':
    unittest.main()
