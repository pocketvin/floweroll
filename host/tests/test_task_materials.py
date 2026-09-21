from __future__ import annotations

import hashlib
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.server import create_server
from floweroll_host.storage import Storage
from floweroll_host.task_assets import MAX_BACKGROUND_UPLOAD_CHUNK_BYTES, TaskAssetStore
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.task_material_tools import register_task_material_capabilities
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker

ROOT = Path(__file__).resolve().parents[2]


class TaskAssetsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Storage(str(Path(self.tmp.name) / 'runtime.sqlite3'))
        self.assets = TaskAssetStore(Path(self.tmp.name) / 'materials', self.store)
        self.store.create_or_get_task(task_id='one', goal='处理附件', invocation_source='unit',
            policy_snapshot={}, submission_id='submission-one', status='active')
        self.store.create_or_get_task(task_id='two', goal='另一个任务', invocation_source='unit',
            policy_snapshot={}, submission_id='submission-two', status='active')

    def tearDown(self):
        self.assets.close(); self.tmp.cleanup()

    def upload(self, fid='input-one', content='履历文本仅为测试'):
        raw = content.encode()
        return self.assets.upload(file_id=fid, name='测试简历.txt', media_type='text/plain',
            data=raw, sha256=hashlib.sha256(raw).hexdigest())

    def test_upload_replay_is_immutable(self):
        first = self.upload()
        self.assertEqual(self.upload(), first)
        with self.assertRaises(ValueError): self.upload(content='changed')

    def test_resumable_upload_survives_store_reopen_and_publishes_once(self):
        data=(b'resumable material ' * 20000)[:300000]
        digest=hashlib.sha256(data).hexdigest()
        created=self.assets.begin_resumable_upload(file_id='resume-offset',name='resume.txt',
            media_type='text/plain',expected_size=len(data),sha256=digest)
        self.assertEqual(created['offset'],0)
        first=data[:128*1024]
        state=self.assets.append_resumable_upload(file_id='resume-offset',offset=0,data=first,complete=False)
        self.assertEqual(state['offset'],len(first));self.assertFalse(state['complete'])
        self.assets.close();self.assets=TaskAssetStore(Path(self.tmp.name)/'materials',self.store)
        recovered=self.assets.resumable_upload_state('resume-offset')
        self.assertEqual(recovered['offset'],len(first));self.assertFalse(recovered['complete'])
        with self.assertRaisesRegex(RuntimeError,'UPLOAD_OFFSET_MISMATCH'):
            self.assets.append_resumable_upload(file_id='resume-offset',offset=0,data=b'x',complete=False)
        final=self.assets.append_resumable_upload(file_id='resume-offset',offset=len(first),
            data=data[len(first):],complete=True)
        self.assertTrue(final['complete']);self.assertEqual(final['offset'],len(data))
        self.assertEqual(final['file']['sha256'],digest)
        replay=self.assets.begin_resumable_upload(file_id='resume-offset',name='resume.txt',
            media_type='text/plain',expected_size=len(data),sha256=digest)
        self.assertTrue(replay['complete']);self.assertEqual(replay['offset'],len(data))

    def test_background_range_can_exceed_foreground_chunk_without_relaxing_default(self):
        data=(b'background-range-material ' * 30000)[:600000]
        digest=hashlib.sha256(data).hexdigest()
        self.assets.begin_resumable_upload(file_id='background-range',name='background.txt',
            media_type='text/plain',expected_size=len(data),sha256=digest)
        with self.assertRaisesRegex(ValueError,'上传分段超过大小限制'):
            self.assets.append_resumable_upload(file_id='background-range',offset=0,data=data,complete=True)
        self.assertEqual(self.assets.resumable_upload_state('background-range')['offset'],0)
        final=self.assets.append_resumable_upload(file_id='background-range',offset=0,data=data,complete=True,
            max_chunk_bytes=MAX_BACKGROUND_UPLOAD_CHUNK_BYTES)
        self.assertTrue(final['complete']);self.assertEqual(final['offset'],len(data))
        self.assertEqual(final['file']['sha256'],digest)

    def test_replayed_begin_verifies_full_staged_prefix_after_publication_interruption(self):
        data = b'complete bytes without a published receipt'; digest = hashlib.sha256(data).hexdigest()
        kwargs = dict(file_id='staged-complete', name='staged.txt', media_type='text/plain',
                      expected_size=len(data), sha256=digest)
        self.assets.begin_resumable_upload(**kwargs)
        self.assets.append_resumable_upload(file_id='staged-complete', offset=0, data=data, complete=False)
        self.assertFalse(self.assets.resumable_upload_state('staged-complete')['complete'])
        replay = self.assets.begin_resumable_upload(**kwargs)
        self.assertTrue(replay['complete'])
        self.assertEqual(replay['file']['sha256'], digest)
        self.assertEqual(self.assets.begin_resumable_upload(**kwargs), replay)

    def test_bad_hash_is_rejected(self):
        with self.assertRaises(ValueError):
            self.assets.upload(file_id='x', name='x.txt', media_type='text/plain', data=b'hello', sha256='wrong')

    def test_spoofed_media_type_is_rejected(self):
        raw = b'<script>invalid</script>'
        with self.assertRaises(ValueError):
            self.assets.upload(file_id='x', name='x.pdf', media_type='application/pdf', data=raw, sha256=hashlib.sha256(raw).hexdigest())

    def test_path_traversal_identifier_rejected(self):
        for fid in ('../one', '/one', 'a/b', 'x%2fy', '', 'a'*101):
            with self.subTest(fid=fid), self.assertRaises(ValueError): self.upload(fid=fid)

    def test_only_current_task_and_explicit_lineage_can_read_input(self):
        item=self.upload(); self.assets.bind('submission:submission-one', [item['id']])
        self.assertTrue(self.assets.file_path('one',item['id']).exists())
        with self.assertRaises(KeyError): self.assets.file_path('two',item['id'])

    def test_binding_replay_cannot_replace_or_drop_attachments(self):
        item=self.upload(); self.assets.bind('submission:submission-one',[item['id']])
        self.assets.bind('submission:submission-one',[item['id']])
        with self.assertRaises(ValueError): self.assets.bind('submission:submission-one',[])

    def test_unadmitted_turn_does_not_expose_attachment(self):
        item=self.upload(); self.assets.bind('turn:one:event-one',[item['id']])
        self.assertEqual(self.assets.input_ids('one'),[])
        self.store.admit_inbox_event(task_id='one',event_id='event-one',event_type='USER_TURN',source='user',
            payload={'content':{'kind':'text','text':'看看附件'}})
        self.assertEqual(self.assets.input_ids('one'),[item['id']])

    def test_restart_retains_input_binding(self):
        self.upload(); self.assets.bind('submission:submission-one',['input-one'])
        self.assets.close(); self.assets=TaskAssetStore(Path(self.tmp.name)/'materials',self.store)
        self.assertEqual(self.assets.input_ids('one'),['input-one'])
        provenance = self.assets.manifest('one')['input_provenance']
        self.assertEqual(len(provenance), 1)
        self.assertEqual(provenance[0]['source_kind'], 'submission')
        self.assertEqual(provenance[0]['source_id'], 'submission-one')
        self.assertEqual(provenance[0]['file_ids'], ['input-one'])
        self.assertEqual(provenance[0]['files'][0]['sha256'], self.assets.get('input-one')['sha256'])

    def test_progressive_output_is_delivery_only_until_action_verifies(self):
        item = self.assets.publish_bytes(
            task_id='one', action_id='scan-action', name='scan.pdf',
            media_type='application/pdf', data=b'%PDF-staged', category='document',
            metadata={'status':'processing','quality_status':'processing','structural_verified':True},
        )
        progress = self.assets.set_output_progress(
            task_id='one', action_id='scan-action', file_id=item['id'],
            phase='ocr_processing', status='processing',
            detail={'pdf_status':'ready','ocr_status':'processing'},
        )
        self.assertEqual(progress['detail']['pdf_status'], 'ready')
        manifest = self.assets.manifest('one')
        self.assertEqual(manifest['outputs'], [])
        self.assertEqual(len(manifest['progressive_outputs']), 1)
        self.assertEqual(manifest['progressive_outputs'][0]['id'], item['id'])
        self.assertEqual(manifest['progressive_outputs'][0]['progress']['phase'], 'ocr_processing')
        self.assertEqual(self.assets.delivery_file_path('one', item['id']).read_bytes(), b'%PDF-staged')
        with self.assertRaises(KeyError):
            self.assets.file_path('one', item['id'])
        with self.assertRaises(KeyError):
            self.assets.delivery_file_path('two', item['id'])
        self.assets.close(); self.assets=TaskAssetStore(Path(self.tmp.name)/'materials',self.store)
        recovered = self.assets.manifest('one')['progressive_outputs']
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0]['progress']['detail']['ocr_status'], 'processing')

    def test_progressive_delivery_guard_rejects_unverified_non_pdf_or_not_ready(self):
        cases = [
            ('not-structural', 'application/pdf', {'structural_verified': False}, {'pdf_status':'ready'}),
            ('not-ready', 'application/pdf', {'structural_verified': True}, {'pdf_status':'processing'}),
            ('non-pdf', 'text/html', {'structural_verified': True}, {'pdf_status':'ready'}),
        ]
        for action_id, media_type, metadata, detail in cases:
            with self.subTest(action_id=action_id):
                data = b'%PDF-guard' if media_type == 'application/pdf' else b'<html></html>'
                item = self.assets.publish_bytes(
                    task_id='one', action_id=action_id,
                    name='guard.pdf' if media_type == 'application/pdf' else 'guard.html',
                    media_type=media_type, data=data, category='document',
                    metadata={'status':'processing', **metadata},
                )
                self.assets.set_output_progress(
                    task_id='one', action_id=action_id, file_id=item['id'],
                    phase='ocr_processing', status='processing',
                    detail={**detail, 'ocr_status':'processing'},
                )
                with self.assertRaises(KeyError):
                    self.assets.delivery_file_path('one', item['id'])

        with self.assertRaises(KeyError):
            self.assets.delivery_file_path('one', 'missing-file')

    def test_progressive_delivery_rejects_sibling_task_without_lineage(self):
        item = self.assets.publish_bytes(
            task_id='one', action_id='parent-scan', name='parent.pdf',
            media_type='application/pdf', data=b'%PDF-parent', category='document',
            metadata={'status':'processing','structural_verified':True},
        )
        self.assets.set_output_progress(
            task_id='one', action_id='parent-scan', file_id=item['id'],
            phase='ocr_processing', status='processing',
            detail={'pdf_status':'ready','ocr_status':'processing'},
        )
        with self.assertRaises(KeyError):
            self.assets.delivery_file_path('two', item['id'])

    def test_file_tampering_even_same_size_is_rejected(self):
        self.upload(content='abc'); self.assets.bind('submission:submission-one',['input-one'])
        path=self.assets.file_path('one','input-one'); path.write_bytes(b'def')
        with self.assertRaises(ValueError): self.assets.file_path('one','input-one')

    def test_unverified_output_never_appears_as_delivered(self):
        item=self.assets.publish_bytes(task_id='one',action_id='not-verified',name='draft.html',
            media_type='text/html',data=b'draft',category='study',metadata={'status':'ready'})
        self.assertEqual(self.assets.manifest('one')['outputs'],[])
        with self.assertRaises(KeyError): self.assets.file_path('one',item['id'])

    def test_plan_rejects_cycles_and_unknown_dependency(self):
        for items in ([{'id':'a','title':'A','depends_on':['b']},{'id':'b','title':'B','depends_on':['a']}],
                      [{'id':'a','title':'A','depends_on':['missing']}],
                      [{'id':'a','title':'A'},{'id':'a','title':'B'}]):
            with self.assertRaises(ValueError): self.assets.save_plan('one','计划',items)

    def test_same_plan_replay_is_idempotent_without_moving_timestamp(self):
        self.assets.save_plan(
            'one',
            '面试准备',
            [{'id':'resume','title':'扫描PDF','depends_on':[]}],
        )
        before = self.assets.db.execute(
            "SELECT updated_at FROM plans WHERE task_id=?",
            ('one',),
        ).fetchone()['updated_at']
        replay = self.assets.save_plan(
            'one',
            '面试准备',
            [{'id':'resume','title':'扫描PDF','depends_on':[]}],
        )
        after = self.assets.db.execute(
            "SELECT updated_at FROM plans WHERE task_id=?",
            ('one',),
        ).fetchone()['updated_at']
        self.assertTrue(replay['idempotent_replay'])
        self.assertEqual(after, before)

    def test_publish_bytes_same_action_replay_requires_identical_artifact(self):
        first = self.assets.publish_bytes(
            task_id='one',
            action_id='action-replay',
            name='结果.md',
            media_type='text/markdown',
            data=b'first',
            category='report',
            metadata={'kind':'general'},
        )
        replay = self.assets.publish_bytes(
            task_id='one',
            action_id='action-replay',
            name='结果.md',
            media_type='text/markdown',
            data=b'first',
            category='report',
            metadata={'kind':'general'},
        )
        self.assertEqual(replay['id'], first['id'])
        self.assertEqual(replay['sha256'], first['sha256'])

        with self.assertRaisesRegex(ValueError, '输出重放与已保存成果不一致'):
            self.assets.publish_bytes(
                task_id='one',
                action_id='action-replay',
                name='结果.md',
                media_type='text/markdown',
                data=b'different',
                category='report',
                metadata={'kind':'general'},
            )

    def test_plan_accepts_real_dependencies(self):
        result=self.assets.save_plan('one','面试准备',[{'id':'resume','title':'扫描PDF'},
            {'id':'study','title':'学习计划','depends_on':['resume']}])
        self.assertEqual(len(result['items']),2)
        self.assertEqual(self.assets.manifest('one')['plan']['title'],'面试准备')


class MaterialRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.store=Storage(':memory:')
        self.assets=TaskAssetStore(Path(self.tmp.name)/'materials',self.store)
        self.registry=CapabilityRegistry()
        self.executors=register_task_material_capabilities(self.registry, assets=self.assets,
            helpers=ROOT/'host/native_helpers', runtime_dir=Path(self.tmp.name)/'native')
        self.execution=ExecutionRuntime(self.store,self.registry.execution_adapters())
        self.worker=FunctionExecutionWorker(self.execution,self.registry,self.executors)
        self.store.create_or_get_task(task_id='test-task', goal='准备面试', invocation_source='unit',
            policy_snapshot={},submission_id='sub',status='active')
        data='测试简历：Python、FastAPI；没有提供面试时间和酒店预算。'.encode()
        self.assets.upload(file_id='resume',name='resume.txt',media_type='text/plain',data=data,sha256=hashlib.sha256(data).hexdigest())
        self.assets.bind('submission:sub',['resume'])

    def tearDown(self): self.assets.close(); self.tmp.cleanup()

    def execute(self,capability,args):
        self.store.create_action(action_id='act',task_id='test-task',step_index=1,action_type=capability,
            payload=args,expected={},idempotency_key='one',on_verified='COMPLETE')
        self.worker.run_once('test-task')
        return self.store.action_attempts('act')[0]

    def test_real_text_attachment_through_attempt_observation(self):
        attempt=self.execute('materials.inspect',{'file_ids':['resume']})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS')
        obs=self.store.verified_observations('test-task')[0]['data']
        self.assertIn('FastAPI',obs['materials'][0]['text'])
        self.assertNotIn(str(Path(self.tmp.name)),json.dumps(obs))

    def test_report_file_only_visible_after_runtime_verification(self):
        attempt=self.execute('deliverables.publish',{'title':'学习计划','sections':[{'heading':'复习','body':'先讲清 Python 项目。'}],
            'kind':'study','source_urls':[],'status':'draft','item_id':'study'})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS')
        files=self.assets.manifest('test-task')['outputs']
        self.assertEqual(len(files),2)
        self.assertTrue(self.assets.file_path('test-task',files[0]['id']).exists())
        self.assertEqual(files[0]['metadata']['status'],'draft')

    def test_hotel_report_cannot_claim_booked(self):
        self.execute('deliverables.publish',{'title':'住宿方案','sections':[{'heading':'候选','body':'尚未查询房价，请补充预算。'}],
            'kind':'hotel','source_urls':[],'status':'ready','missing_information':['预算']})
        item=self.assets.manifest('test-task')['outputs'][0]
        self.assertEqual(item['metadata']['status'],'handoff_required')
        self.assertEqual(item['metadata']['booking_status'],'not_booked')

    def test_fabricated_source_is_model_correctable_not_success(self):
        attempt=self.execute('deliverables.publish',{'title':'研究','sections':[{'heading':'来源','body':'未知事实'}],
            'kind':'company','source_urls':['https://made-up.invalid'],'status':'ready'})
        self.assertEqual(attempt['latest_outcome'],'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(self.assets.manifest('test-task')['outputs'],[])

    def test_report_escapes_scripts(self):
        self.execute('deliverables.publish',{'title':'<img src=x>','sections':[{'heading':'安全','body':'<script>alert(1)</script>'}],
            'kind':'study','source_urls':[],'status':'draft'})
        item=next(x for x in self.assets.manifest('test-task')['outputs'] if x['media_type']=='text/html')
        body=self.assets.file_path('test-task',item['id']).read_text()
        self.assertNotIn('<script>',body); self.assertIn('&lt;script&gt;',body)
        self.assertIn('Content-Security-Policy',body)


class MaterialHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.server=create_server('127.0.0.1',0,str(Path(self.tmp.name)/'runtime.sqlite'),
            auth_token='test-pair-token',task_asset_root=Path(self.tmp.name)/'materials')
        self.server.app.supervisor.stop()
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.url='http://127.0.0.1:'+str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join(2);self.tmp.cleanup()

    def request(self,path,*,data=None,headers=None,authenticated=True):
        h={'Authorization':'Bearer test-pair-token'} if authenticated else {}
        h.update(headers or {})
        if isinstance(data,dict): data=json.dumps(data).encode();h['Content-Type']='application/json'
        req=urllib.request.Request(self.url+path,data=data,headers=h)
        try:
            with urllib.request.urlopen(req,timeout=5) as result: return result.status,result.read()
        except urllib.error.HTTPError as exc: return exc.code,exc.read()

    def upload(self):
        content=b'resume fixture'
        return self.request('/v1/files',data=content,headers={'Content-Type':'text/plain','X-File-ID':'resume',
            'X-File-Name':'resume.txt','X-Content-SHA256':hashlib.sha256(content).hexdigest()})

    def submit(self,ids=None,submission='http-sub'):
        return self.request('/v1/tasks',data={'submission_id':submission,'input':{'kind':'text','text':'处理附件','attachment_ids':ids or []},'invocation_source':'unit'})

    def test_upload_submission_manifest_download_roundtrip(self):
        self.assertEqual(self.upload()[0],201)
        code,body=self.submit(['resume']);self.assertEqual(code,201)
        task=json.loads(body)['task_id']
        code,body=self.request(f'/v1/tasks/{task}/materials');self.assertEqual(code,200)
        self.assertEqual(json.loads(body)['inputs'][0]['id'],'resume')
        self.assertEqual(self.request(f'/v1/tasks/{task}/files/resume'),(200,b'resume fixture'))
        self.assertEqual(self.submit(['resume'])[0],200)
        self.assertEqual(len(self.server.app.storage.list_tasks()['items']),1)

    def test_attachment_endpoint_requires_auth(self):
        self.assertEqual(self.request('/v1/files',data=b'x',authenticated=False)[0],401)

    def test_missing_attachment_does_not_create_task(self):
        self.assertEqual(self.submit(['missing'])[0],400)
        self.assertEqual(len(self.server.app.storage.list_tasks()['items']),0)

    def test_cross_task_download_denied(self):
        self.upload();self.submit(['resume'])
        _,body=self.submit([],submission='other');tid=json.loads(body)['task_id']
        self.assertEqual(self.request(f'/v1/tasks/{tid}/files/resume')[0],404)

    def test_changes_to_replayed_attachment_set_fail(self):
        self.upload();self.submit(['resume'])
        self.assertEqual(self.submit([])[0],400)

    def test_task_bound_turn_attachment_roundtrip(self):
        self.upload();_,body=self.submit([]);tid=json.loads(body)['task_id']
        code,_=self.request(f'/v1/tasks/{tid}/turns',data={'event_id':'turn-test','content':{
            'kind':'text','text':'这份简历也看看','attachment_ids':['resume']}})
        self.assertEqual(code,202)
        _,body=self.request(f'/v1/tasks/{tid}/materials')
        self.assertEqual(json.loads(body)['inputs'][0]['id'],'resume')

if __name__=='__main__': unittest.main()
