from __future__ import annotations

from datetime import datetime, timedelta, tzinfo
import re
from typing import Any, Dict, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .execution_contracts import ExecutionProfile, ExecutionVerification


_READ_PROFILE = ExecutionProfile(
    timeout_seconds=15,
    idempotency_mode="NATURAL_READ_ONLY",
    retry_mode="SAFE_WITH_SAME_KEY",
    verification_mode="DEVICE_READ_BACK",
    reconciliation_mode="SAFE_REREAD",
    max_attempts=2,
    retry_backoff_seconds=1,
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

_HEX_64_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_UPDATE_MODEL_CORRECTABLE_ERRORS = {
    "calendar_update_invalid",
    "calendar_event_not_found_or_stale",
    "calendar_update_revision_stale",
    "calendar_update_calendar_changed",
    "calendar_update_read_only_calendar",
    "calendar_update_unsupported_target",
}
_REMOVE_MODEL_CORRECTABLE_ERRORS = {
    "calendar_remove_invalid",
    "calendar_event_not_found_or_stale",
    "calendar_remove_revision_stale",
    "calendar_remove_calendar_changed",
    "calendar_remove_read_only_calendar",
    "calendar_remove_unsupported_target",
}


def _parse_iso(value: str) -> Optional[datetime]:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def normalize_calendar_update_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    required = {
        "event_id", "expected_revision", "expected_calendar_id", "title",
        "start_at", "end_at", "time_zone", "location",
    }
    if not isinstance(arguments, dict) or set(arguments) != required:
        return None
    event_id = arguments.get("event_id")
    revision = arguments.get("expected_revision")
    calendar_id = arguments.get("expected_calendar_id")
    title = arguments.get("title")
    start_at = arguments.get("start_at")
    end_at = arguments.get("end_at")
    zone_id = arguments.get("time_zone")
    location = arguments.get("location")
    for value, limit, allow_empty in (
        (event_id, 512, False), (calendar_id, 512, False), (title, 160, False),
        (start_at, 40, False), (end_at, 40, False), (zone_id, 64, False), (location, 500, True),
    ):
        if not isinstance(value, str) or value != value.strip() or len(value) > limit or (not allow_empty and not value):
            return None
    if not isinstance(revision, str) or _HEX_64_RE.fullmatch(revision) is None:
        return None
    start = _parse_iso(start_at)
    end = _parse_iso(end_at)
    if start is None or end is None or start.tzinfo is None or end.tzinfo is None or end <= start:
        return None
    if end - start > timedelta(days=7):
        return None
    try:
        zone = ZoneInfo(zone_id)
    except (ZoneInfoNotFoundError, ValueError):
        return None
    if start.utcoffset() != start.astimezone(zone).utcoffset() or end.utcoffset() != end.astimezone(zone).utcoffset():
        return None
    return {
        "event_id": event_id,
        "expected_revision": revision.lower(),
        "expected_calendar_id": calendar_id,
        "title": title,
        "start_at": start_at,
        "end_at": end_at,
        "time_zone": zone_id,
        "location": location,
        "start": start,
        "end": end,
        "zone": zone,
    }


def normalize_calendar_remove_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, str]]:
    required = {"event_id", "expected_revision", "expected_calendar_id", "expected_title"}
    if not isinstance(arguments, dict) or set(arguments) != required:
        return None
    event_id = arguments.get("event_id")
    revision = arguments.get("expected_revision")
    calendar_id = arguments.get("expected_calendar_id")
    title = arguments.get("expected_title")
    for value, limit in ((event_id, 512), (calendar_id, 512), (title, 160)):
        if not isinstance(value, str) or value != value.strip() or not value or len(value) > limit:
            return None
    if not isinstance(revision, str) or _HEX_64_RE.fullmatch(revision) is None:
        return None
    return {
        "event_id": event_id,
        "expected_revision": revision.lower(),
        "expected_calendar_id": calendar_id,
        "expected_title": title,
    }


def _valid_calendar_snapshot(item: Any) -> bool:
    if not isinstance(item, dict):
        return False
    required = {
        "event_id", "revision", "title", "start_at", "end_at", "time_zone", "location",
        "calendar_id", "calendar_name", "calendar_writable", "all_day", "has_recurrence",
        "is_detached", "has_attendees", "has_organizer", "last_modified_at", "update_eligible",
        "remove_eligible",
    }
    if not required.issubset(item):
        return False
    if not isinstance(item.get("title"), str) or not isinstance(item.get("location"), str):
        return False
    start = _parse_iso(item.get("start_at")) if isinstance(item.get("start_at"), str) else None
    end = _parse_iso(item.get("end_at")) if isinstance(item.get("end_at"), str) else None
    if start is None or end is None or start.tzinfo is None or end.tzinfo is None or end <= start:
        return False
    if not isinstance(item.get("time_zone"), str):
        return False
    for key in ("calendar_id", "calendar_name"):
        if not isinstance(item.get(key), str) or not item[key].strip():
            return False
    for key in ("calendar_writable", "all_day", "has_recurrence", "is_detached", "has_attendees", "has_organizer", "update_eligible", "remove_eligible"):
        if not isinstance(item.get(key), bool):
            return False
    event_id = item.get("event_id")
    revision = item.get("revision")
    if event_id is not None and (not isinstance(event_id, str) or not event_id.strip()):
        return False
    if revision is not None and (not isinstance(revision, str) or _HEX_64_RE.fullmatch(revision) is None):
        return False
    if item["update_eligible"]:
        if event_id is None or revision is None or not item["calendar_writable"] or not item["time_zone"]:
            return False
        if any(item[key] for key in ("all_day", "has_recurrence", "is_detached", "has_attendees", "has_organizer")):
            return False
    if item["remove_eligible"]:
        if event_id is None or revision is None or not item["calendar_writable"]:
            return False
        if any(item[key] for key in ("has_recurrence", "is_detached", "has_attendees", "has_organizer")):
            return False
    reason = item.get("update_ineligible_reason")
    if reason is not None and not isinstance(reason, str):
        return False
    remove_reason = item.get("remove_ineligible_reason")
    if remove_reason is not None and not isinstance(remove_reason, str):
        return False
    modified = item.get("last_modified_at")
    if modified is not None and (not isinstance(modified, str) or _parse_iso(modified) is None):
        return False
    return True


def _bounded_calendar_event(item: Dict[str, Any]) -> Dict[str, Any]:
    fields = (
        "event_id", "revision", "title", "start_at", "end_at", "time_zone", "location",
        "calendar_id", "calendar_name", "calendar_writable", "all_day", "has_recurrence",
        "is_detached", "has_attendees", "has_organizer", "last_modified_at",
        "update_eligible", "update_ineligible_reason",
        "remove_eligible", "remove_ineligible_reason",
    )
    return {key: item.get(key) for key in fields}


def _update_failure(error: Optional[str], output: Dict[str, Any], fallback: str) -> ExecutionVerification:
    code = output.get("error_code")
    return ExecutionVerification(
        outcome="MODEL_CORRECTABLE_FAILURE" if code in _UPDATE_MODEL_CORRECTABLE_ERRORS else "TERMINAL_FAILURE",
        error=error or (str(code) if code else fallback),
    )


def _remove_failure(error: Optional[str], output: Dict[str, Any], fallback: str) -> ExecutionVerification:
    code = output.get("error_code")
    return ExecutionVerification(
        outcome="MODEL_CORRECTABLE_FAILURE" if code in _REMOVE_MODEL_CORRECTABLE_ERRORS else "TERMINAL_FAILURE",
        error=error or (str(code) if code else fallback),
    )


def _window_label(start_at: str, end_at: str) -> str:
    start = _parse_iso(start_at)
    end = _parse_iso(end_at)
    if start is None or end is None:
        return f"{start_at} 到 {end_at}"
    if (
        start.hour == 0
        and start.minute == 0
        and end.hour == 0
        and end.minute == 0
        and end.date() == start.date() + timedelta(days=1)
    ):
        return f"{start.month}月{start.day}日"
    if start.date() == end.date():
        return f"{start.month}月{start.day}日 {start:%H:%M}–{end:%H:%M}"
    return f"{start.month}月{start.day}日 {start:%H:%M} 到 {end.month}月{end.day}日 {end:%H:%M}"


def _time_range(start_at: str, end_at: str, display_tz: Optional[tzinfo] = None) -> str:
    start = _parse_iso(start_at)
    end = _parse_iso(end_at)
    if start is None or end is None:
        return f"{start_at}–{end_at}"
    if display_tz is not None:
        start = start.astimezone(display_tz)
        end = end.astimezone(display_tz)
    return f"{start:%H:%M}–{end:%H:%M}"


def _freebusy_summary(observation: Dict[str, Any]) -> str:
    window = _window_label(str(observation["start_at"]), str(observation["end_at"]))
    intervals = observation["busy_intervals"]
    window_start = _parse_iso(str(observation["start_at"]))
    display_tz = window_start.tzinfo if window_start is not None else None
    if observation["is_free"]:
        return f"{window}有空，没有检测到忙碌安排。"
    visible = [
        _time_range(str(item["start_at"]), str(item["end_at"]), display_tz)
        for item in intervals[:6]
        if isinstance(item, dict)
    ]
    suffix = "、".join(visible)
    if len(intervals) > len(visible):
        suffix += f"，另有{len(intervals) - len(visible)}段"
    return f"{window}不是完全空闲，有{len(intervals)}个忙碌时段：{suffix}。"


def _calendar_query_summary(observation: Dict[str, Any]) -> str:
    window = _window_label(str(observation["start_at"]), str(observation["end_at"]))
    events = observation["events"]
    window_start = _parse_iso(str(observation["start_at"]))
    display_tz = window_start.tzinfo if window_start is not None else None
    if not events:
        return f"{window}没有日程安排。"
    parts = []
    for event in events[:10]:
        if not isinstance(event, dict):
            continue
        title = str(event.get("title") or "无标题")
        if event.get("all_day") is True:
            when = "全天"
        else:
            when = _time_range(
                str(event.get("start_at") or ""),
                str(event.get("end_at") or ""),
                display_tz,
            )
        location = event.get("location")
        place = f"（{location}）" if isinstance(location, str) and location.strip() else ""
        parts.append(f"{when} {title}{place}")
    extra = len(events) - len(parts)
    suffix = "；".join(parts)
    if extra > 0 or observation.get("truncated") is True:
        suffix += f"；另有{max(extra, 1)}项未展开"
    return f"{window}共有{len(events)}项日程：{suffix}。"


class CalendarFreeBusyAdapter:
    capability_id = "calendar.freebusy"
    source_kind = "ios"
    execution_profile = _READ_PROFILE

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
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=error or "iPhone calendar free/busy executor reported failure",
            )

        expected = action["payload"]
        if output.get("verified") is not True:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="calendar free/busy result was not device verified",
            )
        if output.get("start_at") != expected.get("start_at") or output.get("end_at") != expected.get("end_at"):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="calendar free/busy result window did not match the dispatched Action",
            )
        intervals = output.get("busy_intervals")
        is_free = output.get("is_free")
        if not isinstance(intervals, list) or not isinstance(is_free, bool):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="calendar free/busy result shape is invalid",
            )
        for item in intervals:
            if not isinstance(item, dict):
                return ExecutionVerification(
                    outcome="TERMINAL_FAILURE",
                    error="calendar free/busy interval must be an object",
                )
            if not isinstance(item.get("start_at"), str) or not isinstance(item.get("end_at"), str):
                return ExecutionVerification(
                    outcome="TERMINAL_FAILURE",
                    error="calendar free/busy interval is missing boundaries",
                )
        if is_free != (len(intervals) == 0):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="calendar free/busy is_free disagrees with busy intervals",
            )

        # Privacy boundary: planner sees only time occupancy, never titles,
        # notes, attendees, organizers, URLs or calendar names.
        observation = {
            "start_at": output["start_at"],
            "end_at": output["end_at"],
            "is_free": is_free,
            "busy_intervals": intervals,
            "event_count": int(output.get("event_count", len(intervals))),
        }
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=_freebusy_summary(observation),
        )


class CalendarQueryAdapter:
    capability_id = "calendar.query"
    source_kind = "ios"
    execution_profile = _READ_PROFILE

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
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=error or "iPhone calendar query executor reported failure",
            )

        expected = action["payload"]
        if output.get("verified") is not True:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="calendar query result was not device verified",
            )
        if output.get("start_at") != expected.get("start_at") or output.get("end_at") != expected.get("end_at"):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="calendar query result window did not match the dispatched Action",
            )
        events = output.get("events")
        if not isinstance(events, list):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="calendar query result is missing events",
            )
        bounded_events = []
        for item in events:
            if not _valid_calendar_snapshot(item):
                return ExecutionVerification(
                    outcome="TERMINAL_FAILURE",
                    error="calendar event management snapshot is malformed",
                )
            bounded_events.append(_bounded_calendar_event(item))

        observation = {
            "start_at": output["start_at"],
            "end_at": output["end_at"],
            "events": bounded_events,
            "truncated": bool(output.get("truncated", False)),
        }
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=_calendar_query_summary(observation),
        )

class CalendarUpdateAdapter:
    capability_id = "calendar.update"
    source_kind = "ios"
    execution_profile = _UPDATE_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def predispatch_confirmation(self, action: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        args = normalize_calendar_update_arguments(action.get("payload", {}))
        if args is None:
            return None
        start = args["start"].astimezone(args["zone"])
        end = args["end"].astimezone(args["zone"])
        place = args["location"] or "无地点"
        prompt = (
            f"修改日程：{args['title']}\n"
            f"{start:%Y-%m-%d %H:%M} → {end:%Y-%m-%d %H:%M}\n"
            f"时区：{args['time_zone']}\n地点：{place}"
        )
        return {
            "prompt": prompt,
            "suggested_options": [{"id": "approve", "label": "确认修改"}, {"id": "cancel", "label": "取消"}],
            "accepts_text": False,
            "reason": "side_effect_approval",
            "execution_fields": dict(action["payload"]),
        }

    def verify_result(
        self, action: Dict[str, Any], *, success: bool, output: Dict[str, Any], error: Optional[str]
    ) -> ExecutionVerification:
        if not success:
            return _update_failure(error, output, "iPhone Calendar update failed")
        expected = normalize_calendar_update_arguments(action.get("payload", {}))
        if expected is None:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update Action arguments are invalid")
        if output.get("verified") is not True or output.get("requested_event_id") != expected["event_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update result lost target correlation")
        if not _valid_calendar_snapshot(output):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update readback snapshot is malformed")
        if output.get("event_id") != expected["event_id"] or output.get("calendar_id") != expected["expected_calendar_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update readback identity changed")
        if output.get("calendar_writable") is not True or output.get("update_eligible") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update readback target is outside the supported V1 scope")
        if any(output.get(key) is not False for key in ("all_day", "has_recurrence", "is_detached", "has_attendees", "has_organizer")):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update readback crossed an unsupported event boundary")
        if output.get("title") != expected["title"] or output.get("location") != expected["location"] or output.get("time_zone") != expected["time_zone"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update readback did not reach the approved state")
        actual_start = _parse_iso(output.get("start_at")) if isinstance(output.get("start_at"), str) else None
        actual_end = _parse_iso(output.get("end_at")) if isinstance(output.get("end_at"), str) else None
        if actual_start != expected["start"] or actual_end != expected["end"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update readback schedule does not match the approved state")
        applied = output.get("applied")
        if applied is not None and not isinstance(applied, bool):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar update applied marker is malformed")

        observation = _bounded_calendar_event(output)
        observation["requested_event_id"] = expected["event_id"]
        if applied is not None:
            observation["applied"] = applied
        when = expected["start"].astimezone(expected["zone"])
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=(
                f"已修改日程「{output['title']}」，{when:%Y年%m月%d日 %H:%M}，"
                f"保存在「{output['calendar_name']}」。"
            ),
        )


class CalendarRemoveAdapter:
    capability_id = "calendar.remove"
    source_kind = "ios"
    execution_profile = _REMOVE_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def predispatch_confirmation(self, action: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        args = normalize_calendar_remove_arguments(action.get("payload", {}))
        if args is None:
            return None
        return {
            "prompt": f"删除日程「{args['expected_title']}」？删除后小卷不会自动恢复。",
            "suggested_options": [{"id": "approve", "label": "确认删除"}, {"id": "cancel", "label": "取消"}],
            "accepts_text": False,
            "reason": "destructive_side_effect_approval",
            "execution_fields": dict(action["payload"]),
        }

    def verify_result(
        self, action: Dict[str, Any], *, success: bool, output: Dict[str, Any], error: Optional[str]
    ) -> ExecutionVerification:
        if not success:
            return _remove_failure(error, output, "iPhone Calendar remove failed")
        expected = normalize_calendar_remove_arguments(action.get("payload", {}))
        if expected is None:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar remove Action arguments are invalid")
        if output.get("verified") is not True or output.get("deleted") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar remove result was not verified absent")
        if output.get("requested_event_id") != expected["event_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar remove result lost target correlation")
        if output.get("calendar_id") != expected["expected_calendar_id"] or output.get("title") != expected["expected_title"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar remove result does not match the approved target")
        if output.get("verification") != "immediate_exact_id_absence":
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Calendar remove result lacks immediate native absence proof")
        observation = {
            "requested_event_id": expected["event_id"],
            "calendar_id": expected["expected_calendar_id"],
            "title": expected["expected_title"],
            "deleted": True,
            "verification": "immediate_exact_id_absence",
        }
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=f"已删除日程「{expected['expected_title']}」并核对。",
        )
