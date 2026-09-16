"""Decode the Host contract with the production Swift model, including old hosts."""
import json
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path

from floweroll_host.work_item_projection import project_work_items


@unittest.skipUnless(platform.system() == 'Darwin', 'Swift contract check requires macOS')
class IOSWorkProgressContractTests(unittest.TestCase):
    def test_progress_uses_verified_items_and_unknown_is_not_a_percentage(self):
        root = Path(__file__).resolve().parents[2]
        models = root/'ios/Floweroll/App/RuntimeClient/HostModels.swift'
        materials = (root/'ios/Floweroll/App/RuntimeClient/Materials/Attachments/TaskAttachmentModels.swift').read_text()
        # Include the actual attachment value/error types required by HostModels,
        # omitting SwiftUI/camera code that cannot run in a macOS command test.
        attachment_start = materials.index('struct PendingAttachment:')
        attachment_types = materials[attachment_start:]
        summary = project_work_items({'title': '验证', 'items': [
            {'id': 'doc', 'title': '资料', 'completion_rule': 'document', 'depends_on': []},
            {'id': 'hotel', 'title': '预订', 'completion_rule': 'reservation', 'depends_on': []}]},
            [{'id':'file', 'metadata':{'item_id':'doc', 'status':'ready'}}], [])
        view = {'task': {'task_id':'test', 'thread_id':'test', 'goal':'验证', 'status':'waiting',
            'current_step':99, 'created_at':'2026-09-11T00:00:00Z', 'updated_at':'2026-09-11T00:00:00Z'},
            'timeline':[], 'artifacts':[], 'presentation_cursor':0, 'work_summary':summary}
        main = '''import Foundation
var payload = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
func decode() throws -> HostTaskView {
    try JSONDecoder().decode(HostTaskView.self, from: JSONSerialization.data(withJSONObject: payload))
}
var value = try decode()
precondition(value.progressUnitCounts.completed == 1 && value.progressUnitCounts.total == 2)
precondition(value.workSummary?.fraction == 0.5)
for status in ["cancelled", "failed", "blocked", "active"] {
    var task = payload["task"] as! [String: Any]; task["status"] = status; payload["task"] = task
    value = try decode()
    precondition(value.progressUnitCounts.completed == 1 && value.progressUnitCounts.total == 2)
}
// Reject inconsistent counts instead of displaying a fabricated completed bar.
var bad = payload["work_summary"] as! [String: Any]; bad["completed"] = 2; payload["work_summary"] = bad
precondition(try decode().progressUnitCounts.total == -1)
// Old hosts have no work_summary; decoding still succeeds and waits honestly.
payload.removeValue(forKey: "work_summary")
value = try decode()
precondition(value.workSummary == nil && value.progressUnitCounts.total == -1)
var task = payload["task"] as! [String: Any]; task["status"] = "completed"; payload["task"] = task
value = try decode()
precondition(value.progressUnitCounts.completed == 1 && value.progressUnitCounts.total == 1)
print("Swift outcome progress contract passed")
'''
        # Swift precondition's autoclosure is non-throwing.
        main = main.replace('precondition(try decode().progressUnitCounts.total == -1)',
                            'value = try decode(); precondition(value.progressUnitCounts.total == -1)')
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder)
            (work/'Attachments.swift').write_text('import Foundation\nimport CryptoKit\n' + attachment_types)
            (work/'main.swift').write_text(main)
            (work/'view.json').write_text(json.dumps(view, ensure_ascii=False))
            build = subprocess.run(['/usr/bin/xcrun', 'swiftc', str(models), str(work/'Attachments.swift'),
                str(work/'main.swift'), '-o', str(work/'progress-check')], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(work/'progress-check'), str(work/'view.json')],
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('contract passed', result.stdout)
