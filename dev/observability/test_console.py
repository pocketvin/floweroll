from __future__ import annotations
import copy
import http.client
import json
import threading
import unittest
from unittest.mock import patch

from . import console as co
from .test_observability import fixture


class InspectorTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = fixture()
        self.config = {'runtime_db': str(co.ROOT/'work/test-only.sqlite'), 'snapshot_dir': str(co.ROOT/'work/test-captures'),
                       'mode':'local_full', 'langfuse_url':'http://localhost:3033', 'project_id':'floweroll'}
        self.inspector = co.Inspector(self.config)
        self.load = patch.object(co, 'load_task', side_effect=lambda *a:self.snapshot)
        self.load.start()

    def tearDown(self):
        self.load.stop()

    def test_historical_request_never_uses_current_prompt_as_evidence(self):
        result=self.inspector.call(self.snapshot['task']['id'],1)
        self.assertFalse(result['available'])
        self.assertNotIn('system_prompt',result)
        self.assertNotIn('wire_request',result)

    def capture(self):
        return {'mode':'local_full','state':'response_validated','request_bytes':80,
                'wire_request':{'model':'model-test','messages':[
                    {'role':'system','content':'CAPTURED_SYSTEM'},
                    {'role':'user','content':json.dumps({'decision_context':{'task':{'goal':'PRIVATE_GOAL'}, 'available_capabilities':['tool.test']}})}],
                    'response_format':{'json_schema':{'schema':{'type':'object','properties':{'ok':{'type':'boolean'}},'required':['ok']}}}},
                'response_text':'{"ok":true}', 'visible_capabilities':['tool.test']}

    def test_captured_wire_prompt_context_and_tool_surfaces_are_real(self):
        self.snapshot['captures'][1]=self.capture()
        before=copy.deepcopy(self.snapshot)
        result=self.inspector.call(self.snapshot['task']['id'],1)
        self.assertTrue(result['available'])
        self.assertEqual(result['system_prompt'],'CAPTURED_SYSTEM')
        self.assertEqual(result['context']['task']['goal'],'PRIVATE_GOAL')
        self.assertEqual(result['tools']['visible'],['tool.test'])
        self.assertEqual(result['contract_check']['status'],'pass')
        self.assertIn('CAPTURED_SYSTEM',result['prompt_diff'])
        self.assertEqual(before,self.snapshot)

    def test_metadata_and_off_do_not_reveal_previous_full_capture(self):
        self.snapshot['captures'][1]=self.capture()
        self.snapshot['task']['goal']='PRIVATE_GOAL'
        for mode in ('metadata','off'):
            i=co.Inspector(dict(self.config,mode=mode))
            with self.subTest(mode=mode):
                self.assertFalse(i.call(self.snapshot['task']['id'],1)['available'])
                self.assertNotIn('PRIVATE_GOAL',json.dumps(i.overview(self.snapshot['task']['id'])))
                self.assertNotIn('CAPTURED_SYSTEM',json.dumps(i.call(self.snapshot['task']['id'],1)))

    def test_response_schema_failure_is_not_claimed_success(self):
        capture=self.capture();capture['response_text']='{"ok":"wrong"}'
        self.assertEqual(co.contract_check(capture)['status'],'fail')
        capture['response_text']='not json'
        self.assertEqual(co.contract_check(capture)['status'],'fail')
        capture.pop('response_text')
        self.assertEqual(co.contract_check(capture)['status'],'unavailable')

    def test_current_runtime_status_is_distinct_from_model_success(self):
        self.snapshot['task']['status']='blocked'
        result=self.inspector.overview(self.snapshot['task']['id'])
        self.assertEqual(result['summary']['task_status'],'blocked')
        self.assertIsNone(result['summary']['cost'])
        self.assertEqual(result['summary']['full_captured_calls'],0)
        self.assertIn('Prompt quality',result['summary']['not_automatically_evaluated'])

    def test_uuid_and_call_bounds(self):
        for tid in ('../local.env','not-a-uuid'):
            with self.assertRaises(ValueError):self.inspector.call(tid,1)
        for n in (0,-1,10001):
            with self.assertRaises(ValueError):self.inspector.call(self.snapshot['task']['id'],n)


class ConsoleHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=co.ConsoleServer(('127.0.0.1',0),co.Handler)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join(2)

    def request(self,path='/api/tasks',method='GET',headers=None):
        conn=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=2)
        try:
            conn.request(method,path,headers=headers or {})
            response=conn.getresponse();return response.status,dict(response.getheaders()),response.read()
        finally:conn.close()

    def test_cross_origin_and_rebinding_rejected_before_database_read(self):
        for headers in ({},{'X-Floweroll-Console':'1','Origin':'https://evil.example'},
                        {'X-Floweroll-Console':'1','Host':'evil.example'},
                        {'X-Floweroll-Console':'1','Sec-Fetch-Site':'cross-site'}):
            with self.subTest(headers=headers),patch.object(co,'load_config',side_effect=AssertionError('must not read')):
                self.assertEqual(self.request(headers=headers)[0],403)

    def test_readonly_methods(self):
        for method in ('POST','PUT','DELETE','PATCH','OPTIONS'):
            with self.subTest(method=method):self.assertEqual(self.request(method=method)[0],405)

    def test_static_allowlist_and_content_security_headers(self):
        status,headers,body=self.request('/')
        self.assertEqual(status,200);self.assertIn('开发观察台'.encode(),body)
        self.assertEqual(headers['Cache-Control'],'no-store')
        self.assertIn("frame-ancestors 'none'",headers['Content-Security-Policy'])
        for path in ('/../../work/observability/local.env','/local.env','/config.json'):
            self.assertEqual(self.request(path)[0],404)

    def test_same_origin_api_path_and_response(self):
        config={'runtime_db':str(co.ROOT/'work/unit.sqlite'), 'snapshot_dir':str(co.ROOT/'work/captures'),
                'mode':'metadata','langfuse_url':'http://localhost:3033'}
        with patch.object(co,'load_config',return_value=config),patch.object(co.Inspector,'index',return_value={'tasks':[]}):
            status,_,body=self.request(headers={'X-Floweroll-Console':'1'})
        self.assertEqual(status,200);self.assertEqual(json.loads(body),{'tasks':[]})

    def test_observation_api_routes_use_same_origin_readonly_boundary(self):
        config={'runtime_db':str(co.ROOT/'work/unit.sqlite'), 'snapshot_dir':str(co.ROOT/'work/captures'),
                'mode':'metadata','langfuse_url':'http://localhost:3033'}
        with patch.object(co,'load_config',return_value=config),patch.object(co.Inspector,'observations',return_value={'available':True,'observations':[]}):
            status,_,body=self.request('/api/observations',headers={'X-Floweroll-Console':'1'})
        self.assertEqual(status,200);self.assertEqual(json.loads(body),{'available':True,'observations':[]})

    def test_no_html_interpretation_of_user_or_model_content(self):
        js=(co.STATIC/'app.js').read_text()
        self.assertNotIn('innerHTML',js)
        self.assertNotIn('eval(',js)
        self.assertIn('textContent',js)


if __name__=='__main__':unittest.main()
