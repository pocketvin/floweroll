from __future__ import annotations

"""Authenticated developer-only read model for Floweroll Runtime observability.

This module deliberately has no Task/Action mutation primitive and no model/tool
client. It reads the existing Runtime SQLite database in query-only mode plus the
bounded local Planner capture files. It is not a second source of Runtime truth.
"""

from contextlib import closing
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sqlite3
from typing import Any, Dict, Optional
import uuid


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = ROOT / "work" / "observability" / "config.json"
_ENABLED = {"1", "true", "yes", "on"}
_SECRET_KEY = re.compile(
    r"^(authorization|proxy.authorization|api.?key|.*secret.*|password|access.?token|refresh.?token|cookie|set.cookie)$",
    re.I,
)
_PRIVATE_REASONING_KEYS = {"reasoning_content", "reasoning_details", "chain_of_thought"}
_SECRET_TEXT = re.compile(r'(?i)(Bearer\s+)[^\s"\\]+|\b(?:sk-|pk-lf-|sk-lf-)[A-Za-z0-9_\-]{8,}|(?i:((?:api_key|access_token|refresh_token|token|secret|password)=))[^\s&"\\]+')
IMPORTANT_EVENTS = {
    "planner.call.failed",
    "planner.retry_wait",
    "planner.retry_resumed",
    "task.blocked",
    "task.completed",
    "task.cancelled",
    "action.model_correctable_failure",
}


def _decode(value: Any, default: Any = None) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            return default
    return value if value is not None else default


def _bounded(value: Any, *, depth: int = 0) -> Any:
    """Bound arbitrary trace/capture content without changing its meaning."""
    if depth > 12:
        return "[depth-limit]"
    if isinstance(value, dict):
        output: Dict[str, Any] = {}
        for index, (key, item) in enumerate(value.items()):
            if index >= 200:
                output["_truncated_fields"] = len(value) - 200
                break
            name = str(key)
            if name in _PRIVATE_REASONING_KEYS:
                continue
            if _SECRET_KEY.match(name):
                output[name] = "[redacted-secret]"
            else:
                output[name] = _bounded(item, depth=depth + 1)
        return output
    if isinstance(value, list):
        result = [_bounded(item, depth=depth + 1) for item in value[:200]]
        if len(value) > 200:
            result.append({"_truncated_items": len(value) - 200})
        return result
    if isinstance(value, str):
        # DecisionContext is intentionally encoded as a JSON string inside the
        # model request. Traverse it too so a capture bug cannot bypass the
        # developer API's second redaction boundary.
        if value.lstrip().startswith(("{", "[")):
            try:
                decoded = json.loads(value)
                if isinstance(decoded, (dict, list)):
                    return json.dumps(_bounded(decoded, depth=depth + 1), ensure_ascii=False, separators=(",", ":"))
            except (ValueError, TypeError):
                pass
        text = value if len(value) <= 200_000 else value[:200_000] + "\n[truncated]"
        return _SECRET_TEXT.sub(lambda match: (match.group(1) or match.group(2) or "") + "[redacted-secret]", text)
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return str(value)


def _readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.5)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    return connection


def _iso_duration_ms(start: Optional[str], end: Optional[str]) -> Optional[float]:
    if not start or not end:
        return None
    try:
        a = datetime.fromisoformat(start.replace("Z", "+00:00"))
        b = datetime.fromisoformat(end.replace("Z", "+00:00"))
        if a.tzinfo is None:
            a = a.replace(tzinfo=timezone.utc)
        if b.tzinfo is None:
            b = b.replace(tzinfo=timezone.utc)
        return max(0.0, (b - a).total_seconds() * 1000.0)
    except ValueError:
        return None


def _system_prompt(wire_request: Dict[str, Any]) -> Optional[str]:
    messages = wire_request.get("messages", wire_request.get("input", []))
    values = [
        item.get("content", "")
        for item in messages
        if isinstance(item, dict)
        and item.get("role") == "system"
        and isinstance(item.get("content"), str)
    ]
    return "\n".join(values) if values else None


def _decision_context(wire_request: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    messages = wire_request.get("messages", wire_request.get("input", []))
    for item in messages:
        if not isinstance(item, dict) or item.get("role") != "user":
            continue
        content = item.get("content")
        if not isinstance(content, str):
            continue
        parsed = _decode(content, {})
        if isinstance(parsed, dict) and isinstance(parsed.get("decision_context"), dict):
            return parsed["decision_context"]
    return None


class DeveloperObservabilityService:
    def __init__(
        self,
        db_path: str,
        *,
        enabled: bool,
        capture_mode: str = "off",
        capture_dir: Optional[Path] = None,
        configuration_note: Optional[str] = None,
    ) -> None:
        self.db_path = Path(db_path)
        self.enabled = bool(enabled)
        self.capture_mode = capture_mode if capture_mode in {"off", "metadata", "local_full"} else "off"
        self.capture_dir = capture_dir
        self.configuration_note = configuration_note
        self.planner_description: Optional[Dict[str, Any]] = None

    @classmethod
    def from_environment(cls, db_path: str) -> "DeveloperObservabilityService":
        enabled = os.environ.get("FLOWEROLL_DEVELOPER_OBSERVABILITY", "").strip().lower() in _ENABLED
        if not enabled:
            return cls(db_path, enabled=False, configuration_note="developer_observability_disabled")

        config_path = Path(os.environ.get("FLOWEROLL_OBSERVABILITY_CONFIG", str(DEFAULT_CONFIG)))
        try:
            config = json.loads(config_path.read_text())
            mode = str(config.get("mode", "off"))
            configured_db = Path(str(config.get("runtime_db", ""))).resolve()
            actual_db = Path(db_path).resolve()
            if configured_db != actual_db:
                return cls(
                    db_path,
                    enabled=True,
                    capture_mode=mode,
                    configuration_note="capture_runtime_db_mismatch",
                )
            raw_dir = Path(str(config.get("snapshot_dir", ""))).resolve()
            raw_dir.relative_to((ROOT / "work").resolve())
            return cls(
                db_path,
                enabled=True,
                capture_mode=mode,
                capture_dir=raw_dir,
            )
        except Exception as exc:
            # Developer observability must never stop the product Host from booting.
            return cls(
                db_path,
                enabled=True,
                capture_mode="off",
                configuration_note="capture_config_unavailable:" + type(exc).__name__,
            )

    def status(self) -> Dict[str, Any]:
        return {
            "enabled": self.enabled,
            "capture_mode": self.capture_mode,
            "full_capture_available": self.capture_mode == "local_full" and self.capture_dir is not None,
            "configuration_note": self.configuration_note,
            "planner": self.planner_description,
            "read_only": True,
            "limitations": [
                "historical uncaptured requests cannot be reconstructed",
                "schema conformance is not task-quality evaluation",
                "no mutation/retry/tool execution endpoints exist here",
                "private model reasoning is never exposed",
            ],
        }

    @staticmethod
    def _validate_task_id(task_id: str) -> str:
        try:
            return str(uuid.UUID(task_id))
        except (ValueError, AttributeError, TypeError) as exc:
            raise ValueError("task_id must be a UUID") from exc

    def _task_exists(self, connection: sqlite3.Connection, task_id: str) -> bool:
        return connection.execute("SELECT 1 FROM tasks WHERE id=?", (task_id,)).fetchone() is not None

    def list_tasks(self, *, limit: int = 40) -> Dict[str, Any]:
        if limit < 1 or limit > 50:
            raise ValueError("limit must be between 1 and 50")
        with closing(_readonly(self.db_path)) as connection:
            rows = [
                dict(row)
                for row in connection.execute(
                    """
                    SELECT t.id AS task_id,t.goal,t.status,t.created_at,t.updated_at,
                           r.phase,r.planner_calls,
                           (SELECT count(*) FROM actions a WHERE a.task_id=t.id) AS action_count
                    FROM tasks t
                    LEFT JOIN task_runtime r ON r.task_id=t.id
                    ORDER BY t.updated_at DESC
                    LIMIT ?
                    """,
                    (limit,),
                )
            ]
        return _bounded({"tasks": rows, "limit": limit, "status": self.status()})

    def _captures_for_task(self, task_id: str) -> Dict[int, Dict[str, Any]]:
        if self.capture_dir is None:
            return {}
        folder = self.capture_dir / task_id
        if not folder.is_dir() or folder.is_symlink():
            return {}
        values: Dict[int, Dict[str, Any]] = {}
        for path in sorted(folder.glob("*.json"))[-256:]:
            try:
                if path.is_symlink() or path.stat().st_size > 4 * 1024 * 1024:
                    continue
                value = json.loads(path.read_text())
                if value.get("task_id") != task_id:
                    continue
                number = int(value.get("call_number", 0))
                if number < 1 or number > 10_000:
                    continue
                if number not in values or value.get("updated_at", "") > values[number].get("updated_at", ""):
                    values[number] = value
            except (OSError, ValueError, TypeError):
                continue
        return values

    def task_overview(self, task_id: str) -> Dict[str, Any]:
        task_id = self._validate_task_id(task_id)
        with closing(_readonly(self.db_path)) as connection:
            task = connection.execute(
                """
                SELECT t.id AS task_id,t.goal,t.status,t.created_at,t.updated_at,t.thread_id,t.parent_task_id,
                       r.phase,r.planner_calls,r.runtime_revision,r.block_reason,r.wait_kind,r.wake_at
                FROM tasks t LEFT JOIN task_runtime r ON r.task_id=t.id WHERE t.id=?
                """,
                (task_id,),
            ).fetchone()
            if task is None:
                raise KeyError(task_id)
            traces = [
                dict(row)
                for row in connection.execute(
                    "SELECT id,event_type,data_json,created_at FROM traces WHERE task_id=? ORDER BY id LIMIT 10000",
                    (task_id,),
                )
            ]
            actions = [
                dict(row)
                for row in connection.execute(
                    """
                    SELECT a.id AS action_id,a.step_index,a.action_type,a.status,a.failure_code,a.error_text,
                           a.created_at,a.updated_at,
                           (SELECT count(*) FROM action_attempts aa WHERE aa.action_id=a.id) AS attempt_count
                    FROM actions a WHERE a.task_id=? ORDER BY a.step_index LIMIT 500
                    """,
                    (task_id,),
                )
            ]

        captures = self._captures_for_task(task_id)
        grouped: Dict[int, Dict[str, Any]] = {}
        current_call: Optional[int] = None
        for trace in traces:
            data = _decode(trace.get("data_json"), {})
            if trace["event_type"] == "planner.call.started" and isinstance(data.get("call_number"), int):
                current_call = data["call_number"]
            number = data.get("call_number")
            if isinstance(number, int):
                grouped.setdefault(number, {})[trace["event_type"]] = {**trace, "data": data}
            elif trace["event_type"] == "planner.decision" and current_call is not None:
                grouped.setdefault(current_call, {})[trace["event_type"]] = {**trace, "data": data}

        planner_calls = []
        reported_tokens = 0
        model_ms_sum = 0.0
        for number, group in sorted(grouped.items()):
            started = group.get("planner.call.started", {}).get("created_at")
            metrics = group.get("planner.call.metrics", {}).get("data", {})
            end_candidates = [
                item.get("created_at")
                for item in group.values()
                if isinstance(item, dict) and item.get("created_at")
            ]
            capture = captures.get(number, {})
            if capture.get("updated_at"):
                end_candidates.append(capture["updated_at"])
            ended = max(end_candidates) if end_candidates else started
            total_tokens = metrics.get("total_tokens")
            if isinstance(total_tokens, int) and not isinstance(total_tokens, bool):
                reported_tokens += total_tokens
            model_ms = metrics.get("model_ms")
            if isinstance(model_ms, (int, float)) and not isinstance(model_ms, bool):
                model_ms_sum += float(model_ms)
            outcome = metrics.get("outcome")
            if not outcome:
                outcome = "error" if "planner.call.failed" in group else ("committed" if "planner.call.committed" in group else "in_flight")
            planner_calls.append(
                {
                    "call_number": number,
                    "started_at": started,
                    "ended_at": ended,
                    "duration_ms": _iso_duration_ms(started, ended),
                    "outcome": outcome,
                    "provider_model": metrics.get("provider_model") or capture.get("provider_model"),
                    "model_ms": model_ms,
                    "prompt_tokens": metrics.get("prompt_tokens"),
                    "completion_tokens": metrics.get("completion_tokens"),
                    "total_tokens": total_tokens,
                    "visible_capabilities": capture.get("visible_capabilities", []),
                    "capture_available": self.capture_mode == "local_full" and bool(capture.get("wire_request")),
                    "prompt_sha256": (capture.get("prompt") or {}).get("sha256"),
                    "error_type": group.get("planner.call.failed", {}).get("data", {}).get("error_type"),
                }
            )

        evidence = []
        for trace in traces:
            if trace["event_type"] not in IMPORTANT_EVENTS:
                continue
            evidence.append(
                {
                    "event_id": trace["id"],
                    "event_type": trace["event_type"],
                    "created_at": trace["created_at"],
                    "data": _bounded(_decode(trace.get("data_json"), {})),
                }
            )
        evidence = evidence[-80:]

        task_value = dict(task)
        return _bounded(
            {
                "task": task_value,
                "summary": {
                    "planner_calls": len(planner_calls),
                    "actions": len(actions),
                    "reported_tokens_only": reported_tokens,
                    "model_ms_sum": round(model_ms_sum, 3),
                    "full_captured_calls": sum(1 for item in planner_calls if item["capture_available"]),
                    "capture_mode": self.capture_mode,
                    "cost": None,
                    "cost_note": "未配置经核实的模型单价；未知费用不会显示成零。",
                },
                "planner_calls": planner_calls,
                "actions": actions,
                "evidence": evidence,
                "observability": self.status(),
            }
        )

    def planner_call(self, task_id: str, call_number: int) -> Dict[str, Any]:
        task_id = self._validate_task_id(task_id)
        if call_number < 1 or call_number > 10_000:
            raise ValueError("call_number must be between 1 and 10000")
        with closing(_readonly(self.db_path)) as connection:
            if not self._task_exists(connection, task_id):
                raise KeyError(task_id)
            metrics = [
                _decode(row["data_json"], {})
                for row in connection.execute(
                    "SELECT data_json FROM traces WHERE task_id=? AND event_type='planner.call.metrics' ORDER BY id",
                    (task_id,),
                )
                if _decode(row["data_json"], {}).get("call_number") == call_number
            ]

        capture = self._captures_for_task(task_id).get(call_number, {})
        available = self.capture_mode == "local_full" and bool(capture.get("wire_request"))
        metadata = {
            key: capture.get(key)
            for key in (
                "state",
                "started_at",
                "ended_at",
                "request_bytes",
                "request_sha256",
                "provider_model",
                "error_type",
                "content_omitted",
                "visible_capabilities",
            )
        }
        metadata["prompt_sha256"] = (capture.get("prompt") or {}).get("sha256")
        result: Dict[str, Any] = {
            "task_id": task_id,
            "call_number": call_number,
            "available": available,
            "capture_mode": self.capture_mode,
            "metadata": metadata,
            "metrics": metrics,
            "note": (
                "这是发送前采集的最终请求体；密钥已脱敏，不含 HTTP 认证头或模型私有推理。"
                if available
                else "该调用没有完整请求快照。不会使用当前 Prompt 模板伪造历史输入。"
            ),
        }
        if not available:
            return _bounded(result)

        wire = capture["wire_request"]
        context = _decision_context(wire) or {}
        captured_prompt = _system_prompt(wire)
        current_prompt_path = ROOT / "host" / "prompts" / "planner.system.txt"
        current_prompt = current_prompt_path.read_text(encoding="utf-8") if current_prompt_path.is_file() else None
        response_text = capture.get("response_text")
        parsed_response = _decode(response_text, response_text) if isinstance(response_text, str) else None
        result.update(
            {
                "system_prompt": captured_prompt,
                "decision_context": context,
                "tools": {
                    "visible": capture.get("visible_capabilities", []),
                    "definitions": context.get("available_capabilities", []) if isinstance(context, dict) else [],
                    "note": "这是本次真实工作集；未采集的排序分数不会被推测。",
                },
                "wire_request": wire,
                "model_response": parsed_response,
                "prompt_matches_current_source": captured_prompt == current_prompt if captured_prompt is not None and current_prompt is not None else None,
            }
        )
        return _bounded(result)
