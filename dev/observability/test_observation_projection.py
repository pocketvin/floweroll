from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from .observation_projection import list_observations, observation_detail


SESSION_ID = "C67D9192-8015-4DFF-84CC-1056ED9ED0D4"


def make_db(root: Path) -> Path:
    path = root / "runtime.sqlite3.observations.sqlite3"
    connection = sqlite3.connect(path)
    with connection:
        connection.executescript("""
        CREATE TABLE observation_sessions (
          id TEXT PRIMARY KEY, config TEXT NOT NULL, status TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          last_summary_seq INTEGER NOT NULL DEFAULT 0, last_summary_at REAL NOT NULL,
          finish_count INTEGER, last_error TEXT, retry_after REAL NOT NULL DEFAULT 0);
        CREATE TABLE observation_events (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
          id TEXT NOT NULL, digest TEXT NOT NULL, data TEXT NOT NULL, UNIQUE(session_id,id));
        CREATE TABLE observation_notes (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
          kind TEXT NOT NULL, through_seq INTEGER NOT NULL, created_at TEXT NOT NULL, data TEXT NOT NULL);
        CREATE TABLE observation_questions (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, question TEXT NOT NULL,
          status TEXT NOT NULL, data TEXT, error TEXT);
        """)
        config = {"id": SESSION_ID, "preset": "combined", "sources": ["screen", "ambientMicrophone", "deviceAudio"],
                  "created_at": "2026-09-15T08:00:00+00:00", "consent_version": 1}
        connection.execute(
            "INSERT INTO observation_sessions VALUES(?,?,?,?,?,?,?,?,?,?)",
            (SESSION_ID, json.dumps(config), "completed", config["created_at"], "2026-09-15T08:05:00+00:00", 4, 0.0, 4, None, 0.0),
        )
        events = [
            {"id": "e1", "kind": "lifecycle", "source": "system", "captured_at": "2026-09-15T08:00:00+00:00", "offset_ms": 0, "duration_ms": 0, "text": "开始观察"},
            {"id": "e2", "kind": "transcript", "source": "ambientMicrophone", "captured_at": "2026-09-15T08:00:02+00:00", "offset_ms": 2000, "duration_ms": 1400, "text": "PRIVATE TRANSCRIPT"},
            {"id": "e3", "kind": "screen", "source": "screen", "captured_at": "2026-09-15T08:00:05+00:00", "offset_ms": 5000, "duration_ms": 0, "text": "PRIVATE OCR", "image_base64": "VERY_PRIVATE_IMAGE", "screen_understanding": {"event_id": "e3", "page_type": "网页", "summary": "PRIVATE SCREEN SUMMARY", "key_items": ["42"], "visible_actions": ["打开"], "uncertainties": []}},
            {"id": "e4", "kind": "gap", "source": "deviceAudio", "captured_at": "2026-09-15T08:00:08+00:00", "offset_ms": 8000, "duration_ms": 0, "text": "设备音频暂时不可用"},
        ]
        for event in events:
            connection.execute("INSERT INTO observation_events(session_id,id,digest,data) VALUES(?,?,?,?)", (SESSION_ID, event["id"], "digest-" + event["id"], json.dumps(event)))
        note = {"title": "PRIVATE TITLE", "summary": "PRIVATE FINAL SUMMARY", "evidence_ids": ["e2", "e3"],
                "decisions": [{"text": "PRIVATE DECISION", "evidence_ids": ["e2"]}], "todos": [], "open_questions": []}
        connection.execute("INSERT INTO observation_notes VALUES(?,?,?,?,?,?)", ("n1", SESSION_ID, "final", 4, "2026-09-15T08:05:00+00:00", json.dumps(note)))
        answer = {"title": "回答", "summary": "PRIVATE ANSWER", "evidence_ids": ["e3"]}
        connection.execute("INSERT INTO observation_questions VALUES(?,?,?,?,?,?)", ("q1", SESSION_ID, "PRIVATE QUESTION", "completed", json.dumps(answer), None))
    connection.close()
    return path


class ObservationProjectionTests(unittest.TestCase):
    def test_full_projection_is_useful_but_never_exposes_raw_image(self):
        with tempfile.TemporaryDirectory() as directory:
            path = make_db(Path(directory))
            index = list_observations(path, full=True)
            self.assertTrue(index["available"])
            self.assertEqual(index["observations"][0]["id"], SESSION_ID)
            self.assertEqual(index["observations"][0]["title"], "PRIVATE TITLE")
            detail = observation_detail(path, SESSION_ID, full=True)
            encoded = json.dumps(detail)
            self.assertEqual(detail["stats"]["event_count"], 4)
            self.assertEqual(detail["stats"]["kind_counts"]["transcript"], 1)
            self.assertEqual(detail["stats"]["screen_understood"], 1)
            self.assertEqual(detail["analysis"]["pending_events"], 0)
            self.assertIn("PRIVATE TRANSCRIPT", encoded)
            self.assertIn("PRIVATE FINAL SUMMARY", encoded)
            self.assertIn("PRIVATE ANSWER", encoded)
            self.assertNotIn("VERY_PRIVATE_IMAGE", encoded)
            self.assertNotIn("image_base64", encoded)

    def test_metadata_projection_hides_transcript_summary_question_and_title(self):
        with tempfile.TemporaryDirectory() as directory:
            path = make_db(Path(directory))
            index = list_observations(path, full=False)
            self.assertIsNone(index["observations"][0]["title"])
            detail = observation_detail(path, SESSION_ID, full=False)
            encoded = json.dumps(detail)
            for private in ("PRIVATE TRANSCRIPT", "PRIVATE OCR", "PRIVATE SCREEN SUMMARY", "PRIVATE FINAL SUMMARY", "PRIVATE QUESTION", "PRIVATE ANSWER", "PRIVATE TITLE"):
                self.assertNotIn(private, encoded)
            self.assertFalse(detail["privacy"]["content_included"])
            self.assertEqual(detail["notes"][0]["evidence_count"], 2)
            self.assertEqual(detail["questions"][0]["status"], "completed")
            self.assertEqual(detail["stats"]["screen_errors"], 0)

    def test_uuid_validation_preserves_exact_database_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = make_db(Path(directory))
            detail = observation_detail(path, SESSION_ID, full=False)
            self.assertEqual(detail["session"]["id"], SESSION_ID)
            with self.assertRaises(ValueError):
                observation_detail(path, "../observations", full=False)

    def test_missing_database_is_empty_index_but_detail_is_not_fabricated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "missing.sqlite3"
            self.assertEqual(list_observations(path, full=True)["observations"], [])
            self.assertFalse(list_observations(path, full=True)["available"])
            with self.assertRaises(KeyError):
                observation_detail(path, SESSION_ID, full=True)

    def test_pending_count_uses_session_rows_not_global_sqlite_sequence_distance(self):
        with tempfile.TemporaryDirectory() as directory:
            path = make_db(Path(directory))
            connection = sqlite3.connect(path)
            with connection:
                connection.execute("UPDATE observation_events SET seq=seq+200 WHERE session_id=?", (SESSION_ID,))
                connection.execute("UPDATE observation_sessions SET last_summary_seq=0 WHERE id=?", (SESSION_ID,))
            connection.close()
            detail = observation_detail(path, SESSION_ID, full=False)
            self.assertEqual(detail["analysis"]["last_seq"], 204)
            self.assertEqual(detail["analysis"]["pending_events"], 4)
            self.assertEqual(detail["analysis"]["covered_events"], 0)
            self.assertEqual(detail["analysis"]["coverage"], 0.0)

    def test_projection_is_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = make_db(Path(directory))
            before = path.read_bytes()
            list_observations(path, full=True)
            observation_detail(path, SESSION_ID, full=True)
            self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
