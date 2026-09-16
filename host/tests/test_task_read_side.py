from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from floweroll_host.server import create_server
from floweroll_host.storage import Storage


class HTTPReadSideTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        db = str(Path(self.tmp.name) / "read-side.sqlite3")
        self.server = create_server("127.0.0.1", 0, db)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:{}".format(self.server.server_address[1])

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def request(self, method: str, path: str, body=None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode("utf-8")) if raw else None

    @staticmethod
    def submission(submission_id: str, text: str, parent_task_id: str | None = None) -> dict:
        body = {
            "submission_id": submission_id,
            "input": {"kind": "text", "text": text},
            "invocation_source": "ios_new_task",
        }
        if parent_task_id is not None:
            body["parent_task_id"] = parent_task_id
        return body

    def create_probe_task(self, text: str):
        status, task = self.request(
            "POST",
            "/v1/tasks",
            {"goal": text, "invocation_source": "legacy_probe_read_model_test", "policy_snapshot": {"mode": "probe-only"}},
        )
        self.assertEqual(status, 201)
        return task

    def test_submission_replay_returns_same_task_without_duplicate_action_or_timeline(self) -> None:
        body = self.submission("sub-retry-1", "帮我验证提交幂等")

        first_status, first = self.request("POST", "/v1/tasks", body)
        second_status, second = self.request("POST", "/v1/tasks", body)

        self.assertEqual(first_status, 201)
        self.assertEqual(second_status, 200)
        self.assertFalse(first["idempotent_replay"])
        self.assertTrue(second["idempotent_replay"])
        self.assertEqual(first["task_id"], second["task_id"])

        task_id = first["task_id"]
        self.assertIsNone(self.server.app.storage.get_open_action(task_id))
        view = self.server.app.storage.get_task_view(task_id)
        assert view is not None
        self.assertEqual([item["kind"] for item in view["timeline"]], ["PUBLIC_WORKLOG"])
        self.assertEqual(len(self.server.app.storage.presentation_events_after(task_id, 0)), 1)

    def test_conflicting_submission_id_fails_closed_with_problem_details(self) -> None:
        self.request("POST", "/v1/tasks", self.submission("sub-conflict", "第一条任务"))
        status, problem = self.request(
            "POST",
            "/v1/tasks",
            self.submission("sub-conflict", "完全不同的第二条任务"),
        )

        self.assertEqual(status, 409)
        self.assertEqual(problem["code"], "SUBMISSION_ID_CONFLICT")
        self.assertEqual(problem["status"], 409)
        self.assertTrue(problem["type"].startswith("urn:floweroll:problem:"))

    def test_terminal_follow_up_creates_new_episode_in_same_thread(self) -> None:
        parent = self.create_probe_task("先完成第一轮")
        _, action = self.request("GET", f"/v1/tasks/{parent['task_id']}/next-action")
        self.request(
            "POST",
            f"/v1/tasks/{parent['task_id']}/actions/{action['action_id']}/result",
            {"success": True, "output": {"echo": action["payload"]["message"]}},
        )

        status, follow_up = self.request(
            "POST",
            "/v1/tasks",
            self.submission("sub-follow-up", "继续深入这件事", parent["task_id"]),
        )

        self.assertEqual(status, 201)
        self.assertNotEqual(follow_up["task_id"], parent["task_id"])
        self.assertEqual(follow_up["parent_task_id"], parent["task_id"])
        self.assertEqual(follow_up["thread_id"], parent["thread_id"])

        _, running = self.request("GET", "/v1/tasks?bucket=running")
        indexed = next(item for item in running["items"] if item["task_id"] == follow_up["task_id"])
        self.assertEqual(indexed["thread_id"], parent["thread_id"])
        self.assertEqual(indexed["parent_task_id"], parent["task_id"])

    def test_follow_up_rejects_non_terminal_parent(self) -> None:
        _, parent = self.request(
            "POST",
            "/v1/tasks",
            self.submission("sub-parent-running", "还在执行的父任务"),
        )
        status, problem = self.request(
            "POST",
            "/v1/tasks",
            self.submission("sub-invalid-child", "不该新建 episode", parent["task_id"]),
        )
        self.assertEqual(status, 400)
        self.assertEqual(problem["code"], "INVALID_TASK_SUBMISSION")

    def test_task_index_and_view_recover_history_without_client_local_state(self) -> None:
        _, running = self.request(
            "POST",
            "/v1/tasks",
            self.submission("sub-running", "保持运行的任务"),
        )
        finished = self.create_probe_task("完成后重新找回")
        _, action = self.request("GET", f"/v1/tasks/{finished['task_id']}/next-action")
        self.request(
            "POST",
            f"/v1/tasks/{finished['task_id']}/actions/{action['action_id']}/result",
            {"success": True, "output": {"echo": action["payload"]["message"]}},
        )

        status, running_index = self.request("GET", "/v1/tasks?bucket=running")
        self.assertEqual(status, 200)
        self.assertIn(running["task_id"], {item["task_id"] for item in running_index["items"]})
        self.assertNotIn(finished["task_id"], {item["task_id"] for item in running_index["items"]})

        status, history = self.request("GET", "/v1/tasks?bucket=history")
        self.assertEqual(status, 200)
        recovered_ids = {item["task_id"] for item in history["items"]}
        self.assertIn(finished["task_id"], recovered_ids)

        # Simulate a recreated foreground: the only Task identity comes from
        # the Host index, not a phone-side cache.
        recovered_task_id = next(item["task_id"] for item in history["items"] if item["task_id"] == finished["task_id"])
        status, view = self.request("GET", f"/v1/tasks/{recovered_task_id}/view")
        self.assertEqual(status, 200)
        self.assertEqual(view["task"]["status"], "completed")
        self.assertGreater(view["presentation_cursor"], 0)
        self.assertEqual(view["timeline"][0]["title"], "任务已交给小卷")
        self.assertEqual(view["timeline"][-1]["title"], "任务已完成")
        self.assertEqual(view["artifacts"], [])

    def test_view_cursor_covers_snapshot_then_later_events_are_replayable(self) -> None:
        task = self.create_probe_task("测试前台重连游标")
        _, before = self.request("GET", f"/v1/tasks/{task['task_id']}/view")
        cursor = before["presentation_cursor"]

        _, action = self.request("GET", f"/v1/tasks/{task['task_id']}/next-action")
        self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/actions/{action['action_id']}/result",
            {"success": True, "output": {"echo": action["payload"]["message"]}},
        )

        later = self.server.app.storage.presentation_events_after(task["task_id"], cursor)
        self.assertGreaterEqual(len(later), 2)
        self.assertTrue(all(event["seq"] > cursor for event in later))
        self.assertEqual([event["seq"] for event in later], sorted(event["seq"] for event in later))

    def test_task_index_can_filter_one_thread_across_terminal_follow_up_episodes(self) -> None:
        parent = self.create_probe_task("第一轮")
        _, action = self.request("GET", f"/v1/tasks/{parent['task_id']}/next-action")
        self.request(
            "POST",
            f"/v1/tasks/{parent['task_id']}/actions/{action['action_id']}/result",
            {"success": True, "output": {"echo": action["payload"]["message"]}},
        )
        _, child = self.request(
            "POST",
            "/v1/tasks",
            self.submission("sub-thread-filter-child", "第二轮", parent["task_id"]),
        )
        self.request("POST", "/v1/tasks", self.submission("sub-thread-filter-other", "别的事情"))

        thread_id = urllib.parse.quote(parent["thread_id"], safe="")
        status, page = self.request("GET", f"/v1/tasks?bucket=all&thread_id={thread_id}&limit=100")
        self.assertEqual(status, 200)
        self.assertEqual(
            {item["task_id"] for item in page["items"]},
            {parent["task_id"], child["task_id"]},
        )
        self.assertTrue(all(item["thread_id"] == parent["thread_id"] for item in page["items"]))

    def test_task_index_cursor_pages_without_repeating_rows(self) -> None:
        for index in range(3):
            self.request(
                "POST",
                "/v1/tasks",
                self.submission(f"sub-page-{index}", f"分页任务 {index}"),
            )

        status, first = self.request("GET", "/v1/tasks?bucket=running&limit=1")
        self.assertEqual(status, 200)
        self.assertEqual(len(first["items"]), 1)
        self.assertIsNotNone(first["next_cursor"])

        cursor = urllib.parse.quote(first["next_cursor"], safe="")
        status, second = self.request("GET", f"/v1/tasks?bucket=running&limit=1&cursor={cursor}")
        self.assertEqual(status, 200)
        self.assertEqual(len(second["items"]), 1)
        self.assertNotEqual(first["items"][0]["task_id"], second["items"][0]["task_id"])


    def test_retry_endpoint_rejects_non_provider_block_and_resumes_provider_block(self) -> None:
        provider = self.server.app.storage.create_task(
            "retry-http-provider", "重试 provider", "unit", {}, status="active"
        )
        self.server.app.storage.block_task(
            task_id=provider["task_id"], reason="planner_runtime_error", public_summary="暂停"
        )
        status, body = self.request("POST", f"/v1/tasks/{provider['task_id']}/retry")
        self.assertEqual(status, 202)
        self.assertTrue(body["resumed"])
        self.assertEqual(body["task"]["status"], "active")
        status, replay = self.request("POST", f"/v1/tasks/{provider['task_id']}/retry")
        self.assertEqual(status, 202)
        self.assertFalse(replay["resumed"])

        denied = self.server.app.storage.create_task(
            "retry-http-denied", "不可强制重试", "unit", {}, status="active"
        )
        self.server.app.storage.block_task(
            task_id=denied["task_id"], reason="task_capability_denied", public_summary="权限限制"
        )
        status, problem = self.request("POST", f"/v1/tasks/{denied['task_id']}/retry")
        self.assertEqual(status, 409)
        self.assertEqual(problem["code"], "TASK_RETRY_NOT_ALLOWED")


class StorageReadModelTests(unittest.TestCase):
    def test_blocked_runtime_error_is_paused_not_needs_user(self) -> None:
        store = Storage(":memory:")
        task = store.create_task(
            "blocked-provider", "复杂任务继续执行", "unit", {}, status="active"
        )
        store.block_task(
            task_id=task["task_id"],
            reason="planner_runtime_error",
            payload={"error_type": "OpenAICompatibleChatPlannerTransientError"},
            public_summary="规划服务暂时不可用，当前进度已保留。",
        )
        needs_user = store.list_tasks(bucket="needs_user")
        running = store.list_tasks(bucket="running")
        all_rows = store.list_tasks(bucket="all")
        self.assertNotIn(task["task_id"], [row["task_id"] for row in needs_user["items"]])
        row = next(row for row in running["items"] if row["task_id"] == task["task_id"])
        self.assertEqual(row["status"], "blocked")
        self.assertFalse(row["needs_user"])
        all_row = next(row for row in all_rows["items"] if row["task_id"] == task["task_id"])
        self.assertEqual(all_row["bucket"], "running")
        self.assertFalse(all_row["needs_user"])
        view = store.get_task_view(task["task_id"])
        self.assertIsNotNone(view)
        self.assertIsNone(view["pending_interaction"])

    def test_planner_runtime_pause_retry_is_explicit_idempotent_and_not_user_input(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("retry-provider", "继续复杂任务", "unit", {}, status="active")
        store.record_planner_call_failure(
            task_id=task["task_id"], call_number=1, error=TimeoutError("provider timeout")
        )
        store.block_task(
            task_id=task["task_id"], reason="planner_runtime_error",
            payload={"error_type": "TimeoutError"},
            public_summary="后台规划暂时不可用，任务已安全暂停。",
        )
        self.assertEqual(store.consecutive_planner_failures(task["task_id"]), 1)

        first = store.retry_blocked_planner_task(task_id=task["task_id"])
        second = store.retry_blocked_planner_task(task_id=task["task_id"])

        self.assertTrue(first["resumed"])
        self.assertFalse(second["resumed"])
        self.assertEqual(first["task"]["status"], "active")
        self.assertEqual(store.consecutive_planner_failures(task["task_id"]), 0)
        self.assertEqual(store.inbox_events(task["task_id"]), [])
        runtime = store.get_runtime_state(task["task_id"])
        self.assertIsNone(runtime["block_reason"])
        self.assertIsNone(runtime["wait_id"])
        self.assertEqual(runtime["phase"], "planning")
        self.assertIn("task.operator_resumed", [row["event_type"] for row in store.trace(task["task_id"])])
        view = store.get_task_view(task["task_id"])
        self.assertEqual(view["timeline"][-1]["title"], "已重新尝试")

    def test_pending_clarification_places_task_in_needs_user_and_view(self) -> None:
        store = Storage(":memory:")
        task = store.create_task("task-needs-user", "需要补充信息", "unit", {}, status="active")
        decision = store.record_planner_decision(
            decision_id="pd-needs-user",
            task_id=task["task_id"],
            decision_type="CLARIFY",
            decision={"decision_type": "CLARIFY"},
        )
        store.create_clarification(
            clarification_id="clar-needs-user",
            task_id=task["task_id"],
            decision_id=decision["decision_id"],
            clarification={
                "question": "你希望几点提醒？",
                "suggested_options": [{"id": "ten", "label": "10:00"}],
                "accepts_text": True,
                "reason": "missing_exact_time",
            },
        )
        state = store.get_runtime_state(task["task_id"])
        assert state is not None
        store.set_task_runtime(
            task_id=task["task_id"],
            status="waiting",
            phase="awaiting_user",
            plan=state["plan"],
            wait_reason="user_input",
            wait_payload={"clarification_id": "clar-needs-user"},
            pending_clarification_id="clar-needs-user",
            interpreted_goal_summary="需要确认提醒时间",
        )

        needs_user = store.list_tasks(bucket="needs_user")
        self.assertEqual([item["task_id"] for item in needs_user["items"]], [task["task_id"]])
        view = store.get_task_view(task["task_id"])
        assert view is not None
        self.assertEqual(view["pending_interaction"]["kind"], "clarification")
        self.assertEqual(view["pending_interaction"]["question"], "你希望几点提醒？")
        self.assertEqual(view["timeline"][-1]["presentation_state"], "NEEDS_USER")


if __name__ == "__main__":
    unittest.main()
