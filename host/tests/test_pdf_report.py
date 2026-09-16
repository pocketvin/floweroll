from __future__ import annotations

import hashlib
import json
import platform
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from floweroll_host.server import create_server
from floweroll_host.task_material_tools import TaskMaterialTools

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == 'Darwin', 'Actual CoreText/PDFKit rendering requires macOS')
class NativePDFReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT/'work').mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix='pdf-report-test-', dir=ROOT/'work')
        cls.root = Path(cls.temp.name)
        cls.binary = cls.root/'DocumentWorkshop'
        subprocess.run(['/usr/bin/xcrun','swiftc','-O',str(ROOT/'host/native_helpers/DocumentWorkshop.swift'),'-o',str(cls.binary)],
                       capture_output=True, text=True, check=True, timeout=100)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.case = self.root/uuid.uuid4().hex
        self.case.mkdir()
        self.server = create_server('127.0.0.1',0,str(self.case/'runtime.sqlite3'), task_asset_root=self.case/'assets')
        self.app = self.server.app
        self.app.supervisor.stop()
        self.addCleanup(self.server.server_close)
        binary_patch = patch.object(TaskMaterialTools, '_binary', return_value=self.binary)
        binary_patch.start()
        self.addCleanup(binary_patch.stop)
        self.tid = str(uuid.uuid4())
        self.app.storage.create_task(self.tid, '解析文件并以PDF交付', 'test', {}, status='active')
        self.step = 0

    def args(self, title='解析报告', text='中文内容与 English text：2026-09-18，300 元。', **kwargs):
        return {'title':title, 'markdown':text, 'category':'study', 'status':'ready', 'output_format':'pdf', **kwargs}

    def action(self, capability, arguments):
        self.step += 1
        aid = str(uuid.uuid4())
        self.app.storage.create_action(action_id=aid, task_id=self.tid, step_index=self.step,
            action_type=capability, payload=arguments, expected={}, idempotency_key=aid, on_verified='REPLAN')
        self.app.function_worker.run_once(self.tid)
        return self.app.storage.get_action(aid)

    def test_pdf_is_real_searchable_multipage_and_manifest_deliverable(self):
        text = '\n\n'.join(f'第{i}节：机械故障、传感器与时间 10:00。English material {i}. ' * 3 for i in range(90))
        result = self.action('deliverables.publish', self.args(text=text))
        self.assertEqual(result['status'], 'succeeded', result)
        outputs = self.app.task_assets.manifest(self.tid)['outputs']
        self.assertEqual(len(outputs),1)
        out = outputs[0]
        self.assertEqual(out['media_type'],'application/pdf')
        self.assertTrue(out['name'].endswith('.pdf'))
        self.assertGreater(out['metadata']['page_count'],1)
        self.assertTrue(out['metadata']['text_verified'])
        data = self.app.task_assets.file_path(self.tid, out['id']).read_bytes()
        self.assertTrue(data.startswith(b'%PDF-'))
        self.assertEqual(hashlib.sha256(data).hexdigest(), out['sha256'])

    def test_pdf_and_other_report_can_execute_in_same_real_batch(self):
        units = [{'id':n, 'title':n, 'capability':'deliverables.publish',
                  'arguments_json':json.dumps(self.args(title=n)), 'depends_on':[]} for n in ['analysis','travel']]
        result = self.action('work.execute', {'units':units})
        self.assertEqual(result['status'],'succeeded',result)
        receipts = self.app.task_assets.work_units.evidence(self.tid)
        self.assertEqual(len(receipts),2)
        self.assertEqual(len(self.app.task_assets.manifest(self.tid)['outputs']),2)

    def test_fabricated_source_id_never_publishes_a_pdf(self):
        result = self.action('deliverables.publish', self.args(source_ids=['other-task-source']))
        self.assertEqual(result['status'],'failed')
        self.assertEqual(self.app.task_assets.manifest(self.tid)['outputs'], [])

    def test_default_html_contract_and_plaintext_html_safety_are_preserved(self):
        args = self.args(text='<script>alert("not executable")</script>')
        del args['output_format']
        result = self.action('deliverables.publish', args)
        self.assertEqual(result['status'],'succeeded',result)
        out = self.app.task_assets.manifest(self.tid)['outputs'][0]
        self.assertEqual(out['media_type'],'text/html')
        data = self.app.task_assets.file_path(self.tid,out['id']).read_text()
        self.assertIn('&lt;script&gt;',data)

    def test_invalid_format_fails_before_file_publication(self):
        result = self.action('deliverables.publish', self.args(output_format='docx'))
        self.assertEqual(result['status'],'failed')
        self.assertEqual(self.app.task_assets.manifest(self.tid)['outputs'],[])
