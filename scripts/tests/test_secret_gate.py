import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_secrets import ScannerError, scan, self_check


class SecretGateTests(unittest.TestCase):
    def test_scanner_that_always_reports_clean_is_rejected(self):
        with tempfile.TemporaryDirectory() as d, patch('verify_secrets.scan', return_value=(0, [])):
            with self.assertRaisesRegex(ScannerError, 'positive control'):
                self_check(Path('/scanner'), Path(d))

    def test_controls_require_github_rule_and_clean_negative(self):
        with tempfile.TemporaryDirectory() as d, patch('verify_secrets.scan', side_effect=[
            (1, [{'RuleID': 'github-pat'}]), (0, [])
        ]) as mocked:
            self_check(Path('/scanner'), Path(d))
            self.assertEqual(mocked.call_count, 2)

    def test_scanner_that_flags_everything_is_rejected(self):
        with tempfile.TemporaryDirectory() as d, patch('verify_secrets.scan', return_value=(1, [{'RuleID': 'github-pat'}])):
            with self.assertRaisesRegex(ScannerError, 'negative control'):
                self_check(Path('/scanner'), Path(d))

    def test_invalid_exit_code_cannot_look_clean(self):
        with tempfile.TemporaryDirectory() as d:
            report = Path(d) / 'report.json'
            report.write_text('[]')
            with patch('verify_secrets.subprocess.run', return_value=subprocess.CompletedProcess([], 2)):
                with self.assertRaises(ScannerError):
                    scan(Path('/scanner'), 'dir', Path(d), report)

    def test_exit_code_must_agree_with_report(self):
        with tempfile.TemporaryDirectory() as d:
            report = Path(d) / 'report.json'
            report.write_text(json.dumps([{'RuleID': 'github-pat'}]))
            with patch('verify_secrets.subprocess.run', return_value=subprocess.CompletedProcess([], 0)):
                with self.assertRaisesRegex(ScannerError, 'disagrees'):
                    scan(Path('/scanner'), 'dir', Path(d), report)


if __name__ == '__main__':
    unittest.main()
