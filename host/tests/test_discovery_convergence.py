"""Regression for the Shanghai multi-goal task: batch discovery + no-progress bounds.

Only the tool/provider boundary is stubbed. These tests exercise the production
Registry -> Planner schema -> Action/Attempt -> WorkUnitRunner -> SQLite path.
They never call a paid model, book a room, or mutate a real phone/calendar.
"""
from __future__ import annotations

import json
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.capability_discovery import CapabilityContextSelector, SEARCH_ID
from floweroll_host.capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from floweroll_host.discovery_progress import MAX_SEARCHES_WITHOUT_PROGRESS
from floweroll_host.function_tool_adapter import FunctionToolAdapter
from floweroll_host.planner_contracts import CapabilitySpec, DecisionContext, PlannerDecision
from floweroll_host.server import create_server
from floweroll_host.storage import Storage
from floweroll_host.task_runtime import TaskRuntime


class NoModel:
    def decide(self, *args):
        raise AssertionError('This regression must not invoke a model')


class DiscoveryConvergenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        registry = CapabilityRegistry()
        funcs = {}
        for name, description, source in (
            ('coords.convert', '把 WGS84 坐标转换为 GCJ-02', 'http_api'),
            ('weather.query', '查询上海天气预报', 'http_api'),
            ('travel.hotel.search', '查询酒店房间预算住宿', 'managed_cli'),
        ):
            spec = CapabilitySpec(name, description, {'type':'object', 'properties':{}, 'required':[], 'additionalProperties':False})
            registry.register(RegisteredCapability(spec, FunctionToolAdapter(capability_id=name, source_kind=source, read_only=True),
                CapabilitySourceTarget(source, tool_name=name, metadata={'read_only': True})))
            funcs[name] = lambda args: {'result':'verified fixture'}
        self.server = create_server('127.0.0.1', 0, str(self.root/'runtime.sqlite3'),
            capability_registry=registry, function_executors=funcs, task_asset_root=self.root/'assets',
            progressive_discovery=True, task_runtime_factory=lambda storage: TaskRuntime(
                storage, NoModel(), product_native_capabilities()+registry.planner_capabilities()))
        self.app = self.server.app
        self.app.supervisor.stop()
        self.store = self.app.storage
        self.tid = str(uuid.uuid4())
        self.store.create_task(self.tid, '去上海查天气、解析文件生成PDF、酒店、日程和闹钟', 'test', {}, status='active')
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.server.server_close)
        self.step = 0

    def action(self, capability, arguments):
        self.step += 1
        aid = str(uuid.uuid4())
        self.store.create_action(action_id=aid, task_id=self.tid, step_index=self.step,
            action_type=capability, payload=arguments, expected={}, idempotency_key=aid, on_verified='REPLAN')
        self.app.function_worker.run_once(self.tid)
        return self.store.get_action(aid)

    def unit(self, uid, query, domain='all'):
        return {'id':uid, 'title':uid, 'capability':SEARCH_ID,
                'arguments_json':json.dumps({'query':query, 'domain':domain, 'limit':1}), 'depends_on':[]}

    def search(self, query, domain='all', **extra):
        return self.app.function_executors[SEARCH_ID].invoke({'task_id':self.tid}, {'query':query, 'domain':domain, **extra})

    def selected(self):
        basis = self.store.planner_basis(self.tid)
        context = DecisionContext(task_id=self.tid, raw_goal=basis['task']['goal'], task_status='ACTIVE',
            phase='planning', current_time='2030-01-01T12:00:00+08:00', timezone='Asia/Shanghai',
            policy_view={'allowed_capabilities':[s.name for s in self.app.task_runtime.capabilities]},
            capabilities=self.app.task_runtime.capabilities,
            verified_observations=basis['verified_observations']+self.app.task_assets.work_units.model_evidence(self.tid),
            runtime_context={'capability_discovery_state':self.store.capability_discovery_state(self.tid)})
        return self.app.task_runtime.capability_context_selector.apply(context)

    def test_original_six_unit_shape_executes_instead_of_rejecting_discovery(self):
        units = [self.unit('pdf', '生成PDF报告', 'document'), self.unit('transport', '火车交通', 'travel'),
                 self.unit('hotel', '酒店住宿', 'travel'), self.unit('calendar', 'calendar.create', 'device'),
                 self.unit('alarm', 'alarm.create', 'device'),
                 {'id':'coordinates', 'title':'coordinates', 'capability':'coords.convert', 'arguments_json':'{}', 'depends_on':[]}]
        result = self.action('work.execute', {'units':units})
        self.assertEqual(result['status'], 'succeeded', result)
        receipts = self.app.task_assets.work_units.evidence(self.tid)
        self.assertEqual(len(receipts), 6)
        self.assertEqual(sum(r['capability']==SEARCH_ID for r in receipts), 5)
        self.assertEqual(self.store.capability_discovery_state(self.tid)['total_searches'], 5)
        visible = [s.name for s in self.selected().capabilities]
        self.assertIn('alarm.create', visible)
        self.assertIn('calendar.create', visible)
        self.assertIn('travel.hotel.search', visible)
        # Verified units are reused; replay does not burn search budget again.
        self.action('work.execute', {'units':units})
        self.assertEqual(self.store.capability_discovery_state(self.tid)['total_searches'], 5)

    def test_latest_standalone_discovery_head_outranks_older_appended_work_unit_receipts(self):
        # Reproduce the production ordering bug: old nested receipts are
        # appended after newer main observations when Planner context is built.
        # Fill the discovery budget with several older subgoals first.
        units = [
            self.unit('old-hotel', '酒店住宿', 'travel'),
            self.unit('old-alarm', 'alarm.create', 'device'),
            self.unit('old-calendar', 'calendar.create', 'device'),
            self.unit('old-weather', '天气查询', 'location'),
            self.unit('old-doc', '生成 DOCX 文档', 'document'),
        ]
        result = self.action('work.execute', {'units': units})
        self.assertEqual(result['status'], 'succeeded', result)

        # The newest direct search asks for reminder.query. At this point the
        # no-progress budget is exhausted, so the selector cannot rely on one
        # more capability.search turn to repair a bad working set.
        result = self.action(SEARCH_ID, {
            'query': '查询提醒事项 列出提醒 reminder query',
            'domain': 'device',
            'limit': 6,
        })
        self.assertEqual(result['status'], 'succeeded', result)
        state = self.store.capability_discovery_state(self.tid)
        self.assertFalse(state['search_allowed'])
        self.assertEqual(state['pages'][-1]['ids'][0], 'reminder.query')

        visible = [spec.name for spec in self.selected().capabilities]
        self.assertIn('reminder.query', visible)
        self.assertEqual(visible[0], 'reminder.query')
        self.assertNotIn(SEARCH_ID, visible)

    def test_two_duplicate_pages_close_both_direct_and_nested_discovery(self):
        for _ in range(3):
            self.action(SEARCH_ID, {'query':'alarm.create', 'domain':'device', 'limit':1})
        state = self.store.capability_discovery_state(self.tid)
        self.assertFalse(state['search_allowed'])
        selected = self.selected()
        self.assertNotIn(SEARCH_ID, [s.name for s in selected.capabilities])
        batch = next((s for s in selected.capabilities if s.name=='work.execute'), None)
        if batch:
            self.assertNotIn(SEARCH_ID, batch.arguments_schema['properties']['units']['items']['properties']['capability']['enum'])
        # Even a stale/handcrafted batch cannot bypass the execution-time guard.
        result = self.search('换个关键词再继续找')
        self.assertEqual(result['reason_code'], 'discovery_progress_required')
        self.assertFalse(result['has_more'])
        self.assertEqual(result['matches'], [])

    def test_budget_is_shared_atomically_across_concurrent_searches_and_restart(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.search('alarm.create', 'device', limit=1), range(16)))
        state = self.store.capability_discovery_state(self.tid)
        self.assertEqual(state['total_searches'], 16)
        self.assertLessEqual(state['used'], MAX_SEARCHES_WITHOUT_PROGRESS)
        self.assertEqual(state['used'], 3)
        self.assertTrue(any(r.get('reason_code')=='discovery_progress_required' for r in results))
        reopened = Storage(str(self.root/'runtime.sqlite3'))
        self.assertFalse(reopened.capability_discovery_state(self.tid)['search_allowed'])
        self.assertEqual(reopened.capability_discovery_state(self.tid)['total_searches'], 16)

    def test_real_business_progress_reopens_budget_but_discovery_batch_does_not(self):
        for _ in range(3):
            self.search('alarm.create', 'device', limit=1)
        self.assertFalse(self.store.capability_discovery_state(self.tid)['search_allowed'])
        self.action('work.execute', {'units':[self.unit('a','酒店'), self.unit('b','日历')]})
        self.assertFalse(self.store.capability_discovery_state(self.tid)['search_allowed'])
        self.action('coords.convert', {})
        self.assertTrue(self.store.capability_discovery_state(self.tid)['search_allowed'])

    def test_catalog_and_user_turn_changes_invalidate_exhaustion(self):
        for _ in range(3):
            self.search('alarm.create', 'device', limit=1)
        self.store.admit_inbox_event(task_id=self.tid, event_id='new-user-goal', event_type='USER_TURN',
            source='user', payload={'content':{'kind':'text','text':'新增查询联系人'}})
        self.assertTrue(self.store.capability_discovery_state(self.tid)['search_allowed'])
        for _ in range(3):
            self.search('alarm.create', 'device', limit=1)
        registry = self.app.capability_registry
        spec = CapabilitySpec('file.new_read', '读取新接入资料', {'type':'object','properties':{},'required':[]})
        registry.register(RegisteredCapability(spec, FunctionToolAdapter(capability_id=spec.name, source_kind='http_api'),
            CapabilitySourceTarget('http_api', tool_name=spec.name)))
        self.app.function_executors[spec.name] = lambda a: {}
        self.app.task_runtime.capabilities.append(spec)
        result = self.search('file.new_read', limit=1)
        self.assertTrue(result['search_allowed'])
        self.assertIn('file.new_read', result['selected_capability_ids'])

    def test_child_capability_enum_rejects_unbatchable_write_before_action_commit(self):
        selected = self.selected()
        # Use the real registered batch schema even when the small selector did not recall it.
        batch = self.app.capability_registry.get('work.execute').spec
        payload = {'decision_type':'EXECUTE', 'interpreted_goal_summary':'批处理', 'plan_update':None,
                   'action':{'capability':'work.execute','arguments':{'units':[
                       {**self.unit('a','calendar'), 'capability':'calendar.create'}, self.unit('b','alarm')]}},
                   'on_verified':'REPLAN','clarification':None,'wait':None,'completion':None,'stop_reason':None}
        with self.assertRaisesRegex(ValueError, 'outside enum'):
            PlannerDecision.from_dict(payload, [batch])

    def test_completed_location_and_weather_do_not_evict_latest_alarm_schema(self):
        self.action('weather.query', {})
        self.action('coords.convert', {})
        self.action(SEARCH_ID, {'query':'alarm.create','domain':'device','limit':1})
        visible = [s.name for s in self.selected().capabilities]
        self.assertIn('alarm.create', visible)
        self.assertLess(visible.index('alarm.create'), visible.index(SEARCH_ID))

    def test_requested_pdf_output_contract_outranks_pdf_readers_and_notifications(self):
        from floweroll_host.capability_discovery import rank_capabilities
        queries = [
            '把已解析的文档内容生成PDF文件并发送交付给用户',
            '文件格式转换：把DOCX或文本内容转换生成PDF文件并交付给用户',
            '解析这个文件用pdf发我',
        ]
        for query in queries:
            with self.subTest(query=query):
                ranked = rank_capabilities(self.app.task_runtime.capabilities, query, self.app.capability_registry)
                self.assertEqual(ranked[0].name, 'deliverables.publish')
                result = self.search(query, 'document', limit=1)
                self.assertEqual(result['selected_capability_ids'], ['deliverables.publish'])
                spec = ranked[0]
                self.assertIn('pdf', spec.arguments_schema['properties']['output_format']['enum'])

    def test_previously_used_tool_can_be_explicitly_recalled_for_another_target(self):
        self.action('weather.query', {})
        self.action(SEARCH_ID, {'query':'weather.query', 'limit':1})
        self.assertIn('weather.query', [s.name for s in self.selected().capabilities])
