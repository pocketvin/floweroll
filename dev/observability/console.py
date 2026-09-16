"""Thin, read-only Chinese inspector over existing Runtime evidence.

Langfuse owns trace/prompt management. This process only projects local evidence;
it has no Runtime write API, model client, tool executor, or network dependency.
"""
from __future__ import annotations
from .projector import trace_namespace

import argparse
from contextlib import closing
from datetime import datetime, timezone
import difflib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import urlsplit, unquote
import uuid

from .exporter import ROOT, WORK, load_config
from .observation_projection import list_observations, observation_db_path, observation_detail
from .projector import build_spans, decode, decision_context, load_task, prompt_text, readonly
from floweroll_host.planner_capture import scrub

from .topology import source_topology, runtime_stats, component_details
from .execution_paths import task_path, unit_rows, observation_path
from .operation_projection import operations, operation_detail

WEB_DIST = Path(__file__).parent / 'web' / 'dist'

STATIC = Path(__file__).parent / 'static'
TERMINAL = {'completed', 'failed', 'cancelled'}


def contract_check(capture: dict) -> dict:
    """A schema check is evidence, never a quality/success verdict."""
    from jsonschema import Draft202012Validator
    wire, response = capture.get('wire_request') or {}, capture.get('response_text')
    schema = (wire.get('response_format', {}).get('json_schema', {}).get('schema')
              or wire.get('text', {}).get('format', {}).get('schema'))
    if response is None or not isinstance(schema, dict):
        return {'status': 'unavailable', 'note': '没有完整请求/响应，无法回放检查。'}
    try:
        errors = list(Draft202012Validator(schema).iter_errors(json.loads(response)))
        return {'status': 'fail' if errors else 'pass', 'error_count': len(errors),
                'note': '仅验证当时响应是否符合当时的 JSON Schema；不代表任务质量、工具选择或事实正确。'}
    except ValueError:
        return {'status': 'fail', 'note': '模型响应不是合法 JSON。'}


class Inspector:
    def __init__(self, config: dict) -> None:
        self.config = config
        self.db = Path(config['runtime_db'])
        self.captures = Path(config['snapshot_dir'])
        self.namespace = trace_namespace(config, self.db)
        self.full = config['mode'] == 'local_full'
        self.base = config['langfuse_url'].rstrip('/') + '/project/' + config.get('project_id', 'floweroll')
        self.observation_db = observation_db_path(self.db)
        self.observation_db.resolve().parent.relative_to((ROOT / 'work').resolve())

    def task(self, task_id: str) -> dict:
        return load_task(self.db, str(uuid.UUID(task_id)), self.captures)

    def index(self) -> dict:
        with closing(readonly(self.db)) as conn:
            rows = [dict(r) for r in conn.execute('''SELECT t.id,t.goal,t.status,t.created_at,t.updated_at,
                r.phase,r.planner_calls,(SELECT count(*) FROM actions a WHERE a.task_id=t.id) AS action_count
                FROM tasks t LEFT JOIN task_runtime r ON r.task_id=t.id
                ORDER BY t.updated_at DESC LIMIT 60''')]
        for r in rows:
            r['goal'] = r['goal'][:200] if self.full else 'Task ' + r['id'][:8]
        return scrub({'tasks': rows, 'limit': 60})

    def overview(self, task_id: str) -> dict:
        snapshot = self.task(task_id)
        records = build_spans(snapshot, self.namespace)
        root = records[0]
        summary = json.loads(root['attributes']['langfuse.observation.output'])
        task = snapshot['task']
        events = []
        model_ms = 0.0
        for r in records[1:]:
            key, attrs = r['key'], r['attributes']
            if key.startswith('planner:') and key.count(':') != 1:
                continue
            if key.startswith('attempt:'):
                continue
            if key.startswith('event:') and r['name'] not in ('planner.retry_wait','planner.retry_resumed','task.blocked','task.completed','task.cancelled','inbox.accepted'):
                continue
            n = int(key.split(':')[1]) if key.startswith('planner:') else None
            capture = snapshot['captures'].get(n, {})
            output = decode(attrs.get('langfuse.observation.output'), {})
            duration = max(0, r['end_ns'] - r['start_ns']) / 1_000_000
            model_ms += float(attrs.get('langfuse.observation.metadata.model_ms', 0) or 0)
            item = {'key': key, 'name': r['name'], 'kind': attrs['langfuse.observation.type'],
                    'at': datetime.fromtimestamp(r['start_ns']/1e9, timezone.utc).isoformat(),
                    'duration_ms': duration, 'error': r['error'], 'call_number': n,
                    'capture_available': bool(capture.get('wire_request')) and self.full,
                    'in_flight': bool(attrs.get('langfuse.observation.metadata.in_flight')),
                    'status': output.get('status') or output.get('model_call_state'),
                    'prompt_sha256': capture.get('prompt', {}).get('sha256'),
                    'visible_capabilities': capture.get('visible_capabilities', [])}
            if self.full and n is None:
                item.update(input=decode(attrs.get('langfuse.observation.input')), output=output)
            events.append(item)
        end = datetime.now(timezone.utc).timestamp()*1e9 if task['status'] not in TERMINAL else root['end_ns']
        summary.update(elapsed_ms=max(0, end-root['start_ns'])/1e6, model_ms_sum=model_ms)
        # Known snapshots need not mean a full request was captured.
        summary['full_captured_calls'] = sum(bool(c.get('wire_request')) for c in snapshot['captures'].values()) if self.full else 0
        return scrub({'task': {k: task.get(k) for k in ('id','status','created_at','updated_at','thread_id')},
            'goal': task['goal'] if self.full else 'Task ' + task_id[:8], 'summary': summary,
            'events': sorted(events, key=lambda e: (e['at'], e['key'])),
            'trace_url': self.base + '/traces/' + root['trace_id'],
            'checked_at': datetime.now(timezone.utc).isoformat()})

    def call(self, task_id: str, number: int) -> dict:
        if not 1 <= number <= 10000:
            raise ValueError('Invalid call number')
        snapshot = self.task(task_id)
        capture = snapshot['captures'].get(number, {})
        captured = self.full and bool(capture.get('wire_request'))
        result = {'call_number': number, 'available': captured, 'mode': self.config['mode'],
                  'note': '这是发送前采集的最终请求体；密钥已脱敏，不含 HTTP 认证头或模型私有推理。' if captured else '该调用未采集完整请求，或当前处于关闭/元数据模式。不会拿现在的模板伪造历史 Prompt。',
                  'metadata': {k: capture.get(k) for k in ('state','started_at','ended_at','request_bytes','request_sha256','prompt','visible_capabilities','error_type','content_omitted')},
                  'metrics': [decode(t['data_json'], {}) for t in snapshot['traces'] if t['event_type']=='planner.call.metrics' and decode(t['data_json'], {}).get('call_number')==number]}
        if captured:
            text = prompt_text(capture) or ''
            ctx = decision_context(capture) or {}
            current = (ROOT / 'host/prompts/planner.system.txt').read_text(encoding='utf-8')
            result.update(system_prompt=text, context=ctx, wire_request=capture['wire_request'],
                tools={'visible': capture.get('visible_capabilities', []), 'definitions': ctx.get('available_capabilities', []),
                       'note': '真实工作集；没有采集的排序分数不猜测。参数约束见原始请求中的 response_format/text.format。'},
                model_response=decode(capture.get('response_text'), capture.get('response_text')),
                contract_check=contract_check(capture),
                prompt_diff=''.join(difflib.unified_diff(text.splitlines(True), current.splitlines(True), fromfile='本次实际使用', tofile='当前源码', n=3)),
                prompt_matches_current=text==current)
        return scrub(result)

    def status(self) -> dict:
        try:
            export = json.loads((WORK / 'status.json').read_text())
        except (OSError, ValueError):
            export = {'status': 'not_started'}
        source = (ROOT / 'host/prompts/planner.system.txt').read_text(encoding='utf-8')
        return {'mode': self.config['mode'], 'read_only': True, 'export': export,
                'prompt_sha256': hashlib.sha256(source.encode()).hexdigest(),
                'langfuse_url': self.base, 'prompts_url': self.base + '/prompts',
                'prompt_source': 'host/prompts/planner.system.txt',
                'privacy': '完整记录仅在本机。切换采集模式不会删除此前已保存的本地历史。',
                'limitations': ['旧请求无法补录','结构回放不代表质量评测','未知费用不显示成零费用','归因仅陈列证据，不自动判定 Prompt 或模型质量']}

    def topology(self) -> dict:
        return scrub(runtime_stats(source_topology(), self.db))

    def task_path(self, task_id: str) -> dict:
        return scrub(task_path(self.task(task_id), self.namespace, full=self.full,
                               units=unit_rows(self.config, task_id),
                               operation_records=operations(self.config, 'task', task_id)))

    def observation_path(self, session_id: str) -> dict:
        return scrub(observation_path(self.observation(session_id), self.namespace,
            operation_records=operations(self.config, 'observation', session_id)))

    def observation_call(self, session_id: str, capture_id: str) -> dict:
        self.observation(session_id)  # Require the original Session to still exist.
        return scrub(operation_detail(self.config, 'observation', session_id, capture_id))

    def observations(self) -> dict:
        return scrub(list_observations(self.observation_db, full=self.full))

    def observation(self, session_id: str) -> dict:
        return scrub(observation_detail(self.observation_db, session_id, full=self.full))


class ConsoleServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Never log private URLs, payloads, exception bodies or credentials.

    def _send(self, status: int, data: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, status: int, value: dict) -> None:
        self._send(status, json.dumps(value, ensure_ascii=False).encode(), 'application/json; charset=utf-8')

    def do_GET(self) -> None:
        host = self.headers.get('Host', '')
        allowed = {'localhost:' + str(self.server.server_port), '127.0.0.1:' + str(self.server.server_port)}
        if host not in allowed or self.headers.get('Origin') not in (None, 'http://' + host):
            return self._json(403, {'error': 'local_same_origin_only'})
        parsed = urlsplit(self.path)
        if parsed.scheme or parsed.netloc or parsed.query:
            return self._json(400, {'error': 'invalid_path'})
        path = parsed.path
        # Vite artifacts only. Never expose arbitrary local files or source paths.
        target = None
        if path == '/' and (WEB_DIST / 'index.html').is_file():
            target = WEB_DIST / 'index.html'
        elif path.startswith('/ui/assets/'):
            name = path.removeprefix('/ui/assets/')
            if '/' not in name and '\\' not in name and name not in ('.', '..'):
                candidate = WEB_DIST / 'assets' / name
                if candidate.suffix in {'.js', '.css', '.svg', '.woff2'}:
                    target = candidate
        if target is not None:
            if not target.is_file() or target.is_symlink() or not target.resolve().is_relative_to(WEB_DIST.resolve()):
                return self._json(404, {'error':'not_found'})
            content_type = {'.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.svg':'image/svg+xml', '.woff2':'font/woff2'}[target.suffix]
            return self._send(200, target.read_bytes(), content_type)
        assets = {'/': ('index.html','text/html'), '/app.js': ('app.js','text/javascript'), '/app.css': ('app.css','text/css')}
        if path in assets:
            name, kind = assets[path]
            return self._send(200, (STATIC/name).read_bytes(), kind+'; charset=utf-8')
        if not path.startswith('/api/'):
            return self._json(404, {'error': 'not_found'})
        # A cross-origin page cannot add this header without a denied preflight.
        if self.headers.get('X-Floweroll-Console') != '1' or self.headers.get('Sec-Fetch-Site') == 'cross-site':
            return self._json(403, {'error': 'same_origin_header_required'})
        try:
            inspector = Inspector(load_config())
            parts = path.strip('/').split('/')
            if path == '/api/topology':
                data = inspector.topology()
            elif len(parts) == 4 and parts[:2] == ['api','tasks'] and parts[3] == 'path':
                data = inspector.task_path(parts[2])
            elif len(parts) == 4 and parts[:2] == ['api','observations'] and parts[3] == 'path':
                data = inspector.observation_path(parts[2])
            elif len(parts) == 5 and parts[:2] == ['api','observations'] and parts[3] == 'calls':
                data = inspector.observation_call(parts[2], parts[4])
            elif len(parts) == 3 and parts[:2] == ['api','components']:
                data = scrub(component_details(unquote(parts[2])))
            elif path == '/api/status':
                data = inspector.status()
            elif path == '/api/tasks':
                data = inspector.index()
            elif len(parts) == 3 and parts[:2] == ['api','tasks']:
                data = inspector.overview(parts[2])
            elif path == '/api/observations':
                data = inspector.observations()
            elif len(parts) == 3 and parts[:2] == ['api','observations']:
                data = inspector.observation(parts[2])
            elif len(parts) == 5 and parts[:2] == ['api','tasks'] and parts[3] == 'calls':
                data = inspector.call(parts[2], int(parts[4]))
            else:
                return self._json(404, {'error': 'not_found'})
            self._json(200, data)
        except KeyError:
            self._json(404, {'error': 'task_not_found'})
        except ValueError:
            self._json(400, {'error': 'invalid_request_or_config'})
        except Exception as exc:
            self._json(503, {'error': 'read_unavailable', 'error_type': type(exc).__name__})

    def do_POST(self):
        self._json(405, {'error': 'read_only_console'})

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_POST


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=3034)
    args = parser.parse_args()
    load_config()  # Validate loopback/work boundaries before serving.
    with ConsoleServer(('127.0.0.1', args.port), Handler) as server:
        print(f'小卷开发观察台 http://localhost:{server.server_port} (read-only, loopback only)', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
