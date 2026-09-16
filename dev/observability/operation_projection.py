"""读取有界 operation snapshots。只读本机证据，不运行模型或产品 Runtime。"""
from __future__ import annotations

import ast
import json
from pathlib import Path
import uuid

from .projector import prompt_text, decode
from .topology import ROOT, scalar

MAX_RECORDS = 500
MAX_BYTES = 4 * 1024 * 1024
PAYLOAD_KEYS = {'wire_request', 'response_text', 'input', 'output'}


def _folder(config: dict, lifecycle: str, entity_id: str) -> Path:
    if lifecycle not in {'task', 'observation'}: raise ValueError('Invalid lifecycle')
    safe = str(uuid.UUID(entity_id))
    folder = Path(config['snapshot_dir']) / 'operations' / lifecycle / safe
    if not folder.resolve().is_relative_to((ROOT / 'work').resolve()): raise ValueError('Invalid capture path')
    current = folder
    while current != ROOT / 'work' and current != current.parent:
        if current.is_symlink(): raise ValueError('Capture path is symlinked')
        current = current.parent
    return folder


def _read(path: Path, config: dict, lifecycle: str, entity_id: str) -> dict | None:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES: return None
    value = json.loads(path.read_text())
    if not isinstance(value, dict): return None
    if value.get('lifecycle') != lifecycle or str(uuid.UUID(value.get('entity_id', ''))) != str(uuid.UUID(entity_id)): return None
    if value.get('capture_id') != path.stem: return None
    if Path(value.get('runtime_db', '')).resolve() != Path(config['runtime_db']).resolve(): return None
    return value


def operations(config: dict, lifecycle: str, entity_id: str) -> dict:
    folder = _folder(config, lifecycle, entity_id)
    if not folder.is_dir(): return {'records':[], 'truncated':False, 'skipped':0}
    paths=[]
    for p in folder.glob('*.json'):
        try: paths.append((p.stat().st_mtime_ns,p))
        except OSError: continue
    paths.sort(key=lambda item:item[0],reverse=True)
    records=[];skipped=0
    for _,path in paths[:MAX_RECORDS]:
        try:
            value=_read(path,config,lifecycle,entity_id)
            if value is None: skipped+=1;continue
            captured = config.get('mode') == 'local_full' and isinstance(value.get('wire_request'), dict)
            record = {k:v for k,v in value.items() if k not in PAYLOAD_KEYS}
            record['captured'] = captured
            if config.get('mode') == 'local_full' and value.get('operation') == 'work.unit':
                record.update(input=value.get('input'),output=value.get('output'))
            records.append(record)
        except (OSError,ValueError,TypeError,AttributeError): skipped+=1
    records.sort(key=lambda r:(r.get('started_at',''),r['capture_id']))
    return {'records':records,'truncated':len(paths)>MAX_RECORDS,'skipped':skipped}


def model_summary(record: dict) -> dict:
    usage=record.get('usage') or {}
    inp=usage.get('prompt_tokens',usage.get('input_tokens')); out=usage.get('completion_tokens',usage.get('output_tokens'))
    total=usage.get('total_tokens')
    if total is None and scalar(inp) and scalar(out):total=inp+out
    http_times=[]
    for attempt in record.get('attempts',[]):
        from .execution_paths import duration
        ms=attempt.get('duration_ms')
        if not scalar(ms): ms=duration(attempt.get('started_at'),attempt.get('ended_at'))
        if ms is not None:http_times.append(ms)
    return {k:record.get(k) for k in ('capture_id','operation','started_at','ended_at','duration_ms','state','outcome','captured','request_bytes','content_omitted','error_type')} | {
        'model':record.get('provider_model'),'prompt_tokens':inp,'completion_tokens':out,'reported_tokens':total,
        'model_ms':sum(http_times) if http_times else None,'prompt_sha256':(record.get('prompt') or {}).get('sha256')}


def operation_detail(config: dict, lifecycle: str, entity_id: str, capture_id: str) -> dict:
    cid=str(uuid.UUID(capture_id));path=_folder(config,lifecycle,entity_id)/(cid+'.json')
    value=_read(path,config,lifecycle,entity_id)
    if value is None:raise KeyError(cid)
    captured=config.get('mode')=='local_full' and isinstance(value.get('wire_request'),dict)
    result=model_summary(value)|{'available':captured,'note':'模型实际调用快照；模型校验通过不等于结果已被 Session 采纳。'}
    if captured:
        wire=value['wire_request'];prompt=prompt_text({'wire_request':wire})
        user=[m.get('content') for m in wire.get('messages',[]) if m.get('role')=='user']
        result.update(system_prompt=prompt,context=user,wire_request=wire,
                      model_response=decode(value.get('response_text'),value.get('response_text')),validated_output=value.get('output'))
        # Compare only static literal text; never import a module to obtain Prompt.
        file=ROOT/'host/floweroll_host/observation_service.py'
        symbol='understand_screen' if value.get('operation')=='observation.vision' else '__call__'
        current=None
        try:
            tree=ast.parse(file.read_text())
            cls=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='ObservationModel')
            fn=next(n for n in cls.body if isinstance(n,ast.FunctionDef) and n.name==symbol)
            assignment=next(n for n in ast.walk(fn) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='system' for t in n.targets))
            current=ast.literal_eval(assignment.value)
        except (OSError,ValueError,SyntaxError,StopIteration): pass
        result['prompt_matches_current']=current==prompt if isinstance(current,str) else None
    return result


def overlap_evidence(records: list[dict]) -> list[dict]:
    """Overlap is calculated only inside one process and parent action, not clocks across devices."""
    valid=[r for r in records if r.get('operation')=='work.unit' and r.get('process_instance') and
           isinstance(r.get('started_monotonic_ns'),int) and isinstance(r.get('ended_monotonic_ns'),int)]
    result=[]
    for i,a in enumerate(valid):
        for b in valid[i+1:]:
            if (a['process_instance'],a.get('parent_action_id')) != (b['process_instance'],b.get('parent_action_id')): continue
            if a.get('work_unit_id') == b.get('work_unit_id'): continue
            overlap=min(a['ended_monotonic_ns'],b['ended_monotonic_ns'])-max(a['started_monotonic_ns'],b['started_monotonic_ns'])
            if overlap>0:
                result.append({'left':a['capture_id'],'right':b['capture_id'],'overlap_ms':round(overlap/1e6,3),
                               'parent_action_id':a.get('parent_action_id'),'evidence':'same_process_monotonic_intervals'})
    return result
