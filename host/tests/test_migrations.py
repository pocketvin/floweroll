from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from floweroll_host.migrations import LATEST_SCHEMA_VERSION, _migration_1_runtime_foundation
from floweroll_host.storage import Storage


RUNTIME_TABLES = {
    "action_attempts",
    "action_input_requests",
    "artifact_revisions",
    "artifacts",
    "presentation_events",
    "task_inbox_events",
    "task_timeline_items",
    "control_interrupt_decisions",
}


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})")}


def _create_legacy_database(path: str) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute("PRAGMA foreign_keys=ON")
        conn.executescript(
            """
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY,
                goal TEXT NOT NULL,
                invocation_source TEXT NOT NULL,
                policy_snapshot_json TEXT NOT NULL,
                status TEXT NOT NULL,
                current_step INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE task_runtime (
                task_id TEXT PRIMARY KEY,
                phase TEXT NOT NULL,
                plan_json TEXT NOT NULL,
                wait_reason TEXT,
                wait_json TEXT,
                pending_clarification_id TEXT,
                interpreted_goal_summary TEXT,
                updated_at TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id)
            );
            CREATE TABLE actions (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                step_index INTEGER NOT NULL,
                action_type TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                expected_json TEXT NOT NULL,
                status TEXT NOT NULL,
                idempotency_key TEXT NOT NULL UNIQUE,
                result_json TEXT,
                error_text TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id)
            );
            CREATE UNIQUE INDEX idx_actions_task_step ON actions(task_id, step_index);
            CREATE TABLE traces (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                event_type TEXT NOT NULL,
                data_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id)
            );
            CREATE TABLE planner_decisions (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                decision_type TEXT NOT NULL,
                decision_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id),
                UNIQUE(task_id, sequence)
            );
            CREATE TABLE observations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                action_id TEXT,
                capability TEXT NOT NULL,
                data_json TEXT NOT NULL,
                verified INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id),
                FOREIGN KEY(action_id) REFERENCES actions(id)
            );
            CREATE UNIQUE INDEX idx_observations_action
                ON observations(action_id) WHERE action_id IS NOT NULL;
            CREATE TABLE clarifications (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                decision_id TEXT NOT NULL,
                question TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                status TEXT NOT NULL,
                response_json TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id),
                FOREIGN KEY(decision_id) REFERENCES planner_decisions(id)
            );
            """
        )
        now = "2026-09-10T10:00:00+00:00"
        conn.execute(
            "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                "legacy-task",
                "保留旧任务",
                "legacy_test",
                json.dumps({"mode": "probe"}),
                "running",
                1,
                now,
                now,
            ),
        )
        conn.execute(
            "INSERT INTO task_runtime VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("legacy-task", "executing", "[]", None, None, None, "旧语义", now),
        )
        conn.execute(
            """
            INSERT INTO actions
            (id, task_id, step_index, action_type, payload_json, expected_json,
             status, idempotency_key, result_json, error_text, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "legacy-action",
                "legacy-task",
                1,
                "device.probe",
                json.dumps({"message": "hello"}),
                json.dumps({"echo": "hello"}),
                "dispatched",
                "legacy-task:1:device.probe",
                None,
                None,
                now,
                now,
            ),
        )
        conn.execute(
            "INSERT INTO traces(task_id, event_type, data_json, created_at) VALUES (?, ?, ?, ?)",
            ("legacy-task", "task.created", json.dumps({"legacy": True}), now),
        )
        conn.commit()
    finally:
        conn.close()


class StorageMigrationTests(unittest.TestCase):
    def test_fresh_database_reaches_latest_runtime_foundation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "fresh.sqlite3")
            store = Storage(db)
            self.assertEqual(store.schema_version(), LATEST_SCHEMA_VERSION)

            conn = sqlite3.connect(db)
            try:
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], LATEST_SCHEMA_VERSION)
                tables = {
                    row[0]
                    for row in conn.execute(
                        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
                    )
                }
                self.assertTrue(RUNTIME_TABLES.issubset(tables))
                self.assertTrue(
                    {
                        "submission_id",
                        "cancel_requested_at",
                        "finished_at",
                        "thread_id",
                        "parent_task_id",
                    }.issubset(_table_columns(conn, "tasks"))
                )
                self.assertTrue(
                    {
                        "runtime_revision",
                        "wait_id",
                        "runtime_contract_version",
                        "planner_contract_version",
                        "inbox_watermark",
                    }.issubset(_table_columns(conn, "task_runtime"))
                )
                self.assertTrue(
                    {"interrupt_requested_at", "interrupt_reason"}.issubset(
                        _table_columns(conn, "actions")
                    )
                )
                self.assertEqual(conn.execute("PRAGMA foreign_key_check").fetchall(), [])
            finally:
                conn.close()

    def test_legacy_database_migrates_without_losing_existing_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "legacy.sqlite3")
            _create_legacy_database(db)

            store = Storage(db)

            self.assertEqual(store.schema_version(), LATEST_SCHEMA_VERSION)
            task = store.get_task("legacy-task")
            action = store.get_action("legacy-action")
            view = store.get_task_view("legacy-task")
            self.assertIsNotNone(task)
            self.assertIsNotNone(action)
            assert task is not None and action is not None
            self.assertEqual(task["goal"], "保留旧任务")
            self.assertEqual(task["thread_id"], "legacy-task")
            self.assertIsNone(task["parent_task_id"])
            self.assertEqual(action["action_type"], "device.probe")
            self.assertEqual(action["on_verified"], "COMPLETE")
            self.assertEqual([event["event_type"] for event in store.trace("legacy-task")], ["task.created"])
            assert view is not None
            self.assertEqual([item["title"] for item in view["timeline"]], [
                "任务已交给小卷",
                "正在验证设备执行链路",
            ])
            self.assertGreater(view["presentation_cursor"], 0)

            conn = sqlite3.connect(db)
            try:
                self.assertIn("on_verified", _table_columns(conn, "actions"))
                self.assertIn("accepts_text", _table_columns(conn, "clarifications"))
                self.assertIn("runtime_revision", _table_columns(conn, "task_runtime"))
                self.assertEqual(conn.execute("PRAGMA foreign_key_check").fetchall(), [])
            finally:
                conn.close()

    def test_reopening_latest_database_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "reopen.sqlite3")
            first = Storage(db)
            first.create_task("task-1", "一次创建", "migration_test", {})

            second = Storage(db)

            self.assertEqual(second.schema_version(), LATEST_SCHEMA_VERSION)
            self.assertIsNotNone(second.get_task("task-1"))


    def test_version_one_database_upgrades_to_latest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "v1.sqlite3")
            _create_legacy_database(db)
            conn = sqlite3.connect(db)
            conn.row_factory = sqlite3.Row
            try:
                conn.execute("PRAGMA foreign_keys=ON")
                _migration_1_runtime_foundation(conn)
                conn.execute("PRAGMA user_version = 1")
                conn.commit()
                self.assertNotIn("revision", _table_columns(conn, "task_timeline_items"))
            finally:
                conn.close()

            store = Storage(db)
            self.assertEqual(store.schema_version(), LATEST_SCHEMA_VERSION)

            conn = sqlite3.connect(db)
            try:
                self.assertIn("revision", _table_columns(conn, "task_timeline_items"))
                self.assertIn("error_text", _table_columns(conn, "action_attempts"))
            finally:
                conn.close()

    def test_newer_database_version_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = str(Path(tmp) / "future.sqlite3")
            conn = sqlite3.connect(db)
            try:
                conn.execute(f"PRAGMA user_version = {LATEST_SCHEMA_VERSION + 1}")
                conn.commit()
            finally:
                conn.close()

            with self.assertRaisesRegex(RuntimeError, "newer than supported"):
                Storage(db)


if __name__ == "__main__":
    unittest.main()
