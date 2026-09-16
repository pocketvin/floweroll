"""Read-only projection of existing Runtime evidence into portable span records.

This module never imports Storage, executes tools, or changes lifecycle state.
Unavailable historical inputs are explicitly unavailable, not reconstructed.
"""
from __future__ import annotations
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
from typing import Any
import uuid


def decode(value: Any, default: Any = None) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            return default
    return value if value is not None else default


def timestamp(value: str) -> int:
    dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1_000_000_000)


def identity(namespace: str, value: str, length: int = 32) -> str:
    return hashlib.sha256((namespace + ':' + value).encode()).hexdigest()[:length]


def trace_namespace(config: dict, db: Path) -> str:
    """Preserve trace identities when a local database is moved or renamed."""
    configured = config.get('trace_namespace')
    if configured is None:
        return identity('floweroll-db', str(db.resolve()))
    if not isinstance(configured, str) or len(configured) != 32 or any(c not in '0123456789abcdef' for c in configured):
        raise ValueError('trace_namespace must be a 32-character hexadecimal identity')
    return configured


def readonly(path: Path) -> sqlite3.Connection:
    # mode=ro is essential: sqlite3.connect(path) creates/migrates missing DBs.
    c = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=0.5)
    c.row_factory = sqlite3.Row
    c.execute('PRAGMA query_only=ON')
    return c


def load_task(db: Path, task_id: str, capture_dir: Path) -> dict:
    uuid.UUID(task_id)
    with closing(readonly(db)) as c:
        c.execute('BEGIN')
        task = c.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
        if task is None:
            raise KeyError('Task not found')
        runtime = c.execute('SELECT * FROM task_runtime WHERE task_id=?', (task_id,)).fetchone()
        traces = [dict(r) for r in c.execute('SELECT * FROM traces WHERE task_id=? ORDER BY id LIMIT 10000', (task_id,))]
        actions = [dict(r) for r in c.execute('SELECT * FROM actions WHERE task_id=? ORDER BY step_index LIMIT 500', (task_id,))]
        attempts = [dict(r) for r in c.execute('SELECT aa.* FROM action_attempts aa JOIN actions a ON a.id=aa.action_id WHERE a.task_id=? ORDER BY aa.started_at LIMIT 1000', (task_id,))]
        decisions = [dict(r) for r in c.execute('SELECT * FROM planner_decisions WHERE task_id=? ORDER BY sequence LIMIT 500', (task_id,))]
    captures = {}
    folder = capture_dir / task_id
    if folder.is_dir() and not folder.is_symlink():
        for file in sorted(folder.glob('*.json'))[-256:]:
            if file.is_symlink() or file.stat().st_size > 4 * 1024 * 1024:
                continue
            try:
                value = json.loads(file.read_text())
                if value.get('task_id') == task_id:
                    n = int(value['call_number'])
                    if n not in captures or value.get('updated_at', '') > captures[n].get('updated_at', ''):
                        captures[n] = value
            except (OSError, ValueError, KeyError):
                continue
    return dict(task=dict(task), runtime=dict(runtime or {}), traces=traces,
                actions=actions, attempts=attempts, decisions=decisions, captures=captures)


def recent_tasks(db: Path, since: str, limit: int = 100) -> list[str]:
    with closing(readonly(db)) as c:
        # Recent activity, not just recent creation; old interrupted tasks can resume.
        return [r['id'] for r in c.execute('''SELECT t.id FROM tasks t
            LEFT JOIN traces tr ON tr.task_id=t.id
            GROUP BY t.id HAVING MAX(COALESCE(tr.created_at,t.updated_at))>=?
            ORDER BY MAX(COALESCE(tr.created_at,t.updated_at)) DESC LIMIT ?''', (since, min(200, limit)))]


def prompt_text(capture: dict) -> str | None:
    wire = capture.get('wire_request', {})
    messages = wire.get('messages', wire.get('input', []))
    texts = [x['content'] for x in messages if isinstance(x, dict) and x.get('role') == 'system' and isinstance(x.get('content'), str)]
    return '\n'.join(texts) if texts else None


def decision_context(capture: dict) -> dict | None:
    wire = capture.get('wire_request', {})
    for message in wire.get('messages', wire.get('input', [])):
        if isinstance(message, dict) and message.get('role') == 'user':
            parsed = decode(message.get('content'), {})
            if isinstance(parsed, dict) and isinstance(parsed.get('decision_context'), dict):
                return parsed['decision_context']
    return None


def layer_evidence(snapshot: dict) -> list[dict]:
    evidence = []
    for t in snapshot['traces']:
        event, data = t['event_type'], decode(t['data_json'], {})
        claim = layer = None
        if event == 'planner.call.failed':
            error = str(data.get('error_type', ''))
            text = str(data.get('error', '')).lower()
            layer = 'Provider / Transport' if ('Transient' in error or 'timeout' in text or 'timed out' in text or 'disconnected' in text) else 'Planner / Contract'
            claim = '本次模型调用失败；仅凭该事件不能判定 Prompt 质量。'
        elif event == 'planner.retry_resumed':
            layer, claim = 'Runtime', '持久重试等待已唤醒；不等于模型调用或整个任务已成功。'
        elif event == 'action.model_correctable_failure':
            layer, claim = 'Tool / Planner contract', '工具报告可纠正失败；需要结合参数与 Schema 判断责任。'
        elif event == 'task.blocked':
            layer, claim = 'Runtime', '此时任务进入阻塞；当前状态以 Task 根节点为准。'
        if claim:
            evidence.append({'layer': layer, 'evidence_kind': 'observed_event', 'event_id': t['id'],
                             'event': event, 'at': t['created_at'], 'claim': claim,
                             'error_type': data.get('error_type'), 'reason': data.get('reason')})
    return evidence[-50:]


def build_spans(snapshot: dict, namespace: str) -> list[dict]:
    task, rt = snapshot['task'], snapshot['runtime']
    events = snapshot['traces']
    captures = snapshot['captures']
    trace_id = identity(namespace, task['id'])
    session = task.get('thread_id') or task['id']
    common = {'langfuse.session.id': session, 'langfuse.trace.name': task['goal'][:100],
              'langfuse.environment': 'floweroll-local', 'langfuse.trace.public': False,
              'langfuse.trace.metadata.task_id': task['id'], 'langfuse.trace.metadata.thread_id': session,
              'langfuse.trace.metadata.evidence_source': 'read-only Runtime projection',
              'floweroll.task_id': task['id']}
    spans = []
    last_at = max([task['updated_at']] + [e['created_at'] for e in events] + [c.get('updated_at', task['updated_at']) for c in captures.values()])
    root_key = 'task'

    def add(key, name, kind, start, end, *, parent=root_key, input=None, output=None, metadata=None, error=False, extra=None):
        attrs = dict(common, **{'langfuse.observation.type': kind})
        if input is not None:
            attrs['langfuse.observation.input'] = json.dumps(input, ensure_ascii=False, separators=(',', ':'))
        if output is not None:
            attrs['langfuse.observation.output'] = json.dumps(output, ensure_ascii=False, separators=(',', ':'))
        for k, v in (metadata or {}).items():
            if v is not None:
                attrs['langfuse.observation.metadata.' + k] = v if isinstance(v, (str, bool, int, float)) else json.dumps(v, ensure_ascii=False)
        attrs.update(extra or {})
        if error:
            attrs['langfuse.observation.level'] = 'ERROR'
        record = {'key': key, 'name': name, 'trace_id': trace_id, 'span_id': identity(trace_id, key, 16),
                  'parent_span_id': identity(trace_id, parent, 16) if parent else None,
                  'start_ns': timestamp(start), 'end_ns': max(timestamp(start), timestamp(end)),
                  'attributes': attrs, 'error': error}
        spans.append(record)
        return record

    grouped = {}
    decision_calls = {}
    current_call = None
    for e in events:
        data = decode(e['data_json'], {})
        n = data.get('call_number')
        if e['event_type'] == 'planner.call.started':
            current_call = n
        if isinstance(n, int):
            grouped.setdefault(n, {})[e['event_type']] = dict(e, data=data)
        if e['event_type'] == 'planner.decision' and current_call is not None:
            decision_calls[data.get('decision_id')] = current_call
    decisions = {decision_calls[d['id']]: decode(d['decision_json'], {}) for d in snapshot['decisions'] if d['id'] in decision_calls}
    metrics = [g['planner.call.metrics']['data'] for g in grouped.values() if 'planner.call.metrics' in g]
    reported_tokens = sum(x.get('total_tokens', 0) for x in metrics)
    summary = {'task_status': task['status'], 'runtime_phase': rt.get('phase'),
               'planner_calls': len(grouped), 'actions': len(snapshot['actions']),
               'tool_attempts': len(snapshot['attempts']),
               'reported_tokens_only': reported_tokens,
               'calls_without_reported_usage': sum(1 for g in grouped.values() if 'total_tokens' not in g.get('planner.call.metrics', {}).get('data', {})),
               'cost': None, 'cost_note': '未配置经核实的 Kimi 单价；缺失 usage 不按零费用计算。',
               'captured_calls': len(captures),
               'historical_prompt_note': '未采集的请求无法从当前模板精确重建。',
               'layer_evidence': layer_evidence(snapshot),
               'not_automatically_evaluated': ['Prompt quality', 'Context completeness', 'factual correctness', 'iPhone UI', 'RAG quality', 'Skill quality']}
    add(root_key, task['goal'][:100], 'agent', task['created_at'], last_at, parent=None,
        input={'goal': task['goal']}, output=summary,
        metadata={'task_status': task['status'], 'runtime_phase': rt.get('phase'),
                  'is_running_snapshot': task['status'] not in ('completed', 'failed', 'cancelled'),
                  'parent_task_id': task.get('parent_task_id'), 'snapshot_at': last_at},
        error=task['status'] in ('failed', 'blocked'))

    for n, group in sorted(grouped.items()):
        c = captures.get(n, {})
        started = group.get('planner.call.started', next(iter(group.values())))['created_at']
        m = group.get('planner.call.metrics', {}).get('data', {})
        end = max([x['created_at'] for x in group.values()] + [c.get('updated_at', started)])
        error = 'planner.call.failed' in group or c.get('state') == 'error'
        input_value = c.get('wire_request', {'unavailable': 'Exact wire payload was not captured', 'capture_mode': c.get('mode', 'historical')})
        context = decision_context(c)
        extra = {}
        model = c.get('provider_model') or m.get('provider_model')
        if model:
            extra['gen_ai.request.model'] = model
        extra['gen_ai.operation.name'] = 'chat'
        usage = dict(c.get('usage', {}))
        usage.update({k: m[k] for k in ('prompt_tokens', 'completion_tokens', 'total_tokens') if k in m})
        inp = usage.get('prompt_tokens', usage.get('input_tokens'))
        out = usage.get('completion_tokens', usage.get('output_tokens'))
        if inp is not None:
            extra['gen_ai.usage.input_tokens'] = inp
        if out is not None:
            extra['gen_ai.usage.output_tokens'] = out
        if inp is not None or out is not None:
            extra['langfuse.observation.usage_details'] = json.dumps({k: v for k, v in {'input': inp, 'output': out}.items() if v is not None})
        output = {'model_response': decode(c.get('response_text'), c.get('response_text')),
                  'committed_decision': decisions.get(n),
                  'model_call_state': c.get('state', m.get('outcome', 'unavailable')),
                  'commit_event': 'planner.call.committed' in group,
                  'stale_or_superseded': any('stale' in k or 'superseded' in k for k in group)}
        add('planner:' + str(n), 'Planner #' + str(n), 'generation', started, end,
            input=input_value, output=output, error=error, extra=extra,
            metadata={**m, 'call_number': n, 'request_sha256': c.get('request_sha256'),
                      'prompt_sha256': c.get('prompt', {}).get('sha256'), 'capture_mode': c.get('mode', 'not_captured'),
                      'wire_capture_note': 'Final sent body, secrets redacted; no HTTP authorization headers' if c.get('wire_request') else 'not captured',
                      'basis_runtime_revision': c.get('basis_runtime_revision'), 'basis_inbox_seq': c.get('basis_inbox_seq'),
                      'visible_capabilities': c.get('visible_capabilities'),
                      'context_sections': list(context) if context else None,
                      'selector_ranking_evidence': 'Only captured working set is known; no invented ranking scores.',
                      'in_flight': not c.get('ended_at') and 'planner.call.metrics' not in group})
        for attempt in c.get('attempts', []):
            add(f'planner:{n}:http:{attempt["index"]}', f'Provider HTTP attempt {attempt["index"]}', 'span',
                attempt['started_at'], attempt.get('ended_at', end), parent='planner:' + str(n),
                metadata=attempt, error=attempt.get('state') == 'error')

    for a in snapshot['actions']:
        n = decision_calls.get(a.get('planner_decision_id'))
        add('action:' + a['id'], a['action_type'], 'tool', a['created_at'], a['updated_at'],
            parent='planner:' + str(n) if n is not None else root_key,
            input=decode(a['payload_json']), output={'status': a['status'], 'result': decode(a['result_json']),
                                                    'failure_code': a.get('failure_code'), 'error': a.get('error_text')},
            metadata={'action_id': a['id'], 'step_index': a['step_index'], 'status': a['status'],
                      'capability_definition_digest': a.get('capability_definition_digest')},
            error=a['status'] == 'failed')
    for a in snapshot['attempts']:
        add('attempt:' + a['id'], 'Attempt ' + str(a['attempt_number']), 'span', a['started_at'], a.get('finished_at') or a['updated_at'],
            parent='action:' + a['action_id'], output={'outcome': a.get('latest_outcome'), 'status': a['status']},
            metadata={'attempt_id': a['id'], 'source_kind': a.get('source_kind'), 'dispatch_digest': a.get('dispatch_digest'),
                      'policy_revision': a.get('policy_revision'), 'outcome': a.get('latest_outcome')},
            error=a.get('latest_outcome') not in (None, 'SUCCESS', 'INPUT_REQUIRED', 'UNKNOWN'))
    important = ('planner.retry_wait', 'planner.retry_resumed', 'task.blocked', 'task.cancelled', 'task.completed', 'inbox.accepted', 'observation.verified', 'action.verification.metrics')
    for e in events:
        if e['event_type'] not in important:
            continue
        data = decode(e['data_json'], {})
        parent = 'attempt:' + data['attempt_id'] if data.get('attempt_id') else root_key
        if parent != root_key and not any(s['key'] == parent for s in spans):
            parent = root_key
        add('event:' + str(e['id']), e['event_type'], 'event', e['created_at'], e['created_at'],
            parent=parent, output=data, metadata={'runtime_event_id': e['id']})
    return spans


def ready_records(snapshot: dict, records: list[dict]) -> list[dict]:
    """Langfuse v4 observations are immutable: export completed operations once.

    A running Task's root is emitted only at a real terminal state. Short immutable
    request/context and state snapshot events make ongoing work inspectable without
    repeatedly exporting an unfinished generation and double-counting its tokens.
    """
    task = snapshot['task']
    terminal = task['status'] in ('completed', 'failed', 'cancelled')
    closed_calls = set()
    for event in snapshot['traces']:
        data = decode(event['data_json'], {})
        if event['event_type'] in ('planner.call.committed', 'planner.call.failed', 'planner.call.stale', 'planner.result.stale', 'planner.call.superseded'):
            if isinstance(data.get('call_number'), int):
                closed_calls.add(data['call_number'])
    closed_actions = {a['id'] for a in snapshot['actions'] if a['status'] in ('succeeded', 'failed', 'cancelled')}
    closed_attempts = {a['id'] for a in snapshot['attempts'] if a.get('finished_at')}
    ready = []
    for record in records:
        key = record['key']
        include = key.startswith('event:') or (key == 'task' and terminal)
        if key.startswith('planner:'):
            parts = key.split(':')
            number = int(parts[1])
            if len(parts) == 2:
                include = number in closed_calls
            else:
                capture = snapshot['captures'].get(number, {})
                include = any(a.get('ended_at') and a['index'] == int(parts[-1]) for a in capture.get('attempts', []))
        elif key.startswith('action:'):
            include = key[7:] in closed_actions
        elif key.startswith('attempt:'):
            include = key[8:] in closed_attempts
        if include:
            ready.append(record)
    root = records[0]
    # State at an exact durable event, not a mutable current-status field.
    if not terminal:
        event_id = snapshot['traces'][-1]['id'] if snapshot['traces'] else 0
        rev = snapshot['runtime'].get('runtime_revision', 0)
        state_key = f'state:{rev}:{event_id}'
        r = dict(root, key=state_key, name=f'Runtime 状态快照 · {task["status"]}',
                 span_id=identity(root['trace_id'], state_key, 16), parent_span_id=root['span_id'],
                 start_ns=root['end_ns'], attributes=dict(root['attributes']))
        r['attributes']['langfuse.observation.type'] = 'event'
        r['attributes']['langfuse.observation.metadata.snapshot_note'] = '状态仅截至此事件时间；非 Task 终态，后续进展查看更新的状态事件。'
        ready.append(r)
    for n, capture in snapshot['captures'].items():
        if not capture.get('request_sha256'):
            continue
        planner = next((r for r in records if r['key'] == f'planner:{n}'), None)
        if planner is None:
            continue
        key = f'request:{n}'
        attrs = {k: v for k, v in planner['attributes'].items()
                 if not k.startswith('gen_ai.usage.') and k not in ('langfuse.observation.usage_details', 'langfuse.observation.output', 'langfuse.observation.level')}
        attrs['langfuse.observation.type'] = 'event'
        attrs['langfuse.observation.metadata.capture_note'] = '模型请求组装完成；不代表模型已响应或 Runtime 已提交决策。'
        ready.append(dict(planner, key=key, name=f'Planner #{n} · 实际请求',
                          span_id=identity(root['trace_id'], key, 16), parent_span_id=planner['span_id'],
                          end_ns=planner['start_ns'], attributes=attrs, error=False))
    return ready
