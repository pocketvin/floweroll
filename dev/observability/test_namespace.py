from pathlib import Path
import unittest
from .projector import identity, trace_namespace


class TraceNamespaceTests(unittest.TestCase):
    def test_new_environment_derives_identity_from_current_path(self):
        db = Path('work/runtime.sqlite3')
        self.assertEqual(trace_namespace({}, db), identity('floweroll-db', str(db.resolve())))

    def test_explicit_namespace_survives_database_move(self):
        config = {'trace_namespace': 'ab' * 16}
        self.assertEqual(trace_namespace(config, Path('work/first.sqlite3')),
                         trace_namespace(config, Path('work/relocated.sqlite3')))

    def test_invalid_override_does_not_silently_fork_history(self):
        for invalid in ['', 'not-an-identity', 42, 'z' * 32]:
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                trace_namespace({'trace_namespace': invalid}, Path('work/runtime.sqlite3'))


if __name__ == '__main__':
    unittest.main()
