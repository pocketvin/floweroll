import json,socket,ssl,unittest,urllib.error
from unittest.mock import patch
from floweroll_host.capabilities_v0 import REMINDER_CREATE
from floweroll_host.openai_compatible_chat_adapter import OpenAICompatibleChatPlannerAdapter,OpenAICompatibleChatPlannerError
import host.tests.test_openai_compatible_chat_adapter as base

class PlannerTransportRecoveryTests(unittest.TestCase):
    def adapter(self):
        return OpenAICompatibleChatPlannerAdapter(api_key='sensitive-test-token',base_url='https://example.invalid',model='test')
    def response(self):
        decision={'decision_type':'EXECUTE','interpreted_goal_summary':'创建提醒','plan_update':['创建提醒'],'action':{'capability':'reminder.create','arguments':{'title':'报告','due_at':'2026-09-12T10:00:00+08:00'}},'on_verified':'COMPLETE','clarification':None,'wait':None,'completion':None,'stop_reason':None,'cancellation':None,'state_update':None}
        data=json.dumps({'choices':[{'finish_reason':'stop','message':{'content':json.dumps(decision)}}]}).encode()
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self): return data
        return Response()
    def test_raw_and_wrapped_timeout_recover_with_one_retry(self):
        for error in [socket.timeout('read timed out'),urllib.error.URLError(socket.timeout('read timed out'))]:
            with self.subTest(error=type(error).__name__),patch('floweroll_host.openai_compatible_chat_adapter.time.sleep'),patch('floweroll_host.openai_compatible_chat_adapter.urllib.request.urlopen',side_effect=[error,self.response()]) as transport:
                result=self.adapter().decide(base.OpenAICompatibleChatPlannerAdapterTests().request(),[REMINDER_CREATE])
                self.assertEqual(result.decision_type,'EXECUTE');self.assertEqual(transport.call_count,2)
    def test_retry_budget_is_finite(self):
        with patch('floweroll_host.openai_compatible_chat_adapter.time.sleep'),patch('floweroll_host.openai_compatible_chat_adapter.urllib.request.urlopen',side_effect=socket.timeout('read timed out')) as transport:
            with self.assertRaises(OpenAICompatibleChatPlannerError):self.adapter().decide(base.OpenAICompatibleChatPlannerAdapterTests().request(),[REMINDER_CREATE])
            self.assertEqual(transport.call_count,2)
    def test_certificate_failure_is_not_retried(self):
        with patch('floweroll_host.openai_compatible_chat_adapter.urllib.request.urlopen',side_effect=urllib.error.URLError(ssl.SSLError('certificate failure'))) as transport:
            with self.assertRaises(OpenAICompatibleChatPlannerError):self.adapter().decide(base.OpenAICompatibleChatPlannerAdapterTests().request(),[REMINDER_CREATE])
            self.assertEqual(transport.call_count,1)
    def test_network_error_redacts_exact_configured_credential(self):
        with patch('floweroll_host.openai_compatible_chat_adapter.urllib.request.urlopen',side_effect=urllib.error.URLError('sensitive-test-token')):
            with self.assertRaises(OpenAICompatibleChatPlannerError) as error:self.adapter().decide(base.OpenAICompatibleChatPlannerAdapterTests().request(),[REMINDER_CREATE])
            self.assertNotIn('sensitive-test-token',str(error.exception))
