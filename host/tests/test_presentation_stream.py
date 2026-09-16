from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from floweroll_host.server import create_server


def read_sse_event(response) -> dict:
    event_id = None
    event_type = None
    data = None
    while True:
        raw = response.readline()
        if raw == b"":
            break
        line = raw.decode("utf-8").rstrip("\r\n")
        if line == "":
            if data is not None:
                break
            continue
        if line.startswith(":"):
            continue
        if line.startswith("id:"):
            event_id = int(line.split(":", 1)[1].strip())
        elif line.startswith("event:"):
            event_type = line.split(":", 1)[1].strip()
        elif line.startswith("data:"):
            data = json.loads(line.split(":", 1)[1].strip())
    if data is None:
        return {}
    return {"id": event_id, "event": event_type, "data": data}


class PresentationStreamTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        db = str(Path(self.tmp.name) / "stream.sqlite3")
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
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode("utf-8")) if raw else None

    def create_task(self, suffix: str):
        status, task = self.request(
            "POST",
            "/v1/tasks",
            {
                "goal": f"stream test {suffix}",
                "invocation_source": "legacy_probe_stream_test",
                "policy_snapshot": {"mode": "probe-only"},
            },
        )
        self.assertEqual(status, 201)
        return task

    def test_terminal_reconnect_replays_every_durable_event_after_view_cursor(self) -> None:
        task = self.create_task("replay")
        _, view = self.request("GET", f"/v1/tasks/{task['task_id']}/view")
        cursor = view["presentation_cursor"]

        _, action = self.request("GET", f"/v1/tasks/{task['task_id']}/next-action")
        self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/actions/{action['action_id']}/result",
            {
                "attempt_id": action["attempt_id"],
                "success": True,
                "output": {"echo": action["payload"]["message"]},
            },
        )

        req = urllib.request.Request(
            self.base + f"/v1/tasks/{task['task_id']}/stream?after_seq={cursor}",
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=3) as response:
            self.assertEqual(response.status, 200)
            self.assertTrue(response.headers.get("Content-Type", "").startswith("text/event-stream"))
            raw = response.read().decode("utf-8")

        frames = [frame for frame in raw.split("\n\n") if frame.strip()]
        self.assertGreaterEqual(len(frames), 2)
        ids = []
        payloads = []
        for frame in frames:
            lines = frame.splitlines()
            ids.append(int(next(line for line in lines if line.startswith("id:")).split(":", 1)[1]))
            payloads.append(json.loads(next(line for line in lines if line.startswith("data:")).split(":", 1)[1].strip()))
        self.assertTrue(all(value > cursor for value in ids))
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(payloads[-1]["payload"]["title"], "任务已完成")
        # Normal SSE contains public projection, not raw dispatch/verification internals.
        serialized = json.dumps(payloads, ensure_ascii=False)
        self.assertNotIn("dispatch_snapshot", serialized)
        self.assertNotIn("raw_evidence", serialized)

    def test_last_event_id_header_replays_after_cursor(self) -> None:
        task = self.create_task("header")
        _, view = self.request("GET", f"/v1/tasks/{task['task_id']}/view")
        cursor = view["presentation_cursor"]
        _, action = self.request("GET", f"/v1/tasks/{task['task_id']}/next-action")
        self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/actions/{action['action_id']}/result",
            {
                "attempt_id": action["attempt_id"],
                "success": True,
                "output": {"echo": action["payload"]["message"]},
            },
        )

        req = urllib.request.Request(self.base + f"/v1/tasks/{task['task_id']}/stream", method="GET")
        req.add_header("Last-Event-ID", str(cursor))
        with urllib.request.urlopen(req, timeout=3) as response:
            raw = response.read().decode("utf-8")
        first_id = int(next(line for line in raw.splitlines() if line.startswith("id:")).split(":", 1)[1])
        self.assertGreater(first_id, cursor)

    def test_running_stream_tails_new_event_created_after_connection(self) -> None:
        task = self.create_task("live")
        _, view = self.request("GET", f"/v1/tasks/{task['task_id']}/view")
        cursor = view["presentation_cursor"]
        req = urllib.request.Request(
            self.base + f"/v1/tasks/{task['task_id']}/stream?after_seq={cursor}",
            method="GET",
        )
        response = urllib.request.urlopen(req, timeout=4)
        try:
            # Stream is already connected. A different HTTP request creates the
            # next durable presentation event; the open stream must tail it.
            status, action = self.request("GET", f"/v1/tasks/{task['task_id']}/next-action")
            self.assertEqual(status, 200)
            event = read_sse_event(response)
            self.assertEqual(event["event"], "presentation")
            self.assertGreater(event["id"], cursor)
            self.assertEqual(event["data"]["seq"], event["id"])
            self.assertEqual(event["data"]["task_id"], task["task_id"])
        finally:
            response.close()

    def test_reconnect_from_latest_terminal_event_returns_no_duplicate_frames(self) -> None:
        task = self.create_task("no-dup")
        _, action = self.request("GET", f"/v1/tasks/{task['task_id']}/next-action")
        self.request(
            "POST",
            f"/v1/tasks/{task['task_id']}/actions/{action['action_id']}/result",
            {
                "attempt_id": action["attempt_id"],
                "success": True,
                "output": {"echo": action["payload"]["message"]},
            },
        )
        _, view = self.request("GET", f"/v1/tasks/{task['task_id']}/view")
        cursor = view["presentation_cursor"]

        req = urllib.request.Request(
            self.base + f"/v1/tasks/{task['task_id']}/stream?after_seq={cursor}",
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=3) as response:
            self.assertEqual(response.read(), b"")

    def test_invalid_cursor_returns_problem_details(self) -> None:
        task = self.create_task("bad-cursor")
        status, problem = self.request(
            "GET",
            f"/v1/tasks/{task['task_id']}/stream?after_seq=not-a-number",
        )
        self.assertEqual(status, 400)
        self.assertEqual(problem["code"], "INVALID_PRESENTATION_CURSOR")


if __name__ == "__main__":
    unittest.main()
