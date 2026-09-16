#!/usr/bin/env python3
"""Run Gitleaks with positive/negative controls before accepting a clean scan.

Source mode scans an explicit export, never private local configuration or task
records. Git mode scans committed history in the requested repository. Neither
mode calls any credential provider or attempts to validate a detected secret.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import secrets
import string
import subprocess
import sys
import tempfile

from export_public_snapshot import export


class ScannerError(RuntimeError):
    pass


def scan(scanner: Path, mode: str, root: Path, report: Path) -> tuple[int, list[dict]]:
    environment = dict(os.environ)
    # A developer's global allowlist/config must not silently weaken this gate.
    for key in ('GITLEAKS_CONFIG', 'GITLEAKS_CONFIG_TOML'):
        environment.pop(key, None)
    result = subprocess.run(
        [str(scanner), mode, str(root), '--no-banner', '--redact',
         '--exit-code', '1', '--report-format', 'json', '--report-path', str(report)],
        cwd=root, env=environment, capture_output=True, text=True, timeout=180,
    )
    if result.returncode not in (0, 1) or not report.is_file():
        raise ScannerError('Secret scanner did not complete successfully')
    findings = json.loads(report.read_text())
    if not isinstance(findings, list) or any(not isinstance(x, dict) for x in findings):
        raise ScannerError('Invalid secret scanner report')
    if (result.returncode == 0) != (len(findings) == 0):
        raise ScannerError('Scanner exit code disagrees with its report')
    return result.returncode, findings


def self_check(scanner: Path, directory: Path) -> None:
    positive = directory / 'positive'
    negative = directory / 'negative'
    positive.mkdir()
    negative.mkdir()
    # Generated, invalid test material: no real account, API call, or persistent
    # token-shaped fixture is involved. Test that the packaged rules truly run.
    token = ''.join(map(chr, (103, 104, 112, 95))) + ''.join(
        secrets.choice(string.ascii_letters + string.digits) for _ in range(36)
    )
    (positive / 'canary.txt').write_text('github_token = "' + token + '"\n')
    (negative / 'readme.txt').write_text('Floweroll scanner negative control.\n')
    rc, findings = scan(scanner, 'dir', positive, directory / 'positive.json')
    if rc != 1 or not any(f.get('RuleID') == 'github-pat' for f in findings):
        raise ScannerError('Scanner positive control failed; refusing a false clean result')
    rc, findings = scan(scanner, 'dir', negative, directory / 'negative.json')
    if rc != 0 or findings:
        raise ScannerError('Scanner negative control failed')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--mode', choices=('source', 'git'), default='source')
    parser.add_argument('--gitleaks', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    scanner = (args.gitleaks or root / 'work/tools/gitleaks').resolve()
    if not scanner.is_file():
        print('Run python3 scripts/fetch_gitleaks.py first.', file=sys.stderr)
        return 2
    try:
        work = root / 'work' / 'secret-checks'
        work.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.TemporaryDirectory(prefix='scan-', dir=work) as temporary:
            tmp = Path(temporary)
            self_check(scanner, tmp)
            print('Gitleaks positive and negative controls: PASS')
            if args.mode == 'source':
                target = tmp / 'source'
                with contextlib.redirect_stdout(io.StringIO()):
                    export(root, target)
                mode = 'dir'
            else:
                target, mode = root, 'git'
            rc, findings = scan(scanner, mode, target, tmp / 'result.json')
            print(f'Gitleaks {args.mode}: {len(findings)} finding(s)')
            for finding in findings:
                # Never print Match, Secret, commit message, or provider output.
                print('Finding:', finding.get('File'), 'line', finding.get('StartLine'),
                      'rule', finding.get('RuleID'), file=sys.stderr)
            return rc
    except (OSError, ValueError, ScannerError, subprocess.TimeoutExpired) as error:
        print(type(error).__name__ + ': secret gate failed; result NOT accepted', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
