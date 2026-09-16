from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .execution_contracts import ExecutionProfile, ExecutionVerification


def calendar_create_arguments_valid(args: Dict[str, Any]) -> bool:
    required = {"title", "start_at", "end_at", "time_zone"}
    limits = {"title": 160, "start_at": 40, "end_at": 40, "time_zone": 64,
              "location": 500, "calendar_name": 200, "item_id": 64}
    if not required.issubset(args) or set(args) - limits.keys():
        return False
    for key, value in args.items():
        if not isinstance(value, str) or not value.strip() or value != value.strip() or len(value) > limits[key]:
            return False
    try:
        zone = ZoneInfo(args["time_zone"])
        start, end = (datetime.fromisoformat(args[key].replace("Z", "+00:00")) for key in ("start_at", "end_at"))
        for date in (start, end):
            if date.tzinfo is None or date.utcoffset() != date.astimezone(zone).utcoffset():
                return False
        return 0 < (end - start).total_seconds() <= 7 * 86400
    except (ValueError, OverflowError, ZoneInfoNotFoundError):
        return False


class CalendarCreateAdapter:
    """One timed, non-recurring event; confirmation binds the immutable dispatch."""

    capability_id = "calendar.create"
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=20,
        idempotency_mode="DEVICE_JOURNAL_AND_MARKER",
        retry_mode="NO_BLIND_RETRY",
        verification_mode="DEVICE_READ_BACK",
        reconciliation_mode="DEVICE_MARKER_READ_BACK",
        max_attempts=1,
    )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {"capability": self.capability_id, "arguments": dict(action["payload"]),
                "idempotency_key": action["idempotency_key"]}

    def predispatch_confirmation(self, action: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        args = action["payload"]
        if not calendar_create_arguments_valid(args):
            # Device preflight rejects invalid arguments without touching EventKit.
            return None
        start, end = (datetime.fromisoformat(args[key].replace("Z", "+00:00")) for key in ("start_at", "end_at"))
        calendar = args.get("calendar_name", "系统默认日历")
        place = f"\n地点：{args['location']}" if args.get("location") else ""
        zone_label = "北京时间" if args["time_zone"] == "Asia/Shanghai" else args["time_zone"]
        return {
            "prompt": f"添加日程：{args['title']}\n{start:%Y-%m-%d %H:%M} → {end:%Y-%m-%d %H:%M}\n时区：{zone_label}\n日历：{calendar}{place}",
            "suggested_options": [{"id": "approve", "label": "确认添加"}, {"id": "cancel", "label": "取消"}],
            "accepts_text": False,
            "reason": "side_effect_approval",
            "execution_fields": dict(args),
        }

    def verify_result(self, action: Dict[str, Any], *, success: bool,
                      output: Dict[str, Any], error: Optional[str]) -> ExecutionVerification:
        if not success:
            return ExecutionVerification(
                outcome="MODEL_CORRECTABLE_FAILURE" if error == "calendar_create_invalid_arguments" else "TERMINAL_FAILURE",
                error=error or "日程创建未完成。",
            )
        args = action["payload"]
        valid = calendar_create_arguments_valid(args) and output.get("verified") is True and output.get("all_day") is False
        valid = valid and output.get("idempotency_marker") == action["idempotency_key"]
        for field in ("event_id", "calendar_id", "calendar_name"):
            valid = valid and isinstance(output.get(field), str) and bool(output[field].strip())
        for field in ("title", "time_zone", "location", "item_id"):
            valid = valid and output.get(field) == args.get(field)
        if args.get("calendar_name"):
            valid = valid and output.get("calendar_name") == args["calendar_name"]
        try:
            for field in ("start_at", "end_at"):
                actual = datetime.fromisoformat(output[field].replace("Z", "+00:00"))
                expected = datetime.fromisoformat(args[field].replace("Z", "+00:00"))
                valid = valid and actual.tzinfo is not None and abs((actual - expected).total_seconds()) < 1
        except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
            valid = False
        if not valid:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="日程读回结果与本次创建内容不一致，不能确认完成。")
        fields = ("event_id", "calendar_id", "calendar_name", "title", "start_at", "end_at", "time_zone",
                  "location", "item_id", "all_day", "idempotency_marker")
        observation = {key: output[key] for key in fields if key in output}
        when = datetime.fromisoformat(args["start_at"].replace("Z", "+00:00"))
        return ExecutionVerification(
            outcome="SUCCESS", observation=observation,
            direct_completion_summary=f"已添加日程「{args['title']}」，{when:%Y年%m月%d日 %H:%M}，保存在「{output['calendar_name']}」。",
        )
