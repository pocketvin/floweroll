#!/usr/bin/env python3
"""Fetch the pinned official Gitleaks CLI into ignored work/tools (no global install)."""
from __future__ import annotations
import argparse
import hashlib
import io
import json
from pathlib import Path
import platform
import sys
import tarfile
import urllib.request


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=root / 'work/tools/gitleaks')
    args = p.parse_args()
    system = platform.system().lower()
    machine = {'aarch64': 'arm64', 'x86_64': 'x64'}.get(platform.machine(), platform.machine())
    config = json.loads((root / 'scripts/tool_versions.json').read_text())['gitleaks']
    info = config['platforms'].get(system + '_' + machine)
    if info is None:
        print('Unsupported platform; install the official Gitleaks CLI separately.', file=sys.stderr)
        return 1
    try:
        req = urllib.request.Request(info['url'], headers={'User-Agent': 'floweroll-build'})
        with urllib.request.urlopen(req, timeout=60) as response:
            data = response.read(64 * 1024 * 1024 + 1)
        if len(data) > 64 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != info['sha256']:
            raise ValueError('Official archive checksum mismatch')
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            member = archive.getmember('gitleaks')
            if not member.isfile() or member.size > 64 * 1024 * 1024:
                raise ValueError('Invalid scanner archive member')
            content = archive.extractfile(member)
            if content is None:
                raise ValueError('Scanner executable missing')
            binary = content.read()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        pending = args.output.with_suffix('.part')
        pending.write_bytes(binary)
        pending.chmod(0o755)
        pending.replace(args.output)
    except (OSError, ValueError, KeyError, tarfile.TarError) as e:
        print(type(e).__name__ + ': scanner installation failed', file=sys.stderr)
        return 1
    print('Verified Gitleaks ' + config['version'] + ': ' + str(args.output))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
