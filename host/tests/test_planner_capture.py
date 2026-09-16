from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch
import uuid

from floweroll_host import planner_capture as pc
from floweroll_host.capabilities_v0 import REMINDER_CREATE
from floweroll_host.context_builder import ContextBuilder
from floweroll_host.openai_compatible_chat_adapter import OpenAICompatibleChatPlannerAdapter
from floweroll_host.planner_request import PlannerRequestBuilder, PLANNER_SYSTEM_INSTRUCTIONS_V0


def reply():
    decision = {'decision_type': 'EXECUTE', 'interpreted_goal_summary': '创建提醒',
        'plan_update': ['创建提醒'], 'action': {'capability': 'reminder.create',
        'arguments': {'title': '交报告', 'due_at': '2026-09-15T10:00:00+08:00'}},
        'on_verified': 'COMPLETE', 'clarification': None, 'wait': None,
        'completion': None, 'stop_reason': None, 'cancellation': None, 'state_update': None}
    return BytesIO(json.dumps({'choices': [{'finish_reason': 'stop', 'message': {
        'content': json.dumps(decision), 'reasoning_content': 'DO_NOT_CAPTURE_PRIVATE_REASONING'}}],
        'usage': {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 120}}).encode())


class PlannerCaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=pc.ROOT / 'work', prefix='capture-tests-')
        self.root = Path(self.tmp.name)
        self.config = self.root / 'config.json'
        self.task = str(uuid.uuid4())
        self.set_mode('local_full')
        self.env = patch.dict(os.environ, {'FLOWEROLL_OBSERVABILITY_CONFIG': str(self.config)})
        self.env.start()

    def tearDown(self):
        pc.flush_for_test()
        self.env.stop()
        self.tmp.cleanup()

    def set_mode(self, mode, **extra):
        self.config.write_text(json.dumps({'mode': mode, 'snapshot_dir': str(self.root / 'captures'), **extra}))

    def snapshots(self):
        self.assertTrue(pc.flush_for_test())
        return [json.loads(p.read_text()) for p in self.root.glob('captures/*/*.json')]

    def request(self):
        ctx = ContextBuilder().build(task_id=self.task, raw_goal='明天十点提醒我交报告',
            current_time=datetime(2026,9,14,tzinfo=timezone.utc), timezone_name='Asia/Shanghai',
            policy_view={'allowed_capabilities': ['reminder.create']}, capabilities=[REMINDER_CREATE])
        return PlannerRequestBuilder(model='abstract-model').build(ctx)

    def adapter(self):
        return OpenAICompatibleChatPlannerAdapter(api_key='unit-secret-never-live', base_url='https://example.invalid', model='wire-model')

    def call(self, number=1):
        with pc.planner_call(task_id=self.task, call_number=number, visible_capabilities=['reminder.create']):
            return self.adapter().decide(self.request(), [REMINDER_CREATE])

    def test_wire_payload_matches_sent_bytes_not_template(self):
        sent = []
        def transport(request, **kwargs):
            sent.append(request.data)
            return reply()
        with patch('urllib.request.urlopen', side_effect=transport):
            result = self.call()
        c = self.snapshots()[0]
        self.assertEqual(result.action['capability'], 'reminder.create')
        self.assertEqual(c['wire_request']['model'], 'wire-model')
        self.assertEqual(c['wire_request'], json.loads(sent[0]))
        self.assertEqual(c['request_sha256'], hashlib.sha256(sent[0]).hexdigest())
        self.assertEqual(c['state'], 'response_validated')
        self.assertEqual(c['usage']['total_tokens'], 120)
        self.assertNotIn('unit-secret-never-live', json.dumps(c))
        self.assertNotIn('DO_NOT_CAPTURE_PRIVATE_REASONING', json.dumps(c))

    def test_runtime_uses_source_controlled_prompt_without_rewriting(self):
        source = (pc.ROOT / 'host' / 'prompts' / 'planner.system.txt').read_text(encoding='utf-8')
        self.assertEqual(PLANNER_SYSTEM_INSTRUCTIONS_V0, source)
        self.assertEqual(self.request()['input'][0]['content'], source)

    def test_provider_retry_keeps_one_call_two_attempts(self):
        with patch('urllib.request.urlopen', side_effect=[socket.timeout(), reply()]), patch('floweroll_host.openai_compatible_chat_adapter.time.sleep'):
            self.call()
        c = self.snapshots()[0]
        self.assertEqual(len(c['attempts']), 2)
        self.assertEqual(c['attempts'][0]['error_type'], type(socket.timeout()).__name__)
        self.assertEqual(c['attempts'][1]['state'], 'response_received')

    def test_timeout_failure_is_recorded_without_arbitrary_error_body(self):
        with patch('urllib.request.urlopen', side_effect=socket.timeout('arbitrary-private-body')), patch('floweroll_host.openai_compatible_chat_adapter.time.sleep'):
            with self.assertRaises(Exception):
                self.call()
        c = self.snapshots()[0]
        self.assertEqual(c['state'], 'error')
        self.assertIn('Transient', c['error_type'])
        self.assertNotIn('arbitrary-private-body', json.dumps(c))

    def test_metadata_mode_does_not_write_payload_or_response(self):
        self.set_mode('metadata')
        with patch('urllib.request.urlopen', return_value=reply()):
            self.call()
        c = self.snapshots()[0]
        self.assertNotIn('wire_request', c)
        self.assertNotIn('response_text', c)
        self.assertNotIn('交报告', json.dumps(c, ensure_ascii=False))

    def test_off_and_missing_config_do_not_capture(self):
        self.set_mode('off')
        with patch('urllib.request.urlopen', side_effect=lambda *a, **k: reply()):
            self.call()
            self.config.unlink()
            self.call(2)
        self.assertEqual(self.snapshots(), [])

    def test_invalid_output_location_fails_soft_without_creating_it(self):
        self.set_mode('local_full', snapshot_dir='/tmp/never-create-floweroll-capture')
        with patch('urllib.request.urlopen', return_value=reply()):
            self.assertEqual(self.call().decision_type, 'EXECUTE')
        self.assertEqual(self.snapshots(), [])
        self.assertFalse(Path('/tmp/never-create-floweroll-capture').exists())

    def test_telemetry_enqueue_failure_cannot_fail_model(self):
        with patch.object(pc, '_enqueue', side_effect=OSError('disk unavailable')), patch('urllib.request.urlopen', return_value=reply()):
            self.assertEqual(self.call().decision_type, 'EXECUTE')

    def test_snapshot_limit_marks_payload_omitted(self):
        self.set_mode('local_full', max_snapshot_bytes=4096)
        with patch('urllib.request.urlopen', return_value=reply()):
            self.call()
        c = self.snapshots()[0]
        self.assertNotIn('wire_request', c)
        self.assertEqual(c['content_omitted'], 'snapshot_size_limit')

    def test_parallel_tasks_do_not_cross_contaminate_context(self):
        def worker(index):
            task = str(uuid.uuid4())
            body = {'model': 'test', 'messages': [{'role': 'system', 'content': 'system'}, {'role': 'user', 'content': 'task-' + str(index)}]}
            with pc.planner_call(task_id=task, call_number=1):
                pc.request_ready(body, json.dumps(body).encode(), adapter='unit')
            return task
        with ThreadPoolExecutor(max_workers=4) as pool:
            task_ids = list(pool.map(worker, range(8)))
        found = {c['task_id']: c['wire_request']['messages'][1]['content'] for c in self.snapshots()}
        self.assertEqual(found, {task: 'task-' + str(i) for i, task in enumerate(task_ids)})
        self.assertIsNone(pc._ACTIVE.get())

    def test_secret_redaction_traverses_json_encoded_context(self):
        data = {'metadata': json.dumps({'api_key': 'PRIVATE_API', 'password': 'PRIVATE_PASSWORD',
                                      'ordinary': 'prefix CONFIGURED_KEY suffix'}),
                'url': 'https://example.test/?token=SECRET_TOKEN',
                'auth': 'Bearer SECRET_BEARER'}
        result = json.dumps(pc.scrub(data, ('CONFIGURED_KEY',)))
        for secret in ('PRIVATE_API', 'PRIVATE_PASSWORD', 'CONFIGURED_KEY', 'SECRET_TOKEN', 'SECRET_BEARER'):
            self.assertNotIn(secret, result)

    def test_private_file_permissions(self):
        with patch('urllib.request.urlopen', return_value=reply()):
            self.call()
        self.snapshots()
        p = next(self.root.glob('captures/*/*.json'))
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        self.assertEqual(p.parent.stat().st_mode & 0o777, 0o700)

    def test_other_database_is_not_captured_into_production_directory(self):
        self.set_mode('local_full', runtime_db=str(self.root / 'live.sqlite'))
        with pc.planner_call(task_id=self.task, call_number=1, runtime_db=str(self.root / 'unit.sqlite')):
            pc.request_ready({'model':'unit'}, b'{"model":"unit"}', adapter='unit')
        self.assertEqual(self.snapshots(), [])

    def test_matching_runtime_database_still_captures(self):
        db=str(self.root / 'live.sqlite')
        self.set_mode('local_full', runtime_db=db)
        with pc.planner_call(task_id=self.task, call_number=1, runtime_db=db):
            pc.request_ready({'model':'live'}, b'{"model":"live"}', adapter='unit')
        result=self.snapshots()
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['wire_request']['model'], 'live')


if __name__ == '__main__':
    unittest.main()
