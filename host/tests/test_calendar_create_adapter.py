from __future__ import annotations

import tempfile
import unittest
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from floweroll_host.calendar_create_adapter import CalendarCreateAdapter, calendar_create_arguments_valid
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.storage import Storage, StaleActionInputError
from floweroll_host.work_item_projection import project_work_items


ARGS = {"title": "面试", "start_at": "2026-09-16T10:00:00+08:00", "end_at": "2026-09-16T11:00:00+08:00",
        "time_zone": "Asia/Shanghai", "location": "上海", "calendar_name": "验收日历", "item_id": "interview"}


class CalendarCreateTests(unittest.TestCase):
    def make_runtime(self, path=":memory:"):
        store = Storage(path)
        task = store.create_task("calendar-task", "安排面试", "test", {}, status="active")
        action = store.create_action(action_id="calendar-action", task_id=task['task_id'], step_index=1,
            action_type="calendar.create", payload=dict(ARGS), expected={}, idempotency_key="calendar:one",
            on_verified="COMPLETE")
        return store, ExecutionRuntime(store, [CalendarCreateAdapter()]), task, action

    def approve(self, store, runtime, task):
        self.assertIsNone(runtime.next_action(task['task_id']))
        request = store.pending_action_input_for_action("calendar-action")
        self.assertIsNotNone(request)
        store.admit_action_input_response(task_id=task['task_id'], input_request_id=request['input_request_id'],
            event_id="approve", binding_digest=request['binding_digest'], response={"approved": True})
        store.consume_action_input_response(event_id="approve")
        return request

    def output(self):
        return {**ARGS, "start_at": "2026-09-16T02:00:00Z", "end_at": "2026-09-16T03:00:00Z",
                "event_id": "native-event", "calendar_id": "native-calendar", "verified": True,
                "all_day": False, "idempotency_marker": "calendar:one"}

    def test_confirmation_is_once_and_bound_across_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder)/'db.sqlite3')
            store, runtime, task, action = self.make_runtime(path)
            with ThreadPoolExecutor(max_workers=4) as pool:
                self.assertEqual(list(pool.map(lambda _: runtime.next_action(task['task_id']), range(8))), [None]*8)
            view = store.get_task_view(task['task_id'])
            self.assertFalse(any(row['presentation_state'] == 'ACTIVE' for row in view['timeline'] if row['kind'] == 'TOOL_ACTIVITY'))
            request = self.approve(store, runtime, task)
            self.assertIn('2026-09-16 10:00', request['prompt'])
            self.assertEqual(request['binding']['execution_fields'], ARGS)
            self.assertEqual(store.action_attempts(action['action_id']), [])
            store = Storage(path); runtime = ExecutionRuntime(store, [CalendarCreateAdapter()])
            dispatch = runtime.next_action(task['task_id'])
            self.assertEqual(dispatch['dispatch_digest'], request['binding']['dispatch_digest'])
            result = runtime.accept_result(task_id=task['task_id'], action_id=action['action_id'],
                attempt_id=dispatch['attempt_id'], success=True, output=self.output())
            self.assertEqual(result['attempt']['latest_outcome'], 'SUCCESS')
            self.assertEqual(result['task']['status'], 'completed')
            duplicate = runtime.accept_result(task_id=task['task_id'], action_id=action['action_id'],
                attempt_id=dispatch['attempt_id'], success=True, output=self.output())
            self.assertTrue(duplicate['duplicate'])
            self.assertEqual(len(store.verified_observations(task['task_id'])), 1)

    def test_rejection_prevents_dispatch_and_stale_confirmation(self):
        store, runtime, task, action = self.make_runtime()
        self.assertIsNone(runtime.next_action(task['task_id']))
        request = store.pending_action_input_for_action(action['action_id'])
        store.admit_action_input_response(task_id=task['task_id'], input_request_id=request['input_request_id'],
            event_id='reject', binding_digest=request['binding_digest'], response={'approved': False})
        store.consume_action_input_response(event_id='reject')
        self.assertIsNone(runtime.next_action(task['task_id']))
        self.assertEqual(store.action_attempts(action['action_id']), [])
        with self.assertRaises(StaleActionInputError):
            store.admit_action_input_response(task_id=task['task_id'], input_request_id=request['input_request_id'],
                event_id='late', binding_digest=request['binding_digest'], response={'approved': True})

    def test_cancel_during_confirmation_does_not_resurrect_task(self):
        store, runtime, task, action = self.make_runtime()
        original = runtime.adapters['calendar.create'].predispatch_confirmation
        def cancel_before_commit(value):
            request = original(value)
            store.admit_cancel_request(task_id=task['task_id'], event_id='cancel', reason='stop')
            store.consume_cancel_request(event_id='cancel')
            return request
        runtime.adapters['calendar.create'].predispatch_confirmation = cancel_before_commit
        self.assertIsNone(runtime.next_action(task['task_id']))
        self.assertEqual(store.get_task(task['task_id'])['status'], 'cancelled')
        self.assertIsNone(store.pending_action_input_for_action(action['action_id']))
        self.assertEqual(store.action_attempts(action['action_id']), [])

    def test_separate_runtimes_share_one_durable_confirmation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder)/'db.sqlite3')
            store, runtime, task, action = self.make_runtime(path)
            other = ExecutionRuntime(Storage(path), [CalendarCreateAdapter()])
            barrier = threading.Barrier(2)
            for instance in [runtime, other]:
                original = instance.adapters['calendar.create'].predispatch_confirmation
                def synchronized(value, original=original):
                    request = original(value)
                    barrier.wait(timeout=5)
                    return request
                instance.adapters['calendar.create'].predispatch_confirmation = synchronized
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda item: item.next_action(task['task_id']), [runtime, other]))
            self.assertEqual(results, [None, None])
            view = store.get_task_view(task['task_id'])
            prompts = [row for row in view['timeline'] if row['kind'] == 'WAITING_FOR_USER']
            self.assertEqual(len(prompts), 1)
            self.assertEqual(store.action_attempts(action['action_id']), [])

    def test_result_fields_are_readback_not_bare_success(self):
        adapter = CalendarCreateAdapter(); action = {'payload': ARGS, 'idempotency_key': 'calendar:one'}
        for field, value in [('verified', False), ('event_id', ''), ('calendar_id', None),
            ('calendar_name', '其他日历'), ('title', '旧版本'), ('start_at', ARGS['end_at']),
            ('end_at', 'garbage'), ('time_zone', 'UTC'), ('location', '杭州'),
            ('item_id', 'other'), ('all_day', True), ('idempotency_marker', 'other')]:
            with self.subTest(field=field):
                output = self.output(); output[field] = value
                self.assertEqual(adapter.verify_result(action, success=True, output=output, error=None).outcome, 'TERMINAL_FAILURE')
        self.assertEqual(adapter.verify_result(action, success=True, output={}, error=None).outcome, 'TERMINAL_FAILURE')

    def test_cancelled_inflight_native_receipt_can_reconcile_without_redispatch(self):
        store, runtime, task, action = self.make_runtime()
        self.approve(store, runtime, task)
        dispatch = runtime.next_action(task['task_id'])
        store.admit_cancel_request(task_id=task['task_id'], event_id='cancel', reason='stop')
        store.consume_cancel_request(event_id='cancel')
        self.assertIsNone(runtime.next_action(task['task_id'], source_kind='ios'))
        recovered = runtime.next_action(task['task_id'], source_kind='ios', supports_reconciliation=True)
        self.assertTrue(recovered['reconciliation_only'])
        self.assertEqual(recovered['attempt_id'], dispatch['attempt_id'])
        self.assertEqual(len(store.action_attempts(action['action_id'])), 1)
        result = runtime.accept_result(task_id=task['task_id'], action_id=action['action_id'],
            attempt_id=dispatch['attempt_id'], success=True, output=self.output())
        self.assertEqual(result['task']['status'], 'cancelled')
        self.assertEqual(len(store.verified_observations(task['task_id'])), 1)
        self.assertIsNone(runtime.next_action(task['task_id'], source_kind='ios', supports_reconciliation=True))

    def test_unknown_native_attempt_reuses_exact_identity_after_host_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder)/'db.sqlite3')
            store, runtime, task, action = self.make_runtime(path)
            self.approve(store, runtime, task)
            dispatch = runtime.next_action(task['task_id'])
            runtime.mark_current_attempt_unknown(task_id=task['task_id'], action_id=action['action_id'], reason='connection lost')
            reopened = ExecutionRuntime(Storage(path), [CalendarCreateAdapter()])
            self.assertIsNone(reopened.next_action(task['task_id'], source_kind='ios'))
            recovered = reopened.next_action(task['task_id'], source_kind='ios', supports_reconciliation=True)
            self.assertEqual(recovered['dispatch_digest'], dispatch['dispatch_digest'])
            self.assertEqual(recovered['attempt_id'], dispatch['attempt_id'])
            self.assertTrue(recovered['reconciliation_only'])
            result = reopened.accept_result(task_id=task['task_id'], action_id=action['action_id'],
                attempt_id=dispatch['attempt_id'], success=True, output=self.output())
            self.assertEqual(result['task']['status'], 'completed')

    def test_argument_time_zone_and_write_scope(self):
        self.assertTrue(calendar_create_arguments_valid(ARGS))
        for change in [{'end_at': ARGS['start_at']}, {'start_at': '2026-09-16T10:00:00'},
            {'time_zone': 'UTC'}, {'time_zone': 'Invalid/Zone'}, {'title': '  '},
            {'attendees': ['hr@example.com']}, {'all_day': True}, {'item_id': None},
            {'end_at': '2026-10-16T11:00:00+08:00'}]:
            self.assertFalse(calendar_create_arguments_valid({**ARGS, **change}), change)

    def test_calendar_outcome_is_automatic_and_does_not_complete_other_items(self):
        observation = {'action_id': 'calendar-action', 'capability': 'calendar.create', 'data': self.output()}
        plan = {'title': '面试准备', 'items': [
            {'id': 'pdf', 'title': '资料', 'completion_rule': 'document', 'depends_on': []},
            {'id': 'interview', 'title': '面试日程', 'completion_rule': 'calendar_event', 'depends_on': []},
            {'id': 'second', 'title': '第二天日程', 'completion_rule': 'calendar_event', 'depends_on': []}]}
        outputs = [{'id': 'file', 'metadata': {'item_id': 'pdf', 'status': 'ready'}}]
        pending = project_work_items(plan, outputs, [], item_actions={'interview': {
            'status': 'pending', 'waiting_input': True, 'payload': {'item_id': 'interview'}}})
        self.assertEqual(pending['completed'], 1)
        self.assertEqual(pending['items'][1]['state'], 'waiting_approval')
        result = project_work_items(plan, outputs, [observation])
        self.assertEqual(result['completed'], 2)
        self.assertIn('09月16日 10:00', result['items'][1]['result_summary'])
        self.assertEqual(result['items'][2]['state'], 'pending')
        forged_association = {'capability': 'deliverables.verify', 'data': {'item_id': 'second',
            'completion_rule': 'calendar_event', 'evidence_action_id': 'calendar-action'}}
        self.assertEqual(project_work_items(plan, outputs, [observation, forged_association])['completed'], 2)


if __name__ == '__main__':
    unittest.main()
