from __future__ import annotations

import hashlib
import tempfile
import unittest
import uuid
from pathlib import Path

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.server import create_server
from floweroll_host.task_runtime import TaskRuntime
from floweroll_host.work_item_projection import project_work_items, guard_completion


def item(iid, rule='document', dependencies=None):
    return {'id':iid,'title':iid,'depends_on':dependencies or [],'completion_rule':rule}


def output(iid, *, status='ready', missing=None, action='action-one'):
    return {'id':'file-'+iid,'metadata':{'item_id':iid,'status':status,'missing_information':missing or [],'action_id':action}}


def complete():
    return PlannerDecision.from_dict({'decision_type':'COMPLETE','interpreted_goal_summary':'已完成用户目标',
        'plan_update':None,'action':None,'on_verified':None,'clarification':None,'wait':None,
        'completion':{'summary':'已完成'},'stop_reason':None},[])


class WorkItemProjectionTests(unittest.TestCase):
    def project(self, items, outputs=None, observations=None, **kw):
        return project_work_items({'title':'任务','items':items},outputs or [],observations or [],**kw)

    def test_pdf_done_hotel_needs_input_not_all_done(self):
        result=self.project([item('resume'),item('hotel','reservation')],[output('resume'),output('hotel',status='handoff_required',missing=['预算'])])
        self.assertEqual(result['completed'],1);self.assertEqual(result['total'],2)
        self.assertEqual(result['strict_unfinished_ids'],['hotel'])
        self.assertFalse(result['all_required_completed'])
        self.assertEqual(result['items'][1]['state'],'needs_input')

    def test_file_never_proves_reservation_payment_or_email_sent(self):
        for rule in ['reservation','payment','email_sent','calendar_event']:
            with self.subTest(rule=rule):
                result=self.project([item('effect',rule)],[output('effect')])
                self.assertEqual(result['completed'],0)
                self.assertEqual(result['items'][0]['state'],'handoff_required')

    def test_only_a_requested_draft_counts_as_complete(self):
        self.assertTrue(self.project([item('study','draft')],[output('study',status='draft')])['all_required_completed'])
        self.assertFalse(self.project([item('study','document')],[output('study',status='draft')])['all_required_completed'])

    def test_independent_work_remains_ready_while_hotel_waits(self):
        result=self.project([item('hotel','reservation'),item('study'),item('packing',dependencies=['hotel'])],
            [output('hotel',status='needs_input',missing=['面试地址'])])
        self.assertEqual(result['ready_item_ids'],['study'])
        self.assertEqual(result['items'][2]['state'],'blocked')

    def test_dependency_blocks_completed_file_until_prerequisite_is_verified(self):
        result=self.project([item('study',dependencies=['company']),item('company')],[output('study')])
        self.assertEqual(result['items'][0]['state'],'blocked')
        self.assertEqual(result['completed'],0)

    def test_running_item_uses_real_action_not_a_timer(self):
        result=self.project([item('study')],open_action={'payload':{'item_id':'study'}})
        self.assertEqual(result['state'],'running')
        self.assertEqual(result['completed'],0)

    def test_native_receipt_requires_verified_link_to_same_action(self):
        real={'action_id':'native-a','capability':'reminder.create','data':{'reminder_id':'device-id'}}
        link={'action_id':'link-a','capability':'deliverables.verify','data':{'item_id':'remind',
            'completion_rule':'reminder','evidence_action_id':'native-a','verified':True}}
        self.assertFalse(self.project([item('remind','reminder')],observations=[real])['all_required_completed'])
        self.assertTrue(self.project([item('remind','reminder')],observations=[real,link])['all_required_completed'])
        self.assertFalse(self.project([item('hotel','reservation')],observations=[real,link])['all_required_completed'])

    def test_waiting_confirmation_is_not_running_or_complete(self):
        result = self.project([item('hotel', 'reservation'), item('study')], item_actions={
            'hotel': {'status': 'planned', 'waiting_input': True, 'payload': {'item_id': 'hotel'}}})
        self.assertEqual(result['items'][0]['state'], 'waiting_approval')
        self.assertEqual(result['completed'], 0)
        self.assertEqual(result['ready_item_ids'], ['study'])

    def test_queued_action_does_not_claim_it_is_executing(self):
        result = self.project([item('study')], item_actions={
            'study': {'status': 'planned', 'payload': {'item_id': 'study'}}})
        self.assertEqual(result['items'][0]['state'], 'pending')

    def test_guard_surfaces_missing_user_input_instead_of_fake_complete(self):
        result=self.project([item('hotel','reservation')],[output('hotel',status='handoff_required',missing=['入住预算'])])
        decision=guard_completion(complete(),summary=result,observations=[],pending_clarification=None,available_names={'deliverables.status'})
        self.assertEqual(decision.decision_type,'CLARIFY')
        self.assertIn('入住预算',decision.clarification['question'])
        decision.validate([])

    def test_guard_inspects_pending_safe_work_without_asking_user(self):
        result=self.project([item('study')])
        decision=guard_completion(complete(),summary=result,observations=[],pending_clarification=None,available_names={'deliverables.status'})
        self.assertEqual(decision.decision_type,'EXECUTE')
        self.assertEqual(decision.action['capability'],'deliverables.status')
        self.assertIsNone(decision.clarification)

    def test_repeated_premature_complete_cannot_busy_loop_or_fake_success(self):
        result=self.project([item('study')])
        decision=guard_completion(complete(),summary=result,observations=[{'capability':'deliverables.status','data':result}],pending_clarification=None,available_names={'deliverables.status'})
        self.assertEqual(decision.decision_type,'STOP')
        self.assertIn('未完成',decision.stop_reason)

    def test_native_action_cannot_direct_complete_an_unfinished_multi_outcome_task(self):
        from dataclasses import replace
        result=self.project([item('pdf'),item('remind','reminder')])
        decision=replace(complete(),decision_type='EXECUTE',completion=None,on_verified='COMPLETE',
            action={'capability':'reminder.create','arguments':{'title':'fixture','due_at':'2026-09-12T08:00:00+08:00'}})
        corrected=guard_completion(decision,summary=result,observations=[],pending_clarification=None,available_names={'reminder.create'})
        self.assertEqual(corrected.on_verified,'REPLAN')

    def test_existing_question_is_kept_not_duplicated(self):
        result=self.project([item('hotel','reservation')],[output('hotel',status='needs_input')])
        decision=guard_completion(complete(),summary=result,observations=[],pending_clarification={'id':'question'},available_names=set())
        self.assertEqual(decision.decision_type,'WAIT')
        self.assertEqual(decision.state_update['pending_clarification'],'KEEP')
        decision.validate([])

    def test_legacy_plan_is_projected_but_not_silently_migrated_to_new_guard(self):
        result=self.project([{'id':'old','title':'old','depends_on':[]}])
        self.assertEqual(result['strict_unfinished_ids'],[])
        self.assertEqual(guard_completion(complete(),summary=result,observations=[],pending_clarification=None,available_names=set()).decision_type,'COMPLETE')


class WorkItemRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        registry=CapabilityRegistry()
        class Planner:
            def decide(self,request,specs): return complete()
        self.server=create_server('127.0.0.1',0,str(self.root/'runtime.sqlite'),capability_registry=registry,
            task_asset_root=self.root/'assets',progressive_discovery=True,
            task_runtime_factory=lambda store:TaskRuntime(store,Planner(),product_native_capabilities()+registry.planner_capabilities()))
        self.server.app.supervisor.stop()
        self.app=self.server.app
        self.task=self.app.accept_product_task(goal='生成简历资料并订好酒店',invocation_source='unit',submission_id='work-test')
        self.tid=self.task['task_id']
        self.step=100
    def tearDown(self):
        self.server.server_close();self.temp.cleanup()
    def execute(self,cap,args,tid=None):
        tid=tid or self.tid;aid=uuid.uuid4().hex
        self.step+=1
        self.app.storage.create_action(action_id=aid,task_id=tid,step_index=self.step,action_type=cap,payload=args,expected={},idempotency_key=aid,on_verified='REPLAN')
        self.app.function_worker.run_once(tid)
        return self.app.storage.action_attempts(aid)[0]
    def publish(self,iid,category='study',status='ready',missing=None):
        return self.execute('deliverables.publish',{'title':iid,'markdown':'这是用于回归的本地成果，不是真实预订。',
            'category':category,'status':status,'source_ids':[],'source_urls':[],
            'item_id':iid,'missing_information':missing or []})

    def test_actual_file_publish_completes_document_work_item(self):
        self.app.task_assets.save_plan(self.tid,'材料',[item('study')])
        self.assertEqual(self.publish('study')['latest_outcome'],'SUCCESS')
        manifest=self.app.task_assets.manifest(self.tid)
        self.assertEqual(manifest['work_summary']['completed'],1)
        file=manifest['outputs'][0]
        data=self.app.task_assets.file_path(self.tid,file['id']).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(),file['sha256'])
        result=self.app.task_runtime.decide(self.tid)
        self.assertEqual(result['task']['status'],'completed')

    def test_failed_item_is_durable_and_does_not_discard_completed_files(self):
        self.app.task_assets.save_plan(self.tid, '准备', [item('study'), item('company')])
        self.publish('study')
        attempt = self.execute('deliverables.publish', {'title': '公司', 'category': 'company',
            'markdown': '尚未检索来源', 'status': 'ready', 'item_id': 'company',
            'source_urls': ['https://unverified.example/company']})
        self.assertNotEqual(attempt['latest_outcome'], 'SUCCESS')
        summary = self.app.get_task_view(self.tid)['work_summary']
        self.assertEqual([x['state'] for x in summary['items']], ['completed', 'failed'])
        self.assertEqual(summary['completed'], 1)
        self.assertEqual(summary, self.app.task_assets.manifest(self.tid)['work_summary'])
        # A corrected action supersedes only that item's failed attempt.
        self.publish('company')
        self.assertEqual(self.app.get_task_view(self.tid)['work_summary']['completed'], 2)

    def test_pending_approval_survives_reopening_material_store(self):
        from floweroll_host.task_assets import TaskAssetStore
        self.app.task_assets.save_plan(self.tid, '确认', [item('study')])
        action = self.app.storage.create_action(action_id='approval-action', task_id=self.tid,
            step_index=1, action_type='deliverables.publish', payload={'item_id': 'study'},
            expected={}, idempotency_key='approval-action', on_verified='REPLAN')
        self.app.execution.request_predispatch_input(task_id=self.tid, action_id='approval-action',
            input_request_id='approval-input', prompt='确认这项操作？',
            suggested_options=[{'id': 'yes', 'label': '确认'}], accepts_text=False,
            reason='side_effect_approval', artifact_revision_ids=[], execution_fields={'item_id': 'study'})
        reopened = TaskAssetStore(self.root/'assets', self.app.storage)
        try:
            self.assertEqual(reopened.manifest(self.tid)['work_summary']['items'][0]['state'], 'waiting_approval')
        finally:
            reopened.close()

    def test_task_runtime_rejects_fake_complete_when_only_hotel_draft_exists(self):
        self.app.task_assets.save_plan(self.tid,'面试准备',[item('study'),item('hotel','reservation')])
        self.publish('study');self.publish('hotel',category='hotel',missing=['预算'])
        result=self.app.task_runtime.decide(self.tid)
        self.assertEqual(result['decision']['decision_type'],'CLARIFY')
        self.assertNotEqual(result['task']['status'],'completed')
        self.assertEqual(len(self.app.task_assets.manifest(self.tid)['outputs']),2)
        self.assertIn('预算',result['clarification']['payload']['question'])

    def test_unverified_or_wrong_task_action_cannot_fulfill_work(self):
        self.app.task_assets.save_plan(self.tid,'真实操作',[item('hotel','reservation')])
        outcome=self.execute('deliverables.verify',{'item_id':'hotel','evidence_action_id':'invented-order'})
        self.assertEqual(outcome['latest_outcome'],'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(self.app.task_assets.manifest(self.tid)['work_summary']['completed'],0)

    def test_real_adapter_contract_then_bound_native_receipt(self):
        self.app.task_assets.save_plan(self.tid,'提醒事项',[item('remind','reminder')])
        aid='native-reminder';payload={'title':'契约测试提醒','due_at':'2026-09-12T08:00:00+08:00'}
        self.app.storage.create_action(action_id=aid,task_id=self.tid,step_index=1,action_type='reminder.create',
            payload=payload,expected={},idempotency_key='native-fixture',on_verified='REPLAN')
        dispatch=self.app.execution.next_action(self.tid,source_kind='ios')
        # Unit fixture validates the real adapter contract, not a claim of physical device execution.
        self.app.execution.accept_result(task_id=self.tid,action_id=aid,attempt_id=dispatch['attempt_id'],success=True,
            output={**payload,'reminder_id':'test-reminder-id','idempotency_marker':'native-fixture','verified':True},error=None)
        self.assertEqual(self.app.task_assets.manifest(self.tid)['work_summary']['completed'],0)
        attempt=self.execute('deliverables.verify',{'item_id':'remind','evidence_action_id':aid})
        self.assertEqual(attempt['latest_outcome'],'SUCCESS')
        self.assertEqual(self.app.task_assets.manifest(self.tid)['work_summary']['completed'],1)

    def test_plan_completion_rules_survive_reopening_store(self):
        from floweroll_host.task_assets import TaskAssetStore
        self.app.task_assets.save_plan(self.tid,'持久计划',[item('hotel','reservation')])
        self.publish('hotel',category='hotel')
        reopened=TaskAssetStore(self.root/'assets',self.app.storage)
        try:
            summary=reopened.manifest(self.tid)['work_summary']
            self.assertEqual(summary['items'][0]['completion_rule'],'reservation')
            self.assertFalse(summary['all_required_completed'])
        finally:reopened.close()

    def test_model_cannot_downgrade_or_drop_reservation_to_make_task_green(self):
        self.app.task_assets.save_plan(self.tid,'面试',[item('hotel','reservation'),item('study')])
        for revised in [[item('hotel','draft'),item('study')],[item('study')]]:
            with self.subTest(revised=revised),self.assertRaises(ValueError):
                self.app.task_assets.save_plan(self.tid,'假完成',revised)
        self.assertEqual(self.app.task_assets.manifest(self.tid)['plan']['items'][0]['completion_rule'],'reservation')

    def test_real_new_user_turn_allows_goal_revision_without_deleting_history(self):
        self.app.task_assets.save_plan(self.tid,'订房',[item('hotel','reservation')])
        self.app.storage.admit_inbox_event(task_id=self.tid,event_id='new-goal',event_type='USER_TURN',source='user',
            payload={'content':{'kind':'text','text':'现在不需要订房，只整理一份住宿需求草稿。'}})
        self.app.task_assets.save_plan(self.tid,'住宿需求',[item('hotel','draft')])
        self.assertEqual(self.app.task_assets.manifest(self.tid)['plan']['items'][0]['completion_rule'],'draft')

    def test_hotel_requirements_document_completes_but_booking_waits_for_missing_fields(self):
        self.app.task_assets.save_plan(self.tid,'住宿工作',[item('requirements','document'),
            item('reservation','reservation',dependencies=['requirements'])])
        self.assertEqual(self.publish('requirements',category='hotel',missing=['面试地址','预算'])['latest_outcome'],'SUCCESS')
        manifest=self.app.task_assets.manifest(self.tid)
        self.assertEqual(manifest['outputs'][0]['metadata']['booking_status'],'not_booked')
        summary=manifest['work_summary']
        self.assertEqual(summary['completed'],1)
        self.assertEqual(summary['items'][0]['state'],'completed')
        self.assertEqual(summary['items'][1]['state'],'needs_input')
        self.assertIn('预算',summary['items'][1]['missing_information'])
        result=self.app.task_runtime.decide(self.tid)
        self.assertEqual(result['decision']['decision_type'],'CLARIFY')
        self.assertNotEqual(result['task']['status'],'completed')

    def test_unknown_completion_rule_is_rejected(self):
        with self.assertRaises(ValueError):self.app.task_assets.save_plan(self.tid,'无效',[item('buy','anything_success')])
