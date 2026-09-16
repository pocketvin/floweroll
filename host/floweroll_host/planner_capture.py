"""Opt-in, local-only Planner request snapshots; never part of Runtime truth.

No SDK/network dependencies in the product Host. A bounded best-effort queue writes
private snapshots; the separate OTel/Langfuse sidecar reads them. Missing config,
queue pressure, permission/disk failures must not change model execution.
"""
from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
from functools import wraps
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import threading
import time
from typing import Any, Dict, Iterator, Optional
import uuid

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = ROOT / 'work' / 'observability' / 'config.json'
_ACTIVE: ContextVar[Optional['Capture']] = ContextVar('floweroll_planner_capture', default=None)
_ENTITY: ContextVar[Optional[dict]] = ContextVar('floweroll_capture_entity', default=None)
_QUEUE: queue.Queue = queue.Queue(maxsize=64)
_LOCK = threading.Lock()
_WRITER: Optional[threading.Thread] = None
_PROCESS_INSTANCE = str(uuid.uuid4())
_STATS = {'queued': 0, 'written': 0, 'dropped': 0, 'errors': 0}
_SECRET_KEY = re.compile(r'^(authorization|proxy.authorization|api.?key|.*secret.*|password|access.?token|refresh.?token|cookie|set.cookie)$', re.I)
_SECRET_TEXT = re.compile(r'(?i)(Bearer\s+)[^\s"\\]+|\b(?:sk-|pk-lf-|sk-lf-)[A-Za-z0-9_\-]{8,}|(?i:((?:api_key|access_token|refresh_token|token|secret|password)=))[^\s&"\\]+')


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def scrub(value: Any, secret_values: tuple = ()) -> Any:
    """Secret redaction, NOT PII anonymization. local_full may contain personal data."""
    if isinstance(value, dict):
        return {str(k): '[redacted-secret]' if _SECRET_KEY.match(str(k)) else scrub(v, secret_values)
                for k, v in value.items() if str(k) not in ('reasoning_content', 'reasoning_details', 'chain_of_thought')}
    if isinstance(value, (list, tuple)):
        return [scrub(x, secret_values) for x in value]
    if isinstance(value, str):
        # Context and span input/output often contain JSON encoded as strings.
        # Traverse it too, without changing the actual provider request.
        if value.lstrip().startswith(('{', '[')):
            try:
                decoded = json.loads(value)
                if isinstance(decoded, (dict, list)):
                    return json.dumps(scrub(decoded, secret_values), ensure_ascii=False, separators=(',', ':'))
            except (ValueError, TypeError):
                pass
        for secret in secret_values:
            if secret:
                value = value.replace(secret, '[redacted-secret]')
        return _SECRET_TEXT.sub(lambda m: (m.group(1) or m.group(2) or '') + '[redacted-secret]', value)
    return value


def _write_loop() -> None:
    while True:
        path, content = _QUEUE.get()
        try:
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            # Files are in a private ignored project directory, never public assets.
            path.parent.chmod(0o700)
            tmp = path.with_suffix('.tmp')
            fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'wb') as f:
                f.write(content)
            os.replace(str(tmp), str(path))
            _STATS['written'] += 1
        except Exception:
            _STATS['errors'] += 1
        finally:
            _QUEUE.task_done()


def _enqueue(path: Path, content: bytes) -> None:
    global _WRITER
    with _LOCK:
        if _WRITER is None or not _WRITER.is_alive():
            _WRITER = threading.Thread(target=_write_loop, name='planner-snapshot-writer', daemon=True)
            _WRITER.start()
    try:
        _QUEUE.put_nowait((path, content))
        _STATS['queued'] += 1
    except queue.Full:
        _STATS['dropped'] += 1


def flush_for_test(timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while _QUEUE.unfinished_tasks and time.monotonic() < deadline:
        time.sleep(0.01)
    return not _QUEUE.unfinished_tasks


def capture_stats() -> Dict[str, int]:
    return dict(_STATS)


class Capture:
    def __init__(self, config: Dict[str, Any], basis: Dict[str, Any]) -> None:
        self.config = config
        self.secrets: tuple = ()
        self.data = {'schema': 1, **basis, 'capture_id': str(uuid.uuid4()),
                     'started_at': utcnow(), 'mode': config['mode'], 'state': 'started', 'attempts': []}
        self.monotonic_start = time.perf_counter()
        if basis.get('operation'):
            self.data.update(process_instance=_PROCESS_INSTANCE, started_monotonic_ns=time.perf_counter_ns())
        if basis.get('lifecycle') in ('task', 'observation'):
            safe_id = str(uuid.UUID(str(basis['entity_id'])))
            self.path = (Path(config['snapshot_dir']) / 'operations' / basis['lifecycle'] /
                         safe_id / (self.data['capture_id'] + '.json'))
        else:
            safe_id = str(uuid.UUID(str(basis['task_id'])))
            self.path = Path(config['snapshot_dir']) / safe_id / ('%04d-%s.json' % (basis['call_number'], self.data['capture_id']))

    def save(self) -> None:
        self.data['updated_at'] = utcnow()
        result = scrub(self.data, self.secrets)
        raw = json.dumps(result, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        limit = min(4 * 1024 * 1024, max(4096, int(self.config.get('max_snapshot_bytes', 1048576))))
        if len(raw) > limit:
            # Never pass a truncated payload off as the full wire request.
            result.pop('wire_request', None)
            result.pop('response_text', None)
            result.pop('input', None)
            result.pop('output', None)
            result['content_omitted'] = 'snapshot_size_limit'
            raw = json.dumps(result, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        if len(raw) <= limit:
            _enqueue(self.path, raw)
        else:
            _STATS['dropped'] += 1

    def request(self, payload: Dict[str, Any], raw: bytes, adapter: str, secret_values: tuple) -> None:
        self.secrets = secret_values
        self.data.update(adapter=adapter, provider_model=payload.get('model'),
                         request_bytes=len(raw), request_sha256=hashlib.sha256(raw).hexdigest(),
                         state='request_ready')
        messages = payload.get('messages', payload.get('input', []))
        system = '\n'.join(x.get('content', '') for x in messages if isinstance(x, dict)
                           and x.get('role') == 'system' and isinstance(x.get('content'), str))
        self.data['prompt'] = {'name': self.data.get('prompt_name', 'floweroll/planner'), 'sha256': hashlib.sha256(system.encode()).hexdigest(),
                               'source_path': self.data.get('prompt_source', 'host/prompts/planner.system.txt'),
                               'source_symbol': self.data.get('source_symbol')}
        if self.config['mode'] == 'local_full':
            self.data['wire_request'] = payload
        self.save()

    def response(self, text: Optional[str], usage: Any, finish_reason: Any) -> None:
        self.data.update(response_received_at=utcnow(), finish_reason=finish_reason)
        if isinstance(usage, dict):
            self.data['usage'] = {k: v for k, v in usage.items()
                                  if k in ('prompt_tokens', 'completion_tokens', 'total_tokens', 'input_tokens', 'output_tokens')
                                  and isinstance(v, int) and not isinstance(v, bool) and v >= 0}
        if self.config['mode'] == 'local_full' and isinstance(text, str):
            self.data['response_text'] = text
        self.save()


@contextmanager
def _recording(**basis: Any) -> Iterator[None]:
    capture = None
    token = None
    try:
        path = Path(os.environ.get('FLOWEROLL_OBSERVABILITY_CONFIG', str(DEFAULT_CONFIG)))
        config = json.loads(path.read_text()) if path.is_file() else {}
        # Regression/probe databases must not pollute production snapshots just
        # because the developer enabled capture for their real iPhone Host.
        same_database = not (config.get('runtime_db') and basis.get('runtime_db')) or (
            Path(str(config['runtime_db'])).resolve()
            == Path(str(basis['runtime_db'])).resolve()
        )
        if config.get('mode') in ('metadata', 'local_full') and same_database:
            # Fixed project work boundary; a config cannot publish captures elsewhere.
            folder = Path(config['snapshot_dir']).resolve()
            folder.relative_to((ROOT / 'work').resolve())
            capture = Capture(config, basis)
            token = _ACTIVE.set(capture)
            if basis.get('operation'):
                capture.save()
    except Exception:
        _STATS['errors'] += 1
    if token is None:
        token = _ACTIVE.set(None)
    try:
        yield
    except BaseException as exc:
        if capture:
            try:
                capture.data.update(state='error', ended_at=utcnow(), ended_monotonic_ns=time.perf_counter_ns(), error_type=type(exc).__name__,
                                    duration_ms=round((time.perf_counter()-capture.monotonic_start)*1000,3))
                # Deliberately omit arbitrary exception bodies/provider echoes.
                capture.save()
            except Exception:
                _STATS['errors'] += 1
        raise
    else:
        if capture:
            try:
                capture.data.update(state='finished' if basis.get('operation') else 'response_validated', ended_at=utcnow(), ended_monotonic_ns=time.perf_counter_ns(),
                                    duration_ms=round((time.perf_counter()-capture.monotonic_start)*1000,3))
                capture.save()
            except Exception:
                _STATS['errors'] += 1
    finally:
        if token is not None:
            _ACTIVE.reset(token)


def request_ready(payload: Dict[str, Any], raw: bytes, *, adapter: str, secret_values: tuple = ()) -> None:
    try:
        current = _ACTIVE.get()
        if current:
            current.request(payload, raw, adapter, secret_values)
    except Exception:
        _STATS['errors'] += 1


def response_received(text: Optional[str], usage: Any = None, finish_reason: Any = None) -> None:
    try:
        current = _ACTIVE.get()
        if current:
            current.response(text, usage, finish_reason)
    except Exception:
        _STATS['errors'] += 1


@contextmanager
def http_attempt(index: int) -> Iterator[None]:
    current = _ACTIVE.get()
    record = {'index': index, 'started_at': utcnow()}
    started = time.perf_counter()
    if current:
        try:
            current.data['attempts'].append(record)
            current.save()
        except Exception:
            _STATS['errors'] += 1
    try:
        yield
    except BaseException as exc:
        record.update(state='error', error_type=type(exc).__name__)
        code = getattr(exc, 'code', None)
        if isinstance(code, int):
            record['http_status'] = code
        raise
    else:
        record['state'] = 'response_received'
    finally:
        if current:
            try:
                record['ended_at'] = utcnow()
                record['duration_ms'] = round((time.perf_counter()-started)*1000,3)
                current.save()
            except Exception:
                _STATS['errors'] += 1


@contextmanager
def planner_call(**basis: Any) -> Iterator[None]:
    """Existing Planner capture contract; historical directory/IDs are unchanged."""
    with _recording(**basis):
        yield


@contextmanager
def entity_scope(*, lifecycle: str, entity_id: str, runtime_db: str, **metadata: Any):
    """Bind inside a worker, not its submitting thread; no cross-session leakage."""
    token = _ENTITY.set(dict(lifecycle=lifecycle, entity_id=entity_id,
                             runtime_db=runtime_db, **metadata))
    try:
        yield
    finally:
        _ENTITY.reset(token)


def observation_worker(function):
    @wraps(function)
    def wrapped(self, sid, *args, **kwargs):
        with entity_scope(lifecycle='observation', entity_id=sid,
                          runtime_db=getattr(self, '_capture_runtime_db', ':unbound:')):
            return function(self, sid, *args, **kwargs)
    return wrapped


def model_operation(operation: str):
    """Observe existing calls, without retries, provider changes or new execution."""
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            basis = dict(_ENTITY.get() or {})
            if not basis:
                return function(*args, **kwargs)
            actual = operation
            if operation == 'observation.summary':
                actual = ('observation.question' if kwargs.get('question') is not None else
                          'observation.final' if kwargs.get('final') else operation)
            basis.update(operation=actual, source_symbol=function.__qualname__,
                         prompt_name='floweroll/' + ('observation-vision' if actual == 'observation.vision' else 'observation-summary'),
                         prompt_source='host/floweroll_host/observation_service.py')
            with _recording(**basis):
                result = function(*args, **kwargs)
                operation_result(outcome='model_validated', output=result)
                return result
        return wrapped
    return decorate


def work_unit_operation(function):
    @wraps(function)
    def wrapped(self, dispatch, row, owner):
        try:
            basis = dict(lifecycle='task', entity_id=dispatch['task_id'], task_id=dispatch['task_id'],
                         runtime_db=str(self.assets.task_storage.path), operation='work.unit',
                         parent_action_id=dispatch['action_id'], work_unit_id=row['unit_id'],
                         receipt_id=row['receipt_id'], attempt_owner=owner,
                         capability=row['definition']['capability'], source_symbol=function.__qualname__)
        except Exception:
            return function(self, dispatch, row, owner)
        with _recording(**basis):
            return function(self, dispatch, row, owner)
    return wrapped


def operation_result(*, outcome: str, input: Any = None, output: Any = None,
                     accepted: bool | None = None, **metadata: Any) -> None:
    """Best-effort annotation. Runtime receipt, not this record, owns success."""
    try:
        current = _ACTIVE.get()
        if current is None or not current.data.get('operation'):
            return
        current.data.update(outcome=outcome, accepted=accepted, **metadata)
        if current.config['mode'] == 'local_full':
            if input is not None: current.data['input'] = input
            if output is not None: current.data['output'] = output
        current.save()
    except Exception:
        _STATS['errors'] += 1
