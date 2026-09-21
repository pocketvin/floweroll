import unittest

from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_tool_adapter import FunctionToolAdapter
from floweroll_host.storage import Storage


class AcceptanceRecoveryTests(unittest.TestCase):
    def make_action(self, capability, *, source='ios', read_only=True, on_verified='REPLAN'):
        store = Storage(':memory:')
        task = store.create_task('acceptance-task', '验收', 'test', {}, status='active')
        action = store.create_action(action_id='acceptance-action', task_id=task['task_id'],
                                    step_index=1, action_type=capability, payload={}, expected={},
                                    idempotency_key='acceptance-key', on_verified=on_verified)
        adapter = FunctionToolAdapter(capability_id=capability, source_kind=source,
                                      read_only=read_only, replay_safe=True, max_attempts=1)
        runtime = ExecutionRuntime(store, [adapter])
        dispatch = runtime.next_action(task['task_id'], source_kind=source)
        self.assertIsNotNone(dispatch)
        return store, runtime, task, action, dispatch

    def test_legacy_native_reads_can_be_cancelled_without_lost_device_journal(self):
        for capability in ('location.current', 'reminder.query', 'calendar.query', 'contacts.query'):
            with self.subTest(capability=capability):
                store, runtime, task, action, dispatch = self.make_action(capability)
                store.admit_cancel_request(task_id=task['task_id'], event_id='delete', reason='用户已删除')
                result = store.consume_cancel_request(event_id='delete')
                self.assertEqual(result['status'], 'cancelled')
                self.assertEqual(store.get_action(action['action_id'])['status'], 'cancelled')
                self.assertEqual(store.get_action_attempt(dispatch['attempt_id'])['latest_outcome'], 'CANCELLED')
                # A late native query receipt cannot resurrect the deleted Task.
                late = runtime.accept_result(task_id=task['task_id'], action_id=action['action_id'],
                                             attempt_id=dispatch['attempt_id'], success=True, output={'data': 'late'})
                self.assertTrue(late['duplicate'])
                self.assertEqual(store.get_task(task['task_id'])['status'], 'cancelled')
                self.assertEqual(len(store.action_attempts(action['action_id'])), 1)

    def test_unknown_native_writes_still_require_reconciliation_on_cancel(self):
        store, _, task, action, dispatch = self.make_action('alarm.update', read_only=False)
        store.admit_cancel_request(task_id=task['task_id'], event_id='stop', reason='停止')
        result = store.consume_cancel_request(event_id='stop')
        self.assertEqual(result['status'], 'active')
        self.assertTrue(result['cancellation_pending'])
        self.assertEqual(store.get_action_attempt(dispatch['attempt_id'])['status'], 'IN_FLIGHT')
        self.assertEqual(store.get_action(action['action_id'])['status'], 'executing')

    def test_exhausted_research_source_replans_without_claiming_success(self):
        store, runtime, task, action, dispatch = self.make_action('web.fetch', source='host_http')
        result = runtime.accept_result(task_id=task['task_id'], action_id=action['action_id'],
                                       attempt_id=dispatch['attempt_id'], success=False,
                                       output={'error_kind': 'transient'}, error='network error: SSLError')
        self.assertEqual(result['task']['status'], 'active')
        self.assertEqual(result['action']['status'], 'failed')
        self.assertEqual(result['attempt']['latest_outcome'], 'MODEL_CORRECTABLE_FAILURE')
        self.assertEqual(store.get_runtime_state(task['task_id'])['phase'], 'planning')
        self.assertIn('SSLError', result['action']['error'])
        basis = store.planner_basis(task['task_id'])
        self.assertIsNotNone(basis['last_semantic_failure'])
        self.assertFalse(any(o['capability'] == 'web.fetch' for o in basis['verified_observations']))

    def test_direct_fetch_failure_and_write_failure_remain_terminal(self):
        for capability, read_only in [('web.fetch', True), ('test.write', False)]:
            with self.subTest(capability=capability):
                store, runtime, task, action, dispatch = self.make_action(
                    capability, source='host_http', read_only=read_only, on_verified='COMPLETE')
                result = runtime.accept_result(task_id=task['task_id'], action_id=action['action_id'],
                                               attempt_id=dispatch['attempt_id'], success=False,
                                               output={'error_kind': 'transient'}, error='network error')
                self.assertEqual(result['task']['status'], 'failed')
                self.assertEqual(result['attempt']['latest_outcome'], 'TERMINAL_FAILURE')
