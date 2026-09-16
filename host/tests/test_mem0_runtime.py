from __future__ import annotations

import json
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

from floweroll_host.planner_contracts import CapabilitySpec, PlannerDecision
from floweroll_host.storage import Storage
from floweroll_host.task_runtime import TaskRuntime


NOW = datetime(2026, 9, 14, 16, 0, tzinfo=ZoneInfo("Asia/Shanghai"))
READ_CAPABILITY = CapabilitySpec(
    "generic.read",
    "Read a deterministic value",
    {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
)


class CapturingPlanner:
    def __init__(self) -> None:
        self.contexts = []

    def decide(self, request_body, capabilities):
        payload = json.loads(request_body["input"][1]["content"])
        self.contexts.append(payload["decision_context"])
        return PlannerDecision.from_dict(
            {
                "decision_type": "COMPLETE",
                "interpreted_goal_summary": "done",
                "plan_update": None,
                "action": None,
                "on_verified": None,
                "clarification": None,
                "wait": None,
                "completion": {"summary": "done"},
                "stop_reason": None,
                "cancellation": None,
                "state_update": None,
            },
            capabilities,
        )


class FakeMemory:
    def __init__(self) -> None:
        self.remembered = []
        self.queries = []

    def remember_user_text(self, **kwargs):
        self.remembered.append(dict(kwargs))
        return True

    def search(self, query):
        self.queries.append(query)
        return {
            "items": [
                {
                    "memory_id": "mem-job-city",
                    "memory": "用户求职城市优先杭州",
                    "score": 0.91,
                }
            ],
            "error_type": None,
        }


class Mem0RuntimeIntegrationTests(unittest.TestCase):
    def test_retrieved_memories_enter_decision_context(self):
        store = Storage(":memory:")
        planner = CapturingPlanner()
        memory = FakeMemory()
        runtime = TaskRuntime(
            store,
            planner,
            [READ_CAPABILITY],
            memory=memory,
        )
        task = runtime.create_task("帮我看看有什么适合我的工作")

        runtime.decide(task["task_id"], current_time=NOW)

        self.assertEqual(len(memory.queries), 1)
        self.assertIn("适合我的工作", memory.queries[0])
        self.assertEqual(memory.remembered[0]["source_kind"], "task_goal")
        self.assertEqual(
            planner.contexts[0]["runtime_context"]["relevant_memories"],
            [
                {
                    "memory_id": "mem-job-city",
                    "memory": "用户求职城市优先杭州",
                    "score": 0.91,
                }
            ],
        )

    def test_user_turn_is_written_once_even_when_delivery_replays(self):
        store = Storage(":memory:")
        planner = CapturingPlanner()
        memory = FakeMemory()
        runtime = TaskRuntime(store, planner, [READ_CAPABILITY], memory=memory)
        task = runtime.create_task("继续准备求职")

        first = runtime.admit_user_turn(
            task["task_id"],
            event_id="turn-1",
            text="以后找工作只考虑杭州",
        )
        replay = runtime.admit_user_turn(
            task["task_id"],
            event_id="turn-1",
            text="以后找工作只考虑杭州",
        )

        self.assertFalse(first["duplicate"])
        self.assertTrue(replay["duplicate"])
        self.assertEqual(len(memory.remembered), 1)
        self.assertEqual(memory.remembered[0]["source_kind"], "user_turn")
        self.assertEqual(memory.remembered[0]["text"], "以后找工作只考虑杭州")


if __name__ == "__main__":
    unittest.main()
