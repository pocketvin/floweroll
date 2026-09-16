"""将现有执行证据投影到系统节点；不补造网络、并行或 iPhone 运行记录。"""
from __future__ import annotations

import sqlite3
from contextlib import closing
from datetime import datetime
from pathlib import Path
from typing import Any

from .projector import decode, decision_context, identity, readonly
from .topology import now, scalar
from .operation_projection import overlap_evidence, model_summary

TERMINAL={'completed','failed','cancelled'}


def duration(start: str | None, end: str | None) -> float | None:
    if not start or not end: return None
    try:
        a=datetime.fromisoformat(start.replace('Z','+00:00'))
        b=datetime.fromisoformat(end.replace('Z','+00:00'))
        if a.tzinfo is None or b.tzinfo is None: return None
        delta=(b-a).total_seconds()*1000
        return round(delta,3) if delta>=0 else None
    except (ValueError,TypeError): return None


def number(value: Any) -> float | int | None:
    return value if scalar(value) and value>=0 else None


def _json_object(value: Any) -> dict:
    result=decode(value,{})
    return result if isinstance(result,dict) else {}


def unit_rows(config: dict, task_id: str) -> dict:
    # Only an explicitly configured secondary DB; never guess a matching filename.
    raw=config.get('work_units_db')
    if not raw: return {'available':False,'units':[],'note':'未配置工作项记录库；不把规划的 units 当作已执行。'}
    path=Path(raw).resolve(); root=Path(__file__).resolve().parents[2]
    if not path.is_relative_to((root/'work').resolve()): raise ValueError('Work Unit DB must be under project work')
    if not path.is_file(): return {'available':False,'units':[],'note':'工作项记录库不可用。'}
    try:
        with closing(readonly(path)) as db:
            rows=[dict(r) for r in db.execute('SELECT * FROM work_units WHERE task_id=? ORDER BY rowid LIMIT 501',(task_id,))]
        return {'available':True,'units':rows[:500],'truncated':len(rows)>500,
                'note':'工作项有真实状态和尝试次数；旧表未记录完整开始/结束时间，不能判定历史并行。'}
    except sqlite3.Error:
        return {'available':False,'units':[],'note':'工作项表不可读。'}


def task_path(snapshot: dict, namespace: str, *, full: bool, units: dict | None = None, operation_records: dict | None = None) -> dict:
    task=snapshot['task']; tid=task['id']; trace_id=identity(namespace,tid)
    spans=[]; links=[]; calls={}; raw_events=snapshot.get('traces',[])
    def add(key,component,label,*,parent=None,start=None,end=None,ms=None,status='unknown',kind='span',
            evidence='recorded',timing='unknown',payload=None,**extra):
        span_id=identity(trace_id,key,16)
        record={'id':key,'trace_id':trace_id,'span_id':span_id,'component_id':component,'name':label,
                'parent_id':parent,'parent_span_id':identity(trace_id,parent,16) if parent else None,
                'started_at':start,'ended_at':end,'duration_ms':number(ms) if ms is not None else duration(start,end),
                'status':status,'kind':kind,'evidence':evidence,'timing_kind':timing,**extra}
        if full and payload is not None: record['payload']=payload
        spans.append(record)
        if parent:
            links.append({'id':'link:'+span_id,'source':parent,'target':key,'relation':'record_link',
                          'label':'记录关联','evidence':'recorded_identity'})
        return record
    end=task.get('finished_at') or task.get('updated_at') if task['status'] in TERMINAL else now()
    add('task','task.runtime','任务生命周期',start=task.get('created_at'),end=end,status=task['status'],
        timing='lifecycle_wall_time',payload={'goal':task.get('goal'),'runtime':snapshot.get('runtime')})
    for event in raw_events:
        d=_json_object(event.get('data_json')); n=d.get('call_number')
        if isinstance(n,int) and not isinstance(n,bool) and n>0:
            group=calls.setdefault(n,{'events':[],'metrics':{},'capture':snapshot.get('captures',{}).get(n,{})})
            group['events'].append((event,d))
            if event['event_type']=='planner.call.metrics': group['metrics'].update(d)
    for n,capture in snapshot.get('captures',{}).items():
        if isinstance(n,int): calls.setdefault(n,{'events':[],'metrics':{},'capture':capture})
    planner=[]; model_times=[]; reported=[]; prompt_tokens=[]; completion_tokens=[]; http_attempt_count=0
    decision_call: dict[str, int] = {}
    current_call: int | None = None
    for event in raw_events:
        data=_json_object(event.get('data_json'))
        if event['event_type']=='planner.call.started' and isinstance(data.get('call_number'),int):
            current_call=data['call_number']
        elif event['event_type']=='planner.decision' and current_call is not None and isinstance(data.get('decision_id'),str):
            decision_call[data['decision_id']]=current_call
    for n,g in sorted(calls.items()):
        capture=g['capture']; m=g['metrics']; events=g['events']
        start=next((e['created_at'] for e,d in events if e['event_type']=='planner.call.started'),capture.get('started_at'))
        closed=[e['created_at'] for e,d in events if e['event_type'] in {'planner.call.committed','planner.call.failed','planner.result.stale','planner.call.superseded'}]
        ended=max(closed) if closed else capture.get('ended_at')
        outcome=('stale' if any('stale' in e['event_type'] or 'superseded' in e['event_type'] for e,d in events)
                 else 'failed' if any(e['event_type']=='planner.call.failed' for e,d in events)
                 else 'committed' if any(e['event_type']=='planner.call.committed' for e,d in events)
                 else 'response_received' if capture.get('response_text') is not None else 'in_flight')
        usage=_json_object(capture.get('usage'))
        total=number(m.get('total_tokens',usage.get('total_tokens')))
        inp=number(m.get('prompt_tokens',usage.get('prompt_tokens',usage.get('input_tokens'))))
        out=number(m.get('completion_tokens',usage.get('completion_tokens',usage.get('output_tokens'))))
        if total is None and inp is not None and out is not None: total=inp+out
        if total is not None: reported.append(total)
        if inp is not None: prompt_tokens.append(inp)
        if out is not None: completion_tokens.append(out)
        model_ms=number(m.get('model_ms'))
        if model_ms is not None:model_times.append(model_ms)
        captured=full and isinstance(capture.get('wire_request'),dict)
        ctx=decision_context(capture) if captured else None
        memories=_json_object((ctx or {}).get('runtime_context')).get('relevant_memories')
        injected=len(memories) if isinstance(memories,list) else (0 if isinstance(ctx,dict) else None)
        retrieved=number(m.get('memory_result_count'))
        model=capture.get('provider_model') or m.get('provider_model') or (capture.get('wire_request') or {}).get('model')
        call={'call_number':n,'outcome':outcome,'started_at':start,'ended_at':ended,'model':model,
              'duration_ms':duration(start,ended),'model_ms':model_ms,'reported_tokens':total,
              'prompt_tokens':inp,'completion_tokens':out,'captured':captured,
              'request_bytes':number(capture.get('request_bytes')),'retrieved_memories':retrieved,
              'injected_memories':injected,'prompt_sha256':(capture.get('prompt') or {}).get('sha256'),
              'graph_steps':m.get('graph_steps',[])}
        planner.append(call)
        key=f'planner:{n}'
        add(key,'planner.graph',f'Planner #{n}',parent='task',start=start,end=ended,status=outcome,
            timing='planner_invocation',call_number=n,payload={'metrics':m,'capture_available':captured})
        # Pair actual started/finished node events. Same node may run multiple times.
        pending={}; seen_steps=set()
        for event,d in events:
            if event['event_type']!='planner.graph.node' or not isinstance(d.get('node'),str):continue
            name=d['node']; phase=d.get('phase'); seen_steps.add(name)
            if phase=='started':pending.setdefault(name,[]).append(event)
            elif phase=='finished':
                starters=pending.get(name,[]); beginning=starters.pop(0) if starters else None
                add(f'graph:{event["id"]}','planner.step:'+name,name,parent=key,
                    start=beginning['created_at'] if beginning else None,end=event['created_at'],
                    ms=d.get('duration_ms'),status=d.get('outcome','unknown'),timing='measured_node',call_number=n,
                    payload={'finished_event':d,'start_event_id':beginning['id'] if beginning else None})
        for name,starters in pending.items():
            for e in starters:add(f'graph-start:{e["id"]}','planner.step:'+name,name,parent=key,start=e['created_at'],status='in_flight',timing='open_node',call_number=n)
        for i,step in enumerate(m.get('graph_steps') or []):
            if not isinstance(step,dict) or step.get('node') in seen_steps:continue
            name=step.get('node')
            if isinstance(name,str):add(f'graph-metric:{n}:{i}','planner.step:'+name,name,parent=key,ms=step.get('duration_ms'),status=step.get('outcome','unknown'),timing='duration_only',call_number=n,payload=step)
        # A capture is an actual provider-bound request. It is not the pre-adapter schema.
        for i,a in enumerate(capture.get('attempts') or []):
            http_attempt_count+=1
            add(f'provider:{n}:{i}','model.provider',f'模型 HTTP #{a.get("index",i+1)}',parent=key,
                start=a.get('started_at'),end=a.get('ended_at'),status=a.get('state','unknown'),timing='http_attempt',call_number=n,payload=a)
    actions=snapshot.get('actions',[]); attempts=snapshot.get('attempts',[])
    for action in actions:
        cap=action['action_type']; aid=action['id']
        planner_number=decision_call.get(action.get('planner_decision_id'))
        action_parent='planner:'+str(planner_number) if planner_number is not None else 'task'
        add('action:'+aid,'work.execute' if cap=='work.execute' else 'capability:'+cap,cap,parent=action_parent,
            start=action.get('created_at'),end=action.get('updated_at'),status=action['status'],timing='action_record_span',
            action_id=aid,planned=True,payload={'input':decode(action.get('payload_json')),'output':decode(action.get('result_json')),
            'expected':decode(action.get('expected_json')),'failure_code':action.get('failure_code'),'error':action.get('error_text'),
            'source_target':decode(action.get('source_target_json')),'planner_decision_id':action.get('planner_decision_id')})
    action_ids={a['id'] for a in actions}
    native=0
    for attempt in attempts:
        aid=attempt['action_id']; source=attempt.get('source_kind'); native+=int(source=='ios')
        add('attempt:'+attempt['id'],'execution.runtime',f'执行尝试 #{attempt["attempt_number"]} · {source or "未知来源"}',
            parent='action:'+aid if aid in action_ids else 'task',start=attempt.get('started_at'),end=attempt.get('finished_at'),
            status=attempt.get('latest_outcome') or attempt.get('status','unknown'),timing='attempt_execution',
            action_id=aid,source_kind=source,payload={'attempt_id':attempt['id'],'output':decode(attempt.get('result_json')),
            'dispatch':decode(attempt.get('dispatch_snapshot_json')),'source_request_ref':attempt.get('source_request_ref'),
            'error':attempt.get('error_text')})
    important={'action.result.received','action.verified','observation.verified','action.verification.metrics','action.dispatched',
               'planner.retry_wait','planner.retry_resumed','task.blocked','task.cancel_requested','task.cancelled_by_planner','task.created',
               'task.completed','task.cancelled','inbox.accepted','clarification.requested','action_input.requested','action_input.answered'}
    for event in raw_events:
        if event['event_type'] not in important:continue
        d=_json_object(event['data_json']); aid=d.get('action_id'); parent='action:'+aid if aid in action_ids else 'task'
        add('event:'+str(event['id']),'task.state',event['event_type'],parent=parent,start=event['created_at'],end=event['created_at'],
            status='recorded',kind='event',timing='event_instant',payload=d,event_type=event['event_type'])
    units=units or {'available':False,'units':[]}
    for unit in units['units']:
        definition=_json_object(unit.get('definition_json')); aid=unit.get('parent_action_id')
        key='unit:'+unit['unit_id']
        add(key,'capability:'+str(definition.get('capability','unknown')),str(definition.get('capability',unit['unit_id'])),
            parent='action:'+aid if aid in action_ids else 'task',status=unit['state'],kind='work_unit',timing='not_recorded',
            work_unit_id=unit['unit_id'],attempt_count=unit.get('attempts'),depends_on=definition.get('depends_on',[]),
            payload={'input':definition,'output':decode(unit.get('output_json')),'error':unit.get('error'),
                     'receipt_id':unit.get('receipt_id'),'last_record_update':unit.get('updated_at')})
    operation_records = operation_records or {'records':[], 'truncated':False, 'skipped':0}
    timed_units = [r for r in operation_records['records'] if r.get('operation') == 'work.unit']
    unit_ids = {u['unit_id'] for u in units['units']}
    for record in timed_units:
        uid = record.get('work_unit_id'); aid = record.get('parent_action_id')
        parent = 'unit:'+uid if uid in unit_ids else 'action:'+aid if aid in action_ids else 'task'
        add('unit-attempt:'+record['capture_id'], 'capability:'+str(record.get('capability','unknown')),
            '工作项执行 · '+str(uid), parent=parent,
            start=record.get('started_at'), end=record.get('ended_at'), ms=record.get('duration_ms'),
            status=record.get('outcome') or record.get('state','unknown'), kind='work_unit_attempt',
            timing='measured_unit_attempt', work_unit_id=uid, capture_id=record['capture_id'],
            payload={'input':record.get('input'), 'output':record.get('output'),
                     'accepted':record.get('accepted'), 'error_type':record.get('error_type')})
    overlaps = overlap_evidence(timed_units)
    visible_ids={s['id'] for s in spans}
    for unit in units['units']:
        definition=_json_object(unit.get('definition_json'))
        for parent in definition.get('depends_on',[]):
            if 'unit:'+parent in visible_ids: links.append({'id':'dependency:'+parent+':'+unit['unit_id'],
                'source':'unit:'+parent,'target':'unit:'+unit['unit_id'],'relation':'dependency','label':'依赖','evidence':'recorded_definition'})
    by_component={}
    for s in spans:
        item=by_component.setdefault(s['component_id'],{'records':0,'errors':0,'duration_samples':[]})
        item['records']+=1;item['errors']+=int(s['status'] in {'failed','error','FAILURE'})
        if s['duration_ms'] is not None:item['duration_samples'].append(s['duration_ms'])
    def sum_known(values):return sum(values) if values else (0 if not calls else None)
    summary={'task_status':task['status'],'runtime_phase':snapshot.get('runtime',{}).get('phase'),
        'elapsed_ms':duration(task.get('created_at'),end),'planner_calls':len(calls),'actions':len(actions),
        'tool_attempts':len(attempts),'work_units':len(units['units']) if units['available'] else None,
        'reported_tokens_only':sum_known(reported),'reported_usage_calls':len(reported),'calls_without_reported_usage':len(calls)-len(reported),
        'prompt_tokens':sum_known(prompt_tokens),'completion_tokens':sum_known(completion_tokens),
        'model_ms_sum':sum_known(model_times),'model_timed_calls':len(model_times),
        'retry_count':sum(1 for e in raw_events if e['event_type']=='planner.retry_wait')+sum(a.get('attempt_number',1)>1 for a in attempts)+sum(max(0,len(c.get('attempts',[]))-1) for c in snapshot.get('captures',{}).values()),
        'timed_work_unit_attempts':len(timed_units),'parallel_overlaps':len(overlaps),
        'native_attempts':native,'full_captured_calls':sum(p['captured'] for p in planner),'cost':None}
    limitations=['图中关联来自记录 ID，不把按时间排列误当作函数调用。',
                  'Action 跨度包含排队/等待；仅 attempt/node 的计时可用于执行时长。',
                  'iPhone 实际接收、界面合并与灵动岛显示尚未被端到端采集。',
                  '历史模型请求没有采集就不可重建；当前源码不是历史执行版本。']
    if not units['available'] or units['units']:limitations.append(units.get('note','工作项缺少完整计时，历史并行未知。'))
    return {'schema_version':1,'kind':'task','id':tid,'trace_id':trace_id,
            'goal':task.get('goal') if full else 'Task '+tid[:8],'spans':spans[:1500],
            'edges':[e for e in links if e['source'] in {s['id'] for s in spans[:1500]} and e['target'] in {s['id'] for s in spans[:1500]}],
            'components':by_component,'planner_calls':planner,'summary':summary,'parallel_evidence':overlaps,
            'truncated':operation_records.get('truncated',False) or len(spans)>1500 or len(raw_events)>=10000 or len(actions)>=500 or len(attempts)>=1000,
            'coverage':{'source':'runtime_db_and_capture','ios':'not_instrumented','http':'provider_capture_only',
                        'work_units':units['available'],'work_unit_timing':'captured_attempts_only' if timed_units else 'unavailable',
                        'operation_records_skipped':operation_records.get('skipped',0)},
            'limitations':limitations,'checked_at':now()}


def observation_path(detail: dict, namespace: str, *, operation_records: dict | None = None) -> dict:
    session=detail['session']; sid=session['id']; trace=identity(namespace,'observation:'+sid)
    spans=[];edges=[]
    def add(key,component,label,payload,status='recorded',at=None,parent='session'):
        spans.append({'id':key,'span_id':identity(trace,key,16),'trace_id':trace,'parent_id':parent,
            'parent_span_id':identity(trace,parent,16) if parent else None,'component_id':component,
            'name':label,'status':status,'started_at':at,'ended_at':None,'duration_ms':None,
            'timing_kind':'durable_record_not_model_span','evidence':'durable_record','kind':'observation_record','payload':payload})
        if parent:edges.append({'id':'observation-link:'+key,'source':parent,'target':key,'relation':'record_link','label':'记录关联','evidence':'recorded_identity'})
    add('session','observation.service','观察会话',session,session['status'],session.get('created_at'),None)
    for source,stats in detail['stats']['source_stats'].items():
        if stats['events']:
            add('source:'+source,'observation.capture',{'screen':'屏幕','ambientMicrophone':'周围声音','deviceAudio':'手机音频'}.get(source,source),stats)
    for e in detail.get('timeline',[]):
        add('evidence:'+str(e['id']),'observation.store',f'{e["kind"]} · {e["source"]}',e,at=e.get('captured_at'))
        if e.get('has_screen_understanding'):
            add('vision:'+str(e['id']),'observation.vision','屏幕理解结果',e.get('screen_understanding'),'result_recorded',parent='evidence:'+str(e['id']))
    for note in detail.get('notes',[]):
        add('note:'+note['id'],'observation.summary','最终整理' if note['kind']=='final' else '阶段整理',note,'result_recorded',note.get('created_at'))
    for question in detail.get('questions',[]):
        add('question:'+question['id'],'observation.question','观察问答',question,question['status'])
    operation_records=operation_records or {'records':[], 'truncated':False, 'skipped':0}
    captures=[r for r in operation_records['records'] if str(r.get('operation','')).startswith('observation.')]
    model_calls=[model_summary(record) for record in captures]
    labels={'observation.vision':'视觉模型','observation.summary':'阶段整理模型',
            'observation.final':'最终整理模型','observation.question':'观察问答模型'}
    for record in captures:
        op=record['operation']; component='observation.summary' if op=='observation.final' else op
        key='model-call:'+record['capture_id']
        add(key,component,labels.get(op,op),{'capture_id':record['capture_id'],'operation':op,
            'error_type':record.get('error_type'),'model':record.get('provider_model')},
            record.get('outcome') or record.get('state','unknown'),record.get('started_at'))
        spans[-1].update(kind='model_call',timing_kind='measured_model_operation',
                         ended_at=record.get('ended_at'),duration_ms=record.get('duration_ms'),
                         capture_id=record['capture_id'])
    counts={}
    for s in spans:counts.setdefault(s['component_id'],{'records':0,'errors':0})['records']+=1
    summary={'task_status':session['status'],'elapsed_ms':duration(session.get('created_at'),session.get('updated_at')),
             'event_count':detail['stats']['event_count'],'checkpoint_count':detail['stats']['checkpoint_count'],
             'final_count':detail['stats']['final_count'],'question_count':detail['stats']['question_count'],
             'reported_tokens_only':sum(c['reported_tokens'] for c in model_calls if scalar(c['reported_tokens'])) if any(scalar(c['reported_tokens']) for c in model_calls) else None,
             'model_ms_sum':sum(c['model_ms'] for c in model_calls if scalar(c['model_ms'])) if any(scalar(c['model_ms']) for c in model_calls) else None,
             'captured_model_calls':len(model_calls),'reported_usage_calls':sum(scalar(c['reported_tokens']) for c in model_calls),
             'planner_calls':None,'runtime_phase':session['status']}
    return {'schema_version':1,'kind':'observation','id':sid,'trace_id':trace,'goal':session['preset_label'],
            'spans':spans,'edges':edges,'components':counts,'planner_calls':[],'model_calls':model_calls,'summary':summary,'detail':detail,
            'coverage':{'source':'observation_sqlite','ios':'not_instrumented','model_request':'captured_calls_only' if model_calls else 'not_captured',
                        'operation_records_skipped':operation_records.get('skipped',0)},
            'truncated':operation_records.get('truncated',False) or detail['stats']['event_count']>len(detail['timeline']),
            'limitations':['此图是观察持久记录投影，不是每一次模型调用的完整 Trace。',
                '模型统计只包含已采集调用；没有旧请求时不能反推历史 Prompt、Token 或耗时。',
                '采集来源可从事件确认；本地 Journal、上传与 ACK 的完整传输未采集。',
                '这里只显示最近 180 条事件，来源总计覆盖该会话全部记录。'], 'checked_at':now()}
