"""Read-only projection of Observation Mode durable evidence for the local console.

Observation Mode owns a separate SQLite lifecycle. This module never imports the
product ObservationService, never runs a model, and never writes the database.
Raw screenshots are deliberately excluded from every projection.
"""
from __future__ import annotations

from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
from typing import Any
import uuid

TIMELINE_LIMIT = 180
INDEX_LIMIT = 60
MAX_TEXT = 1600


def observation_db_path(runtime_db: Path) -> Path:
    return Path(str(runtime_db) + ".observations.sqlite3")


def _readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.5)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    return connection


def _json(value: Any, default: Any) -> Any:
    if not isinstance(value, str):
        return default
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return default


def _valid_id(value: str) -> str:
    uuid.UUID(value)
    return value


def _short_text(value: Any, limit: int = MAX_TEXT) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value:
        return None
    return value if len(value) <= limit else value[:limit] + "…"


def _preset_label(value: str | None) -> str:
    return {
        "meeting": "会议观察",
        "screen": "屏幕观察",
        "media": "影音观察",
        "combined": "综合观察",
        "custom": "自定观察",
    }.get(value or "", value or "观察")


def _note_projection(row: sqlite3.Row, *, full: bool) -> dict:
    data = _json(row["data"], {})
    result = {
        "id": row["id"],
        "kind": row["kind"],
        "through_seq": row["through_seq"],
        "created_at": row["created_at"],
        "evidence_count": len(data.get("evidence_ids", [])) if isinstance(data, dict) else 0,
    }
    if not full or not isinstance(data, dict):
        return result
    result.update(
        title=_short_text(data.get("title"), 160),
        summary=_short_text(data.get("summary"), 2400),
        decisions=_bounded_items(data.get("decisions")),
        todos=_bounded_items(data.get("todos")),
        open_questions=_bounded_items(data.get("open_questions")),
    )
    return result


def _bounded_items(value: Any) -> list[dict]:
    if not isinstance(value, list):
        return []
    output = []
    for item in value[:12]:
        if not isinstance(item, dict):
            continue
        text = _short_text(item.get("text"), 500)
        if text:
            output.append({"text": text, "evidence_count": len(item.get("evidence_ids", [])) if isinstance(item.get("evidence_ids"), list) else 0})
    return output


def _screen_projection(value: Any) -> dict | None:
    if not isinstance(value, dict):
        return None
    return {
        "page_type": _short_text(value.get("page_type"), 160),
        "summary": _short_text(value.get("summary"), 1200),
        "key_items": [_short_text(x, 180) for x in value.get("key_items", [])[:8] if _short_text(x, 180)],
        "visible_actions": [_short_text(x, 180) for x in value.get("visible_actions", [])[:8] if _short_text(x, 180)],
        "uncertainties": [_short_text(x, 180) for x in value.get("uncertainties", [])[:8] if _short_text(x, 180)],
    }


def _event_projection(seq: int, event: dict, *, full: bool) -> dict:
    result = {
        "seq": seq,
        "id": event.get("id"),
        "kind": event.get("kind"),
        "source": event.get("source"),
        "captured_at": event.get("captured_at"),
        "offset_ms": event.get("offset_ms"),
        "duration_ms": event.get("duration_ms"),
        "screen_error": event.get("screen_understanding_error"),
        "screen_skipped": event.get("screen_understanding_skipped"),
        "has_screen_understanding": isinstance(event.get("screen_understanding"), dict),
    }
    if full:
        result["text"] = _short_text(event.get("text"))
        result["screen_understanding"] = _screen_projection(event.get("screen_understanding"))
    return result


def list_observations(path: Path, *, full: bool, limit: int = INDEX_LIMIT) -> dict:
    if not path.is_file():
        return {"available": False, "observations": [], "limit": limit}
    limit = max(1, min(INDEX_LIMIT, int(limit)))
    with closing(_readonly(path)) as connection:
        rows = connection.execute(
            """SELECT s.*,
               (SELECT COUNT(*) FROM observation_events e WHERE e.session_id=s.id) AS event_count,
               (SELECT COUNT(*) FROM observation_notes n WHERE n.session_id=s.id) AS note_count,
               (SELECT COUNT(*) FROM observation_questions q WHERE q.session_id=s.id) AS question_count
               FROM observation_sessions s ORDER BY s.updated_at DESC LIMIT ?""",
            (limit,),
        ).fetchall()
        result = []
        for row in rows:
            config = _json(row["config"], {})
            latest_title = None
            if full:
                note = connection.execute(
                    "SELECT data FROM observation_notes WHERE session_id=? ORDER BY through_seq DESC,created_at DESC LIMIT 1",
                    (row["id"],),
                ).fetchone()
                if note is not None:
                    latest_title = _short_text(_json(note["data"], {}).get("title"), 160)
            preset = config.get("preset") if isinstance(config, dict) else None
            result.append({
                "id": row["id"],
                "status": row["status"],
                "preset": preset,
                "preset_label": _preset_label(preset),
                "sources": list(config.get("sources", [])) if isinstance(config, dict) else [],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "event_count": row["event_count"],
                "note_count": row["note_count"],
                "question_count": row["question_count"],
                "finish_count": row["finish_count"],
                "last_error": row["last_error"],
                "title": latest_title if full else None,
            })
    return {"available": True, "observations": result, "limit": limit}


def observation_detail(path: Path, session_id: str, *, full: bool, timeline_limit: int = TIMELINE_LIMIT) -> dict:
    sid = _valid_id(session_id)
    if not path.is_file():
        raise KeyError(sid)
    timeline_limit = max(20, min(TIMELINE_LIMIT, int(timeline_limit)))
    with closing(_readonly(path)) as connection:
        row = connection.execute("SELECT * FROM observation_sessions WHERE id=?", (sid,)).fetchone()
        if row is None:
            raise KeyError(sid)
        config = _json(row["config"], {})
        raw_events = connection.execute(
            "SELECT seq,data FROM observation_events WHERE session_id=? ORDER BY seq", (sid,)
        ).fetchall()
        notes = connection.execute(
            "SELECT * FROM observation_notes WHERE session_id=? ORDER BY through_seq,created_at", (sid,)
        ).fetchall()
        questions = connection.execute(
            "SELECT * FROM observation_questions WHERE session_id=? ORDER BY rowid", (sid,)
        ).fetchall()

    summary_through = int(row["last_summary_seq"] or 0)
    kind_counts: dict[str, int] = {}
    source_stats: dict[str, dict[str, Any]] = {}
    screen_total = screen_understood = screen_errors = screen_skipped = 0
    latest_captured_at = None
    projected_events = []
    for item in raw_events:
        event = _json(item["data"], {})
        if not isinstance(event, dict):
            continue
        kind = str(event.get("kind") or "unknown")
        source = str(event.get("source") or "unknown")
        kind_counts[kind] = kind_counts.get(kind, 0) + 1
        stats = source_stats.setdefault(source, {"events": 0, "transcripts": 0, "screens": 0, "gaps": 0, "latest_offset_ms": None, "latest_captured_at": None})
        stats["events"] += 1
        if kind == "transcript": stats["transcripts"] += 1
        if kind == "screen": stats["screens"] += 1
        if kind == "gap": stats["gaps"] += 1
        if isinstance(event.get("offset_ms"), (int, float)):
            stats["latest_offset_ms"] = event["offset_ms"]
        if isinstance(event.get("captured_at"), str):
            stats["latest_captured_at"] = event["captured_at"]
            latest_captured_at = event["captured_at"]
        if kind == "screen":
            screen_total += 1
            screen_understood += int(isinstance(event.get("screen_understanding"), dict))
            screen_errors += int(bool(event.get("screen_understanding_error")))
            screen_skipped += int(bool(event.get("screen_understanding_skipped")))
        projected_events.append(_event_projection(item["seq"], event, full=full))

    for source in config.get("sources", []) if isinstance(config, dict) else []:
        source_stats.setdefault(source, {"events": 0, "transcripts": 0, "screens": 0, "gaps": 0, "latest_offset_ms": None, "latest_captured_at": None})
    max_seq = raw_events[-1]["seq"] if raw_events else 0
    covered_events = sum(item["seq"] <= summary_through for item in raw_events)
    pending_events = len(raw_events) - covered_events
    retry_after = float(row["retry_after"] or 0)
    retry_at = datetime.fromtimestamp(retry_after, timezone.utc).isoformat() if retry_after > 0 else None
    note_views = [_note_projection(item, full=full) for item in notes]
    question_views = []
    for question in questions:
        item = {"id": question["id"], "status": question["status"], "error": question["error"]}
        if full:
            item["question"] = _short_text(question["question"], 1200)
            data = _json(question["data"], {})
            if isinstance(data, dict):
                item["result"] = {"title": _short_text(data.get("title"), 160), "summary": _short_text(data.get("summary"), 1600)}
        question_views.append(item)

    preset = config.get("preset") if isinstance(config, dict) else None
    return {
        "session": {
            "id": sid,
            "status": row["status"],
            "preset": preset,
            "preset_label": _preset_label(preset),
            "sources": list(config.get("sources", [])) if isinstance(config, dict) else [],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "finish_count": row["finish_count"],
            "consent_version": config.get("consent_version") if isinstance(config, dict) else None,
        },
        "stats": {
            "event_count": len(raw_events),
            "kind_counts": kind_counts,
            "source_stats": source_stats,
            "latest_captured_at": latest_captured_at,
            "screen_total": screen_total,
            "screen_understood": screen_understood,
            "screen_errors": screen_errors,
            "screen_skipped": screen_skipped,
            "checkpoint_count": sum(item["kind"] == "checkpoint" for item in note_views),
            "final_count": sum(item["kind"] == "final" for item in note_views),
            "question_count": len(question_views),
        },
        "analysis": {
            "durable_status": row["status"],
            "summary_through_seq": summary_through,
            "last_seq": max_seq,
            "covered_events": covered_events,
            "event_count": len(raw_events),
            "pending_events": pending_events,
            "coverage": 1.0 if not raw_events else covered_events / len(raw_events),
            "last_error": row["last_error"],
            "retry_after": retry_at,
            "in_memory_worker_state": "unavailable_from_durable_db",
        },
        "notes": note_views,
        "questions": question_views,
        "timeline": projected_events[-timeline_limit:],
        "privacy": {
            "mode": "local_full" if full else "metadata_only",
            "raw_images_exposed": False,
            "content_included": full,
            "note": "开发观察台只读 durable Observation SQLite；不会执行模型，也不会读取 iPhone 的实时麦克风电平。",
        },
    }
