"""Operation evidence 不拥有产品状态；全部供应商调用在测试内替换，不消费 API。"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from floweroll_host import planner_capture as pc
from floweroll_host.observation_service import ObservationModel, ObservationModelError
from host.tests import test_work_units as unit_tests


class FakeHTTP:
    def __init__(self, payload): self.payload=payload
    def __enter__(self): return self
    def __exit__(self, *args): return False
    def read(self, size): return json.dumps(self.payload,ensure_ascii=False).encode()[:size]


def summary_response(eid, title='测试'):
    return {'title':title,'summary':'只读测试记录','evidence_ids':[eid], 'decisions':[], 'todos':[], 'open_questions':[]}


def envelope(value):
    return {'choices':[{'message':{'content':json.dumps(value,ensure_ascii=False)},'finish_reason':'stop'}],
            'usage':{'prompt_tokens':11,'completion_tokens':7,'total_tokens':18}}


class OperationCaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=pc.ROOT/'work',prefix='operation-capture-')
        self.root=Path(self.tmp.name);self.db=str(self.root/'runtime.sqlite3');self.capture_dir=self.root/'captures'
        self.config={'mode':'local_full','runtime_db':self.db,'snapshot_dir':str(self.capture_dir),'max_snapshot_bytes':1048576}
        self.config_path=self.root/'config.json';self.config_path.write_text(json.dumps(self.config))
        self.env=patch.dict(os.environ,{'FLOWEROLL_OBSERVABILITY_CONFIG':str(self.config_path),
            'FLOWEROLL_OBSERVATION_API_KEY':'test-key-not-a-secret','FLOWEROLL_OBSERVATION_BASE_URL':'https://model.invalid',
            'FLOWEROLL_OBSERVATION_MODEL':'test-model','FLOWEROLL_OBSERVATION_VISION_API_KEY':'test-vision',
            'FLOWEROLL_OBSERVATION_VISION_BASE_URL':'https://model.invalid','FLOWEROLL_OBSERVATION_VISION_MODEL':'test-vision'})
        self.env.start();self.model=ObservationModel();self.sid=str(uuid.uuid4());self.eid=str(uuid.uuid4())
        self.event={'id':self.eid,'kind':'transcript','source':'deviceAudio','text':'测试资料','offset_ms':0,'duration_ms':1000}
    def tearDown(self):
        pc.flush_for_test();self.env.stop();self.tmp.cleanup()
    def records(self,sid=None):
        self.assertTrue(pc.flush_for_test())
        folder=self.capture_dir/'operations/observation'/(sid or self.sid)
        return [json.loads(p.read_text()) for p in folder.glob('*.json')]
    @contextmanager
    def scope(self,sid=None):
        with pc.entity_scope(lifecycle='observation',entity_id=sid or self.sid,runtime_db=self.db):yield

    def test_summary_wire_request_exact_and_usage_captured(self):
        sent=[]
        def http(request,**kwargs):sent.append(request.data);return FakeHTTP(envelope(summary_response(self.eid)))
        with self.scope(),patch('urllib.request.urlopen',side_effect=http):
            result=self.model(events=[self.event],notes=[])
        r=self.records()[0]
        self.assertEqual(len(sent),1);self.assertEqual(r['operation'],'observation.summary')
        self.assertEqual(r['request_sha256'],hashlib.sha256(sent[0]).hexdigest())
        self.assertEqual(json.loads(sent[0]),r['wire_request'])
        self.assertEqual(r['usage']['total_tokens'],18)
        self.assertEqual(r['outcome'],'model_validated');self.assertEqual(r['output'],result)
        self.assertIsNone(r['accepted']);self.assertGreaterEqual(r['duration_ms'],0)
        self.assertEqual(r['prompt']['name'],'floweroll/observation-summary')
        self.assertIsNone(pc._ACTIVE.get());self.assertIsNone(pc._ENTITY.get())

    def test_vision_separate_prompt_and_operation(self):
        event={'id':self.eid,'kind':'screen','text':'OCR提示','image_base64':'dGVzdA=='}
        value={'page_type':'test','summary':'画面','key_items':[],'visible_actions':[],'uncertainties':[]}
        with self.scope(),patch('urllib.request.urlopen',return_value=FakeHTTP(envelope(value))):self.model.understand_screen(event)
        r=self.records()[0]
        self.assertEqual(r['operation'],'observation.vision');self.assertEqual(r['prompt']['name'],'floweroll/observation-vision')
        self.assertIn('image_url',json.dumps(r['wire_request']))
        self.assertNotIn('planner.system.txt',r['prompt']['source_path'])

    def test_final_and_question_each_have_independent_calls(self):
        with self.scope(),patch('urllib.request.urlopen',return_value=FakeHTTP(envelope(summary_response(self.eid)))):
            self.model(events=[self.event],notes=[],question='为什么')
            self.model(events=[self.event],notes=[],final=True)
        records=self.records();self.assertEqual({r['operation'] for r in records},{'observation.question','observation.final'})
        self.assertEqual(len({r['capture_id'] for r in records}),2)

    def test_disk_capture_failure_never_changes_model_result(self):
        with self.scope(),patch('urllib.request.urlopen',return_value=FakeHTTP(envelope(summary_response(self.eid)))),patch.object(pc.Capture,'save',side_effect=OSError('disk unavailable')):
            value=self.model(events=[self.event],notes=[])
        self.assertEqual(value['title'],'测试');self.assertIsNone(pc._ACTIVE.get())

    def test_provider_failure_preserved_and_not_retried(self):
        with self.scope(),patch('urllib.request.urlopen',side_effect=OSError('offline')) as http:
            with self.assertRaises(ObservationModelError):self.model(events=[self.event],notes=[])
        self.assertEqual(http.call_count,1)
        r=self.records()[0];self.assertEqual(r['state'],'error');self.assertNotIn('output',r)

    def test_worker_scope_isolated_across_concurrent_sessions(self):
        model=self.model;barrier=threading.Barrier(2)
        class Worker:
            _capture_runtime_db=self.db
            @pc.observation_worker
            def run(self,sid,event):
                barrier.wait(timeout=3);return model(events=[event],notes=[])
        def http(request,**kwargs):
            ctx=json.loads(json.loads(request.data)['messages'][1]['content'][0]['text'])
            return FakeHTTP(envelope(summary_response(ctx['observations'][0]['id'])))
        sid2=str(uuid.uuid4());event2=dict(self.event,id=str(uuid.uuid4()))
        with patch('urllib.request.urlopen',side_effect=http),ThreadPoolExecutor(2) as pool:
            a=pool.submit(Worker().run,self.sid,self.event);b=pool.submit(Worker().run,sid2,event2);a.result();b.result()
        self.assertEqual(self.records()[0]['output']['evidence_ids'],[self.eid])
        self.assertEqual(self.records(sid2)[0]['output']['evidence_ids'],[event2['id']])

    def test_other_runtime_db_does_not_enter_target_capture(self):
        with pc.entity_scope(lifecycle='observation',entity_id=self.sid,runtime_db=self.db+'.other'),patch('urllib.request.urlopen',return_value=FakeHTTP(envelope(summary_response(self.eid)))):
            self.model(events=[self.event],notes=[])
        self.assertEqual(self.records(),[])


class WorkUnitCaptureTests(unittest.TestCase):
    unit=unit_tests.WorkUnitTests.unit
    create_action=unit_tests.WorkUnitTests.create_action
    run_batch=unit_tests.WorkUnitTests.run_batch
    def setUp(self):
        unit_tests.WorkUnitTests.setUp(self)
        self.capture_temp=tempfile.TemporaryDirectory(dir=pc.ROOT/'work',prefix='unit-timing-')
        self.addCleanup(self.capture_temp.cleanup)
        root=Path(self.capture_temp.name);self.captures=root/'captures'
        config=root/'config.json';config.write_text(json.dumps({'mode':'local_full','runtime_db':str(self.store.path),'snapshot_dir':str(self.captures)}))
        env=patch.dict(os.environ,{'FLOWEROLL_OBSERVABILITY_CONFIG':str(config)})
        env.start();self.addCleanup(env.stop);self.addCleanup(pc.flush_for_test)
    def records(self):
        self.assertTrue(pc.flush_for_test());folder=self.captures/'operations/task'/str(uuid.UUID(self.task))
        return [json.loads(p.read_text()) for p in folder.glob('*.json')]
    def test_real_worker_records_independent_parallel_attempts_and_does_not_replay(self):
        barrier=threading.Barrier(2,timeout=4)
        def fetch(args):
            barrier.wait();return {'url':args['url'],'status':200,'text':'test'}
        self.runner.executors['web.fetch']=fetch
        args=[self.unit('a'),self.unit('b')]
        self.run_batch(args)
        records=self.records();self.assertEqual(len(records),2)
        self.assertTrue(all(r['outcome']=='verified' and r['accepted'] is True for r in records))
        a,b=records
        self.assertEqual(a['process_instance'],b['process_instance'])
        self.assertGreater(min(a['ended_monotonic_ns'],b['ended_monotonic_ns'])-max(a['started_monotonic_ns'],b['started_monotonic_ns']),0)
        self.run_batch(args);self.assertEqual(len(self.records()),2)
    def test_failed_unit_receipt_and_capture_agree(self):
        self.runner.executors['web.fetch']=lambda args:(_ for _ in ()).throw(OSError('offline'))
        self.run_batch([self.unit('a'),self.unit('b')])
        self.assertTrue(all(r['outcome']=='failed' and r['accepted'] is True for r in self.records()))


if __name__=='__main__':unittest.main()
