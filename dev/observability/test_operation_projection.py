from __future__ import annotations
import json,os,tempfile,time,unittest,uuid
from pathlib import Path
from unittest.mock import patch
from . import operation_projection as op
from . import exporter
from .execution_paths import observation_path,task_path
from .test_observability import fixture


class OperationProjectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=op.ROOT/'work',prefix='operation-projector-')
        self.root=Path(self.tmp.name);self.sid=str(uuid.uuid4());self.cid=str(uuid.uuid4())
        self.config={'runtime_db':str(self.root/'task.sqlite3'),'snapshot_dir':str(self.root/'captures'),'mode':'local_full'}
        self.folder=self.root/'captures/operations/observation'/self.sid;self.folder.mkdir(parents=True)
        self.record={'lifecycle':'observation','entity_id':self.sid,'runtime_db':self.config['runtime_db'],
            'capture_id':self.cid,'operation':'observation.summary','started_at':'2026-09-16T01:00:00Z',
            'ended_at':'2026-09-16T01:00:01Z','duration_ms':1000,'state':'finished','outcome':'model_validated',
            'usage':{'prompt_tokens':5,'completion_tokens':7,'total_tokens':12},'provider_model':'fixture',
            'attempts':[{'duration_ms':800}],'wire_request':{'model':'fixture','messages':[{'role':'system','content':'EXACT_PROMPT'},{'role':'user','content':'ACTUAL_INPUT'}]},
            'response_text':'{"summary":"RAW_MODEL_RESULT"}'}
        self.file=self.folder/(self.cid+'.json');self.file.write_text(json.dumps(self.record))
    def tearDown(self):self.tmp.cleanup()
    def test_records_lightweight_detail_payload_on_demand(self):
        listing=op.operations(self.config,'observation',self.sid)
        self.assertEqual(len(listing['records']),1)
        self.assertNotIn('wire_request',listing['records'][0])
        detail=op.operation_detail(self.config,'observation',self.sid,self.cid)
        self.assertEqual(detail['system_prompt'],'EXACT_PROMPT')
        self.assertEqual(detail['model_ms'],800)
        self.assertEqual(detail['reported_tokens'],12)
        self.assertEqual(detail['model_response']['summary'],'RAW_MODEL_RESULT')
    def test_metadata_never_recovers_old_full_payload(self):
        config=dict(self.config,mode='metadata')
        detail=op.operation_detail(config,'observation',self.sid,self.cid)
        self.assertFalse(detail['available']);self.assertNotIn('wire_request',detail)
        self.assertNotIn('EXACT_PROMPT',json.dumps(op.operations(config,'observation',self.sid)))
    def test_namespace_mismatch_and_symlink_not_accepted(self):
        self.assertEqual(op.operations(dict(self.config,runtime_db=self.config['runtime_db']+'.other'),'observation',self.sid)['records'],[])
        other=self.folder/(str(uuid.uuid4())+'.json');other.symlink_to(self.file)
        self.assertEqual(len(op.operations(self.config,'observation',self.sid)['records']),1)
        with self.assertRaises(ValueError):op.operations(self.config,'observation','../config.json')
    def test_retention_includes_operation_tree(self):
        old=time.time()-20*86400;os.utime(self.file,(old,old))
        removed=exporter.prune_captures(dict(self.config,retention_days=7))
        self.assertEqual(removed,1);self.assertFalse(self.file.exists())
    def test_observation_counts_captured_calls_not_summaries(self):
        detail={'session':{'id':self.sid,'preset_label':'观察','status':'completed'},
                'stats':{'source_stats':{},'event_count':0,'checkpoint_count':20,'final_count':1,'question_count':0},
                'notes':[],'questions':[],'timeline':[]}
        p=observation_path(detail,'test',operation_records=op.operations(self.config,'observation',self.sid))
        self.assertEqual(p['summary']['captured_model_calls'],1)
        self.assertEqual(p['summary']['reported_tokens_only'],12)
        self.assertEqual(p['model_calls'][0]['capture_id'],self.cid)
        self.assertEqual(sum(s['kind']=='model_call' for s in p['spans']),1)
    def test_overlap_requires_same_process_and_batch(self):
        a={'operation':'work.unit','capture_id':'a','work_unit_id':'a','parent_action_id':'batch','process_instance':'p',
           'started_monotonic_ns':1000000,'ended_monotonic_ns':6000000}
        b=dict(a,capture_id='b',work_unit_id='b',started_monotonic_ns=4000000,ended_monotonic_ns=9000000)
        self.assertEqual(op.overlap_evidence([a,b])[0]['overlap_ms'],2)
        self.assertEqual(op.overlap_evidence([a,dict(b,process_instance='other')]),[])
        self.assertEqual(op.overlap_evidence([a,dict(b,parent_action_id='other')]),[])
        self.assertEqual(op.overlap_evidence([a,dict(b,started_monotonic_ns=8000000)]),[])
    def test_unit_attempts_do_not_create_fake_units_or_double_count(self):
        r={'operation':'work.unit','capture_id':'cap','capability':'weather.query','work_unit_id':'a',
           'parent_action_id':'batch','duration_ms':123,'started_at':'2026-09-16T01:00:00Z','ended_at':'2026-09-16T01:00:01Z','outcome':'verified'}
        p=task_path(fixture(),'test',full=True,operation_records={'records':[r]})
        self.assertIsNone(p['summary']['work_units'])
        self.assertEqual(p['summary']['timed_work_unit_attempts'],1)
        self.assertEqual(p['summary']['reported_tokens_only'],120)
        self.assertEqual(next(s for s in p['spans'] if s['kind']=='work_unit_attempt')['duration_ms'],123)

if __name__=='__main__':unittest.main()
