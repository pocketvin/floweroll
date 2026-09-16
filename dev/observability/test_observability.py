from __future__ import annotations
from contextlib import closing
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch, Mock
import uuid

from . import exporter as ex
from . import projector as pr


def fixture():
    tid = '12345678-1234-4234-8234-123456789abc'
    def trace(i, event, sec, data):
        return {'id': i, 'task_id': tid, 'event_type': event, 'created_at': f'2026-09-14T01:00:{sec:02d}+00:00', 'data_json': json.dumps(data)}
    return {'task': {'id': tid, 'goal': '计算测试', 'thread_id': tid, 'parent_task_id': None,
                    'status': 'completed', 'created_at': '2026-09-14T01:00:00+00:00', 'updated_at': '2026-09-14T01:00:03+00:00'},
            'runtime': {'phase': 'completed', 'runtime_revision': 3},
            'traces': [trace(1,'planner.call.started',0,{'call_number':1}),
                       trace(2,'planner.call.metrics',1,{'call_number':1,'provider_model':'test','model_ms':1000,'total_tokens':120,'prompt_tokens':100,'completion_tokens':20}),
                       trace(3,'planner.decision',1,{'decision_id':'decision1'}),
                       trace(4,'planner.call.committed',1,{'call_number':1}),
                       trace(5,'task.completed',3,{})],
            'actions': [], 'attempts': [],
            'decisions': [{'id':'decision1','decision_json':'{"decision_type":"COMPLETE"}'}], 'captures': {}}


class ProjectionTests(unittest.TestCase):
    def test_stable_ids_and_parent_trace_identity(self):
        s=fixture(); a=pr.build_spans(s,'test'); b=pr.build_spans(copy.deepcopy(s),'test')
        self.assertEqual(a,b)
        self.assertEqual(len({r['span_id'] for r in a}),len(a))
        self.assertEqual(len({r['trace_id'] for r in a}),1)
        self.assertNotEqual(a[0]['trace_id'],pr.build_spans(s,'other-db')[0]['trace_id'])

    def test_historical_prompt_is_explicitly_unavailable(self):
        rows=pr.build_spans(fixture(),'test')
        p=next(x for x in rows if x['key']=='planner:1')
        self.assertIn('not captured',p['attributes']['langfuse.observation.input'])
        self.assertNotIn('prompt.version',json.dumps(p))
        self.assertEqual(p['attributes']['gen_ai.usage.input_tokens'],100)

    def test_equivalent_timezones_have_equal_ns(self):
        self.assertEqual(pr.timestamp('2026-09-14T09:00:00+08:00'),pr.timestamp('2026-09-14T01:00:00Z'))

    def test_recovery_event_is_not_task_success(self):
        s=fixture(); s['task']['status']='blocked'; s['runtime']['phase']='planning'
        s['traces'][4].update(event_type='planner.retry_resumed')
        rows=pr.build_spans(s,'test'); summary=json.loads(rows[0]['attributes']['langfuse.observation.output'])
        self.assertEqual(summary['task_status'],'blocked')
        self.assertTrue(any('不等于' in x['claim'] for x in summary['layer_evidence']))
        self.assertIsNone(summary['cost'])
        self.assertIn('Prompt quality',summary['not_automatically_evaluated'])

    def test_v4_does_not_export_unfinished_generation_or_root(self):
        s=fixture(); s['task']['status']='active'; s['traces']=s['traces'][:1]
        ready=pr.ready_records(s,pr.build_spans(s,'test'))
        self.assertFalse(any(r['key'] in ('task','planner:1') for r in ready))
        self.assertTrue(any(r['key'].startswith('state:') for r in ready))
        s['captures'][1]={'request_sha256':'a','wire_request':{'model':'test','messages':[]},'mode':'local_full'}
        ready=pr.ready_records(s,pr.build_spans(s,'test'))
        req=next(r for r in ready if r['key']=='request:1')
        self.assertEqual(req['attributes']['langfuse.observation.type'],'event')
        self.assertNotIn('gen_ai.usage.input_tokens',req['attributes'])

    def test_finished_generation_emitted_after_commit(self):
        s=fixture(); ready=pr.ready_records(s,pr.build_spans(s,'test'))
        self.assertEqual(len([r for r in ready if r['key']=='planner:1']),1)
        self.assertEqual(len([r for r in ready if r['key']=='task']),1)

    def test_readonly_never_creates_or_changes_database(self):
        with tempfile.TemporaryDirectory(dir=ex.ROOT/'work') as td:
            p=Path(td)/'db.sqlite'
            with self.assertRaises(sqlite3.OperationalError):pr.readonly(p)
            self.assertFalse(p.exists())
            with sqlite3.connect(p) as c:c.execute('CREATE TABLE sample(value TEXT)')
            digest=hashlib.sha256(p.read_bytes()).hexdigest()
            with closing(pr.readonly(p)) as c:
                with self.assertRaises(sqlite3.OperationalError):c.execute("INSERT INTO sample VALUES ('bad')")
            self.assertEqual(hashlib.sha256(p.read_bytes()).hexdigest(),digest)


class FakeSink:
    def __init__(self):self.sent=[];self.present=set();self.succeed=True
    def existing_ids(self,*args):return set(self.present)
    def send(self,rows):
        self.sent.extend(rows)
        if self.succeed:self.present.update(r['span_id'] for r in rows)
        return self.succeed
    def prompt(self,text):return 1


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=ex.ROOT/'work',prefix='otel-tests-')
        self.root=Path(self.tmp.name)
        self.p=patch.object(ex,'WORK',self.root);self.p.start()
        self.config={'runtime_db':str(self.root/'runtime.sqlite'),'snapshot_dir':str(self.root/'captures'),
                     'mode':'local_full','langfuse_url':'http://localhost:3033'}
        self.s=fixture(); self.sink=FakeSink()
        self.load=patch.object(ex,'load_task',side_effect=lambda *a:self.s);self.load.start()
    def tearDown(self):self.load.stop();self.p.stop();self.tmp.cleanup()
    def sync(self):return ex.sync(self.config,self.sink,task_id=self.s['task']['id'])

    def test_normal_repeat_and_changed_task_never_double_count_generation(self):
        first=self.sync();second=self.sync()
        self.assertGreater(first['spans_acknowledged'],0);self.assertEqual(second['spans_acknowledged'],0)
        self.s['runtime']['runtime_revision']+=1
        self.sync()
        self.assertEqual(sum(r['key']=='planner:1' for r in self.sink.sent),1)

    def test_lost_local_checkpoint_reconciles_by_v2_readback(self):
        self.sync();count=len(self.sink.sent)
        (self.root/'export-state.json').unlink()
        self.sync();self.assertEqual(len(self.sink.sent),count)

    def test_failure_does_not_ack_or_change_runtime(self):
        before=copy.deepcopy(self.s);self.sink.succeed=False
        r=self.sync();self.assertEqual(r['export_failures'],1)
        self.assertFalse((self.root/'export-state.json').exists())
        self.assertEqual(self.s,before)
        self.sink.succeed=True;self.assertGreater(self.sync()['spans_acknowledged'],0)

    def test_cloud_endpoint_and_paths_outside_work_are_rejected(self):
        for url in ('https://cloud.langfuse.com','http://example.test','http://localhost:3033/redirect','http://user:secret@localhost:3033'):
            cfg=dict(self.config,langfuse_url=url)
            (self.root/'config.json').write_text(json.dumps(cfg))
            with self.subTest(url=url),self.assertRaises(ValueError):ex.load_config()
        (self.root/'config.json').write_text(json.dumps(self.config))
        self.assertEqual(ex.load_config()['mode'],'local_full')

    def test_metadata_export_removes_content_and_secret_names(self):
        from opentelemetry.sdk.trace.export import SpanExportResult
        sink=object.__new__(ex.Sink);sink.secrets=('SECRET_NAME',);sink.config=dict(self.config,mode='metadata')
        sink.exporter=Mock();sink.exporter.export.return_value=SpanExportResult.SUCCESS
        self.s['task']['goal']='SECRET_NAME'
        sink.send(pr.build_spans(self.s,'test'))
        spans=sink.exporter.export.call_args.args[0]
        for span in spans:
            self.assertNotIn('langfuse.observation.input',span.attributes)
            self.assertNotIn('langfuse.observation.output',span.attributes)
            self.assertNotIn('SECRET_NAME',span.name)

    def test_offline_replay_no_model_or_tool_calls(self):
        schema={'type':'object','properties':{'ok':{'type':'boolean'}},'required':['ok']}
        self.s['captures'][1]={'wire_request':{'response_format':{'json_schema':{'schema':schema}}},'response_text':'{"ok":true}'}
        r=ex.replay(self.config,self.s['task']['id'])
        self.assertEqual((r['checked'],r['passed'],r['model_calls'],r['tool_calls']),(1,1,0,0))
        self.s['captures'][1]['response_text']='{"ok":"wrong"}'
        self.assertEqual(ex.replay(self.config,self.s['task']['id'])['passed'],0)

    def test_empty_replay_is_not_quality_pass(self):
        r=ex.replay(self.config,self.s['task']['id'])
        self.assertEqual(r['conclusion'],'NO_CAPTURED_RESPONSES')

    def test_overlapping_sync_never_exports_or_changes_checkpoint(self):
        import fcntl
        with (self.root/'export.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result=self.sync()
            self.assertTrue(result['skipped_locked'])
            self.assertEqual(result['spans_acknowledged'],0)
            self.assertEqual(self.sink.sent,[])
            self.assertFalse((self.root/'export-state.json').exists())


if __name__=='__main__':unittest.main()
