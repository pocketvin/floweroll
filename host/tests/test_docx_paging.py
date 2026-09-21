import unittest

from floweroll_host.docx_semantic import inspect_docx_bytes, render_docx, validate_inspect_arguments
from floweroll_host.planner_compaction import project_evidence


class DocxPagingTests(unittest.TestCase):
    def document(self):
        return render_docx({'output_name': 'paging.docx', 'title': '分页测试', 'sections': [
            {'heading': '正文', 'paragraphs': [{'text': f'第{i}段：' + '连续正文' * 120} for i in range(30)], 'bullets': []}
        ]})

    def test_windows_cover_the_text_exactly_once(self):
        data = self.document()
        whole = inspect_docx_bytes(data, max_chars=50000)
        offset, pieces = 0, []
        while True:
            page = inspect_docx_bytes(data, max_chars=1024, text_offset=offset)
            self.assertEqual(page['text_offset'], offset)
            self.assertEqual(page['total_chars'], len(whole['text']))
            self.assertEqual(page['text_sha256'], whole['text_sha256'])
            pieces.append(page['text'])
            following = page['next_text_offset']
            if following is None:
                break
            self.assertGreater(following, offset)
            offset = following
        self.assertEqual(''.join(pieces), whole['text'])

    def test_projection_cursor_advances_from_visible_text_not_hidden_tail(self):
        data = self.document()
        readback = inspect_docx_bytes(data, max_chars=50000)
        observation = [{'observation_id': 'source', 'capability': 'document.docx.inspect', 'data': {
            'file_id': 'docx-paging', 'sha256': 'a' * 64, 'readback': readback}}]
        for recovery in (False, True):
            projected = project_evidence(observation, recovery=recovery)[0]['data']
            visible = projected['readback']['text']
            cursor = projected['planner_next_read']
            self.assertEqual(cursor['file_id'], 'docx-paging')
            self.assertEqual(cursor['text_offset'], len(visible))
            next_page = inspect_docx_bytes(data, max_chars=1024, text_offset=cursor['text_offset'])
            self.assertEqual(visible + next_page['text'], readback['text'][:len(visible) + 1024])

    def test_duplicate_immutable_window_keeps_one_body_and_both_receipt_ids(self):
        observation = {'capability': 'document.docx.inspect', 'data': {
            'file_id': 'docx-paging', 'sha256': 'a' * 64,
            'readback': inspect_docx_bytes(self.document(), max_chars=50000)}}
        projected = project_evidence([
            {**observation, 'observation_id': 'first'},
            {**observation, 'observation_id': 'repeat'},
        ])
        self.assertEqual(len(projected), 2)
        self.assertEqual(projected[1]['data']['duplicate_of_observation_id'], 'first')
        self.assertNotIn('readback', projected[1]['data'])

    def test_invalid_cursor_is_not_silently_clamped(self):
        for offset in (-1, True, '4'):
            with self.subTest(offset=offset), self.assertRaises(Exception):
                validate_inspect_arguments({'file_id': 'docx', 'text_offset': offset})
        with self.assertRaises(Exception):
            inspect_docx_bytes(self.document(), text_offset=500000)
