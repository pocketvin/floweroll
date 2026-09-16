from __future__ import annotations

import copy
import json
import os
import tempfile
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

from langsmith.run_helpers import get_tracing_context

from floweroll_host.capabilities_v0 import REMINDER_CREATE
from floweroll_host.context_builder import ContextBuilder
from floweroll_host.developer_observability import DeveloperObservabilityService
from floweroll_host.openai_compatible_chat_adapter import OpenAICompatibleChatPlannerAdapter
from floweroll_host.planner_compaction import compact_context, project_evidence
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.planner_graph import GRAPH_NAME, PlannerGraph, PlannerGraphServices
from floweroll_host.planner_request import PlannerRequestBuilder
from floweroll_host.runtime_supervisor import RuntimeSupervisor
from floweroll_host.storage import Storage
from floweroll_host.task_runtime import TaskRuntime


def context(task_id="test", observations=None):
    return ContextBuilder().build(
        task_id=task_id, raw_goal="后天去上海；预算300元；不要预订", current_time=datetime(2026, 9, 16, tzinfo=timezone.utc),
        timezone_name="Asia/Shanghai", capabilities=[REMINDER_CREATE],
        policy_view={"allowed_capabilities": [REMINDER_CREATE.name], "constraints": ["不要预订"]},
        verified_observations=observations or [],
        user_turns=[{"event_id": "turn-1", "content": {"text": "不要付款"}}],
        runtime_context={"relevant_memories": [{"memory": "喜欢交通便利的酒店", "memory_id": "mem-1"}]},
    )


def docx_row():
    text = "原件内容12345。" * 800 + "原件结尾END"
    return {"observation_id": "unit-docx", "action_id": "unit-docx", "parent_action_id": "parent",
            "work_unit_id": "docx", "capability": "document.docx.inspect", "verified": True,
            "data": {"file_id": "file-exact", "readback": {"text": text, "paragraphs": [text],
                "text_sha256": "a" * 64, "truncated": False, "warnings": ["表格版式未重建"],
                "features": {"unsupported_detected": ["table_structure_reconstruction"]}}}}


def search_row():
    return {
        "observation_id": "unit-search",
        "action_id": "unit-search",
        "capability": "capability.search",
        "verified": True,
        "data": {
            "query": "上海黄浦区 酒店 房间 查询",
            "domain": "travel",
            "selected_capability_ids": ["travel.hotel.search", "work.execute"],
            "new_capability_ids": ["travel.hotel.search"],
            "total_candidates": 12,
            "offset": 0,
            "next_offset": 6,
            "has_more": True,
            "notice": "很长的发现说明" * 100,
            "repeated_page": False,
            "search_allowed": True,
            "searches_remaining": 3,
        },
    }


def reminder_decision():
    return PlannerDecision("EXECUTE", "创建提醒", None,
        {"capability": "reminder.create", "arguments": {"title": "面试", "due_at": "2026-09-18T10:00:00+08:00"}},
        "REPLAN", None, None, None, None)


def context_in_request(request):
    return json.loads(next(message["content"] for message in request["input"] if message["role"] == "user"))["decision_context"]


class PlannerGraphTests(unittest.TestCase):
    def services(self, planner, *, value=None, recovery=False):
        value = value or context()
        return PlannerGraphServices(
            load_memory=lambda: {"items": value.runtime_context["relevant_memories"]},
            build_context=lambda memories: value,
            select_context=lambda value: value,
            build_request=PlannerRequestBuilder().build,
            adapter=planner, assert_current=lambda: None, recovery=recovery,
        )

    def test_compiled_stategraph_owns_real_nodes_and_no_checkpoint_or_tool_execution(self):
        calls = []
        class Planner:
            def decide(self, request, capabilities):
                calls.append(request)
                return reminder_decision()
        services = self.services(Planner())
        engine = PlannerGraph()
        result = engine.invoke(services)
        self.assertEqual(result, reminder_decision())
        self.assertEqual(len(calls), 1)
        self.assertEqual([s["node"] for s in services.steps], [
            "memory", "build_context", "select_capabilities", "compact_context", "build_request", "call_model", "validate"])
        self.assertEqual(services.metrics["planner_engine"], "langgraph")
        self.assertIsNone(engine.graph.checkpointer)
        self.assertNotIn("tools", engine.graph.get_graph().nodes)

    def test_recovery_branch_changes_context_without_changing_authority_or_memory(self):
        value = context(observations=[docx_row()])
        before = copy.deepcopy(value.model_view())
        requests = []
        class Planner:
            def decide(self, request, capabilities):
                requests.append(request)
                return reminder_decision()
        engine = PlannerGraph()
        normal, recovery = self.services(Planner(), value=value), self.services(Planner(), value=value, recovery=True)
        engine.invoke(normal)
        engine.invoke(recovery)
        self.assertIn("recovery_context", [s["node"] for s in recovery.steps])
        self.assertNotIn("compact_context", [s["node"] for s in recovery.steps])
        contexts = [context_in_request(r) for r in requests]
        for field in ("task", "time", "policy", "user_turns", "available_capabilities"):
            self.assertEqual(contexts[0][field], contexts[1][field])
        self.assertEqual(contexts[0]["runtime_context"]["relevant_memories"], contexts[1]["runtime_context"]["relevant_memories"])
        self.assertLess(recovery.metrics["request_bytes"], normal.metrics["request_bytes"])
        recovered = contexts[1]["verified_observations"][0]
        self.assertEqual(recovered["data"]["file_id"], "file-exact")
        self.assertTrue(recovered["data"]["planner_text_truncated"])
        self.assertEqual(value.model_view(), before)

    def test_recovery_projection_drops_duplicate_catalog_and_verbose_search_history(self):
        value = context(observations=[docx_row(), search_row()])
        value.runtime_context["capability_catalog"] = {
            "instruction": "目录说明" * 500,
            "recent_pages": [{"notice": "重复目录内容" * 500}],
        }
        before = copy.deepcopy(value.model_view())
        normal, normal_metrics = compact_context(value, recovery=False)
        recovered, recovery_metrics = compact_context(value, recovery=True)

        self.assertIn("capability_catalog", normal.runtime_context)
        self.assertNotIn("capability_catalog", recovered.runtime_context)
        self.assertEqual(
            recovered.runtime_context["relevant_memories"],
            value.runtime_context["relevant_memories"],
        )
        docx = next(row for row in recovered.verified_observations if row["capability"] == "document.docx.inspect")
        self.assertEqual(docx["data"]["file_id"], "file-exact")
        self.assertEqual(docx["data"]["readback"]["text_sha256"], "a" * 64)
        self.assertEqual(docx["data"]["readback"]["warnings"], ["表格版式未重建"])
        self.assertLessEqual(len(docx["data"]["readback"]["text"]), 900)
        search = next(row for row in recovered.verified_observations if row["capability"] == "capability.search")
        self.assertEqual(search["data"]["selected_capability_ids"], ["travel.hotel.search", "work.execute"])
        self.assertEqual(search["data"]["query"], "上海黄浦区 酒店 房间 查询")
        self.assertNotIn("notice", search["data"])
        self.assertNotIn("offset", search["data"])
        self.assertLess(
            recovery_metrics["context_chars_after_compaction"],
            normal_metrics["context_chars_after_compaction"] * 0.7,
        )
        self.assertEqual(value.model_view(), before)

    def test_mcp_transport_dedup_requires_exact_equality_and_preserves_warnings(self):
        structured = {"city": "上海", "forecasts": [{"date": "2026-09-18", "daytemp": "30"}]}
        warning = {"type": "text", "text": "数据暂缺"}
        row = {"capability": "weather.query", "data": {"structured_content": structured,
            "content": [{"type": "text", "text": json.dumps(structured)}, warning], "truncated": True}}
        original = copy.deepcopy(row)
        projected = project_evidence([row])[0]
        self.assertEqual(projected["data"]["content"], [warning])
        self.assertEqual(projected["data"]["structured_content"], structured)
        self.assertTrue(projected["data"]["truncated"])
        self.assertEqual(row, original)

    def test_mcp_annotated_text_is_not_discarded_as_duplicate_transport(self):
        data = {"value": 1}
        block = {"type": "text", "text": json.dumps(data),
                 "annotations": {"audience": ["user"], "priority": 0.9}}
        row = {"capability": "weather.query", "data": {"structured_content": data, "content": [block]}}
        self.assertEqual(project_evidence([row])[0], row)

    def test_parent_compaction_retains_failed_and_missing_child_receipts(self):
        parent = {"action_id": "parent", "capability": "work.execute", "data": {"all_completed": False,
            "units": [{"id": "docx", "state": "completed", "receipt_id": "unit-docx"},
                      {"id": "missing", "state": "completed", "receipt_id": "unit-not-loaded"},
                      {"id": "failed", "state": "failed", "error": "network failed"}]}}
        result = project_evidence([parent, docx_row()])
        self.assertEqual([x["id"] for x in result[0]["data"]["units"]], ["missing", "failed"])
        self.assertFalse(result[0]["data"]["all_completed"])
        self.assertEqual(project_evidence([parent])[0], parent)

    def test_native_exact_target_and_permission_receipts_are_never_truncated(self):
        data = {"event_id": "event-a", "expected_revision": "fresh-exact", "calendar_id": "calendar-a",
                "notes": "重要信息" * 15000, "start_at": "2026-09-18T10:00:00+08:00", "verified": True}
        row = {"capability": "calendar.query", "data": data}
        result, _ = compact_context(context(observations=[row]), recovery=True)
        self.assertEqual(result.verified_observations[0], row)

    def test_langsmith_environment_does_not_enable_external_task_tracing(self):
        flags = []
        class Planner:
            def decide(self, request, capabilities):
                flags.append(get_tracing_context()["enabled"])
                return reminder_decision()
        with patch.dict(os.environ, {"LANGSMITH_TRACING": "true", "LANGCHAIN_TRACING_V2": "true"}):
            PlannerGraph().invoke(self.services(Planner()))
        self.assertEqual(flags, [False])

    def test_graph_state_is_isolated_across_concurrent_tasks(self):
        barrier = threading.Barrier(2, timeout=3)
        seen = []
        class Planner:
            def decide(self, request, capabilities):
                goal = context_in_request(request)["task"]["task_id"]
                barrier.wait()
                seen.append(goal)
                result = reminder_decision()
                result.interpreted_goal_summary = goal
                return result
        graph = PlannerGraph()
        services = [self.services(Planner(), value=context(task_id=tid)) for tid in ["alpha", "beta"]]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(graph.invoke, services))
        self.assertEqual([x.interpreted_goal_summary for x in results], ["alpha", "beta"])
        self.assertEqual(set(seen), {"alpha", "beta"})
        self.assertIsNot(services[0].steps, services[1].steps)

    def test_invalid_model_decision_never_leaves_the_graph(self):
        class Planner:
            def decide(self, request, capabilities):
                result = reminder_decision()
                result.action = {"capability": "payment.charge", "arguments": {}}
                return result
        services = self.services(Planner())
        with self.assertRaises(ValueError):
            PlannerGraph().invoke(services)
        self.assertEqual(services.steps[-1]["node"], "validate")
        self.assertEqual(services.steps[-1]["outcome"], "error")

    def test_diagnostic_write_failure_does_not_change_planner_result(self):
        class Planner:
            def decide(self, request, capabilities):
                return reminder_decision()
        services = self.services(Planner())
        services.emit = lambda event: (_ for _ in ()).throw(OSError("disk unavailable"))
        self.assertEqual(PlannerGraph().invoke(services), reminder_decision())


class PlannerGraphRuntimeTests(unittest.TestCase):
    def setup_runtime(self, *, db=":memory:", budget=32):
        store = Storage(db)
        adapter = OpenAICompatibleChatPlannerAdapter(api_key="test-not-real", base_url="https://example.test", model="test",
                                                    transient_http_retries=2)
        runtime = TaskRuntime(store, adapter, [REMINDER_CREATE], max_planner_calls=budget)
        runtime.additional_observation_provider = lambda tid: [docx_row()]
        task = runtime.create_task("帮我准备面试材料，然后创建提醒")
        supervisor = RuntimeSupervisor(store, runtime)
        return store, runtime, task["task_id"], supervisor

    def resume(self, store, tid):
        wait_id = store.get_runtime_state(tid)["wait_id"]
        event_id = "timer:" + wait_id
        store.admit_inbox_event(task_id=tid, event_id=event_id, event_type="TIMER_FIRED", source="runtime_scheduler",
                               target_type="WAIT", target_id=wait_id, payload={})
        store.resume_planner_retry_wait(task_id=tid, wait_id=wait_id, event_id=event_id)

    def test_real_adapter_uses_one_http_attempt_per_durable_graph_call(self):
        store, runtime, tid, supervisor = self.setup_runtime()
        payloads = []
        timeouts = []
        def transport(request, timeout):
            payloads.append(json.loads(request.data))
            timeouts.append(timeout)
            if len(payloads) == 1:
                raise TimeoutError("synthetic timeout")
            return BytesIO(json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(asdict(reminder_decision()))}}],
                                      "usage": {"total_tokens": 123}}).encode())
        with patch("urllib.request.urlopen", side_effect=transport):
            first = supervisor.advance_task(tid)
            self.assertEqual(first["status"], "WAITING")
            self.assertEqual(len(payloads), 1)
            self.resume(store, tid)
            second = supervisor.advance_task(tid)
            self.assertEqual(second["status"], "ADVANCED")
        self.assertEqual(len(payloads), 2)
        self.assertEqual(timeouts[0], runtime.planner_adapter.timeout_seconds)
        self.assertGreaterEqual(timeouts[1], 120.0)
        self.assertLess(len(json.dumps(payloads[1])), len(json.dumps(payloads[0])))
        self.assertEqual(store.get_runtime_state(tid)["planner_calls"], 2)
        metrics = [r["data"] for r in store.trace(tid) if r["event_type"] == "planner.call.metrics"]
        self.assertEqual([m["provider_attempts"] for m in metrics], [1, 1])
        self.assertEqual([m["recovery_context"] for m in metrics], [False, True])
        self.assertEqual(sum(r["event_type"] == "action.planned" for r in store.trace(tid)), 1)
        self.assertEqual(runtime.planner_adapter.transient_http_retries, 2, "do not mutate a shared adapter")

    def test_double_timeout_blocks_with_two_not_four_or_six_http_attempts(self):
        store, runtime, tid, supervisor = self.setup_runtime()
        with patch("urllib.request.urlopen", side_effect=TimeoutError("synthetic timeout")) as transport:
            self.assertEqual(supervisor.advance_task(tid)["status"], "WAITING")
            self.resume(store, tid)
            self.assertEqual(supervisor.advance_task(tid)["status"], "BLOCKED")
            self.assertEqual(transport.call_count, 2)
        self.assertIsNone(store.get_open_action(tid))
        self.assertEqual(store.get_runtime_state(tid)["planner_calls"], 2)

    def test_recovery_cannot_bypass_existing_planner_budget(self):
        store, runtime, tid, supervisor = self.setup_runtime(budget=1)
        with patch("urllib.request.urlopen", side_effect=TimeoutError()) as transport:
            supervisor.advance_task(tid)
            self.resume(store, tid)
            result = supervisor.advance_task(tid)
            self.assertEqual(result["reason"], "planner_budget_exhausted")
            self.assertEqual(transport.call_count, 1)

    def test_recovery_survives_storage_reopen_without_langgraph_checkpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "runtime.sqlite3")
            store, runtime, tid, supervisor = self.setup_runtime(db=path)
            with patch("urllib.request.urlopen", side_effect=TimeoutError()):
                supervisor.advance_task(tid)
            reopened = Storage(path)
            adapter = runtime.planner_adapter
            new_runtime = TaskRuntime(reopened, adapter, [REMINDER_CREATE])
            new_runtime.additional_observation_provider = runtime.additional_observation_provider
            next_supervisor = RuntimeSupervisor(reopened, new_runtime)
            self.resume(reopened, tid)
            with patch("urllib.request.urlopen", side_effect=TimeoutError()) as transport:
                next_supervisor.advance_task(tid)
                self.assertEqual(transport.call_count, 1)
            metrics = [r["data"] for r in reopened.trace(tid) if r["event_type"] == "planner.call.metrics"]
            self.assertTrue(metrics[-1]["recovery_context"])
            self.assertIsNone(new_runtime.planner_graph.graph.checkpointer)

    def test_late_user_turn_before_model_fences_old_request(self):
        store = Storage(":memory:")
        requests = []
        class Planner:
            def decide(self, request, capabilities):
                requests.append(context_in_request(request))
                return reminder_decision()
        runtime = TaskRuntime(store, Planner(), [REMINDER_CREATE])
        tid = runtime.create_task("创建提醒")["task_id"]
        class Memory:
            searches = 0
            def remember_user_text(self, **kwargs):
                pass
            def search(self, query):
                self.searches += 1
                if self.searches == 1:
                    runtime.admit_user_turn(tid, event_id="new-turn", text="改到后天十点")
                return {"items": [], "error_type": None}
        runtime.memory = Memory()
        runtime.decide(tid)
        self.assertEqual(len(requests), 1)
        self.assertIn("改到后天十点", json.dumps(requests[0], ensure_ascii=False))
        self.assertEqual(sum(r["event_type"] == "action.planned" for r in store.trace(tid)), 1)

    def test_graph_steps_reach_existing_developer_metrics_without_new_ios_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "runtime.sqlite3")
            store, runtime, tid, supervisor = self.setup_runtime(db=path)
            with patch("urllib.request.urlopen", side_effect=TimeoutError()):
                supervisor.advance_task(tid)
            service = DeveloperObservabilityService(path, enabled=True)
            detail = service.planner_call(tid, 1)
            self.assertEqual(detail["metrics"][0]["planner_engine"], "langgraph")
            self.assertIn("call_model", [s["node"] for s in detail["metrics"][0]["graph_steps"]])
            serialized = json.dumps(detail)
            self.assertNotIn("test-not-real", serialized)
            self.assertNotIn("原件内容", serialized)
