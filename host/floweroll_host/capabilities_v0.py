from __future__ import annotations

from typing import List

from .planner_contracts import CapabilitySpec


LOCATION_CURRENT = CapabilitySpec(
    name="location.current",
    description=(
        "获取用户当前这台 iPhone 的一次性当前位置（Core Location）。仅在用户明确问“我现在在哪”、"
        "“获取当前位置”、“看看我现在的位置”或当前任务明确依赖 current device location 时使用。"
        "返回真实坐标、水平精度、定位时间和系统的精确/大概位置状态；不推断地址或 POI。"
        "不要用于指定地点、位置历史、持续跟踪、后台定位、附近搜索、路线或逆地理编码。"
        "如果这次已验证的位置本身就回答了用户问题，可 on_verified=COMPLETE；否则用 REPLAN。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": False,
    },
)


REMINDER_CREATE = CapabilitySpec(
    name="reminder.create",
    description=(
        "Create one reminder on the user's iPhone. Use only when the title and "
        "exact due time are determined from the user goal/context."
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "title": {"type": "string"},
            "due_at": {
                "type": "string",
                "description": "ISO 8601 timestamp with timezone offset",
            },
        },
        "required": ["title", "due_at"],
        "additionalProperties": False,
    },
)

REMINDER_QUERY = CapabilitySpec(
    name="reminder.query",
    description=(
        "读取 iPhone 提醒事项。支持精确 reminder_id，或在一个精确列表/有界时间窗内按 incomplete/completed 查询；"
        "title_contains 只做确定性子串过滤，标题不是后续修改操作的 identity。"
        "如果后续要修改完成状态，先用这里返回的 fresh reminder_id + revision。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "reminder_id": {"type": "string", "maxLength": 512},
            "status": {"type": "string", "enum": ["incomplete", "completed"]},
            "start_at": {"type": "string", "description": "ISO 8601 timestamp with explicit offset"},
            "end_at": {"type": "string", "description": "ISO 8601 timestamp with explicit offset"},
            "calendar_id": {"type": "string", "maxLength": 512},
            "title_contains": {"type": "string", "maxLength": 160},
            "max_results": {"type": "integer", "minimum": 1, "maximum": 50},
        },
        "required": [],
        "additionalProperties": False,
    },
)

REMINDER_SET_COMPLETION = CapabilitySpec(
    name="reminder.set_completion",
    description=(
        "把一个已经通过 reminder.query 精确读取的非重复提醒标记为完成，或改回未完成。"
        "必须携带当前 reminder_id + expected_revision；completed 是目标状态，不是 toggle。"
        "不修改标题、备注、到期时间、闹铃、列表或重复规则。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "reminder_id": {"type": "string", "maxLength": 512},
            "expected_revision": {"type": "string", "maxLength": 64},
            "completed": {"type": "boolean"},
        },
        "required": ["reminder_id", "expected_revision", "completed"],
        "additionalProperties": False,
    },
)

REMINDER_UPDATE = CapabilitySpec(
    name="reminder.update",
    description=(
        "修改一个刚刚通过 reminder.query 精确读取到的非重复提醒事项。"
        "必须携带 fresh reminder_id + expected_revision + expected_list_id，并提供标题、备注、优先级、到期时间和到期提醒的完整最终状态。"
        "V1 不移动列表、不修改重复规则，也绝不修改完成状态；完成/未完成只能使用 reminder.set_completion。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "reminder_id": {"type": "string", "maxLength": 512},
            "expected_revision": {"type": "string", "maxLength": 64},
            "expected_list_id": {"type": "string", "maxLength": 512},
            "title": {"type": "string", "maxLength": 160},
            "notes": {"type": "string", "maxLength": 4000},
            "priority": {"type": "integer", "minimum": 0, "maximum": 9},
            "due_mode": {"type": "string", "enum": ["none", "timed"]},
            "due_at": {"type": "string", "maxLength": 40},
            "due_time_zone": {"type": "string", "maxLength": 64},
            "alarm_mode": {"type": "string", "enum": ["none", "at_due"]},
        },
        "required": [
            "reminder_id", "expected_revision", "expected_list_id", "title",
            "notes", "priority", "due_mode", "due_at", "due_time_zone", "alarm_mode",
        ],
        "additionalProperties": False,
    },
)


REMINDER_REMOVE = CapabilitySpec(
    name="reminder.remove",
    description=(
        "删除一个刚刚通过 reminder.query 精确读取到的现有提醒事项。"
        "必须携带 fresh reminder_id + expected_revision + expected_list_id + expected_title，"
        "用于把破坏性确认绑定到用户刚看到的同一个原生目标。"
        "V1 只删除当前可写列表中的非重复提醒；不做标题模糊匹配、不删除重复系列，也不会在结果不确定时自动重试。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "reminder_id": {"type": "string", "maxLength": 512},
            "expected_revision": {"type": "string", "maxLength": 64},
            "expected_list_id": {"type": "string", "maxLength": 512},
            "expected_title": {"type": "string", "minLength": 1, "maxLength": 160},
        },
        "required": ["reminder_id", "expected_revision", "expected_list_id", "expected_title"],
        "additionalProperties": False,
    },
)


CONTACTS_QUERY = CapabilitySpec(
    name="contacts.query",
    description=(
        "读取这台 iPhone 当前允许小卷访问的联系人。V1 只支持两种有界模式："
        "使用已知 contact_id 精确读取，或使用 name_query 按姓名查找最多 1–10 个候选。"
        "姓名搜索只返回姓名、组织和脱敏联系方式提示；只有精确 contact_id 读取才返回有限的完整电话/邮箱。"
        "Limited 权限下的空结果只表示当前授权范围内没有可访问匹配，不能声称通讯录中不存在。"
        "不要用于全量通讯录导出、模糊自动选人、邮箱/电话反查或联系人写入。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "contact_id": {
                "type": "string",
                "maxLength": 512,
                "description": "Fresh device-local contact identifier from a prior trusted result or product selection.",
            },
            "name_query": {
                "type": "string",
                "minLength": 2,
                "maxLength": 80,
                "description": "Bounded exact Contacts-name predicate input; not fuzzy semantic matching.",
            },
            "max_results": {"type": "integer", "minimum": 1, "maximum": 10},
        },
        "required": [],
        "additionalProperties": False,
    },
    post_verify_mode="REPLAN_REQUIRED",
)


_CONTACT_METHOD_LABELS = ["mobile", "home", "work", "other"]
_CONTACT_PHONE_SCHEMA = {
    "type": "array",
    "maxItems": 3,
    "items": {
        "type": "object",
        "properties": {
            "label": {"type": "string", "enum": _CONTACT_METHOD_LABELS},
            "value": {"type": "string", "maxLength": 64},
        },
        "required": ["label", "value"],
        "additionalProperties": False,
    },
}
_CONTACT_EMAIL_SCHEMA = {
    "type": "array",
    "maxItems": 3,
    "items": {
        "type": "object",
        "properties": {
            "label": {"type": "string", "enum": ["home", "work", "other"]},
            "value": {"type": "string", "maxLength": 254},
        },
        "required": ["label", "value"],
        "additionalProperties": False,
    },
}
_CONTACT_DESIRED_PROPERTIES = {
    "given_name": {"type": "string", "maxLength": 80},
    "family_name": {"type": "string", "maxLength": 80},
    "organization_name": {"type": "string", "maxLength": 160},
    "phone_numbers": _CONTACT_PHONE_SCHEMA,
    "email_addresses": _CONTACT_EMAIL_SCHEMA,
}


CONTACTS_CREATE = CapabilitySpec(
    name="contacts.create",
    description=(
        "在 iPhone 通讯录中创建一个普通个人联系人。必须由用户确认后执行；V1 只写姓名、组织、最多 3 个电话和最多 3 个邮箱，"
        "使用系统默认容器，不写备注/头像/地址，不自动合并重复联系人。Limited 权限下也只按系统当前授权范围执行。"
    ),
    arguments_schema={
        "type": "object",
        "properties": dict(_CONTACT_DESIRED_PROPERTIES),
        "required": ["given_name", "family_name", "organization_name", "phone_numbers", "email_addresses"],
        "additionalProperties": False,
    },
)


CONTACTS_UPDATE = CapabilitySpec(
    name="contacts.update",
    description=(
        "修改一个刚刚通过 contacts.query 精确读取且明确可修改的普通个人联系人。必须携带 fresh contact_id + expected_revision，"
        "并给出姓名、组织、电话和邮箱的完整最终状态。V1 不修改 linked/multi-backing unified 联系人，不按姓名/电话猜目标，不删除或合并联系人。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "contact_id": {"type": "string", "maxLength": 512},
            "expected_revision": {"type": "string", "maxLength": 64},
            **_CONTACT_DESIRED_PROPERTIES,
        },
        "required": [
            "contact_id", "expected_revision", "given_name", "family_name",
            "organization_name", "phone_numbers", "email_addresses",
        ],
        "additionalProperties": False,
    },
)


_ALARM_WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
_ALARM_SCHEDULE_SCHEMA = {
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": ["fixed", "weekly"]},
        "fire_at": {"type": "string", "description": "Required for fixed; ISO 8601 with explicit timezone offset"},
        "hour": {"type": "integer", "minimum": 0, "maximum": 23},
        "minute": {"type": "integer", "minimum": 0, "maximum": 59},
        "weekdays": {"type": "array", "items": {"type": "string", "enum": _ALARM_WEEKDAYS}},
    },
    "required": ["kind"],
    "additionalProperties": False,
}

ALARM_QUERY = CapabilitySpec(
    name="alarm.query",
    description=(
        "列出 iPhone 上属于小卷的 Apple AlarmKit 闹钟，包括 native state、schedule、title 和 supported sound。 "
        "Use this before update/pause/resume/cancel when the exact alarm_id or current state is not already known."
    ),
    arguments_schema={
        "type": "object",
        "properties": {"max_results": {"type": "integer", "minimum": 1, "maximum": 100}},
        "required": [],
        "additionalProperties": False,
    },
)

ALARM_CREATE = CapabilitySpec(
    name="alarm.create",
    description=(
        "Create one Floweroll-owned Apple AlarmKit alarm with a stable native ID and read-back verification. "
        "Use schedule.kind=fixed with fire_at for a one-time alarm, or kind=weekly with hour/minute/weekdays for recurrence. "
        "Only supported sound values may be used; currently sound=default."
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "title": {"type": "string", "maxLength": 160},
            "schedule": _ALARM_SCHEDULE_SCHEMA,
            "sound": {"type": "string", "enum": ["default"]},
        },
        "required": ["title", "schedule", "sound"],
        "additionalProperties": False,
    },
)

ALARM_UPDATE = CapabilitySpec(
    name="alarm.update",
    description=(
        "修改一个小卷自有 AlarmKit 闹钟并保留相同 alarm_id。Update in place while preserving the same alarm_id. "
        "Provide the complete desired title/schedule/sound after reading current state. The iPhone reschedules the same native UUID and verifies readback; it never cancels and recreates under a random ID."
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "alarm_id": {"type": "string"},
            "title": {"type": "string", "maxLength": 160},
            "schedule": _ALARM_SCHEDULE_SCHEMA,
            "sound": {"type": "string", "enum": ["default"]},
        },
        "required": ["alarm_id", "title", "schedule", "sound"],
        "additionalProperties": False,
    },
)

ALARM_PAUSE = CapabilitySpec(
    name="alarm.pause",
    description=(
        "暂停一个小卷自有 AlarmKit 闹钟。Pause only when AlarmKit reports a native countdown state that can actually be paused. "
        "This invokes AlarmManager.pause(id:) and verifies native state; it never writes a fake local paused flag."
    ),
    arguments_schema={
        "type": "object",
        "properties": {"alarm_id": {"type": "string"}},
        "required": ["alarm_id"],
        "additionalProperties": False,
    },
)

ALARM_RESUME = CapabilitySpec(
    name="alarm.resume",
    description=(
        "恢复一个小卷自有 AlarmKit 闹钟。Resume only when AlarmKit reports it paused. "
        "This invokes AlarmManager.resume(id:) and verifies the native state."
    ),
    arguments_schema={
        "type": "object",
        "properties": {"alarm_id": {"type": "string"}},
        "required": ["alarm_id"],
        "additionalProperties": False,
    },
)

ALARM_CANCEL = CapabilitySpec(
    name="alarm.cancel",
    description="Cancel one Floweroll-owned AlarmKit alarm by exact alarm_id and verify native absence on the iPhone.",
    arguments_schema={
        "type": "object",
        "properties": {"alarm_id": {"type": "string"}},
        "required": ["alarm_id"],
        "additionalProperties": False,
    },
)



CALENDAR_CREATE = CapabilitySpec(
    name="calendar.create",
    description=(
        "在 iPhone 添加一个有明确起止时间的日历日程（面试/会议/学习安排），并读回核对。"
        "从用户输入/材料确定标题、起止时间和 IANA 时区，仅缺必要信息时询问。"
        "Runtime 会在写入前展示具体日程并确认一次，不要提前另问同样的许可。"
        "省略 calendar_name 使用系统默认日历；指定时必须是用户选定的准确名称。"
        "不支持全天、重复、参会邀请或修改已有事件。有交付计划时传对应 item_id，验证后自动关联成果；"
        "简单创建任务可 on_verified=COMPLETE，仍有其他工作用 REPLAN。"
    ),
    arguments_schema={
        "type": "object", "properties": {
            "title": {"type": "string", "maxLength": 160},
            "start_at": {"type": "string", "description": "ISO 8601 timestamp with the time_zone's explicit offset"},
            "end_at": {"type": "string", "description": "After start_at, at most 7 days later; explicit timezone offset"},
            "time_zone": {"type": "string", "description": "IANA timezone, e.g. Asia/Shanghai"},
            "location": {"type": "string", "maxLength": 500},
            "calendar_name": {"type": "string", "maxLength": 200},
            "item_id": {"type": "string", "maxLength": 64},
        },
        "required": ["title", "start_at", "end_at", "time_zone"], "additionalProperties": False,
    },
)

CALENDAR_FREEBUSY = CapabilitySpec(
    name="calendar.freebusy",
    description=(
        "Check whether the user's iPhone calendar is free within an exact time window. "
        "Returns only busy time intervals; use this instead of calendar.query when event titles are unnecessary. "
        "If this result alone answers the user's remaining goal, set on_verified=COMPLETE; "
        "use REPLAN only when the result must drive another action."
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "start_at": {"type": "string", "description": "ISO 8601 start timestamp with timezone offset"},
            "end_at": {"type": "string", "description": "ISO 8601 end timestamp with timezone offset"},
        },
        "required": ["start_at", "end_at"],
        "additionalProperties": False,
    },
)

CALENDAR_QUERY = CapabilitySpec(
    name="calendar.query",
    description=(
        "Read a bounded summary of calendar events in an exact time window when the user explicitly needs to know their schedule. "
        "If this result alone answers the user's remaining goal, set on_verified=COMPLETE; "
        "use REPLAN only when the result must drive another action."
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "start_at": {"type": "string", "description": "ISO 8601 start timestamp with timezone offset"},
            "end_at": {"type": "string", "description": "ISO 8601 end timestamp with timezone offset"},
            "max_results": {"type": "number", "minimum": 1, "maximum": 100},
        },
        "required": ["start_at", "end_at"],
        "additionalProperties": False,
    },
)


CALENDAR_UPDATE = CapabilitySpec(
    name="calendar.update",
    description=(
        "修改一个刚刚通过 calendar.query 精确读取到的现有日程。"
        "必须携带 fresh event_id + expected_revision + expected_calendar_id，并提供标题、起止时间、时区和地点的完整最终状态。"
        "V1 只支持同一可写日历中的有明确时间、非重复、无参会人/组织者的普通事件；不移动日历、不修改全天/重复/邀请，也不删除事件。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "event_id": {"type": "string", "maxLength": 512},
            "expected_revision": {"type": "string", "maxLength": 64},
            "expected_calendar_id": {"type": "string", "maxLength": 512},
            "title": {"type": "string", "maxLength": 160},
            "start_at": {"type": "string", "maxLength": 40},
            "end_at": {"type": "string", "maxLength": 40},
            "time_zone": {"type": "string", "maxLength": 64},
            "location": {"type": "string", "maxLength": 500},
        },
        "required": [
            "event_id", "expected_revision", "expected_calendar_id", "title",
            "start_at", "end_at", "time_zone", "location",
        ],
        "additionalProperties": False,
    },
)


CALENDAR_REMOVE = CapabilitySpec(
    name="calendar.remove",
    description=(
        "删除一个刚刚通过 calendar.query 精确读取到的现有日程。"
        "必须携带 fresh event_id + expected_revision + expected_calendar_id + expected_title，"
        "用于把破坏性确认绑定到用户刚看到的同一个原生目标。"
        "V1 只删除同一可写日历中的非重复、非例外、无参会人/组织者事件；不做标题匹配或系列删除，结果不确定时不会自动重试。"
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "event_id": {"type": "string", "maxLength": 512},
            "expected_revision": {"type": "string", "maxLength": 64},
            "expected_calendar_id": {"type": "string", "maxLength": 512},
            "expected_title": {"type": "string", "minLength": 1, "maxLength": 160},
        },
        "required": ["event_id", "expected_revision", "expected_calendar_id", "expected_title"],
        "additionalProperties": False,
    },
)


NOTIFY_USER = CapabilitySpec(
    name="notify.user",
    description=(
        "Send one explicit user-facing local notification on the user's iPhone. "
        "Use only when the task intentionally chooses an interruptive notification; "
        "IMPORTANT or USER_REQUIRED presentation state alone never invokes this capability."
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "title": {"type": "string", "minLength": 1, "maxLength": 120},
            "body": {"type": "string", "minLength": 1, "maxLength": 600},
            "attention_level": {
                "type": "string",
                "enum": ["IMPORTANT", "USER_REQUIRED"],
            },
        },
        "required": ["title", "body", "attention_level"],
        "additionalProperties": False,
    },
)


WEATHER_QUERY = CapabilitySpec(
    name="weather.query",
    description=(
        "Query forecast data needed to make a later decision. This action only "
        "observes weather; it does not create reminders or other side effects."
    ),
    arguments_schema={
        "type": "object",
        "properties": {
            "location": {"type": "string"},
            "date": {
                "type": "string",
                "description": "Calendar date in YYYY-MM-DD format",
            },
        },
        "required": ["location", "date"],
        "additionalProperties": False,
    },
    post_verify_mode="REPLAN_REQUIRED",
)

JOURNAL_APPEND = CapabilitySpec(
    name="journal.append",
    description="Append one user-provided note to 小卷's journal and return a verifiable record id.",
    arguments_schema={
        "type": "object",
        "properties": {
            "content": {"type": "string"},
        },
        "required": ["content"],
        "additionalProperties": False,
    },
)


def planner_v0_capabilities() -> List[CapabilitySpec]:
    return [REMINDER_CREATE, WEATHER_QUERY, JOURNAL_APPEND]


def product_native_capabilities() -> List[CapabilitySpec]:
    """Current iPhone-native semantic capabilities exposed to the product Planner."""
    return [
        LOCATION_CURRENT,
        REMINDER_CREATE,
        REMINDER_QUERY,
        REMINDER_SET_COMPLETION,
        CONTACTS_QUERY,
        CONTACTS_CREATE,
        CONTACTS_UPDATE,
        REMINDER_UPDATE,
        REMINDER_REMOVE,
        ALARM_QUERY,
        ALARM_CREATE,
        ALARM_UPDATE,
        ALARM_PAUSE,
        ALARM_RESUME,
        ALARM_CANCEL,
        CALENDAR_CREATE,
        CALENDAR_FREEBUSY,
        CALENDAR_QUERY,
        CALENDAR_UPDATE,
        CALENDAR_REMOVE,
        NOTIFY_USER,
    ]
