from __future__ import annotations

from datetime import datetime, timedelta
import re
from typing import Any, Dict, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .execution_contracts import ExecutionProfile, ExecutionVerification


_QUERY_PROFILE = ExecutionProfile(
    timeout_seconds=15,
    idempotency_mode="NATURAL_READ_ONLY",
    retry_mode="SAFE_WITH_SAME_KEY",
    verification_mode="DEVICE_READ_BACK",
    reconciliation_mode="SAFE_REREAD",
    max_attempts=2,
    retry_backoff_seconds=1,
)

_COMPLETION_PROFILE = ExecutionProfile(
    timeout_seconds=20,
    idempotency_mode="DEVICE_JOURNAL_AND_DESIRED_STATE",
    retry_mode="NO_BLIND_RETRY",
    verification_mode="DEVICE_READ_BACK",
    reconciliation_mode="DEVICE_DESIRED_STATE_READ_BACK",
    max_attempts=1,
)

_UPDATE_PROFILE = ExecutionProfile(
    timeout_seconds=20,
    idempotency_mode="DEVICE_JOURNAL_AND_DESIRED_STATE",
    retry_mode="NO_BLIND_RETRY",
    verification_mode="DEVICE_READ_BACK",
    reconciliation_mode="DEVICE_EXACT_STATE_READ_BACK",
    max_attempts=1,
)

_REMOVE_PROFILE = ExecutionProfile(
    timeout_seconds=20,
    idempotency_mode="DESTRUCTIVE_ONE_SHOT_DEVICE_JOURNAL",
    retry_mode="NO_BLIND_RETRY",
    verification_mode="DEVICE_ABSENCE_READ_BACK",
    reconciliation_mode="READ_ONLY_AMBIGUOUS_AFTER_MAY_HAVE_STARTED",
    max_attempts=1,
)

_MODEL_CORRECTABLE_ERRORS = {
    "reminder_query_invalid",
    "reminder_query_too_broad",
    "reminder_calendar_not_found",
    "reminder_completion_invalid",
    "reminder_not_found_or_stale",
    "reminder_revision_stale",
    "reminder_read_only_list",
    "reminder_recurring_mutation_unsupported",
    "reminder_target_changed",
    "reminder_update_invalid",
    "reminder_update_unsupported_topology",
    "reminder_completion_changed",
    "reminder_remove_invalid",
}

_HEX_64_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def _clean_text(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    return cleaned or None


def _parse_instant(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or value != value.strip() or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed


def normalize_query_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    allowed = {
        "reminder_id", "status", "start_at", "end_at",
        "calendar_id", "title_contains", "max_results",
    }
    if not isinstance(arguments, dict) or set(arguments) - allowed:
        return None
    max_results = arguments.get("max_results", 20)
    if isinstance(max_results, bool) or not isinstance(max_results, int) or not 1 <= max_results <= 50:
        return None

    reminder_id = _clean_text(arguments.get("reminder_id"))
    if reminder_id is not None:
        if len(reminder_id) > 512 or set(arguments) - {"reminder_id", "max_results"}:
            return None
        return {
            "mode": "exact_id",
            "reminder_id": reminder_id,
            "max_results": 1,
            "date_semantics": None,
        }

    status = arguments.get("status")
    if status not in {"incomplete", "completed"}:
        return None
    calendar_id = _clean_text(arguments.get("calendar_id"))
    if calendar_id is not None and len(calendar_id) > 512:
        return None
    title_contains = _clean_text(arguments.get("title_contains"))
    if title_contains is not None and not 2 <= len(title_contains) <= 160:
        return None

    raw_start = arguments.get("start_at")
    raw_end = arguments.get("end_at")
    if (raw_start is None) != (raw_end is None):
        return None
    start = _parse_instant(raw_start) if raw_start is not None else None
    end = _parse_instant(raw_end) if raw_end is not None else None
    if raw_start is not None and (start is None or end is None):
        return None
    if start is not None:
        if end <= start or end - start > timedelta(days=366):
            return None
    if calendar_id is None and start is None:
        return None

    return {
        "mode": "filtered",
        "status": status,
        "calendar_id": calendar_id,
        "title_contains": title_contains,
        "start_at": raw_start,
        "end_at": raw_end,
        "date_semantics": "due_date" if status == "incomplete" else "completion_date",
        "max_results": max_results,
    }


def completion_arguments_valid(arguments: Dict[str, Any]) -> bool:
    if not isinstance(arguments, dict) or set(arguments) != {"reminder_id", "expected_revision", "completed"}:
        return False
    reminder_id = _clean_text(arguments.get("reminder_id"))
    revision = arguments.get("expected_revision")
    completed = arguments.get("completed")
    return (
        reminder_id is not None
        and len(reminder_id) <= 512
        and isinstance(revision, str)
        and _HEX_64_RE.fullmatch(revision) is not None
        and isinstance(completed, bool)
    )


def normalize_remove_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, str]]:
    required = {"reminder_id", "expected_revision", "expected_list_id", "expected_title"}
    if not isinstance(arguments, dict) or set(arguments) != required:
        return None
    reminder_id = arguments.get("reminder_id")
    revision = arguments.get("expected_revision")
    list_id = arguments.get("expected_list_id")
    title = arguments.get("expected_title")
    for value, limit in ((reminder_id, 512), (list_id, 512), (title, 160)):
        if not isinstance(value, str) or value != value.strip() or not value or len(value) > limit:
            return None
    if not isinstance(revision, str) or _HEX_64_RE.fullmatch(revision) is None:
        return None
    return {
        "reminder_id": reminder_id,
        "expected_revision": revision.lower(),
        "expected_list_id": list_id,
        "expected_title": title,
    }


def normalize_update_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    required = {
        "reminder_id", "expected_revision", "expected_list_id", "title", "notes",
        "priority", "due_mode", "due_at", "due_time_zone", "alarm_mode",
    }
    if not isinstance(arguments, dict) or set(arguments) != required:
        return None

    reminder_id = arguments.get("reminder_id")
    revision = arguments.get("expected_revision")
    list_id = arguments.get("expected_list_id")
    title = arguments.get("title")
    notes = arguments.get("notes")
    priority = arguments.get("priority")
    due_mode = arguments.get("due_mode")
    due_at = arguments.get("due_at")
    due_time_zone = arguments.get("due_time_zone")
    alarm_mode = arguments.get("alarm_mode")

    if not isinstance(reminder_id, str) or reminder_id != reminder_id.strip() or not reminder_id or len(reminder_id) > 512:
        return None
    if not isinstance(revision, str) or _HEX_64_RE.fullmatch(revision) is None:
        return None
    if not isinstance(list_id, str) or list_id != list_id.strip() or not list_id or len(list_id) > 512:
        return None
    if not isinstance(title, str) or title != title.strip() or not title or len(title) > 160:
        return None
    if not isinstance(notes, str) or len(notes) > 4000:
        return None
    if isinstance(priority, bool) or not isinstance(priority, int) or not 0 <= priority <= 9:
        return None
    if due_mode not in {"none", "timed"} or alarm_mode not in {"none", "at_due"}:
        return None
    if not isinstance(due_at, str) or not isinstance(due_time_zone, str):
        return None

    if due_mode == "none":
        if due_at != "" or due_time_zone != "" or alarm_mode != "none":
            return None
    else:
        if not due_at or due_at != due_at.strip() or not due_time_zone or due_time_zone != due_time_zone.strip():
            return None
        instant = _parse_instant(due_at)
        if instant is None:
            return None
        try:
            zone = ZoneInfo(due_time_zone)
        except (ZoneInfoNotFoundError, ValueError):
            return None
        if instant.utcoffset() != instant.astimezone(zone).utcoffset():
            return None

    return {
        "reminder_id": reminder_id,
        "expected_revision": revision.lower(),
        "expected_list_id": list_id,
        "title": title,
        "notes": notes,
        "priority": priority,
        "due_mode": due_mode,
        "due_at": due_at,
        "due_time_zone": due_time_zone,
        "alarm_mode": alarm_mode,
    }


def _failure(error: Optional[str], output: Dict[str, Any], fallback: str) -> ExecutionVerification:
    code = output.get("error_code")
    outcome = "MODEL_CORRECTABLE_FAILURE" if code in _MODEL_CORRECTABLE_ERRORS else "TERMINAL_FAILURE"
    return ExecutionVerification(
        outcome=outcome,
        error=error or (str(code) if code else fallback),
    )


def _valid_optional_instant(value: Any) -> bool:
    return value is None or _parse_instant(value) is not None


def _valid_snapshot(item: Any) -> bool:
    if not isinstance(item, dict):
        return False
    required = {
        "reminder_id", "revision", "title", "completed", "due_at", "completion_at",
        "calendar_id", "calendar_name", "calendar_writable", "has_recurrence",
        "list_id", "list_name", "list_writable",
        "notes", "priority", "due_mode", "due_time_zone", "alarm_mode", "update_eligible",
        "remove_eligible",
    }
    if not required.issubset(item):
        return False
    if any(not isinstance(item.get(key), str) or not item[key].strip()
           for key in ("reminder_id", "title", "calendar_id", "calendar_name")):
        return False
    revision = item.get("revision")
    if not isinstance(revision, str) or _HEX_64_RE.fullmatch(revision) is None:
        return False
    if not isinstance(item.get("completed"), bool):
        return False
    if not isinstance(item.get("calendar_writable"), bool):
        return False
    if not isinstance(item.get("has_recurrence"), bool):
        return False
    if item.get("list_id") != item.get("calendar_id") or item.get("list_name") != item.get("calendar_name"):
        return False
    if item.get("list_writable") is not item.get("calendar_writable"):
        return False
    if not isinstance(item.get("notes"), str) or not isinstance(item.get("priority"), int) or isinstance(item.get("priority"), bool):
        return False
    if not 0 <= item["priority"] <= 9 or not isinstance(item.get("update_eligible"), bool):
        return False
    if not isinstance(item.get("remove_eligible"), bool):
        return False
    if item["remove_eligible"] and (not item["calendar_writable"] or item["has_recurrence"]):
        return False
    if item["update_eligible"]:
        if item.get("due_mode") not in {"none", "timed"} or item.get("alarm_mode") not in {"none", "at_due"}:
            return False
        if not isinstance(item.get("due_time_zone"), str):
            return False
        if item["due_mode"] == "none":
            if item.get("due_at") not in {None, ""} or item["due_time_zone"] != "" or item["alarm_mode"] != "none":
                return False
        else:
            due = _parse_instant(item.get("due_at"))
            if due is None or not item["due_time_zone"]:
                return False
            try:
                ZoneInfo(item["due_time_zone"])
            except (ZoneInfoNotFoundError, ValueError):
                return False
            # Device query normalizes due_at to UTC while separately carrying the
            # original EventKit IANA zone. Offset matching is enforced on update
            # arguments, not on the readback's canonical UTC instant.
    else:
        if item.get("due_mode") not in {None, "none", "timed"}:
            return False
        if item.get("alarm_mode") not in {None, "none", "at_due"}:
            return False
        if item.get("due_time_zone") is not None and not isinstance(item.get("due_time_zone"), str):
            return False
    reason = item.get("update_ineligible_reason")
    if reason is not None and not isinstance(reason, str):
        return False
    remove_reason = item.get("remove_ineligible_reason")
    if remove_reason is not None and not isinstance(remove_reason, str):
        return False
    return _valid_optional_instant(item.get("due_at")) and _valid_optional_instant(item.get("completion_at"))


def _bounded_observation_item(item: Dict[str, Any]) -> Dict[str, Any]:
    fields = (
        "reminder_id", "revision", "title", "completed", "due_at", "completion_at",
        "calendar_id", "calendar_name", "calendar_writable", "has_recurrence",
        "list_id", "list_name", "list_writable",
        "notes", "priority", "due_mode", "due_time_zone", "alarm_mode",
        "update_eligible", "update_ineligible_reason",
        "remove_eligible", "remove_ineligible_reason",
    )
    return {key: item.get(key) for key in fields}


def _query_summary(observation: Dict[str, Any]) -> str:
    reminders = observation["reminders"]
    if not reminders:
        return "没有找到符合条件的提醒事项。"
    parts = []
    for item in reminders[:8]:
        state = "已完成" if item["completed"] else "未完成"
        due = item.get("due_at")
        suffix = f"，到期 {due}" if isinstance(due, str) else ""
        parts.append(f"「{item['title']}」{state}{suffix}")
    tail = "；".join(parts)
    if observation.get("truncated") is True:
        tail += "；还有更多结果未展开"
    return f"找到 {len(reminders)} 个提醒事项：{tail}。"


class ReminderQueryAdapter:
    capability_id = "reminder.query"
    source_kind = "ios"
    execution_profile = _QUERY_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            return _failure(error, output, "iPhone Reminder query failed")
        expected = normalize_query_arguments(action.get("payload", {}))
        if expected is None:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query Action arguments are invalid")
        if output.get("verified") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query was not device verified")
        if output.get("query_mode") != expected["mode"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query mode did not match the Action")
        if output.get("date_semantics") != expected["date_semantics"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query date semantics did not match the Action")
        reminders = output.get("reminders")
        truncated = output.get("truncated")
        if not isinstance(reminders, list) or not isinstance(truncated, bool):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query result shape is invalid")
        if len(reminders) > expected["max_results"] or (expected["mode"] == "exact_id" and len(reminders) > 1):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query exceeded its result bound")

        start = _parse_instant(expected.get("start_at")) if expected.get("start_at") else None
        end = _parse_instant(expected.get("end_at")) if expected.get("end_at") else None
        for item in reminders:
            if not _valid_snapshot(item):
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query returned a malformed snapshot")
            if expected["mode"] == "exact_id" and item["reminder_id"] != expected["reminder_id"]:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Exact Reminder query returned a different native target")
            if expected.get("calendar_id") and item["calendar_id"] != expected["calendar_id"]:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query returned a different list")
            if expected.get("status") == "incomplete" and item["completed"] is not False:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Incomplete Reminder query returned a completed item")
            if expected.get("status") == "completed" and item["completed"] is not True:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Completed Reminder query returned an incomplete item")
            if expected.get("title_contains") and expected["title_contains"].casefold() not in item["title"].casefold():
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder title filter was not preserved")
            if start is not None:
                date_field = "due_at" if expected["date_semantics"] == "due_date" else "completion_at"
                actual = _parse_instant(item.get(date_field))
                if actual is None or not (start <= actual <= end):
                    return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder query returned an item outside the requested date window")

        observation = {
            "query_mode": expected["mode"],
            "date_semantics": expected["date_semantics"],
            "reminders": [_bounded_observation_item(item) for item in reminders],
            "truncated": truncated,
        }
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=_query_summary(observation),
        )


class ReminderSetCompletionAdapter:
    capability_id = "reminder.set_completion"
    source_kind = "ios"
    execution_profile = _COMPLETION_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            return _failure(error, output, "iPhone Reminder completion update failed")
        args = action.get("payload", {})
        if not completion_arguments_valid(args):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder completion Action arguments are invalid")
        if output.get("verified") is not True or output.get("requested_reminder_id") != args["reminder_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder completion result lost target correlation")
        if output.get("completed") is not args["completed"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder completion readback did not reach desired state")
        if output.get("has_recurrence") is not False or output.get("calendar_writable") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder completion target is outside the supported V1 scope")
        if not _valid_snapshot(output):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder completion readback snapshot is malformed")
        applied = output.get("applied")
        if applied is not None and not isinstance(applied, bool):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder completion applied marker is malformed")

        observation = _bounded_observation_item(output)
        observation["requested_reminder_id"] = args["reminder_id"]
        if applied is not None:
            observation["applied"] = applied
        verb = "标记为完成" if args["completed"] else "恢复为未完成"
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=f"已将提醒「{output['title']}」{verb}。",
        )

class ReminderUpdateAdapter:
    capability_id = "reminder.update"
    source_kind = "ios"
    execution_profile = _UPDATE_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def predispatch_confirmation(self, action: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        args = normalize_update_arguments(action.get("payload", {}))
        if args is None:
            return None
        due = "无到期时间" if args["due_mode"] == "none" else f"到期：{args['due_at']}（{args['due_time_zone']}）"
        alarm = "到期时提醒" if args["alarm_mode"] == "at_due" else "不设置到期提醒"
        notes = args["notes"].replace("\n", " ")
        if len(notes) > 96:
            notes = notes[:96] + "…"
        prompt = f"修改提醒事项：{args['title']}\n{due}\n{alarm}\n优先级：{args['priority']}"
        if notes:
            prompt += f"\n备注：{notes}"
        return {
            "prompt": prompt,
            "suggested_options": [{"id": "approve", "label": "确认修改"}, {"id": "cancel", "label": "取消"}],
            "accepts_text": False,
            "reason": "side_effect_approval",
            "execution_fields": dict(action["payload"]),
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            return _failure(error, output, "iPhone Reminder update failed")
        expected = normalize_update_arguments(action.get("payload", {}))
        if expected is None:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update Action arguments are invalid")
        if output.get("verified") is not True or output.get("requested_reminder_id") != expected["reminder_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update result lost target correlation")
        if not _valid_snapshot(output):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update readback snapshot is malformed")
        if output.get("list_id") != expected["expected_list_id"] or output.get("list_writable") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update readback list does not match the approved target")
        if output.get("has_recurrence") is not False or output.get("update_eligible") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update target is outside the supported V1 scope")
        if output.get("title") != expected["title"] or output.get("notes") != expected["notes"] or output.get("priority") != expected["priority"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update readback did not reach the approved content state")
        if output.get("due_mode") != expected["due_mode"] or output.get("alarm_mode") != expected["alarm_mode"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update readback did not reach the approved due/alarm state")
        if expected["due_mode"] == "none":
            if output.get("due_at") not in {None, ""} or output.get("due_time_zone") != "":
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update readback unexpectedly retained a due date")
        else:
            actual_due = _parse_instant(output.get("due_at"))
            wanted_due = _parse_instant(expected["due_at"] )
            if actual_due is None or wanted_due is None or actual_due != wanted_due or output.get("due_time_zone") != expected["due_time_zone"]:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update readback due time does not match the approved state")
        if output.get("completion_preserved") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update did not prove completion-state preservation")
        applied = output.get("applied")
        if applied is not None and not isinstance(applied, bool):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder update applied marker is malformed")

        observation = _bounded_observation_item(output)
        observation["requested_reminder_id"] = expected["reminder_id"]
        observation["completion_preserved"] = True
        if applied is not None:
            observation["applied"] = applied
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=f"已修改提醒「{output['title']}」并重新核对。",
        )



class ReminderRemoveAdapter:
    capability_id = "reminder.remove"
    source_kind = "ios"
    execution_profile = _REMOVE_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def predispatch_confirmation(self, action: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        args = normalize_remove_arguments(action.get("payload", {}))
        if args is None:
            return None
        return {
            "prompt": f"删除提醒事项「{args['expected_title']}」？删除后小卷不会自动恢复。",
            "suggested_options": [{"id": "approve", "label": "确认删除"}, {"id": "cancel", "label": "取消"}],
            "accepts_text": False,
            "reason": "destructive_side_effect_approval",
            "execution_fields": dict(action["payload"]),
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            return _failure(error, output, "iPhone Reminder remove failed")
        expected = normalize_remove_arguments(action.get("payload", {}))
        if expected is None:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder remove Action arguments are invalid")
        if output.get("verified") is not True or output.get("deleted") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder remove result was not verified absent")
        if output.get("requested_reminder_id") != expected["reminder_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder remove result lost target correlation")
        if output.get("list_id") != expected["expected_list_id"] or output.get("title") != expected["expected_title"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder remove result does not match the approved target")
        if output.get("verification") != "immediate_exact_id_absence":
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Reminder remove result lacks immediate native absence proof")
        observation = {
            "requested_reminder_id": expected["reminder_id"],
            "list_id": expected["expected_list_id"],
            "title": expected["expected_title"],
            "deleted": True,
            "verification": "immediate_exact_id_absence",
        }
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=f"已删除提醒事项「{expected['expected_title']}」并核对。",
        )
