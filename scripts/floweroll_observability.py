#!/usr/bin/env python3
"""Local Langfuse lifecycle. Does not restart the product Host or alter its DB."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work' / 'observability'
ENV = WORK / 'local.env'
CONFIG = WORK / 'config.json'
COMPOSE = ROOT / 'dev' / 'observability' / 'compose.yaml'


def private_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(text)
    path.chmod(0o600)


def initialize(mode: str) -> None:
    WORK.mkdir(parents=True, exist_ok=True, mode=0o700)
    WORK.chmod(0o700)
    if not ENV.exists():
        names = ('POSTGRES_PASSWORD', 'CLICKHOUSE_PASSWORD', 'MINIO_ROOT_PASSWORD',
                 'REDIS_AUTH', 'SALT', 'NEXTAUTH_SECRET', 'LANGFUSE_ADMIN_PASSWORD')
        values = {n: secrets.token_hex(24) for n in names}
        values.update(ENCRYPTION_KEY=secrets.token_hex(32),
                      LANGFUSE_PUBLIC_KEY='pk-lf-' + secrets.token_hex(16),
                      LANGFUSE_SECRET_KEY='sk-lf-' + secrets.token_hex(32))
        private_write(ENV, ''.join(k + '=' + v + '\n' for k, v in values.items()))
    if not CONFIG.exists():
        private_write(CONFIG, json.dumps({
            'schema': 1, 'mode': mode, 'snapshot_dir': str(WORK / 'captures'),
            'max_snapshot_bytes': 1048576, 'retention_days': 7,
            'max_capture_disk_bytes': 268435456,
            'runtime_db': str(ROOT / 'work' / 'floweroll-v1.sqlite3'),
            'langfuse_url': 'http://localhost:3033', 'project_id': 'floweroll',
            'poll_seconds': 10,
        }, ensure_ascii=False, indent=2) + '\n')
    print('Local configuration: ' + str(CONFIG))
    print('Login: developer@floweroll.local (password: LANGFUSE_ADMIN_PASSWORD in ' + str(ENV) + ')')
    print('No credentials printed. Existing configuration is never overwritten.')


def compose(*args: str) -> int:
    if not ENV.exists():
        raise SystemExit('Run init first.')
    return subprocess.call(['docker', 'compose', '--env-file', str(ENV), '-f', str(COMPOSE), *args], cwd=ROOT)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['init', 'up', 'down', 'status', 'sync', 'watch', 'replay', 'serve', 'capture'])
    p.add_argument('--capture', choices=['off', 'metadata', 'local_full'], default='metadata')
    p.add_argument('--port', type=int, default=3034)
    p.add_argument('--task-id')
    args = p.parse_args()
    if args.command == 'init':
        initialize(args.capture)
        return 0
    if args.command in ('up', 'down', 'status'):
        opts = {'up': ('up', '-d'), 'down': ('stop',), 'status': ('ps',)}
        return compose(*opts[args.command])
    if args.command == 'capture':
        config = json.loads(CONFIG.read_text())
        config['mode'] = args.capture
        private_write(CONFIG, json.dumps(config, ensure_ascii=False, indent=2) + '\n')
        print('Capture mode: ' + args.capture + '; existing local history is preserved.')
        return 0
    python = WORK / 'venv' / 'bin' / 'python'
    if not python.exists():
        raise SystemExit('Create work/observability/venv with Python 3.12 and install dev/observability/requirements.lock with --require-hashes.')
    if args.command == 'serve':
        return subprocess.call([str(python), '-m', 'dev.observability.console', '--port', str(args.port)], cwd=ROOT)
    cli = [str(python), '-m', 'dev.observability.exporter', args.command]
    if args.task_id:
        cli += ['--task-id', args.task_id]
    return subprocess.call(cli, cwd=ROOT)


if __name__ == '__main__':
    raise SystemExit(main())
