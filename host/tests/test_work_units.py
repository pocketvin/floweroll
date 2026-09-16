from __future__ import annotations

import json
import tempfile
import threading
import subprocess
import sys
import unittest
import uuid
from pathlib import Path

from floweroll_host.amap_webservice import register_amap_webservice_capabilities
from floweroll_host.capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from floweroll_host.function_execution_worker import TaskScopedFunction
from floweroll_host.mcp_adapter import MCPReadToolAdapter
from floweroll_host.mcp_driver import MCPFinalResult
from floweroll_host.planner_contracts import CapabilitySpec
from floweroll_host.public_http_tools import register_public_http_capabilities
from floweroll_host.server import create_server
from floweroll_host.work_units import WorkUnitStore


class WorkUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        registry = CapabilityRegistry()
        functions, _ = register_public_http_capabilities(registry)
        functions['web.fetch'] = lambda a: {'url': a['url'], 'status': 200, 'text': 'Fixture source'}
        self.server = create_server('127.0.0.1', 0, str(self.root/'tasks.sqlite3'),
            capability_registry=registry, function_executors=functions, task_asset_root=self.root/'assets')
        self.app = self.server.app
        self.app.supervisor.stop()
        self.store = self.app.storage
        self.assets = self.app.task_assets
        self.runner = self.app.function_executors['work.execute'].invoke.__self__
        self.task = self.store.create_task(task_id=uuid.uuid4().hex, goal='Prepare interview materials',
            invocation_source='test', policy_snapshot={}, status='active')['task_id']
        self.step = 0
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.server.server_close)

    def unit(self, uid, deps=None, cap='web.fetch', arguments=None):
        return {'id': uid, 'title': uid, 'depends_on': deps or [], 'capability': cap,
                'arguments_json': json.dumps(arguments or {'url': 'https://example.com/'+uid})}

    def report(self, uid, deps=None):
        return self.unit(uid, deps, 'deliverables.publish', {'title': uid, 'markdown': '测试准备资料',
            'category': 'study', 'status': 'ready', 'item_id': uid})

    def create_action(self, units, retry=False):
        self.step += 1
        aid = uuid.uuid4().hex
        self.store.create_action(action_id=aid, task_id=self.task, step_index=self.step,
            action_type='work.execute', payload={'units': units, 'retry_failed': retry}, expected={},
            idempotency_key=aid, on_verified='REPLAN')
        return aid

    def run_batch(self, units, retry=False):
        aid = self.create_action(units, retry)
        self.app.function_worker.run_once(self.task)
        return self.store.action_attempts(aid)[0]

    def test_independent_work_overlaps_and_dependencies_wait_for_verified_receipts(self):
        barrier = threading.Barrier(2, timeout=4)
        seen = set()
        lock = threading.Lock()
        def fetch(args):
            key = args['url'].rsplit('/', 1)[1]
            if key in {'a', 'b'}:
                barrier.wait()
            else:
                with lock:
                    self.assertEqual(seen, {'a', 'b'})
                evidence = self.assets.work_units.evidence(self.task)
                self.assertEqual({r['work_unit_id'] for r in evidence}, {'a', 'b'})
            with lock:
                seen.add(key)
            return {'url': args['url'], 'status': 200, 'text': key}
        self.runner.executors['web.fetch'] = fetch
        result = self.run_batch([self.unit('c', ['a','b']), self.unit('a'), self.unit('b')])
        self.assertEqual(result['latest_outcome'], 'SUCCESS')
        self.assertEqual(seen, {'a','b','c'})
        self.assertTrue(all(r['state'] == 'completed' for r in self.assets.work_units.rows(self.task)))

    def test_failure_isolated_transitive_blocking_and_restart_reuses_completed_files(self):
        calls = []
        def fail(args):
            calls.append(args['url'])
            raise TimeoutError('fixture offline')
        self.runner.executors['web.fetch'] = fail
        units = [self.unit('grandchild', ['child']), self.unit('child', ['source']),
                 self.unit('source'), self.report('study')]
        self.run_batch(units)
        states = {r['id']: r['state'] for r in self.assets.work_units.summary(self.task)}
        self.assertEqual(states, {'grandchild':'blocked', 'child':'blocked', 'source':'failed', 'study':'completed'})
        output = self.assets.manifest(self.task)['outputs'][0]
        data = self.assets.file_path(self.task, output['id']).read_bytes()
        self.assets.work_units = WorkUnitStore(Path(self.assets.work_units.path))
        self.runner.store = self.assets.work_units
        self.runner.executors['web.fetch'] = lambda a: {'status': 200, 'url': a['url'], 'text': 'recovered'}
        self.run_batch(units, retry=True)
        rows = {r['unit_id']: r for r in self.assets.work_units.rows(self.task)}
        self.assertEqual(rows['study']['attempts'], 1)
        self.assertEqual(rows['source']['attempts'], 2)
        self.assertTrue(all(r['state'] == 'completed' for r in rows.values()))
        self.assertEqual(self.assets.file_path(self.task, output['id']).read_bytes(), data)
        self.assertEqual(len(self.assets.manifest(self.task)['outputs']), 1)

    def test_files_become_available_before_slow_sibling_finishes_and_remain_task_scoped(self):
        entered, release = threading.Event(), threading.Event()
        def slow(args):
            entered.set()
            release.wait(5)
            return {'url': args['url'], 'status': 200}
        self.runner.executors['web.fetch'] = slow
        published = threading.Event()
        original_finish = self.runner.store.finish
        def finish(*args, **kwargs):
            result = original_finish(*args, **kwargs)
            if args[1] == 'study':
                published.set()
            return result
        self.runner.store.finish = finish
        self.create_action([self.unit('slow'), self.report('study')])
        thread = threading.Thread(target=self.app.function_worker.run_once, args=(self.task,))
        thread.start()
        try:
            self.assertTrue(entered.wait(4))
            self.assertTrue(published.wait(4))
            outputs = self.assets.manifest(self.task)['outputs']
            self.assertEqual(len(outputs), 1)
            self.assertTrue(self.assets.file_path(self.task, outputs[0]['id']).is_file())
            other = self.store.create_task(task_id=uuid.uuid4().hex, goal='Other', invocation_source='test',
                policy_snapshot={}, status='active')['task_id']
            with self.assertRaises(KeyError):
                self.assets.file_path(other, outputs[0]['id'])
        finally:
            release.set()
            thread.join(5)
        self.assertFalse(thread.is_alive())

    def test_no_receipt_for_corrupt_generated_file_even_when_tool_says_verified(self):
        original = self.runner.executors['deliverables.publish']
        def corrupt(dispatch, args):
            result = original.invoke(dispatch, args)
            fid = result['files'][0]['id']
            path = self.assets.verify_unit_file(self.task, dispatch['action_id'], fid)
            path.write_bytes(b'corrupt')
            return result
        self.runner.executors['deliverables.publish'] = TaskScopedFunction(corrupt)
        self.run_batch([self.report('study'), self.unit('source')])
        self.assertEqual([r['work_unit_id'] for r in self.assets.work_units.evidence(self.task)], ['source'])
        self.assertEqual(self.assets.manifest(self.task)['outputs'], [])

    def test_invalid_graph_schema_or_unsafe_capability_has_no_partial_execution(self):
        cases = [
            [self.unit('a', ['b']), self.unit('b', ['a'])],
            [self.unit('a'), self.unit('a')],
            [self.unit('a'), self.unit('b', ['missing'])],
            [self.unit('a'), self.unit('b', cap='reminder.create')],
            [self.unit('a'), self.unit('b', arguments={'url': ['wrong']})],
            [self.unit('a'), self.unit('b', cap='work.execute')],
        ]
        for units in cases:
            with self.subTest(units=units):
                result = self.run_batch(units)
                self.assertEqual(result['latest_outcome'], 'MODEL_CORRECTABLE_FAILURE')
                self.assertEqual(self.assets.work_units.rows(self.task), [])

    def test_result_binding_must_target_schema_and_come_from_explicit_dependency(self):
        bad = self.unit('b', ['a'], arguments={})
        bad['bindings'] = [{
            'argument': 'url',
            'from_unit': 'not-a-dependency',
            'source_pointer': '/url',
        }]
        result = self.run_batch([self.unit('a'), bad])
        self.assertEqual(result['latest_outcome'], 'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(self.assets.work_units.rows(self.task), [])

    def test_parent_authorization_does_not_grant_nested_capabilities(self):
        self.task = self.store.create_task(task_id=uuid.uuid4().hex, goal='Read', invocation_source='test',
            policy_snapshot={'allowed_capabilities':['work.execute','deliverables.publish']}, status='active')['task_id']
        result = self.run_batch([self.report('study'), self.unit('source')])
        self.assertEqual(result['latest_outcome'], 'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(self.assets.work_units.rows(self.task), [])

    def test_later_user_turn_restriction_is_rechecked_for_nested_capability(self):
        self.store.admit_inbox_event(
            task_id=self.task,
            event_id=uuid.uuid4().hex,
            event_type='USER_TURN',
            source='test',
            payload={'content': {'kind':'text', 'text':'不要查询网页，只处理本地内容。'}},
        )
        result = self.run_batch([self.report('study'), self.unit('source')])
        self.assertEqual(result['latest_outcome'], 'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(self.assets.work_units.rows(self.task), [])

    def test_replay_is_immutable_and_conflicting_batch_is_atomic(self):
        units = [self.report('study'), self.unit('source')]
        self.run_batch(units)
        self.run_batch(units)
        self.assertEqual([r['attempts'] for r in self.assets.work_units.rows(self.task)], [1,1])
        changed = self.unit('source', arguments={'url':'https://example.org/changed'})
        result = self.run_batch([self.unit('new'), changed])
        self.assertEqual(result['latest_outcome'], 'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(len(self.assets.work_units.rows(self.task)), 2)

    def test_replay_rechecks_file_integrity_and_revokes_broken_receipt(self):
        units = [self.report('study'), self.unit('source')]
        self.run_batch(units)
        output = self.assets.manifest(self.task)['outputs'][0]
        self.assets.file_path(self.task, output['id']).write_bytes(b'corrupt-after-success')
        self.run_batch(units)
        self.assertEqual(self.assets.manifest(self.task)['outputs'], [])
        self.assertEqual(self.assets.work_units.rows(self.task)[0]['state'], 'failed')

    def test_progress_events_and_outcome_counts_survive_host_reopen(self):
        self.assets.save_plan(self.task, '面试准备', [
            {'id':'study','title':'学习资料','depends_on':[],'completion_rule':'document'}])
        self.run_batch([self.report('study'), self.unit('source')])
        view = self.app.get_task_view(self.task)
        events = self.store.presentation_events_after(self.task, 0)
        unit_events = [e for e in events if e['payload'].get('title') == 'study']
        self.assertTrue(unit_events)
        self.assertEqual(view['work_summary']['completed'], 1)
        reopened = create_server('127.0.0.1', 0, str(self.root/'tasks.sqlite3'), task_asset_root=self.root/'assets')
        try:
            reopened.app.supervisor.stop()
            after = reopened.app.get_task_view(self.task)
            self.assertEqual(after['work_summary'], view['work_summary'])
            self.assertEqual(after['presentation_cursor'], view['presentation_cursor'])
        finally:
            reopened.server_close()

    def test_process_crash_resumes_same_action_and_does_not_repeat_verified_unit(self):
        # The child exits without cleanup after the first real file is verified
        # and the dependent unit's lease is persisted. No model or network.
        code = r'''
import json, os, sys
from pathlib import Path
from unittest.mock import patch
from floweroll_host.server import create_server
from floweroll_host.function_execution_worker import TaskScopedFunction
folder=Path(sys.argv[1])
with patch('floweroll_host.runtime_supervisor.RuntimeSupervisor.start'):
    server=create_server('127.0.0.1',0,str(folder/'crash.sqlite3'),task_asset_root=folder/'crash-assets')
app=server.app
app.storage.create_task('crash-task','Prepare files','test',{},status='active')
units=[{'id':uid,'title':uid,'depends_on':deps,'capability':'deliverables.publish',
    'arguments_json':json.dumps({'title':uid,'markdown':'Verified fixture file',
        'category':'study','status':'ready','item_id':uid})}
    for uid,deps in [('first',[]),('second',['first'])]]
app.storage.create_action(action_id='crash-action',task_id='crash-task',step_index=1,
    action_type='work.execute',payload={'units':units},expected={},idempotency_key='crash-key',on_verified='REPLAN')
runner=app.function_executors['work.execute'].invoke.__self__
original=runner.executors['deliverables.publish']
def crash(dispatch,args):
    if dispatch['work_unit_id']=='second': os._exit(0)
    return original.invoke(dispatch,args)
runner.executors['deliverables.publish']=TaskScopedFunction(crash)
app.function_worker.run_once('crash-task')
raise RuntimeError('Expected abrupt process exit')
'''
        subprocess.run([sys.executable, '-c', code, str(self.root)], check=True, timeout=15)
        from unittest.mock import patch
        with patch('floweroll_host.runtime_supervisor.RuntimeSupervisor.start'):
            reopened = create_server('127.0.0.1', 0, str(self.root/'crash.sqlite3'), task_asset_root=self.root/'crash-assets')
        try:
            runner = reopened.app.function_executors['work.execute'].invoke.__self__
            rows = runner.store.rows('crash-task')
            self.assertEqual([r['state'] for r in rows], ['completed','running'])
            # Advance the lease clock instead of spending five real minutes.
            import time
            runner.store.clock = lambda: time.time()+301
            before = reopened.app.storage.current_action_attempt('crash-action')['attempt_id']
            reopened.app.function_worker.run_once('crash-task')
            rows = runner.store.rows('crash-task')
            self.assertEqual([r['state'] for r in rows], ['completed','completed'])
            self.assertEqual([r['attempts'] for r in rows], [1,2])
            self.assertEqual(len(reopened.app.task_assets.manifest('crash-task')['outputs']), 2)
            self.assertEqual(reopened.app.storage.current_action_attempt('crash-action')['attempt_id'], before)
            self.assertEqual(len(reopened.app.storage.action_attempts('crash-action')), 1)
        finally:
            reopened.server_close()

    def test_cancel_stops_successors_and_does_not_publish_late_receipt(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def slow(args):
            calls.append(args['url'])
            entered.set()
            release.wait(5)
            return {'url':args['url'],'status':200}
        self.runner.executors['web.fetch'] = slow
        self.create_action([self.unit('source'), self.unit('later', ['source'])])
        thread = threading.Thread(target=self.app.function_worker.run_once, args=(self.task,))
        thread.start()
        try:
            self.assertTrue(entered.wait(4))
            self.store.admit_cancel_request(task_id=self.task, event_id=uuid.uuid4().hex, reason='test cancellation')
        finally:
            release.set()
            thread.join(5)
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.assets.work_units.evidence(self.task), [])
        self.assertNotEqual(self.assets.work_units.rows(self.task)[1]['state'], 'completed')

    def test_unit_sources_can_be_cited_by_later_report_without_fabricating_a_booking(self):
        self.run_batch([self.unit('source'), self.report('study')])
        receipt = self.assets.work_units.evidence(self.task)[0]
        args = {'title':'酒店备选', 'markdown':'仅准备资料', 'category':'hotel','status':'ready',
                'source_ids':[receipt['action_id']], 'source_urls':['https://example.com/source'], 'item_id':'hotel'}
        self.assets.save_plan(self.task, '面试准备', [
            {'id':'study','title':'学习资料','depends_on':[],'completion_rule':'document'},
            {'id':'hotel','title':'酒店预订','depends_on':[],'completion_rule':'reservation'}])
        self.run_batch([self.unit('hotel_info', cap='deliverables.publish', arguments=args), self.unit('source')])
        summary = self.assets.manifest(self.task)['work_summary']
        self.assertEqual((summary['completed'],summary['total']), (1,2))
        self.assertIn('hotel', summary['strict_unfinished_ids'])


class _FakeReadMCPDriver:
    def __init__(self, handler):
        self.handler = handler

    def call_tool(self, tool_name, arguments):
        return self.handler(tool_name, dict(arguments))


class WorkUnitReadMCPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.registry = CapabilityRegistry()
        functions, _ = register_amap_webservice_capabilities(self.registry)
        functions['coords.convert'] = lambda a: {
            'provider': 'fixture',
            'source_coordinate_reference': 'WGS84',
            'coordinate_reference': 'GCJ-02',
            'longitude': 120.2,
            'latitude': 30.3,
            'location': '120.2,30.3',
            'verified_by_provider': True,
        }
        self.calls = []

        def handler(tool_name, arguments):
            self.calls.append((tool_name, arguments))
            if tool_name == 'reverse':
                payload = {'country': '中国', 'province': '浙江省', 'city': '杭州市'}
            elif tool_name == 'weather':
                payload = {'city': arguments['city'], 'forecasts': [{'date': '2026-09-15'}]}
            elif tool_name == 'search':
                payload = {'query': arguments['query'], 'results': []}
            else:
                raise AssertionError(tool_name)
            return MCPFinalResult(content=[], structured_content=payload, is_error=False, meta=None)

        self.driver = _FakeReadMCPDriver(handler)
        self._register_mcp('geocode.reverse', 'reverse', {
            'type': 'object', 'properties': {'location': {'type': 'string'}},
            'required': ['location'], 'additionalProperties': False})
        self._register_mcp('weather.query', 'weather', {
            'type': 'object', 'properties': {'city': {'type': 'string'}},
            'required': ['city'], 'additionalProperties': False})
        self._register_mcp('web.search', 'search', {
            'type': 'object', 'properties': {'query': {'type': 'string'}},
            'required': ['query'], 'additionalProperties': False})
        self.server = create_server(
            '127.0.0.1', 0, str(self.root/'tasks.sqlite3'),
            capability_registry=self.registry,
            mcp_drivers={'fake': self.driver},
            function_executors=functions,
            task_asset_root=self.root/'assets')
        self.app = self.server.app
        self.app.supervisor.stop()
        self.store = self.app.storage
        self.runner = self.app.function_executors['work.execute'].invoke.__self__
        self.task = self.store.create_task(
            task_id=uuid.uuid4().hex, goal='Weather from current location',
            invocation_source='test', policy_snapshot={}, status='active')['task_id']
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.server.server_close)

    def _register_mcp(self, capability, tool_name, schema):
        spec = CapabilitySpec(
            name=capability, description='fixture read', arguments_schema=schema,
            post_verify_mode='REPLAN_REQUIRED')
        self.registry.register(RegisteredCapability(
            spec=spec,
            adapter=MCPReadToolAdapter(
                capability_id=capability, server_id='fake', tool_name=tool_name),
            source=CapabilitySourceTarget(
                kind='mcp', server_id='fake', tool_name=tool_name,
                metadata={'read_only': True}),
            tags=('read',)))

    def _run(self, units):
        action_id = uuid.uuid4().hex
        self.store.create_action(
            action_id=action_id, task_id=self.task, step_index=1,
            action_type='work.execute', payload={'units': units}, expected={},
            idempotency_key=action_id, on_verified='REPLAN')
        self.app.function_worker.run_once(self.task)
        return self.store.action_attempts(action_id)[0]

    def test_verified_receipt_bindings_drive_conversion_reverse_geocode_weather_chain(self):
        units = [
            {'id':'convert','title':'转换当前位置坐标','capability':'coords.convert',
             'arguments_json':json.dumps({'longitude':120.1,'latitude':30.2}), 'depends_on':[]},
            {'id':'reverse','title':'解析当前位置','capability':'geocode.reverse',
             'arguments_json':'{}', 'depends_on':['convert'], 'bindings':[
                 {'argument':'location','from_unit':'convert','source_pointer':'/location'}]},
            {'id':'weather','title':'查询本地天气','capability':'weather.query',
             'arguments_json':'{}', 'depends_on':['reverse'], 'bindings':[
                 {'argument':'city','from_unit':'reverse','source_pointer':'/structured_content/city'}]},
        ]
        result = self._run(units)
        self.assertEqual(result['latest_outcome'], 'SUCCESS')
        self.assertEqual(self.calls, [
            ('reverse', {'location':'120.2,30.3'}),
            ('weather', {'city':'杭州市'}),
        ])
        self.assertTrue(all(r['state'] == 'completed' for r in self.runner.store.rows(self.task)))

    def test_independent_read_only_mcp_units_overlap(self):
        barrier = threading.Barrier(2, timeout=4)
        def handler(tool_name, arguments):
            self.assertEqual(tool_name, 'search')
            barrier.wait()
            return MCPFinalResult(content=[], structured_content={'query':arguments['query']},
                                  is_error=False, meta=None)
        self.driver.handler = handler
        units = [
            {'id':'a','title':'A','capability':'web.search','arguments_json':'{"query":"a"}','depends_on':[]},
            {'id':'b','title':'B','capability':'web.search','arguments_json':'{"query":"b"}','depends_on':[]},
        ]
        result = self._run(units)
        self.assertEqual(result['latest_outcome'], 'SUCCESS')
        self.assertTrue(all(r['state'] == 'completed' for r in self.runner.store.rows(self.task)))


class WorkUnitLeaseTests(unittest.TestCase):
    def test_large_unit_results_stay_durable_but_model_context_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = WorkUnitStore(Path(tmp)/'units.sqlite3')
            units = [{'id':str(i), 'title':str(i), 'depends_on':[],
                      'capability':'materials.inspect','arguments':{}} for i in range(20)]
            store.prepare('task', units)
            for definition in units:
                owner = store.claim('task',definition['id'],'parent')
                store.finish('task',definition['id'],owner,output={'text':'资料'*20000})
            context = store.model_evidence('task')
            self.assertLess(len(json.dumps(context,ensure_ascii=False)), 24100)
            self.assertTrue(all(row['data']['truncated'] for row in context))
            self.assertEqual(len(store.evidence('task')),20)
            self.assertEqual(len(store.evidence('task')[0]['data']['text']),40000)

    def test_cross_connection_claim_expiry_and_stale_result_fence(self):
        with tempfile.TemporaryDirectory() as tmp:
            now = [100.0]
            a = WorkUnitStore(Path(tmp)/'units.sqlite3', clock=lambda:now[0])
            b = WorkUnitStore(Path(tmp)/'units.sqlite3', clock=lambda:now[0])
            a.prepare('task', [{'id':'source','title':'source','depends_on':[], 'capability':'web.fetch', 'arguments':{}}])
            owner = a.claim('task','source','parent1')
            self.assertIsNone(b.claim('task','source','parent2'))
            now[0] += 301
            newer = b.claim('task','source','parent2')
            self.assertIsNotNone(newer)
            self.assertFalse(a.finish('task','source',owner,output={'text':'stale'}))
            self.assertTrue(b.finish('task','source',newer,output={'text':'current'}))
            self.assertEqual(a.evidence('task')[0]['data'], {'text':'current'})
            self.assertIsNone(a.claim('task','source','parent3'))

    def test_failed_units_require_explicit_retry_and_stop_at_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = WorkUnitStore(Path(tmp)/'units.sqlite3')
            definition = [{'id':'a','title':'a','depends_on':[], 'capability':'web.fetch','arguments':{}}]
            for attempt in range(3):
                store.prepare('task', definition, retry_failed=True)
                owner = store.claim('task','a','parent')
                self.assertIsNotNone(owner)
                store.finish('task','a',owner,error='offline')
                store.prepare('task', definition)
                self.assertIsNone(store.claim('task','a','parent'))
            store.prepare('task', definition, retry_failed=True)
            self.assertIsNone(store.claim('task','a','parent'))
            self.assertEqual(store.rows('task')[0]['attempts'], 3)
