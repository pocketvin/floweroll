"""架构发现与运行投影的证据合同；测试不会启动生产 Host。"""
from __future__ import annotations
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from . import topology as tp
from .execution_paths import task_path, observation_path, duration, unit_rows
from .test_observability import fixture
from . import test_console as console_tests
from . import console as co


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=tp.ROOT/'work',prefix='topology-test-')
        self.root=Path(self.tmp.name);self.host=self.root/'host/floweroll_host';self.host.mkdir(parents=True)
    def tearDown(self):self.tmp.cleanup()
    def write(self,name,text): (self.host/name).write_text(text)

    def test_discovers_new_route_without_executing_module(self):
        self.write('http_new.py', '''raise RuntimeError("MUST_NOT_EXECUTE")
PREFIX = "/v1/observations"
SESSION = PREFIX + "/sessions/{session_id}"
@routes.post(SESSION + "/compare", response_model=schema.Compare)
async def compare(body: schema.Input): pass
''')
        graph=tp.discover(self.root)
        n=next(n for n in graph['nodes'] if n['id']=='http:POST:/v1/observations/sessions/{session_id}/compare')
        self.assertEqual(n['lifecycle_owner'],'observation')
        self.assertEqual(n['source']['symbol'],'compare')
        self.assertEqual(n['input_schema'],{'body':'schema.Input'})
        self.assertEqual(n['loaded_in_running_host'],'unknown')
        self.assertIsNone(n['stats'])

    def test_new_graph_nodes_and_conditional_edges(self):
        self.write('planner_graph.py','''
nodes = {"memory": self._memory, "new_step": self._new}
builder.add_node("final", self._final)
builder.add_edge("memory", "new_step")
builder.add_conditional_edges("new_step", route, {"ok": "final"})
''')
        graph=tp.discover(self.root)
        self.assertIn('planner.step:new_step',{n['id'] for n in graph['nodes']})
        self.assertTrue(any(e['source']=='planner.step:new_step' and e['target']=='planner.step:final' for e in graph['edges']))
        self.assertTrue(all(e['evidence']=='source_defined' for e in graph['edges']))

    def test_capability_definition_does_not_imply_ready(self):
        self.write('capabilities.py','BATCH_ID="work.execute"\nspec=CapabilitySpec(name=BATCH_ID,description="batch",arguments_schema={"type":"object"})\n')
        a=tp.discover(self.root);b=tp.discover(self.root)
        self.assertEqual([n['id'] for n in a['nodes']],[n['id'] for n in b['nodes']])
        n=next(n for n in a['nodes'] if n['id']=='capability:work.execute')
        self.assertEqual(n['readiness'],'unknown');self.assertEqual(n['input_schema'],{'type':'object'})

    def test_source_parse_failure_is_explicit(self):
        self.write('http_broken.py','def broken(')
        graph=tp.discover(self.root)
        self.assertEqual(graph['diagnostics'][0]['kind'],'source_parse_failed')

    def test_missing_database_keeps_source_graph_and_does_not_create_db(self):
        path=self.root/'missing.sqlite3'
        graph=tp.runtime_stats(tp.discover(self.root),path)
        self.assertFalse(path.exists());self.assertEqual(graph['scope']['kind'],'unavailable')
        self.assertGreater(len(graph['nodes']),0)

    def test_known_source_only_no_arbitrary_path(self):
        with self.assertRaises(KeyError):tp.component_details('../../work/observability/local.env')
        with self.assertRaises(KeyError):tp.component_details('unknown')


class ExecutionPathTests(unittest.TestCase):
    def test_snapshot_not_mutated_and_ids_are_stable(self):
        s=fixture();before=copy.deepcopy(s)
        a=task_path(s,'ns',full=True);b=task_path(s,'ns',full=True)
        self.assertEqual(s,before);self.assertEqual(a['spans'],b['spans'])
        ids=[n['id'] for n in a['spans']];self.assertEqual(len(ids),len(set(ids)))

    def test_missing_usage_and_model_timing_are_not_zero(self):
        s=fixture();s['traces'][1]['data_json']='{"call_number":1}'
        p=task_path(s,'ns',full=True)
        self.assertIsNone(p['summary']['reported_tokens_only'])
        self.assertIsNone(p['summary']['model_ms_sum'])
        self.assertEqual(p['summary']['calls_without_reported_usage'],1)
        self.assertIsNone(p['planner_calls'][0]['injected_memories'])

    def test_repeated_metrics_do_not_double_count_tokens(self):
        s=fixture();s['traces'].append(dict(s['traces'][1],id=99))
        p=task_path(s,'ns',full=True)
        self.assertEqual(p['summary']['reported_tokens_only'],120)
        self.assertEqual(p['summary']['model_ms_sum'],1000)

    def test_measured_graph_steps_are_not_overwritten_by_same_event_type(self):
        s=fixture()
        def event(i,name,phase):return {'id':i,'created_at':f'2026-09-14T01:00:0{i-9}+00:00','event_type':'planner.graph.node','data_json':json.dumps({'call_number':1,'node':name,'phase':phase,'duration_ms':21,'outcome':'success'})}
        s['traces']+= [event(10,'memory','started'),event(11,'memory','finished'),event(12,'build_context','started'),event(13,'build_context','finished')]
        p=task_path(s,'ns',full=True);steps=[x for x in p['spans'] if x['timing_kind']=='measured_node']
        self.assertEqual(len(steps),2);self.assertEqual(steps[0]['component_id'],'planner.step:memory')
        self.assertEqual(steps[0]['duration_ms'],21)

    def test_duration_only_graph_metrics_do_not_invent_timestamps(self):
        s=fixture();m=json.loads(s['traces'][1]['data_json']);m['graph_steps']=[{'node':'memory','duration_ms':12,'outcome':'success'}];s['traces'][1]['data_json']=json.dumps(m)
        p=task_path(s,'ns',full=True);n=next(n for n in p['spans'] if n['component_id']=='planner.step:memory')
        self.assertIsNone(n['started_at']);self.assertIsNone(n['ended_at']);self.assertEqual(n['duration_ms'],12)

    def test_actual_injected_memories_and_unobserved_retrieval(self):
        s=fixture();s['captures'][1]={'wire_request':{'messages':[{'role':'user','content':json.dumps({'decision_context':{'runtime_context':{'relevant_memories':[{'memory':'fact'}]}}})}]}}
        c=task_path(s,'ns',full=True)['planner_calls'][0]
        self.assertEqual(c['injected_memories'],1);self.assertIsNone(c['retrieved_memories'])
        s['captures'][1]['wire_request']['messages']=[]
        self.assertIsNone(task_path(s,'ns',full=True)['planner_calls'][0]['injected_memories'])

    def test_metadata_mode_does_not_expose_payload(self):
        s=fixture();s['task']['goal']='PRIVATE_TEST_CONTENT'
        p=task_path(s,'ns',full=False)
        self.assertNotIn('PRIVATE_TEST_CONTENT',json.dumps(p))
        self.assertFalse(any('payload' in n for n in p['spans']))

    def test_action_uses_recorded_planner_decision_parent(self):
        s=fixture();did='decision1'
        s['actions']=[{'id':'a','action_type':'calendar.query','status':'succeeded','created_at':s['task']['created_at'],
            'updated_at':s['task']['updated_at'],'planner_decision_id':did}]
        p=task_path(s,'ns',full=True)
        action=next(x for x in p['spans'] if x['id']=='action:a')
        self.assertEqual(action['parent_id'],'planner:1')
        self.assertTrue(any(e['source']=='planner:1' and e['target']=='action:a' for e in p['edges']))

    def test_native_attempt_is_not_evidence_of_client_ui_merge(self):
        s=fixture();s['actions']=[{'id':'a','action_type':'calendar.query','status':'succeeded','created_at':s['task']['created_at'],'updated_at':s['task']['updated_at']}]
        s['attempts']=[{'id':'at','action_id':'a','attempt_number':1,'source_kind':'ios','status':'finished','latest_outcome':'SUCCESS','started_at':s['task']['created_at'],'finished_at':s['task']['updated_at']}]
        p=task_path(s,'ns',full=True)
        self.assertEqual(p['summary']['native_attempts'],1)
        self.assertNotIn('ios.presentation',p['components']);self.assertEqual(p['coverage']['ios'],'not_instrumented')

    def test_work_unit_records_not_invented_parallel_timing(self):
        s=fixture();units={'available':True,'units':[{'unit_id':'u1','state':'completed','definition_json':'{"capability":"weather.query","depends_on":[]}'},{'unit_id':'u2','state':'pending','definition_json':'{"capability":"calendar.query","depends_on":["u1"]}'}]}
        p=task_path(s,'ns',full=True,units=units)
        rows=[r for r in p['spans'] if r['kind']=='work_unit']
        self.assertEqual(len(rows),2);self.assertTrue(all(r['duration_ms'] is None and r['started_at'] is None for r in rows))
        self.assertTrue(any(e['relation']=='dependency' for e in p['edges']))
        self.assertEqual(p['coverage']['work_unit_timing'],'unavailable')

    def test_unit_db_only_uses_explicit_config(self):
        self.assertFalse(unit_rows({},fixture()['task']['id'])['available'])
        with self.assertRaises(ValueError):unit_rows({'work_units_db':'/etc/passwd'},fixture()['task']['id'])

    def test_equivalent_time_offsets_and_invalid_time(self):
        self.assertEqual(duration('2026-09-14T09:00:00+08:00','2026-09-14T01:00:01Z'),1000)
        self.assertIsNone(duration('2026-09-14T01:00:00', '2026-09-14T01:00:01'))

    def test_observation_results_not_counted_as_llm_calls(self):
        detail={'session':{'id':'obs','preset_label':'观察','status':'completed'},'stats':{'source_stats':{},'event_count':0,'checkpoint_count':1,'final_count':0,'question_count':0},'notes':[{'id':'n','kind':'checkpoint','summary':'observed'}],'timeline':[],'questions':[]}
        result=observation_path(detail,'ns')
        self.assertIsNone(result['summary']['reported_tokens_only'])
        self.assertIsNone(result['summary']['model_ms_sum'])
        self.assertIsNone(result['summary']['planner_calls'])
        self.assertEqual(result['kind'],'observation')


class TopologyHTTPTests(unittest.TestCase):
    setUpClass = console_tests.ConsoleHTTPTests.__dict__['setUpClass']
    tearDownClass = console_tests.ConsoleHTTPTests.__dict__['tearDownClass']
    request = console_tests.ConsoleHTTPTests.request

    def test_topology_endpoint(self):
        config={'runtime_db':str(co.ROOT/'work/unit.sqlite'),'snapshot_dir':str(co.ROOT/'work/captures'),'mode':'metadata','langfuse_url':'http://localhost:3033'}
        with patch.object(co,'load_config',return_value=config),patch.object(co.Inspector,'topology',return_value={'nodes':[],'edges':[]}):
            status,_,body=self.request('/api/topology',headers={'X-Floweroll-Console':'1'})
        self.assertEqual(status,200);self.assertEqual(json.loads(body),{'nodes':[],'edges':[]})

    def test_asset_traversal_is_denied(self):
        for path in ['/ui/assets/../../local.env','/ui/assets/%2e%2e%2flocal.env','/ui/assets/local.env','/ui/assets/not-there.js']:
            with self.subTest(path=path):self.assertEqual(self.request(path)[0],404)


if __name__=='__main__':unittest.main()
