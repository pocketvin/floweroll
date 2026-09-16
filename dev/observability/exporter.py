"""Local sidecar: existing durable evidence -> official OTel SDK -> Langfuse.

No tool/model execution, no Runtime DB writes. Identical snapshots are skipped;
closed operations are exported once under stable IDs (Langfuse v4 is immutable).
"""
from __future__ import annotations
from .projector import trace_namespace
import argparse
import base64
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import logging
import os
from pathlib import Path
import sys
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host'))
from floweroll_host.planner_capture import scrub
from .projector import build_spans, load_task, prompt_text, recent_tasks, ready_records

WORK = ROOT / 'work' / 'observability'


def load_config() -> dict:
    config = json.loads((WORK / 'config.json').read_text())
    url = urlsplit(config['langfuse_url'])
    # Full content can NEVER silently leave the local machine. No cloud fallback.
    if url.scheme not in ('http', 'https') or url.hostname not in ('localhost', '127.0.0.1', '::1') or url.username or url.password or url.path not in ('', '/') or url.query or url.fragment:
        raise ValueError('Observability exporter permits loopback Langfuse only')
    if config.get('mode') not in ('off', 'metadata', 'local_full'):
        raise ValueError('Invalid capture mode')
    for field in ('snapshot_dir', 'runtime_db'):
        Path(config[field]).resolve().relative_to((ROOT / 'work').resolve())
    return config


def private_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix('.tmp')
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def environment() -> dict:
    return dict(line.split('=', 1) for line in (WORK / 'local.env').read_text().splitlines() if '=' in line and not line.startswith('#'))


class Sink:
    def __init__(self, config: dict) -> None:
        import httpx
        import requests
        from langfuse import Langfuse
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        values = environment()
        self.config = config
        self.secrets = tuple(values.values())
        # Management APIs via the official SDK; historical spans via official OTel.
        self.client = Langfuse(public_key=values['LANGFUSE_PUBLIC_KEY'], secret_key=values['LANGFUSE_SECRET_KEY'],
                               base_url=config['langfuse_url'], timeout=5, tracing_enabled=False,
                               httpx_client=httpx.Client(timeout=5, trust_env=False))
        auth = base64.b64encode((values['LANGFUSE_PUBLIC_KEY'] + ':' + values['LANGFUSE_SECRET_KEY']).encode()).decode()
        session = requests.Session()
        session.trust_env = False
        self.exporter = OTLPSpanExporter(endpoint=config['langfuse_url'].rstrip('/') + '/api/public/otel/v1/traces',
                                         headers={'Authorization': 'Basic ' + auth, 'x-langfuse-ingestion-version': '4'},
                                         timeout=5, session=session)
        self.prompt_refs = {}
        logging.getLogger('langfuse').setLevel(logging.CRITICAL)
        logging.getLogger('opentelemetry.exporter').setLevel(logging.CRITICAL)

    def prompt(self, text: str) -> int:
        sha = hashlib.sha256(text.encode()).hexdigest()
        if sha in self.prompt_refs:
            return self.prompt_refs[sha]
        label = 'sha-' + sha[:16]
        try:
            prompt = self.client.get_prompt('floweroll/planner', label=label, cache_ttl_seconds=0, max_retries=0)
        except Exception as exc:
            if getattr(exc, 'status_code', None) != 404:
                raise
            prompt = self.client.create_prompt(name='floweroll/planner', prompt=text, type='text',
                      labels=[label, 'host-source'], tags=['source-controlled', 'local'],
                      config={'sha256': sha, 'source_path': 'host/prompts/planner.system.txt',
                              'activation': 'Reviewed source change plus Host restart; UI edits do not deploy'},
                      commit_message='Mirror exact source/captured System Prompt; no semantic rewrite')
        if prompt.prompt != text:
            raise ValueError('Prompt label content mismatch')
        self.prompt_refs[sha] = prompt.version
        return prompt.version

    def send(self, records: list[dict]) -> bool:
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import ReadableSpan
        from opentelemetry.sdk.trace.export import SpanExportResult
        from opentelemetry.sdk.util.instrumentation import InstrumentationScope
        from opentelemetry.trace import SpanContext, TraceFlags, Status, StatusCode
        spans = []
        for r in records:
            tid = int(r['trace_id'], 16)
            parent = SpanContext(tid, int(r['parent_span_id'], 16), False, TraceFlags(1)) if r['parent_span_id'] else None
            attrs = scrub(r['attributes'], self.secrets)
            if self.config['mode'] != 'local_full':
                attrs.pop('langfuse.observation.input', None)
                attrs.pop('langfuse.observation.output', None)
                attrs['langfuse.trace.name'] = 'Task ' + attrs['floweroll.task_id'][:8]
                # Metrics/identities remain; arbitrary Context/errors do not.
            spans.append(ReadableSpan(name=scrub(r['name'], self.secrets) if r['key'] != 'task' or self.config['mode']=='local_full' else 'Floweroll task',
                context=SpanContext(tid, int(r['span_id'], 16), False, TraceFlags(1)), parent=parent,
                attributes=attrs, start_time=r['start_ns'], end_time=r['end_ns'],
                status=Status(StatusCode.ERROR if r['error'] else StatusCode.UNSET),
                resource=Resource.create({'service.name': 'floweroll-host', 'service.version': 'observability-v1'}),
                instrumentation_scope=InstrumentationScope('floweroll.durable-evidence', '1')))
        return self.exporter.export(spans) == SpanExportResult.SUCCESS

    def existing_ids(self, trace_id: str, start: str) -> set[str]:
        # V4 observations are immutable. Readback also reconciles a lost local
        # checkpoint without re-ingesting all generations and doubling usage.
        found = set()
        cursor = None
        for _ in range(20):
            page = self.client.api.observations.get_many(
                trace_id=trace_id, fields='core', limit=1000, cursor=cursor,
                from_start_time=datetime.fromisoformat(start.replace('Z', '+00:00')) - timedelta(seconds=1),
                to_start_time=datetime.now(timezone.utc) + timedelta(days=1))
            found.update(row.id for row in page.data)
            cursor = page.meta.cursor
            if not cursor:
                return found
        raise ValueError('Observation pagination exceeded bounded task limit')

    def close(self) -> None:
        self.exporter.shutdown()
        self.client.flush()


def prune_captures(config: dict) -> int:
    folder = Path(config['snapshot_dir'])
    folder.resolve().relative_to((ROOT / 'work').resolve())
    cutoff = time.time() - max(1, min(30, int(config.get('retention_days', 7)))) * 86400
    files = []
    if not folder.exists():
        return 0
    # Keep the original Planner layout and new operation snapshots under one
    # retention budget. os.walk does not follow directory symlinks.
    for directory, dirs, names in os.walk(folder, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
        for name in names:
            p = Path(directory) / name
            if p.suffix != '.json' or p.is_symlink():
                continue
            try:
                stat = p.stat()
                files.append((stat.st_mtime, stat.st_size, p))
            except FileNotFoundError:
                continue
    total = sum(size for _, size, _ in files)
    limit = min(1024**3, max(1024**2, int(config.get('max_capture_disk_bytes', 268435456))))
    removed = 0
    for mtime, size, p in sorted(files):
        if mtime < cutoff or total > limit:
            p.unlink()
            total -= size
            removed += 1
    return removed


def sync(config: dict, sink: Sink, *, task_id: str | None = None) -> dict:
    # A manual sync can overlap the watch process. Serialize readback/export/
    # checkpoint as one operation so immutable generations never double count.
    WORK.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(str(WORK / 'export.lock'), os.O_WRONLY | os.O_CREAT, 0o600)
    with os.fdopen(fd, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'skipped_locked': True, 'spans_acknowledged': 0}
        try:
            return _sync_locked(config, sink, task_id=task_id)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _sync_locked(config: dict, sink: Sink, *, task_id: str | None = None) -> dict:
    state_path = WORK / 'export-state.json'
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        state = {}
    if state.get('schema') != 2:
        state = {'schema': 2, 'fingerprints': {}, 'span_ids': {}}
    db = Path(config['runtime_db'])
    ns = trace_namespace(config, db)
    since = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()
    ids = [task_id] if task_id else recent_tasks(db, since)
    report = {'changed_tasks': 0, 'skipped_tasks': 0, 'export_failures': 0, 'prompt_sync_failures': 0, 'spans_acknowledged': 0}
    for tid in ids:
        snapshot = load_task(db, tid, Path(config['snapshot_dir']))
        fingerprint = hashlib.sha256(json.dumps(snapshot, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
        key = config['mode'] + ':' + tid
        if state['fingerprints'].get(key) == fingerprint:
            report['skipped_tasks'] += 1
            continue
        records = build_spans(snapshot, ns)
        trace_id = records[0]['trace_id']
        # Public API v2 readback is bounded to this task. Never resend an accepted
        # observation to "update" it: v4 would count another row, not an upsert.
        existing = set(state['span_ids'].get(trace_id, [])) | sink.existing_ids(trace_id, snapshot['task']['created_at'])
        records = [r for r in ready_records(snapshot, records) if r['span_id'] not in existing]
        prompt_failed = False
        if config['mode'] == 'local_full':
            for n, capture in snapshot['captures'].items():
                text = prompt_text(capture)
                linked = [r for r in records if r['key'] in (f'planner:{n}', f'request:{n}')]
                if text is None or not linked:
                    continue
                try:
                    version = sink.prompt(text)
                    for record in linked:
                        record['attributes'].update({'langfuse.observation.prompt.name': 'floweroll/planner',
                                                     'langfuse.observation.prompt.version': version})
                except Exception:
                    report['prompt_sync_failures'] += 1
                    prompt_failed = True
            if prompt_failed:
                continue  # Retry linkage later; never export a half-linked generation.
        if not records or sink.send(records):
            state['fingerprints'][key] = fingerprint
            state['span_ids'][trace_id] = sorted(existing | {r['span_id'] for r in records})
            report['changed_tasks'] += 1
            report['spans_acknowledged'] += len(records)
            private_json(state_path, state)
        else:
            report['export_failures'] += 1
    report['pruned_local_captures'] = prune_captures(config)
    report['checked_at'] = datetime.now(timezone.utc).isoformat()
    private_json(WORK / 'status.json', report)
    return report


def replay(config: dict, task_id: str | None) -> dict:
    """Offline contract replay. Never invokes LLMs, tools, or native operations."""
    from jsonschema import Draft202012Validator
    db = Path(config['runtime_db'])
    since = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()
    ids = [task_id] if task_id else recent_tasks(db, since)
    results = []
    for tid in ids:
        snapshot = load_task(db, tid, Path(config['snapshot_dir']))
        for number, c in snapshot['captures'].items():
            wire, text = c.get('wire_request'), c.get('response_text')
            if not wire or not text:
                continue
            schema = wire.get('response_format', {}).get('json_schema', {}).get('schema') or wire.get('text', {}).get('format', {}).get('schema')
            if not isinstance(schema, dict):
                continue
            try:
                value = json.loads(text)
                errors = list(Draft202012Validator(schema).iter_errors(value))
                passed = not errors
                reason = None if passed else 'captured_response_violates_captured_schema'
            except ValueError:
                passed, reason = False, 'model_response_not_json'
            results.append({'task_id': tid, 'call_number': number, 'schema_valid': passed, 'reason': reason,
                            'prompt_sha256': c.get('prompt', {}).get('sha256')})
    report = {'scope': 'offline captured request/response schema only; NOT end-to-end quality',
              'model_calls': 0, 'tool_calls': 0, 'checked': len(results),
              'conclusion': 'NO_CAPTURED_RESPONSES' if not results else 'SCHEMA_CHECK_ONLY',
              'passed': sum(r['schema_valid'] for r in results), 'results': results,
              'not_covered': ['task success', 'tool selection appropriateness', 'factual correctness', 'UI', 'model nondeterminism']}
    private_json(WORK / 'replay-report.json', report)
    return report


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['sync', 'watch', 'replay'])
    p.add_argument('--task-id')
    args = p.parse_args()
    config = load_config()
    if args.command == 'replay':
        report = replay(config, args.task_id)
        print(json.dumps({k: v for k, v in report.items() if k != 'results'}, ensure_ascii=False))
        return 0 if report['passed'] == report['checked'] else 1
    if config['mode'] == 'off':
        print('Observability disabled; no content exported.')
        return 0
    sink = Sink(config)
    try:
        while True:
            try:
                # Retried by the sidecar, never by a product Planner call.
                sink.prompt((ROOT / 'host' / 'prompts' / 'planner.system.txt').read_text())
                report = sync(config, sink, task_id=args.task_id)
                print(json.dumps(report, ensure_ascii=False), flush=True)
            except Exception as exc:
                # Log types only; no API error bodies/credentials/user documents.
                private_json(WORK / 'status.json', {'export_error_type': type(exc).__name__, 'checked_at': datetime.now(timezone.utc).isoformat()})
                print('Observability sync error: ' + type(exc).__name__, flush=True)
                if args.command != 'watch':
                    return 1
            if args.command != 'watch':
                return 0 if not (report.get('export_failures') or report.get('prompt_sync_failures')) else 1
            time.sleep(max(5, min(60, int(config.get('poll_seconds', 10)))))
            changed = load_config()
            if changed['mode'] == 'off':
                return 0
            config = changed
            sink.config = config
    finally:
        sink.close()


if __name__ == '__main__':
    raise SystemExit(main())
