from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.server import create_server


class DeviceActionWaitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.server = create_server(
            "127.0.0.1",
            0,
            str(Path(self.tmp.name) / "device-wait.sqlite3"),
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:{}".format(self.server.server_address[1])

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def request(self, path: str, *, method: str = "GET", body=None):
        data = None if body is None else json.dumps(body).encode()
        headers = {"Content-Type": "application/json"} if data is not None else {}
        req = urllib.request.Request(
            self.base + path, data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=4) as response:
                data = response.read()
                return response.status, json.loads(data.decode()) if data else None
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode()) if raw else None

    def test_device_action_wait_returns_as_soon_as_action_is_committed(self) -> None:
        task = self.server.app.storage.create_task(
            task_id="device-wait-task",
            goal="wait for native action",
            invocation_source="unit",
            policy_snapshot={},
            status="active",
        )
        result = {}

        def wait_for_action() -> None:
            started = time.monotonic()
            status, body = self.request(
                f"/v1/tasks/{task['task_id']}/next-device-action?wait_seconds=2"
            )
            result.update(status=status, body=body, elapsed=time.monotonic() - started)

        waiter = threading.Thread(target=wait_for_action)
        waiter.start()
        time.sleep(0.2)
        self.server.app.storage.create_action(
            action_id="device-wait-action",
            task_id=task["task_id"],
            step_index=1,
            action_type="device.probe",
            payload={"message": "ready"},
            expected={},
            idempotency_key="device-wait-task:1",
            on_verified="COMPLETE",
        )
        waiter.join(timeout=3)

        self.assertFalse(waiter.is_alive())
        self.assertEqual(result["status"], 200)
        self.assertEqual(result["body"]["action_id"], "device-wait-action")
        self.assertGreaterEqual(result["elapsed"], 0.18)
        self.assertLess(result["elapsed"], 0.8)

    def test_device_action_wait_rejects_out_of_range_window(self) -> None:
        task = self.server.app.storage.create_task(
            task_id="device-wait-invalid",
            goal="wait invalid",
            invocation_source="unit",
            policy_snapshot={},
            status="active",
        )
        status, body = self.request(
            f"/v1/tasks/{task['task_id']}/next-device-action?wait_seconds=21"
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["code"], "INVALID_DEVICE_ACTION_WAIT")

    def test_readonly_reconciliation_requires_new_client_opt_in(self):
        app = self.server.app
        app.storage.create_task('recover', 'recover', 'test', {}, status='active')
        app.storage.create_action(action_id='recover-action', task_id='recover', step_index=1,
            action_type='device.probe', payload={'message': 'ready'}, expected={},
            idempotency_key='recover:1', on_verified='COMPLETE')
        original = app.execution.next_action('recover')
        app.execution.mark_current_attempt_unknown(task_id='recover', action_id='recover-action', reason='lost')
        for endpoint in ['next-device-action', 'next-action?supports_reconciliation=true',
                         'next-device-action?supports_reconciliation=false']:
            self.assertEqual(self.request('/v1/tasks/recover/'+endpoint)[0], 204)
        status, dispatch = self.request('/v1/tasks/recover/next-device-action?supports_reconciliation=true')
        self.assertEqual(status, 200)
        self.assertTrue(dispatch['reconciliation_only'])
        self.assertEqual(dispatch['attempt_id'], original['attempt_id'])

    def test_device_definitely_not_started_http_finalizes_pending_cancel_idempotently(self):
        app = self.server.app
        app.storage.create_task(
            'cancel-reconcile', 'execute device operation', 'test', {}, status='active'
        )
        app.storage.create_action(
            action_id='cancel-reconcile-action',
            task_id='cancel-reconcile',
            step_index=1,
            action_type='device.probe',
            payload={'message': 'ready'},
            expected={},
            idempotency_key='cancel-reconcile:1',
            on_verified='COMPLETE',
        )
        dispatch = app.execution.next_action('cancel-reconcile', source_kind='ios')
        self.assertIsNotNone(dispatch)
        app.storage.admit_cancel_request(
            task_id='cancel-reconcile',
            event_id='cancel-reconcile-event',
            reason='stop',
        )
        app.storage.consume_cancel_request(event_id='cancel-reconcile-event')

        path = (
            '/v1/tasks/cancel-reconcile/actions/cancel-reconcile-action/'
            'reconciliations/definitely-not-started'
        )
        wrong_status, wrong = self.request(
            path,
            method='POST',
            body={'attempt_id': 'wrong-attempt'},
        )
        self.assertEqual(wrong_status, 404)
        self.assertEqual(wrong['code'], 'ACTION_ATTEMPT_NOT_FOUND')

        status, body = self.request(
            path,
            method='POST',
            body={'attempt_id': dispatch['attempt_id']},
        )
        self.assertEqual(status, 200)
        self.assertEqual(body['task']['status'], 'cancelled')
        self.assertEqual(body['action']['status'], 'cancelled')
        self.assertEqual(len(app.storage.action_attempts('cancel-reconcile-action')), 1)

        replay_status, replay = self.request(
            path,
            method='POST',
            body={'attempt_id': dispatch['attempt_id']},
        )
        self.assertEqual(replay_status, 200)
        self.assertEqual(replay['task']['status'], 'cancelled')
        self.assertEqual(len(app.storage.action_attempts('cancel-reconcile-action')), 1)


if __name__ == "__main__":
    unittest.main()
