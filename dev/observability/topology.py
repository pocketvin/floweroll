"""只读架构索引。解析源码，不 import/启动 Host，也不把源码等同于已部署进程。

稳定组件与运行实例分开；自动发现的 route/spec/graph 声明只是 source evidence。
统计限定在显式的最近任务窗口，未知值不会填成零。
"""
from __future__ import annotations

import ast
import hashlib
import re
import sqlite3
import threading
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .projector import decode, readonly

ROOT = Path(__file__).resolve().parents[2]
HOST = 'host/floweroll_host/'
IOS = 'ios/Floweroll/App/'
SCHEMA_VERSION = 1
RECENT_LIMIT = 60

# 只人工声明稳定的产品边界；route、capability 和 Planner 内部节点由源码发现。
CORE = [
 ('ios.entry','任务入口','task','ios',IOS+'Home/HomeView.swift','HomeView',None),
 ('transport.http','HTTP 接口','shared','transport',HOST+'http_app.py','create_http_app',None),
 ('task.runtime','任务运行时','task','runtime',HOST+'task_runtime.py','TaskRuntime',None),
 ('task.transition','下一步判定','task','runtime',HOST+'transition_engine.py','TransitionEngine','task.runtime'),
 ('planner.graph','Planner 决策','task','planner',HOST+'planner_graph.py','PlannerGraph',None),
 ('planner.context','上下文构造','task','planner',HOST+'context_builder.py','ContextBuilder','planner.graph'),
 ('planner.request','模型请求构造','task','planner',HOST+'planner_request.py','PlannerRequestBuilder','planner.graph'),
 ('execution.runtime','Action 执行','task','execution',HOST+'execution_runtime.py','ExecutionRuntime',None),
 ('capability.registry','能力目录','task','capability',HOST+'capability_registry.py','CapabilityRegistry',None),
 ('work.execute','批量工作项','task','execution',HOST+'work_units.py','WorkUnitRunner',None),
 ('task.materials','附件与成果','task','materials',HOST+'task_assets.py','TaskAssetStore','execution.runtime'),
 ('task.state','持久状态 / 核验','task','storage',HOST+'storage.py','Storage',None),
 ('ios.native','原生能力执行','task','ios',IOS+'RuntimeClient/DeviceExecutionCoordinator.swift','DeviceExecutionCoordinator','execution.runtime'),
 ('ios.presentation','客户端状态投影','task','ios',IOS+'RuntimeClient/RuntimeTaskStore.swift','RuntimeTaskStore',None),
 ('ios.sse','状态接收','task','transport',IOS+'RuntimeClient/HostTaskLiveSession.swift','HostTaskLiveSession','ios.presentation'),
 ('ios.activity','系统执行 / 灵动岛','task','ios',IOS+'FlowerollActivitySession.swift','FlowerollActivitySession','ios.presentation'),
 ('observation.capture','屏幕与声音采集','observation','ios',IOS+'Observation/ObservationCapture.swift','ObservationCaptureEngine',None),
 ('observation.sync','本地记录 / 同步','observation','transport',IOS+'Observation/ObservationController.swift','ObservationController',None),
 ('observation.service','观察会话','observation','runtime',HOST+'observation_service.py','ObservationService',None),
 ('observation.vision','屏幕视觉理解','observation','model',HOST+'observation_service.py','understand_screen','observation.service'),
 ('observation.summary','分段 / 最终整理','observation','model',HOST+'observation_service.py','_summarize','observation.service'),
 ('observation.question','基于记录问答','observation','model',HOST+'observation_service.py','_answer','observation.service'),
 ('observation.store','观察记录与纪要','observation','storage',HOST+'observation_service.py','ObservationService',None),
 ('model.provider','模型供应商','shared','model',HOST+'openai_compatible_chat_adapter.py','OpenAICompatibleChatPlannerAdapter',None),
]
CORE_EDGES = [
 ('ios.entry','transport.http','提交'), ('transport.http','task.runtime','任务接口'),
 ('task.runtime','planner.graph','需要语义决策时'), ('task.runtime','execution.runtime','提交 Action'),
 ('execution.runtime','capability.registry','能力分发'), ('capability.registry','work.execute','批量能力'),
 ('execution.runtime','task.state','核验 / 持久化'), ('task.state','ios.presentation','状态同步'),
 ('planner.graph','model.provider','模型请求'), ('observation.capture','observation.sync','证据记录'),
 ('observation.sync','transport.http','事件上传 / 对账'), ('transport.http','observation.service','观察接口'),
 ('observation.service','observation.store','保存证据 / 纪要'), ('observation.service','model.provider','视觉 / 整理 / 问答'),
]


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def scalar(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def source_reference(root: Path, relative: str, symbol: str, line: int | None = None) -> dict:
    path = root / relative
    result = {'file': relative, 'symbol': symbol, 'line': line, 'available': False,
              'basis': 'current_source', 'sha256': None}
    if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        return result
    text = path.read_text(encoding='utf-8')
    result.update(available=True, sha256=hashlib.sha256(text.encode()).hexdigest())
    if line is None:
        pattern = r'\b(?:class|struct|enum|func|def)\s+' + re.escape(symbol.split('.')[-1]) + r'\b'
        result['line'] = next((i for i, row in enumerate(text.splitlines(), 1) if re.search(pattern, row)), None)
    return result


def make_node(id: str, name: str, owner: str, kind: str, *, parent: str | None = None,
              source: dict | None = None, **extra: Any) -> dict:
    return dict(id=id, name=name, lifecycle_owner=owner, kind=kind, parent_id=parent,
                source=source, evidence='source_defined', stats=None, **extra)


def make_edge(source: str, target: str, label: str, *, relation: str = 'declared_flow', **extra: Any) -> dict:
    key = hashlib.sha256(f'{source}|{target}|{relation}|{label}'.encode()).hexdigest()[:16]
    return dict(id='edge:'+key, source=source, target=target, label=label, relation=relation,
                evidence='source_defined', **extra)


def _literal(node: ast.AST | None, names: dict) -> Any:
    if isinstance(node, ast.Constant): return node.value
    if isinstance(node, ast.Name): return names.get(node.id)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        a, b = _literal(node.left, names), _literal(node.right, names)
        if isinstance(a, str) and isinstance(b, str): return a + b
    if isinstance(node, (ast.List, ast.Tuple)):
        return [_literal(v, names) for v in node.elts]
    if isinstance(node, ast.Dict):
        return {_literal(k, names): _literal(v, names) for k, v in zip(node.keys, node.values) if k is not None}
    return None


def _constants(tree: ast.AST) -> dict:
    names = {'START':'__start__', 'END':'__end__'}
    for stmt in ast.walk(tree):
        if isinstance(stmt, ast.Assign):
            val = _literal(stmt.value, names)
            if isinstance(val, (str, int, float, bool)):
                for target in stmt.targets:
                    if isinstance(target, ast.Name): names[target.id] = val
    return names


def discover(root: Path = ROOT) -> dict:
    nodes, edges, diagnostics = {}, [], []
    fingerprints = []
    for id, label, owner, kind, file, symbol, parent in CORE:
        nodes[id] = make_node(id, label, owner, kind, parent=parent,
                             source=source_reference(root, file, symbol))
    edges.extend(make_edge(a, b, label) for a, b, label in CORE_EDGES)
    for path in sorted((root / HOST).glob('*.py')):
        if path.is_symlink(): continue
        relative = str(path.relative_to(root))
        text = path.read_text(encoding='utf-8')
        fingerprints.append(relative + ':' + hashlib.sha256(text.encode()).hexdigest())
        try: tree = ast.parse(text)
        except SyntaxError:
            diagnostics.append({'kind':'source_parse_failed','file':relative}); continue
        names = _constants(tree)
        # FastAPI declaration metadata: no Host construction, no startup hooks.
        if path.name.startswith('http_'):
            for function in ast.walk(tree):
                if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)): continue
                for decorator in function.decorator_list:
                    if not isinstance(decorator, ast.Call) or not isinstance(decorator.func, ast.Attribute): continue
                    method = decorator.func.attr.upper()
                    route = _literal(decorator.args[0], names) if decorator.args else None
                    if method not in {'GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS'} or not isinstance(route, str): continue
                    id = 'http:'+method+':'+route
                    owner = 'observation' if route.startswith('/v1/observations') else ('shared' if '/developer/' in route or route=='/health' else 'task')
                    response = next((ast.unparse(k.value) for k in decorator.keywords if k.arg=='response_model'), None)
                    params = {arg.arg:ast.unparse(arg.annotation) for arg in function.args.args if arg.annotation is not None and arg.arg!='request'}
                    nodes[id] = make_node(id, method+' '+route, owner, 'http', parent='transport.http',
                        source=source_reference(root,relative,function.name,function.lineno),
                        method=method, route=route, input_schema=params, output_schema=response,
                        loaded_in_running_host='unknown')
        # Capability definitions, not a claim of live registry readiness.
        for call in ast.walk(tree):
            if not isinstance(call, ast.Call): continue
            function_name = ast.unparse(call.func).split('.')[-1]
            if function_name != 'CapabilitySpec': continue
            kw = {k.arg:k.value for k in call.keywords}
            name = _literal(kw.get('name') or (call.args[0] if call.args else None), names)
            if not isinstance(name,str) or not name.strip(): continue
            id = 'capability:'+name
            if id in nodes: continue
            schema = _literal(kw.get('arguments_schema'), names)
            description = _literal(kw.get('description'), names)
            nodes[id] = make_node(id, name, 'task', 'capability', parent='capability.registry',
                source=source_reference(root,relative,'CapabilitySpec',call.lineno),
                input_schema=schema, description=description, readiness='unknown')
        if path.name=='planner_graph.py':
            for assignment in ast.walk(tree):
                if isinstance(assignment, ast.Assign) and any(isinstance(t,ast.Name) and t.id=='nodes' for t in assignment.targets) and isinstance(assignment.value,ast.Dict):
                    for key,val in zip(assignment.value.keys,assignment.value.values):
                        name=_literal(key,names)
                        if isinstance(name,str):
                            symbol=ast.unparse(val).replace('self.','PlannerGraph.')
                            nodes['planner.step:'+name]=make_node('planner.step:'+name,name,'task','graph_step',parent='planner.graph',source=source_reference(root,relative,symbol))
            for call in ast.walk(tree):
                if not isinstance(call,ast.Call) or not isinstance(call.func,ast.Attribute): continue
                method=call.func.attr
                if method=='add_node' and len(call.args)>=2:
                    name=_literal(call.args[0],names)
                    if isinstance(name,str): nodes['planner.step:'+name]=make_node('planner.step:'+name,name,'task','graph_step',parent='planner.graph',source=source_reference(root,relative,ast.unparse(call.args[1]),call.lineno))
                pairs=[]
                if method=='add_edge' and len(call.args)>=2:
                    pairs=[(_literal(call.args[0],names),_literal(call.args[1],names),'流程')]
                elif method=='add_conditional_edges' and len(call.args)>=3:
                    mapping=_literal(call.args[2],names)
                    if isinstance(mapping,dict): pairs=[(_literal(call.args[0],names),target,str(label)) for label,target in mapping.items()]
                for a,b,label in pairs:
                    if 'planner.step:'+str(a) in nodes and 'planner.step:'+str(b) in nodes:
                        edges.append(make_edge('planner.step:'+a,'planner.step:'+b,label))
    for node in nodes.values():
        if node['parent_id']:
            edges.append(make_edge(node['parent_id'],node['id'],'包含',relation='contains'))
    return {'schema_version':SCHEMA_VERSION,'nodes':list(nodes.values()),'edges':edges,
            'source_fingerprint':hashlib.sha256('\n'.join(fingerprints).encode()).hexdigest(),
            'source_basis':'current_checkout_not_running_process','diagnostics':diagnostics,
            'limitations':['源码定义不证明当前 Host 已加载或实际运行。','虚线是声明关系，不是本次任务的实测调用。','未埋点的 iOS/网络段不能由 Host 记录补造。'], 'checked_at':now()}


_cache: dict = {}
_cache_lock=threading.Lock()


def source_topology() -> dict:
    # Bound discovery work; caller receives a new tree and cannot mutate cache.
    import copy
    with _cache_lock:
        if time.monotonic()-_cache.get('at',0)>5 or not _cache:
            _cache.update(at=time.monotonic(),data=discover())
        return copy.deepcopy(_cache['data'])


def runtime_stats(graph: dict, db_path: Path) -> dict:
    index={n['id']:n for n in graph['nodes']}
    stats: dict[str,dict] = {}
    def mark(id: str, task: str, calls: int = 1, *, status: str | None = None, at: str | None = None):
        stat=stats.setdefault(id,{'calls':0,'task_ids':set(),'errors':0,'last_seen':None})
        stat['calls']+=calls; stat['task_ids'].add(task)
        stat['errors']+=int(status in {'failed','error'})
        if at and (stat['last_seen'] is None or at>stat['last_seen']): stat['last_seen']=at
    try:
        with closing(readonly(db_path)) as c:
            c.execute('BEGIN')
            tasks=[dict(r) for r in c.execute('SELECT id,status,updated_at FROM tasks ORDER BY updated_at DESC LIMIT ?', (RECENT_LIMIT,))]
            ids=[t['id'] for t in tasks]
            if not ids:
                graph['scope']={'kind':'recent_tasks','limit':RECENT_LIMIT,'task_count':0};return graph
            placeholders=','.join('?' for _ in ids)
            actions=[dict(r) for r in c.execute(f'SELECT id,task_id,action_type,status FROM actions WHERE task_id IN ({placeholders})',ids)]
            action_map={a['id']:a for a in actions}
            attempts=[dict(r) for r in c.execute(f'SELECT aa.id,aa.action_id,aa.started_at,aa.status FROM action_attempts aa JOIN actions a ON a.id=aa.action_id WHERE a.task_id IN ({placeholders})',ids)]
            events=[dict(r) for r in c.execute(f"SELECT id,task_id,event_type,data_json,created_at FROM traces WHERE task_id IN ({placeholders}) AND event_type IN ('planner.call.started','planner.graph.node') ORDER BY id DESC LIMIT 30001",ids)]
        for task in tasks: mark('task.runtime',task['id'],status=task['status'],at=task['updated_at'])
        seen_calls=set()
        for e in events[:30000]:
            d=decode(e['data_json'],{})
            if not isinstance(d,dict): continue
            if e['event_type']=='planner.call.started':
                key=(e['task_id'],d.get('call_number'))
                if key not in seen_calls: mark('planner.graph',e['task_id'],at=e['created_at']);seen_calls.add(key)
            elif d.get('phase')=='started' and isinstance(d.get('node'),str):
                mark('planner.step:'+d['node'],e['task_id'],at=e['created_at'])
        for attempt in attempts:
            a=action_map[attempt['action_id']]
            mark('execution.runtime',a['task_id'],status=attempt['status'],at=attempt['started_at'])
            mark('capability:'+a['action_type'],a['task_id'],status=attempt['status'],at=attempt['started_at'])
            if a['action_type']=='work.execute': mark('work.execute',a['task_id'],status=attempt['status'],at=attempt['started_at'])
        for id,stat in stats.items():
            if id not in index:
                parent='capability.registry' if id.startswith('capability:') else 'planner.graph'
                node=make_node(id,id.split(':',1)[-1],'task','unmapped',parent=parent)
                node['evidence']='unmapped_runtime'; graph['nodes'].append(node);index[id]=node
                graph['edges'].append(make_edge(parent,id,'已记录，源码未映射',relation='contains'))
            index[id]['stats']={k:v for k,v in stat.items() if k!='task_ids'}|{'task_count':len(stat['task_ids'])}
            index[id]['evidence']='observed' if index[id]['source'] else 'unmapped_runtime'
        graph['scope']={'kind':'recent_tasks','limit':RECENT_LIMIT,'task_count':len(ids),'event_limit_reached':len(events)>30000,
                        'note':'调用数来自本窗口的 Planner started / Action attempt started；无采集的组件为未知，不是零。'}
    except (OSError,sqlite3.Error):
        graph['scope']={'kind':'unavailable','note':'Runtime 数据库暂不可读；系统图仍显示源码。'}
    return graph


def component_details(component_id: str) -> dict:
    graph=source_topology()
    node=next((n for n in graph['nodes'] if n['id']==component_id),None)
    if node is None: raise KeyError(component_id)
    source=node.get('source')
    if source and source['available'] and source['line']:
        path=ROOT/source['file']
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()): raise ValueError('Invalid source')
        lines=path.read_text().splitlines(); start=max(1,source['line']-2); end=min(len(lines),start+65)
        node['source_excerpt']={'start_line':start,'end_line':end,'text':'\n'.join(lines[start-1:end]),'basis':'current_source_not_historical'}
    node['incoming']=[e for e in graph['edges'] if e['target']==component_id]
    node['outgoing']=[e for e in graph['edges'] if e['source']==component_id]
    return node
