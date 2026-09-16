from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.agent_loop import AgentLoop
from floweroll_host.server import create_server
from floweroll_host.storage import Storage


class InteractionAPITests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "api.sqlite3")
        self.server = create_server("127.0.0.1", 0, self.db)
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
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode("utf-8")) if raw else None

    def create_product_task(self, submission_id: str, text: str):
        status, task = self.request(
            "POST",
            "/v1/tasks",
            {
                "submission_id": submission_id,
                "input": {"kind": "text", "text": text},
                "invocation_source": "ios_new_task",
            },
        )
        self.assertEqual(status, 201)
        return task

    def create_probe_task(self, text: str):
        status, task = self.request(
            "POST", "/v1/tasks",
            {"goal": text, "invocation_source": "legacy_probe_test", "policy_snapshot": {"mode": "probe-only"}},
        )
        self.assertEqual(status, 201)
        return task

    def test_user_turn_endpoint_durably_supersedes_undispatched_action(self) -> None:
        task = self.create_probe_task("明天九点提醒")
        old_action = self.server.app.storage.get_open_action(task["task_id"])
        assert old_action is not None

        status, response = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/turns",
            {
                "event_id": "turn-api-1",
                "content": {"kind": "text", "text": "改成十点"},
            },
        )
        self.assertEqual(status, 202)
        self.assertFalse(response["accepted"]["duplicate"])
        self.assertEqual(self.server.app.storage.get_action(old_action["action_id"])["status"], "cancelled")
        self.assertEqual(self.server.app.storage.get_inbox_event("turn-api-1")["status"], "ACCEPTED")
        self.assertEqual(self.server.app.storage.get_runtime_state(task["task_id"])["phase"], "planning")

        # Network retry of the same turn is idempotent.
        status, replay = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/turns",
            {
                "event_id": "turn-api-1",
                "content": {"kind": "text", "text": "改成十点"},
            },
        )
        self.assertEqual(status, 202)
        self.assertTrue(replay["accepted"]["duplicate"])

    def test_clarification_response_endpoint_validates_and_admits_one_user_turn(self) -> None:
        task = self.server.app.storage.create_task(
            "clar-api-task",
            "下午提醒我",
            "unit",
            {},
            status="active",
        )
        decision = self.server.app.storage.record_planner_decision(
            decision_id="clar-api-decision",
            task_id=task["task_id"],
            decision_type="CLARIFY",
            decision={"decision_type": "CLARIFY"},
        )
        self.server.app.storage.create_clarification(
            clarification_id="clar-api",
            task_id=task["task_id"],
            decision_id=decision["decision_id"],
            clarification={
                "question": "几点提醒？",
                "suggested_options": [{"id": "ten", "label": "10:00"}],
                "accepts_text": True,
                "reason": "missing_time",
            },
        )
        self.server.app.storage.set_task_runtime(
            task_id=task["task_id"],
            status="waiting",
            phase="planning",
            plan=["确认时间"],
            wait_reason="user_input",
            wait_payload={"clarification_id": "clar-api"},
            pending_clarification_id="clar-api",
            interpreted_goal_summary="需要确认时间",
        )

        status, body = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/clarifications/clar-api/responses",
            {"event_id": "clar-answer", "response": {"option_id": "ten"}},
        )
        self.assertEqual(status, 202)
        self.assertEqual(body["accepted"]["event_type"], "USER_TURN")
        event = self.server.app.storage.get_inbox_event("clar-answer")
        self.assertEqual(event["target_id"], "clar-api")
        self.assertEqual(event["payload"]["content"]["text"], "10:00")
        # Planner, not the API handler, semantically resolves the clarification.
        self.assertEqual(self.server.app.storage.get_clarification("clar-api")["status"], "pending")

        bad_status, bad = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/clarifications/clar-api/responses",
            {"event_id": "clar-bad", "response": {"option_id": "not-real"}},
        )
        self.assertEqual(bad_status, 400)
        self.assertEqual(bad["code"], "INVALID_CLARIFICATION_RESPONSE")

    def test_action_input_endpoint_consumes_exact_binding_then_dispatches_approved_attempt(self) -> None:
        task = self.create_probe_task("执行一个需要确认的动作")
        action = self.server.app.storage.get_open_action(task["task_id"])
        assert action is not None
        request = self.server.app.agent.execution.request_predispatch_input(
            task_id=task["task_id"],
            action_id=action["action_id"],
            input_request_id="input-api",
            prompt="确认执行？",
            suggested_options=[{"id": "yes", "label": "确认"}],
            accepts_text=False,
            reason="approval",
        )

        status, body = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/action-inputs/input-api/responses",
            {
                "event_id": "input-answer-api",
                "binding_digest": request["binding_digest"],
                "response": {"approved": True, "option_id": "yes"},
            },
        )
        self.assertEqual(status, 202)
        self.assertEqual(body["request"]["status"], "ANSWERED")
        self.assertEqual(self.server.app.storage.get_inbox_event("input-answer-api")["status"], "CONSUMED")

        status, dispatch = self.request("GET", f"/v1/tasks/{task['task_id']}/next-action")
        self.assertEqual(status, 200)
        attempt = self.server.app.storage.get_action_attempt(dispatch["attempt_id"])
        self.assertEqual(attempt["approved_input_request_id"], "input-api")

        stale_status, stale = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/action-inputs/input-api/responses",
            {
                "event_id": "another-answer",
                "binding_digest": request["binding_digest"],
                "response": {"approved": True},
            },
        )
        self.assertEqual(stale_status, 409)
        self.assertEqual(stale["code"], "STALE_ACTION_INPUT")

    def test_cancel_endpoint_is_202_and_exact_retry_remains_idempotent_after_terminal(self) -> None:
        task = self.create_product_task("sub-cancel-api", "稍后执行")
        body = {"event_id": "cancel-api", "reason": "不需要了"}
        status, first = self.request("POST", f"/v1/tasks/{task['task_id']}/cancel", body)
        self.assertEqual(status, 202)
        self.assertEqual(first["task"]["status"], "cancelled")
        self.assertFalse(first["task"]["cancellation_pending"])

        status, replay = self.request("POST", f"/v1/tasks/{task['task_id']}/cancel", body)
        self.assertEqual(status, 202)
        self.assertTrue(replay["accepted"]["duplicate"])
        self.assertEqual(replay["task"]["status"], "cancelled")

    def test_artifact_get_and_revision_endpoint_support_replay_and_stale_conflict(self) -> None:
        task = self.create_product_task("sub-artifact-api", "编辑邮件")
        self.server.app.storage.create_artifact(
            task_id=task["task_id"],
            artifact_id="artifact-api",
            revision_id="artifact-api-rev1",
            kind="email_draft",
            title="邮件草稿",
            content={"body": "第一版"},
            created_by="planner",
        )

        status, original = self.request("GET", f"/v1/tasks/{task['task_id']}/artifacts/artifact-api")
        self.assertEqual(status, 200)
        self.assertEqual(original["current_revision_id"], "artifact-api-rev1")

        edit = {
            "event_id": "edit-api-1",
            "expected_revision_id": "artifact-api-rev1",
            "content": {"body": "第二版"},
        }
        status, changed = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/artifacts/artifact-api/revisions",
            edit,
        )
        self.assertEqual(status, 201)
        self.assertFalse(changed["idempotent_replay"])
        second_revision = changed["current_revision_id"]

        status, replay = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/artifacts/artifact-api/revisions",
            edit,
        )
        self.assertEqual(status, 200)
        self.assertTrue(replay["idempotent_replay"])
        self.assertEqual(replay["current_revision_id"], second_revision)

        status, conflict = self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/artifacts/artifact-api/revisions",
            {
                "event_id": "edit-api-conflict",
                "expected_revision_id": "artifact-api-rev1",
                "content": {"body": "第三版但用了旧基线"},
            },
        )
        self.assertEqual(status, 409)
        self.assertEqual(conflict["code"], "STALE_ARTIFACT_REVISION")
        self.assertEqual(conflict["current_revision_id"], second_revision)


class StartupControlRecoveryTests(unittest.TestCase):
    def test_action_input_response_accepted_before_crash_is_consumed_on_host_restart(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "action-input-restart.sqlite3")
            store = Storage(db)
            loop = AgentLoop(store)
            task = loop.create_task("等待确认")
            action = store.get_open_action(task["task_id"])
            assert action is not None
            request = loop.execution.request_predispatch_input(
                task_id=task["task_id"],
                action_id=action["action_id"],
                input_request_id="restart-input",
                prompt="确认？",
                suggested_options=[{"id": "yes", "label": "确认"}],
                accepts_text=False,
                reason="approval",
            )
            store.admit_action_input_response(
                task_id=task["task_id"],
                input_request_id="restart-input",
                event_id="restart-input-answer",
                binding_digest=request["binding_digest"],
                response={"approved": True},
            )
            self.assertEqual(store.get_inbox_event("restart-input-answer")["status"], "ACCEPTED")

            server = create_server("127.0.0.1", 0, db)
            try:
                self.assertEqual(server.app.storage.get_inbox_event("restart-input-answer")["status"], "CONSUMED")
                self.assertEqual(server.app.storage.get_action_input_request("restart-input")["status"], "ANSWERED")
                owners = {item.get("owner") for item in server.app.startup_recovery_report}
                self.assertIn("ACTION_INPUT", owners)
            finally:
                server.server_close()

    def test_cancel_accepted_before_crash_is_consumed_on_host_restart(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "cancel-restart.sqlite3")
            store = Storage(db)
            loop = AgentLoop(store)
            task = loop.create_task("稍后取消")
            store.admit_cancel_request(task_id=task["task_id"], event_id="restart-cancel", reason="停止")
            self.assertEqual(store.get_inbox_event("restart-cancel")["status"], "ACCEPTED")

            server = create_server("127.0.0.1", 0, db)
            try:
                self.assertEqual(server.app.storage.get_inbox_event("restart-cancel")["status"], "CONSUMED")
                self.assertEqual(server.app.storage.get_task(task["task_id"])["status"], "cancelled")
                owners = {item.get("owner") for item in server.app.startup_recovery_report}
                self.assertIn("CANCELLATION", owners)
            finally:
                server.server_close()


if __name__ == "__main__":
    unittest.main()
