from __future__ import annotations
import hashlib
import http.client
import json
import platform
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path
from urllib.parse import quote
from unittest.mock import patch

from floweroll_host.mac_perception_tools import MacPerceptionToolSet
from floweroll_host.server import create_server
from floweroll_host.storage import Storage
from floweroll_host.task_assets import TaskAssetStore

class MaterialDeliveryE2ETests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.server = create_server('127.0.0.1',0,str(self.root/'tasks.sqlite3'),
            auth_token='test-pairing',task_asset_root=self.root/'workspace')
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.addCleanup(self.cleanup)
    def cleanup(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=5);self.temp.cleanup()
    def request(self,method,path,body=None,headers=None,authorized=True):
        conn=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=120)
        h={'Authorization':'Bearer test-pairing'} if authorized else {}
        if isinstance(body,dict): body=json.dumps(body).encode();h['Content-Type']='application/json'
        h.update(headers or {})
        conn.request(method,path,body=body,headers=h)
        response=conn.getresponse();data=response.read();status=response.status;conn.close()
        return status,data
    def request_with_headers(self,method,path,body=None,headers=None,authorized=True):
        conn=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=120)
        h={'Authorization':'Bearer test-pairing'} if authorized else {}
        if isinstance(body,dict): body=json.dumps(body).encode();h['Content-Type']='application/json'
        h.update(headers or {})
        conn.request(method,path,body=body,headers=h)
        response=conn.getresponse();data=response.read();status=response.status
        response_headers={key.lower():value for key,value in response.getheaders()}
        conn.close();return status,data,response_headers
    def upload(self,data=b'Example applicant: Python and Agent development.',media='text/plain',fid=None):
        fid=fid or uuid.uuid4().hex
        status,body=self.request('POST','/v1/files',data,{'X-File-ID':fid,'X-File-Name':quote('简历.txt'),
            'Content-Type':media,'X-Content-SHA256':hashlib.sha256(data).hexdigest()})
        self.assertEqual(status,201,body);return json.loads(body)
    def task(self,files,submission=None,parent=None):
        status,body=self.request('POST','/v1/tasks',{'submission_id':submission or uuid.uuid4().hex,
            'input':{'kind':'text','text':'Prepare the supplied materials.','attachment_ids':files},
            'invocation_source':'test_material_delivery','parent_task_id':parent})
        self.assertIn(status,[200,201],body);return json.loads(body)
    def action(self,task_id,cap,args,complete=False):
        store=self.server.app.storage;aid=uuid.uuid4().hex
        existing=store.get_open_action(task_id)
        self.assertIsNone(existing,'test needs no open prior action')
        store.create_action(action_id=aid,task_id=task_id,step_index=int(time.time()*1000),action_type=cap,
            payload=args,expected={},idempotency_key=aid,on_verified='COMPLETE' if complete else 'REPLAN')
        self.server.app.function_worker.run_once(task_id)
        return store.action_attempts(aid)[0]
    def scan_image_fixture(self):
        synthetic=self.root/'a16-synthetic';synthetic.mkdir(exist_ok=True)
        script=Path(__file__).resolve().parent/'fixtures/document_quality/SyntheticDocumentFixtures.swift'
        subprocess.run(['/usr/bin/xcrun','swift',str(script),str(synthetic)],
            check=True,capture_output=True,text=True,timeout=60)
        return (synthetic/'03-edge-content.png').read_bytes()
    def test_host_preserves_injected_empty_registry_when_adding_material_tools(self):
        from floweroll_host.capability_registry import CapabilityRegistry
        from floweroll_host.task_runtime import TaskRuntime
        registry=CapabilityRegistry()
        server=create_server('127.0.0.1',0,':memory:',capability_registry=registry,
            task_asset_root=self.root/'injected-empty-registry',
            task_runtime_factory=lambda storage:TaskRuntime(storage,object(),registry.planner_capabilities()))
        try:
            self.assertIs(server.app.capability_registry,registry)
            self.assertIn('materials.inspect',[x.name for x in server.app.task_runtime.capabilities])
        finally:server.server_close()

    def test_public_report_schema_has_one_body_and_enumerated_category(self):
        spec=self.server.app.capability_registry.get('deliverables.publish').spec
        self.assertEqual(spec.post_verify_mode,'COMPLETE_ALLOWED')
        props=spec.arguments_schema['properties']
        self.assertIn('study',props['category']['enum'])
        self.assertNotIn('kind',props)
        self.assertNotIn('sections',props)
        self.assertIn('markdown',spec.arguments_schema['required'])

    def test_occupied_port_keeps_bind_error_and_cleans_up_partial_server(self):
        with self.assertRaises(OSError):
            create_server('127.0.0.1', self.server.server_port, str(self.root/'occupied.sqlite3'))

    def test_unauthorized_upload_and_download_are_rejected(self):
        self.assertEqual(self.request('POST','/v1/files',b'data',authorized=False)[0],401)
        f=self.upload();t=self.task([f['id']])
        self.assertEqual(self.request('GET',f"/v1/files/{f['id']}",authorized=False)[0],401)
        self.assertEqual(self.request('GET',f"/v1/tasks/{t['task_id']}/files/{f['id']}",authorized=False)[0],401)

    def test_unbound_input_upload_has_idempotent_readback_receipt(self):
        data=b'attachment acknowledgement recovery fixture';fid=uuid.uuid4().hex
        digest=hashlib.sha256(data).hexdigest();uploaded=self.upload(data,'text/plain',fid)
        status,raw=self.request('GET',f'/v1/files/{fid}')
        self.assertEqual(status,200,raw);receipt=json.loads(raw)
        self.assertEqual(receipt['id'],fid);self.assertEqual(receipt['sha256'],digest)
        self.assertEqual(receipt['size_bytes'],len(data));self.assertEqual(receipt['category'],'input')
        replay=self.upload(data,'text/plain',fid)
        self.assertEqual(replay['id'],uploaded['id']);self.assertEqual(replay['sha256'],uploaded['sha256'])
        self.assertEqual(self.request('GET','/v1/files/not-present')[0],404)

    def test_resumable_upload_roundtrip_uses_durable_offset_and_final_readback(self):
        data=(b'chunked attachment\n' * 18000)[:300000]
        fid=uuid.uuid4().hex
        digest=hashlib.sha256(data).hexdigest()
        common={
            'X-File-ID':fid,'X-File-Name':quote('resume.txt'),
            'X-File-Media-Type':'text/plain','X-Content-SHA256':digest,
            'Upload-Length':str(len(data)),
        }
        status,raw,_=self.request_with_headers('POST','/v1/files/uploads',headers=common)
        self.assertEqual(status,201,raw)
        created=json.loads(raw);self.assertEqual(created['offset'],0);self.assertFalse(created['complete'])

        status,_,headers=self.request_with_headers('HEAD',f'/v1/files/uploads/{fid}')
        self.assertEqual(status,204);self.assertEqual(headers['upload-offset'],'0')
        first=data[:128*1024]
        status,_,headers=self.request_with_headers('PATCH',f'/v1/files/uploads/{fid}',first,{
            'Content-Type':'application/offset+octet-stream','Upload-Offset':'0','Upload-Complete':'?0'})
        self.assertEqual(status,204);self.assertEqual(int(headers['upload-offset']),len(first))

        # Repeating an already-committed offset is rejected with the durable Host offset.
        status,_,headers=self.request_with_headers('PATCH',f'/v1/files/uploads/{fid}',first,{
            'Content-Type':'application/offset+octet-stream','Upload-Offset':'0','Upload-Complete':'?0'})
        self.assertEqual(status,409);self.assertEqual(int(headers['upload-offset']),len(first))
        status,_,headers=self.request_with_headers('HEAD',f'/v1/files/uploads/{fid}')
        self.assertEqual(int(headers['upload-offset']),len(first))

        offset=len(first)
        while offset < len(data):
            chunk=data[offset:offset+128*1024];final=offset+len(chunk)==len(data)
            status,_,headers=self.request_with_headers('PATCH',f'/v1/files/uploads/{fid}',chunk,{
                'Content-Type':'application/offset+octet-stream','Upload-Offset':str(offset),
                'Upload-Complete':'?1' if final else '?0'})
            self.assertEqual(status,204);offset=int(headers['upload-offset'])
        self.assertEqual(offset,len(data))
        status,_,headers=self.request_with_headers('HEAD',f'/v1/files/uploads/{fid}')
        self.assertEqual(status,204);self.assertEqual(headers['upload-complete'],'?1')
        status,raw=self.request('GET',f'/v1/files/{fid}')
        self.assertEqual(status,200,raw);receipt=json.loads(raw)
        self.assertEqual(receipt['sha256'],digest);self.assertEqual(receipt['size_bytes'],len(data))

    def test_authenticated_background_range_finishes_in_one_system_owned_patch(self):
        data=(b'background urlsession payload\n' * 30000)[:600000]
        fid=uuid.uuid4().hex
        digest=hashlib.sha256(data).hexdigest()
        common={
            'X-File-ID':fid,'X-File-Name':quote('background.txt'),
            'X-File-Media-Type':'text/plain','X-Content-SHA256':digest,
            'Upload-Length':str(len(data)),
        }
        status,raw,_=self.request_with_headers('POST','/v1/files/uploads',headers=common)
        self.assertEqual(status,201,raw)

        # The ordinary resumable lane keeps the 256 KiB boundary.
        status,raw,_=self.request_with_headers('PATCH',f'/v1/files/uploads/{fid}',data,{
            'Content-Type':'application/offset+octet-stream','Upload-Offset':'0','Upload-Complete':'?1'})
        self.assertEqual(status,400,raw)
        status,_,headers=self.request_with_headers('HEAD',f'/v1/files/uploads/{fid}')
        self.assertEqual(status,204);self.assertEqual(headers['upload-offset'],'0')

        # The marker is not a generic large-chunk escape hatch: it is only valid
        # for the final remainder of this attachment.
        status,raw,_=self.request_with_headers('PATCH',f'/v1/files/uploads/{fid}',data,{
            'Content-Type':'application/offset+octet-stream','Upload-Offset':'0','Upload-Complete':'?0',
            'X-Floweroll-Background-Upload':'?1'})
        self.assertEqual(status,400,raw)
        status,_,headers=self.request_with_headers('HEAD',f'/v1/files/uploads/{fid}')
        self.assertEqual(status,204);self.assertEqual(headers['upload-offset'],'0')

        # Only the authenticated system-background marker permits the remaining
        # range to be one file-backed request, so suspension cannot strand the
        # transfer between 256 KiB app-scheduled chunks.
        status,raw,headers=self.request_with_headers('PATCH',f'/v1/files/uploads/{fid}',data,{
            'Content-Type':'application/offset+octet-stream','Upload-Offset':'0','Upload-Complete':'?1',
            'X-Floweroll-Background-Upload':'?1'})
        self.assertEqual(status,204,raw);self.assertEqual(int(headers['upload-offset']),len(data))
        self.assertEqual(headers['upload-complete'],'?1')
        status,raw=self.request('GET',f'/v1/files/{fid}')
        self.assertEqual(status,200,raw);receipt=json.loads(raw)
        self.assertEqual(receipt['sha256'],digest);self.assertEqual(receipt['size_bytes'],len(data))

    def test_background_stream_saves_prefix_before_request_finishes_and_resumes_after_disconnect(self):
        import socket
        data = (b"streaming real socket fixture\n" * 40000)[:800000]
        fid = uuid.uuid4().hex
        common = {'X-File-ID': fid, 'X-File-Name': 'stream.txt', 'X-File-Media-Type': 'text/plain',
                  'X-Content-SHA256': hashlib.sha256(data).hexdigest(), 'Upload-Length': str(len(data))}
        status, raw, _ = self.request_with_headers('POST', '/v1/files/uploads', headers=common)
        self.assertEqual(status, 201, raw)
        sock = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5)
        self.addCleanup(sock.close)
        wire = (f'PATCH /v1/files/uploads/{fid} HTTP/1.1\r\nHost: localhost\r\n'
                f'Authorization: Bearer test-pairing\r\nContent-Length: {len(data)}\r\n'
                'Content-Type: application/offset+octet-stream\r\nUpload-Offset: 0\r\n'
                'Upload-Complete: ?1\r\nX-Floweroll-Background-Upload: ?1\r\n\r\n').encode()
        prefix = 300000
        sock.sendall(wire + data[:prefix])
        committed = 0
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            _, _, headers = self.request_with_headers('HEAD', f'/v1/files/uploads/{fid}')
            committed = int(headers['upload-offset'])
            if committed: break
            time.sleep(.02)
        self.assertEqual(committed, 256 * 1024, 'Host must commit before the HTTP body completes')
        self.assertEqual(self.request('GET', f'/v1/files/{fid}')[0], 404)
        sock.shutdown(socket.SHUT_RDWR); sock.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            _, _, headers = self.request_with_headers('HEAD', f'/v1/files/uploads/{fid}')
            committed = int(headers['upload-offset'])
            if committed == prefix: break
            time.sleep(.02)
        self.assertEqual(committed, prefix, 'Disconnect must retain the final partial receive buffer')
        status, raw, _ = self.request_with_headers('POST', '/v1/files/uploads', headers=common)
        self.assertEqual(json.loads(raw)['offset'], prefix)
        status, raw, headers = self.request_with_headers('PATCH', f'/v1/files/uploads/{fid}', data[prefix:], {
            'Content-Type': 'application/offset+octet-stream', 'Upload-Offset': str(prefix),
            'Upload-Complete': '?1', 'X-Floweroll-Background-Upload': '?1'})
        self.assertEqual(status, 204, raw)
        self.assertEqual(headers['upload-complete'], '?1')
        status, raw = self.request('GET', f'/v1/files/{fid}')
        self.assertEqual(status, 200, raw)
        self.assertEqual(json.loads(raw)['sha256'], common['X-Content-SHA256'])

    def test_background_final_range_rejects_wrong_size_before_saving_bytes(self):
        data = b'x' * 700000; fid = uuid.uuid4().hex
        common = {'X-File-ID': fid, 'X-File-Name': 'stream.txt', 'X-File-Media-Type': 'text/plain',
                  'X-Content-SHA256': hashlib.sha256(data).hexdigest(), 'Upload-Length': str(len(data))}
        self.assertEqual(self.request_with_headers('POST', '/v1/files/uploads', headers=common)[0], 201)
        status, raw = self.request('PATCH', f'/v1/files/uploads/{fid}', data[:-1], {
            'Content-Type': 'application/offset+octet-stream', 'Upload-Offset': '0',
            'Upload-Complete': '?1', 'X-Floweroll-Background-Upload': '?1'})
        self.assertEqual(status, 400, raw)
        _, _, headers = self.request_with_headers('HEAD', f'/v1/files/uploads/{fid}')
        self.assertEqual(headers['upload-offset'], '0')

    def test_resumable_upload_routes_require_auth(self):
        fid=uuid.uuid4().hex
        headers={'X-File-ID':fid,'X-File-Name':'x.txt','X-File-Media-Type':'text/plain',
            'X-Content-SHA256':hashlib.sha256(b'x').hexdigest(),'Upload-Length':'1'}
        self.assertEqual(self.request('POST','/v1/files/uploads',headers=headers,authorized=False)[0],401)
        self.assertEqual(self.request('HEAD',f'/v1/files/uploads/{fid}',authorized=False)[0],401)
        self.assertEqual(self.request('PATCH',f'/v1/files/uploads/{fid}',b'x',{'Content-Type':'application/offset+octet-stream','Upload-Offset':'0'},authorized=False)[0],401)

    def test_submission_readback_distinguishes_absent_from_durable_task(self):
        sid=uuid.uuid4().hex
        status,_=self.request('GET',f'/v1/submissions/{sid}/task')
        self.assertEqual(status,404)
        task=self.task([],submission=sid)
        status,raw=self.request('GET',f'/v1/submissions/{sid}/task')
        self.assertEqual(status,200,raw);recovered=json.loads(raw)
        self.assertEqual(recovered['task_id'],task['task_id'])
        self.assertEqual(recovered['submission_id'],sid)
        self.assertEqual(self.request('GET',f'/v1/submissions/{sid}/task',authorized=False)[0],401)

    def test_task_view_exposes_verified_work_progress_without_completing_booking(self):
        tid = self.task([])['task_id']
        self.action(tid, 'deliverables.plan', {'title': '面试准备', 'items': [
            {'id': 'study', 'title': '复习资料', 'depends_on': [], 'completion_rule': 'document'},
            {'id': 'hotel', 'title': '酒店预订', 'depends_on': [], 'completion_rule': 'reservation'}]})
        for iid, category in [('study', 'study'), ('hotel', 'hotel')]:
            self.assertEqual(self.action(tid, 'deliverables.publish', {
                'title': iid, 'markdown': '仅为接口测试准备资料', 'category': category,
                'item_id': iid, 'status': 'ready', 'missing_information': ['预算'] if iid == 'hotel' else []
            })['latest_outcome'], 'SUCCESS')
        status, raw = self.request('GET', f'/v1/tasks/{tid}/view')
        self.assertEqual(status, 200)
        view = json.loads(raw)
        _, materials = self.request('GET', f'/v1/tasks/{tid}/materials')
        self.assertEqual(view['work_summary'], json.loads(materials)['work_summary'])
        self.assertEqual((view['work_summary']['completed'], view['work_summary']['total']), (1, 2))
        self.assertEqual(view['work_summary']['items'][1]['state'], 'needs_input')
        self.assertNotEqual(view['task']['status'], 'completed')
        self.assertEqual(self.request('GET', f'/v1/tasks/{tid}/view', authorized=False)[0], 401)
    def test_material_read_model_maps_initial_and_turn_attachments_to_user_messages(self):
        first=self.upload(b'first material');second=self.upload(b'second material')
        task=self.task([first['id']]);tid=task['task_id']
        status,raw=self.request('POST',f'/v1/tasks/{tid}/turns',{
            'event_id':'turn-material-1',
            'content':{'kind':'text','text':'再看这份','attachment_ids':[second['id']]},
        })
        self.assertEqual(status,202,raw)
        status,raw=self.request('GET',f'/v1/tasks/{tid}/materials');manifest=json.loads(raw)
        self.assertEqual(status,200);self.assertEqual(manifest['initial_input_ids'],[first['id']])
        self.assertEqual({x['id'] for x in manifest['inputs']},{first['id'],second['id']})
        provenance=manifest['input_provenance']
        self.assertEqual([row['source_kind'] for row in provenance],['submission','user_turn'])
        self.assertEqual(provenance[0]['file_ids'],[first['id']])
        self.assertEqual(provenance[1]['source_id'],'turn-material-1')
        self.assertEqual(provenance[1]['file_ids'],[second['id']])
        self.assertEqual([f['id'] for f in provenance[0]['files']],[first['id']])
        self.assertEqual([f['id'] for f in provenance[1]['files']],[second['id']])
        status,raw=self.request('GET',f'/v1/tasks/{tid}/view');view=json.loads(raw)
        user_rows=[x for x in view['timeline'] if x['kind']=='USER_INPUT']
        self.assertTrue(user_rows);self.assertEqual(user_rows[-1]['payload']['attachment_ids'],[second['id']])

    def test_upload_bound_to_submission_replay_and_download_exact_bytes(self):
        data='简历内容 Example\nPython Agent'.encode();f=self.upload(data);sid=uuid.uuid4().hex
        t=self.task([f['id']],sid);replay=self.task([f['id']],sid)
        self.assertEqual(t['task_id'],replay['task_id'])
        status,body=self.request('GET',f"/v1/tasks/{t['task_id']}/files/{f['id']}")
        self.assertEqual((status,body),(200,data))
        f2=self.upload(b'Another resume')
        status,_=self.request('POST','/v1/tasks',{'submission_id':sid,'input':{'kind':'text','text':'Prepare the supplied materials.','attachment_ids':[f2['id']]}})
        self.assertEqual(status,400)
    def test_task_cannot_read_another_tasks_file(self):
        f=self.upload();owner=self.task([f['id']]);other=self.task([])
        self.assertEqual(self.request('GET',f"/v1/tasks/{other['task_id']}/files/{f['id']}")[0],404)
        attempt=self.action(other['task_id'],'materials.inspect',{'file_ids':[f['id']]})
        self.assertNotEqual(attempt['latest_outcome'],'SUCCESS')
    def test_followup_context_and_download_reuse_verified_ancestor_outputs(self):
        parent=self.task([])
        attempt=self.action(parent['task_id'],'deliverables.publish',{
            'title':'上一轮学习计划','markdown':'仅为测试资料','category':'study','status':'draft','source_ids':[]},complete=True)
        self.assertEqual(attempt['latest_outcome'],'SUCCESS')
        self.assertEqual(self.server.app.storage.get_task(parent['task_id'])['status'],'completed')
        file=self.server.app.task_assets.manifest(parent['task_id'])['outputs'][0]
        child=self.task([],parent=parent['task_id'])
        context=self.server.app.task_assets.context(child['task_id'])
        self.assertIn(file['id'],[x['id'] for x in context['prior_thread_outputs']])
        self.assertEqual(self.request('GET',f"/v1/tasks/{child['task_id']}/files/{file['id']}")[0],200)
        unrelated=self.task([])
        self.assertNotIn(file['id'],json.dumps(self.server.app.task_assets.context(unrelated['task_id'])))
        self.assertEqual(self.request('GET',f"/v1/tasks/{unrelated['task_id']}/files/{file['id']}")[0],404)

    @unittest.skipUnless(platform.system()=='Darwin','Vision/PDFKit blocked-OCR proof requires macOS')
    def test_progressive_pdf_http_download_while_ocr_is_blocked_then_same_id_verifies(self):
        self.server.app.supervisor.stop()
        f=self.upload(self.scan_image_fixture(),'image/png');tid=self.task([f['id']])['task_id']
        self.assertEqual(self.action(tid,'deliverables.plan',{
            'title':'扫描材料','items':[{
                'id':'scan','title':'扫描 PDF','depends_on':[],'completion_rule':'document'}]
        })['latest_outcome'],'SUCCESS')
        store=self.server.app.storage;aid=uuid.uuid4().hex
        store.create_action(action_id=aid,task_id=tid,step_index=int(time.time()*1000),
            action_type='document.scan_pdf',payload={
                'file_ids':[f['id']],'name':'候选人材料扫描.pdf','scan':True,'item_id':'scan'},
            expected={},idempotency_key=aid,on_verified='REPLAN')
        started=threading.Event();release=threading.Event()
        original=MacPerceptionToolSet.pdf_ocr_file
        def blocked_ocr(tool,path,*,public_path=None,timeout_seconds=120):
            started.set()
            if not release.wait(timeout=20): raise TimeoutError('A16 OCR blocker timeout')
            return original(tool,path,public_path=public_path,timeout_seconds=timeout_seconds)
        with patch.object(MacPerceptionToolSet,'pdf_ocr_file',new=blocked_ocr):
            worker=threading.Thread(target=self.server.app.function_worker.run_once,args=(tid,),daemon=True)
            worker.start();self.assertTrue(started.wait(timeout=20),'OCR did not reach blocked boundary')
            try:
                manifest=self.server.app.task_assets.manifest(tid)
                self.assertEqual(manifest['outputs'],[])
                self.assertEqual(manifest['work_summary']['completed'],0)
                self.assertEqual(manifest['work_summary']['items'][0]['state'],'running')
                self.assertEqual(len(manifest['progressive_outputs']),1)
                staged=manifest['progressive_outputs'][0]
                self.assertEqual(staged['progress']['detail']['pdf_status'],'ready')
                self.assertEqual(staged['progress']['detail']['ocr_status'],'processing')
                status,body,headers=self.request_with_headers('GET',f"/v1/tasks/{tid}/files/{staged['id']}")
                self.assertEqual(status,200,body)
                self.assertTrue(body.startswith(b'%PDF-'))
                self.assertEqual(hashlib.sha256(body).hexdigest(),staged['sha256'])
                self.assertEqual(headers.get('x-content-sha256'),staged['sha256'])
                self.assertEqual(headers.get('content-type'),'application/pdf')
                with self.assertRaises(KeyError):
                    self.server.app.task_assets.file_path(tid,staged['id'])
                other=self.task([])
                self.assertEqual(self.request('GET',f"/v1/tasks/{other['task_id']}/files/{staged['id']}")[0],404)
                staged_id=staged['id']
            finally:
                release.set();worker.join(timeout=90)
            self.assertFalse(worker.is_alive(),'scan worker did not converge after OCR release')
        attempt=store.action_attempts(aid)[0]
        self.assertEqual(attempt['latest_outcome'],'SUCCESS',attempt)
        final=self.server.app.task_assets.manifest(tid)
        self.assertEqual(final['progressive_outputs'],[])
        self.assertEqual(len(final['outputs']),1)
        self.assertEqual(final['outputs'][0]['id'],staged_id)
        status,body,headers=self.request_with_headers('GET',f"/v1/tasks/{tid}/files/{staged_id}")
        self.assertEqual(status,200)
        self.assertEqual(hashlib.sha256(body).hexdigest(),final['outputs'][0]['sha256'])
        self.assertEqual(headers.get('x-content-sha256'),final['outputs'][0]['sha256'])

    @unittest.skipUnless(platform.system()=='Darwin','Vision/PDFKit OCR failure proof requires macOS')
    def test_ocr_failure_keeps_downloadable_pdf_and_does_not_complete_work_item(self):
        self.server.app.supervisor.stop()
        f=self.upload(self.scan_image_fixture(),'image/png');tid=self.task([f['id']])['task_id']
        self.assertEqual(self.action(tid,'deliverables.plan',{
            'title':'扫描材料','items':[{
                'id':'scan','title':'扫描 PDF','depends_on':[],'completion_rule':'document'}]
        })['latest_outcome'],'SUCCESS')
        with patch.object(MacPerceptionToolSet,'pdf_ocr_file',side_effect=TimeoutError('simulated OCR timeout')):
            attempt=self.action(tid,'document.scan_pdf',{
                'file_ids':[f['id']],'name':'OCR失败扫描.pdf','scan':True,'item_id':'scan'})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS',attempt)
        manifest=self.server.app.task_assets.manifest(tid)
        self.assertEqual(len(manifest['outputs']),1)
        self.assertEqual(manifest['progressive_outputs'],[])
        output=manifest['outputs'][0]
        self.assertEqual(output['metadata']['ocr_status'],'failed')
        self.assertEqual(output['metadata']['quality_status'],'needs_visual_review')
        self.assertEqual(output['metadata']['status'],'needs_review')
        self.assertEqual(manifest['work_summary']['completed'],0)
        self.assertEqual(manifest['work_summary']['items'][0]['state'],'needs_review')
        status,body,headers=self.request_with_headers('GET',f"/v1/tasks/{tid}/files/{output['id']}")
        self.assertEqual(status,200,body)
        self.assertEqual(hashlib.sha256(body).hexdigest(),output['sha256'])
        self.assertEqual(headers.get('x-content-sha256'),output['sha256'])

    def test_progressive_http_route_rejects_unsafe_staged_files_and_unknown_id(self):
        assets=self.server.app.task_assets;tid=self.task([])['task_id']
        cases=[
            ('not-structural','application/pdf',{'structural_verified':False},{'pdf_status':'ready'}),
            ('not-ready','application/pdf',{'structural_verified':True},{'pdf_status':'processing'}),
            ('non-pdf','text/html',{'structural_verified':True},{'pdf_status':'ready'}),
        ]
        for action_id,media_type,metadata,detail in cases:
            with self.subTest(action_id=action_id):
                data=b'%PDF-unsafe' if media_type=='application/pdf' else b'<html></html>'
                item=assets.publish_bytes(task_id=tid,action_id=action_id,
                    name='unsafe.pdf' if media_type=='application/pdf' else 'unsafe.html',
                    media_type=media_type,data=data,category='document',
                    metadata={'status':'processing',**metadata})
                assets.set_output_progress(task_id=tid,action_id=action_id,file_id=item['id'],
                    phase='ocr_processing',status='processing',
                    detail={**detail,'ocr_status':'processing'})
                self.assertEqual(self.request('GET',f"/v1/tasks/{tid}/files/{item['id']}")[0],404)
        status,body=self.request('GET',f"/v1/tasks/{tid}/files/not-present")
        self.assertEqual(status,404)
        problem=json.loads(body)
        self.assertEqual(problem['code'],'FILE_NOT_FOUND')
        self.assertEqual(problem['type'],'urn:floweroll:problem:file-not-found')

    def test_corrupt_sha_and_wrong_mime_fail(self):
        data=b'not a picture'
        for media,digest in [('image/png',hashlib.sha256(data).hexdigest()),('text/plain','0'*64)]:
            status,_=self.request('POST','/v1/files',data,{'Content-Type':media,'X-File-ID':uuid.uuid4().hex,'X-Content-SHA256':digest})
            self.assertEqual(status,400)
    def test_text_material_read_and_result_publish_download(self):
        f=self.upload();t=self.task([f['id']]);tid=t['task_id']
        attempt=self.action(tid,'materials.inspect',{'file_ids':[f['id']]})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS')
        self.action(tid,'deliverables.plan',{'title':'面试准备','items':[{'id':'study','title':'学习资料','depends_on':[]}]})
        attempt=self.action(tid,'deliverables.publish',{'title':'面试学习资料','kind':'study','item_id':'study',
            'sections':[{'heading':'技能证据','body':'简历中列出了 Python。<script>alert(1)</script>'}], 'source_urls':[]})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS')
        status,raw=self.request('GET',f'/v1/tasks/{tid}/materials');manifest=json.loads(raw)
        self.assertEqual(status,200);self.assertEqual(len(manifest['outputs']),2)
        for out in manifest['outputs']:
            status,data=self.request('GET',f"/v1/tasks/{tid}/files/{out['id']}")
            self.assertEqual(status,200);self.assertEqual(hashlib.sha256(data).hexdigest(),out['sha256'])
            self.assertEqual(out['metadata']['item_id'],'study')
            if out['media_type']=='text/html':
                self.assertNotIn(b'<script>',data);self.assertIn(b'&lt;script&gt;',data)
        # Manifest survives restart of the file service, independent of model context.
        reopened=TaskAssetStore(self.root/'workspace',self.server.app.storage)
        self.assertEqual(len(reopened.manifest(tid)['outputs']),2);reopened.close()
    def test_url_in_uploaded_material_does_not_count_as_retrieved_web_evidence(self):
        url='https://invented-source.example/not-retrieved'
        f=self.upload(('The document mentions '+url).encode());tid=self.task([f['id']])['task_id']
        self.assertEqual(self.action(tid,'materials.inspect',{'file_ids':[f['id']]})['latest_outcome'],'SUCCESS')
        result=self.action(tid,'deliverables.publish',{'title':'Source test','kind':'company',
            'sections':[{'heading':'Facts','body':'A link in a CV is not web retrieval.'}],'source_urls':[url]})
        self.assertEqual(result['latest_outcome'],'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(self.server.app.task_assets.manifest(tid)['outputs'],[])

    def test_fabricated_source_and_cycle_fail_closed(self):
        t=self.task([]);tid=t['task_id']
        attempt=self.action(tid,'deliverables.publish',{'title':'公司研究','kind':'company',
            'sections':[{'heading':'公司','body':'unverified'}], 'source_urls':['https://invented-source.example/page']})
        self.assertNotEqual(attempt['latest_outcome'],'SUCCESS')
        # Test plan graph separately after model-correctable error.
        t=self.task([])
        attempt=self.action(t['task_id'],'deliverables.plan',{'title':'Bad graph','items':[
            {'id':'a','title':'a','depends_on':['b']},{'id':'b','title':'b','depends_on':['a']}]})
        self.assertNotEqual(attempt['latest_outcome'],'SUCCESS')
    @unittest.skipUnless(platform.system()=='Darwin','real PDFKit proof requires macOS')
    def test_real_images_pdf_merge_select_and_authenticated_delivery(self):
        image=self.root/'resume.png'
        script=self.root/'fixture.swift'
        script.write_text('''import AppKit
import Foundation
let image = NSImage(size: NSSize(width: 800, height: 1100))
image.lockFocus()
NSColor.white.setFill(); NSRect(x: 0,y: 0,width:800,height:1100).fill()
("EXAMPLE RESUME\\nPython / Agent Development\\nEducation and projects" as NSString).draw(in: NSRect(x:70,y:600,width:660,height:350), withAttributes:[.font:NSFont.systemFont(ofSize:30),.foregroundColor:NSColor.black])
image.unlockFocus()
let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
''')
        subprocess.run(['/usr/bin/xcrun','swift',str(script),str(image)],check=True,capture_output=True,timeout=45)
        f=self.upload(image.read_bytes(),'image/png');tid=self.task([f['id']])['task_id']
        attempt=self.action(tid,'document.scan_pdf',{'file_ids':[f['id']],'name':'简历扫描件.pdf','scan':True,'item_id':'resume'})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS',attempt)
        first=self.server.app.task_assets.manifest(tid)['outputs'][0]
        self.assertEqual(first['metadata']['page_count'],1)
        self.assertEqual(self.request('GET',f"/v1/tasks/{tid}/files/{first['id']}")[1][:5],b'%PDF-')
        attempt=self.action(tid,'document.pdf_merge',{'file_ids':[first['id'],first['id']],'name':'合并.pdf'})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS',attempt)
        merged=self.server.app.task_assets.manifest(tid)['outputs'][-1]
        self.assertEqual(merged['metadata']['page_count'],2)
        attempt=self.action(tid,'document.pdf_select',{'file_id':merged['id'],'pages':[2,1,2],'name':'选页.pdf'})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS',attempt)
        final=self.server.app.task_assets.manifest(tid)['outputs'][-1]
        self.assertEqual(final['metadata']['page_count'],3)
