from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from typing import Any, Dict, Optional, Tuple


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def stable_id(prefix: str, *parts: str) -> str:
    digest = hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()[:32]
    return f"{prefix}_{digest}"


def capability_label(capability: str) -> str:
    labels = {
        "device.probe": "验证设备执行链路",
        "location.current": "获取当前位置",
        "weather.query": "查询天气",
        "reminder.create": "创建提醒",
        "reminder.query": "查看提醒事项",
        "reminder.set_completion": "更新提醒完成状态",
        "contacts.query": "查看联系人",
        "contacts.create": "创建联系人",
        "contacts.update": "修改联系人",
        "reminder.update": "修改提醒事项",
        "reminder.remove": "删除提醒事项",
        "alarm.query": "查看闹钟",
        "alarm.create": "设置闹钟",
        "alarm.update": "修改闹钟",
        "alarm.pause": "暂停闹钟",
        "alarm.resume": "恢复闹钟",
        "alarm.cancel": "取消闹钟",
        "calendar.freebusy": "查看日历空闲情况",
        "calendar.query": "查看日程",
        "calendar.create": "添加日程",
        "calendar.update": "修改日程",
        "calendar.remove": "删除日程",
        "notify.user": "发送通知",
        "geocode.resolve": "确认地点位置",
        "geocode.reverse": "确认当前位置",
        "places.search": "搜索地点",
        "places.search_nearby": "搜索附近地点",
        "places.detail": "查看地点详情",
        "routes.walk": "规划步行路线",
        "routes.drive": "规划驾车路线",
        "routes.transit": "规划公共交通路线",
        "routes.distance": "计算路线距离",
        "travel.hotel.search": "查询飞猪酒店",
        "file.list": "查看工作区文件",
        "capability.search": "查找可用能力",
        "work.execute": "并行处理任务事项",
        "deliverables.status": "核对任务进度",
        "deliverables.verify": "核对完成结果",
        "file.read": "读取文件",
        "artifact.write_text": "保存结果",
        "document.parse": "解析文档",
        "data.analyze": "分析数据",
        "calculate.deterministic": "确定性计算",
        "web.fetch": "读取网络资料",
        "web.search": "搜索公开资料",
        "image.ocr": "识别图片文字",
        "pdf.extract_text": "提取 PDF 文本",
        "docs.library.resolve": "定位技术文档库",
        "docs.query": "查询技术文档",
        "feishu.calendar.agenda": "查看飞书日程",
        "feishu.contact.search": "搜索飞书联系人",
        "feishu.message.search": "搜索飞书消息",
        "feishu.docs.search": "搜索飞书文档",
        "feishu.tasks.list": "查看飞书任务",
        "feishu.mail.search": "搜索飞书邮件",
        "dingtalk.calendar.agenda": "查看钉钉日程",
        "dingtalk.contact.search": "搜索钉钉联系人",
        "dingtalk.message.search": "搜索钉钉消息",
        "dingtalk.docs.search": "搜索钉钉文档",
        "dingtalk.tasks.list": "查看钉钉待办",
        "dingtalk.mail.search": "搜索钉钉邮件",
        "materials.inspect": "读取任务附件",
        "image.inspect": "查看图片信息",
        "image.transform": "处理图片",
        "document.docx.inspect": "读取 Word 文档",
        "document.docx.generate": "生成 Word 文档",
        "document.scan_pdf": "制作扫描 PDF",
        "deliverables.plan": "安排交付清单",
        "deliverables.publish": "整理准备资料",
        "journal.append": "记录内容",
    }
    # Public presentation must never fall back to an implementation identifier
    # such as `calendar.freebusy` or a provider's raw tool name.
    return labels.get(capability, "处理下一步")


def _default_public_summary(kind: str, presentation_state: str = "") -> Optional[str]:
    kind = kind.upper()
    state = presentation_state.upper()
    if kind == "RESULT":
        return "任务已完成，具体结果和产物可以在本页查看。"
    if kind == "FAILURE_NOTE":
        return "这一步没有按预期完成，请查看当前任务状态。"
    if kind == "TOOL_ACTIVITY" and state in {"FAILED", "INFO"}:
        return "这一步需要调整，小卷会按当前任务继续处理。"
    return None


def _default_public_title(kind: str, presentation_state: str = "") -> str:
    kind = kind.upper()
    state = presentation_state.upper()
    if kind == "RESULT":
        return "任务已完成"
    if kind == "FAILURE_NOTE":
        return "任务需要查看"
    if kind == "AGENT_ACTIVITY":
        return "小卷正在处理"
    if kind == "USER_INPUT":
        return "你补充了任务"
    if kind == "TOOL_ACTIVITY":
        if state == "COMPLETE":
            return "这一步已完成"
        if state == "FAILED":
            return "这一步遇到问题"
        return "正在处理下一步"
    return "任务进展"


_PUBLIC_FILE_SUFFIXES = {"html", "pdf", "docx", "xlsx", "csv", "txt", "md", "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif"}
_PUBLIC_TIMELINE_PAYLOAD_KEYS_BY_KIND: Dict[str, Tuple[str, ...]] = {
    # The normal iPhone Timeline currently needs no raw execution metadata.
    # Add a field here only when it is a deliberate product-level display
    # contract. Trace/Action/Attempt storage remains untouched.
    "USER_INPUT": ("attachment_ids",),
    "PUBLIC_WORKLOG": (),
    "AGENT_ACTIVITY": (),
    "TOOL_ACTIVITY": (),
    "RESULT": (),
    "FAILURE_NOTE": (),
}


def _looks_like_internal_public_text(text: str) -> bool:
    """Reject implementation-shaped text rather than renaming individual fields."""

    if re.search(r'(?i)\bObservation\s+\d+\b', text):
        return True
    if re.search(r'\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b', text):
        return True
    if re.search(r'"[A-Za-z_][A-Za-z0-9_]*"\s*:', text):
        return True
    if re.search(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b', text, re.I):
        return True
    if re.search(r'https?://', text, re.I):
        return True
    if re.search(r'/(?:Users|private|tmp|var)/', text):
        return True
    for token in re.findall(r'(?<![\w/])([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)', text):
        suffix = token.rsplit('.', 1)[-1]
        if suffix not in _PUBLIC_FILE_SUFFIXES:
            return True
    return False


def project_public_text(
    value: Optional[str],
    *,
    kind: str = "",
    presentation_state: str = "",
    fallback: Optional[str] = None,
) -> Optional[str]:
    """Project one bounded product sentence without exposing Runtime vocabulary."""

    if value is None:
        return fallback
    text = str(value).strip()
    if not text:
        return text
    if kind.upper() == "USER_INPUT":
        return text[:2000]
    if _looks_like_internal_public_text(text):
        return fallback if fallback is not None else _default_public_summary(kind, presentation_state)
    return text[:1200]


def project_public_payload(kind: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    allowed = _PUBLIC_TIMELINE_PAYLOAD_KEYS_BY_KIND.get(kind.upper(), ())
    return {key: payload[key] for key in allowed if key in payload}


def capability_activity_title(capability: str, stage: str) -> str:
    """Return product copy for one semantic capability lifecycle stage.

    Runtime/Trace keeps exact capability ids. Public Timeline/SSE intentionally
    uses user-facing language and a safe generic fallback, so adding a new tool
    can never leak its internal identifier into the foreground by default.
    """

    copies = {
        "device.probe": {
            "preparing": "正在准备检查设备连接",
            "active": "正在检查设备连接",
            "complete": "设备连接已确认",
            "failed": "设备检查遇到问题",
            "cancelled": "设备检查已取消",
            "replanning": "设备检查需要换个方案",
        },
        "weather.query": {
            "preparing": "正在准备查看天气",
            "active": "正在查看天气",
            "complete": "天气信息已获取",
            "failed": "查看天气遇到问题",
            "cancelled": "天气查询已取消",
            "replanning": "天气查询需要换个方案",
        },
        "reminder.create": {
            "preparing": "正在准备创建提醒",
            "active": "正在创建提醒",
            "complete": "提醒已创建",
            "failed": "创建提醒遇到问题",
            "cancelled": "创建提醒已取消",
            "replanning": "提醒创建需要换个方案",
        },
        "reminder.query": {
            "preparing": "正在准备查看提醒事项",
            "active": "正在查看提醒事项",
            "complete": "提醒事项已读取",
            "failed": "查看提醒事项遇到问题",
            "cancelled": "提醒事项查询已停止",
            "replanning": "提醒事项查询需要换个方案",
        },
        "reminder.set_completion": {
            "preparing": "正在准备更新提醒状态",
            "active": "正在更新提醒状态",
            "complete": "提醒状态已更新",
            "failed": "更新提醒状态遇到问题",
            "cancelled": "提醒状态更新已停止",
            "replanning": "提醒状态更新需要重新确认",
        },
        "contacts.query": {
            "preparing": "正在准备查找联系人",
            "active": "正在查找联系人",
            "complete": "联系人信息已核对",
            "failed": "查找联系人遇到问题",
            "cancelled": "联系人查询已停止",
            "replanning": "联系人信息需要进一步确认",
        },
        "contacts.create": {
            "preparing": "正在准备创建联系人",
            "active": "正在保存联系人",
            "complete": "联系人已创建",
            "failed": "创建联系人遇到问题",
            "cancelled": "联系人创建已停止",
            "replanning": "创建联系人需要重新确认",
        },
        "contacts.update": {
            "preparing": "正在准备修改联系人",
            "active": "正在修改联系人",
            "complete": "联系人已修改",
            "failed": "修改联系人遇到问题",
            "cancelled": "联系人修改已停止",
            "replanning": "修改联系人需要重新确认",
        },
        "reminder.update": {
            "preparing": "正在准备修改提醒事项",
            "active": "正在修改并核对提醒事项",
            "complete": "提醒事项已修改并核对",
            "failed": "提醒事项尚未确认修改",
            "cancelled": "修改提醒事项已取消",
            "replanning": "提醒事项修改需要重新确认",
        },
        "reminder.remove": {
            "preparing": "正在准备删除提醒事项",
            "active": "正在删除并核对提醒事项",
            "complete": "提醒事项已删除并核对",
            "failed": "提醒事项尚未确认删除",
            "cancelled": "删除提醒事项已取消",
            "replanning": "提醒事项删除需要重新确认",
        },
        "alarm.query": {
            "preparing": "正在准备查看闹钟",
            "active": "正在查看小卷闹钟",
            "complete": "闹钟状态已读取",
            "failed": "读取闹钟遇到问题",
            "cancelled": "闹钟查询已停止",
            "replanning": "闹钟查询需要换个方案",
        },
        "alarm.create": {
            "preparing": "正在准备设置闹钟",
            "active": "正在设置闹钟",
            "complete": "闹钟已设置",
            "failed": "设置闹钟遇到问题",
            "cancelled": "设置闹钟已取消",
            "replanning": "闹钟设置需要换个方案",
        },
        "alarm.update": {
            "preparing": "正在准备修改闹钟",
            "active": "正在修改闹钟",
            "complete": "闹钟已修改",
            "failed": "修改闹钟遇到问题",
            "cancelled": "闹钟修改已停止",
            "replanning": "闹钟修改需要换个方案",
        },
        "alarm.pause": {
            "preparing": "正在准备暂停闹钟",
            "active": "正在暂停闹钟",
            "complete": "闹钟已暂停",
            "failed": "暂停闹钟遇到问题",
            "cancelled": "暂停操作已停止",
            "replanning": "暂停闹钟需要换个方案",
        },
        "alarm.resume": {
            "preparing": "正在准备恢复闹钟",
            "active": "正在恢复闹钟",
            "complete": "闹钟已恢复",
            "failed": "恢复闹钟遇到问题",
            "cancelled": "恢复操作已停止",
            "replanning": "恢复闹钟需要换个方案",
        },
        "alarm.cancel": {
            "preparing": "正在准备取消闹钟",
            "active": "正在取消闹钟",
            "complete": "闹钟已取消",
            "failed": "取消闹钟遇到问题",
            "cancelled": "取消操作已停止",
            "replanning": "取消闹钟需要换个方案",
        },
        "calendar.freebusy": {
            "preparing": "正在准备查看你的日历",
            "active": "正在查看你的日历",
            "complete": "日历空闲情况已确认",
            "failed": "查看日历遇到问题",
            "cancelled": "日历检查已取消",
            "replanning": "日历检查需要换个方案",
        },
        "calendar.create": {
            "preparing": "正在准备添加日程",
            "active": "正在添加并核对日程",
            "complete": "日程已添加并核对",
            "failed": "日程尚未确认添加",
            "cancelled": "添加日程已取消",
            "replanning": "正在调整日程安排",
        },
        "calendar.query": {
            "preparing": "正在准备查看你的日程",
            "active": "正在查看你的日程",
            "complete": "日程已查看",
            "failed": "查看日程遇到问题",
            "cancelled": "日程查询已取消",
            "replanning": "日程查询需要换个方案",
        },
        "calendar.update": {
            "preparing": "正在准备修改日程",
            "active": "正在修改并核对日程",
            "complete": "日程已修改并核对",
            "failed": "日程尚未确认修改",
            "cancelled": "修改日程已取消",
            "replanning": "日程修改需要重新确认",
        },
        "calendar.remove": {
            "preparing": "正在准备删除日程",
            "active": "正在删除并核对日程",
            "complete": "日程已删除并核对",
            "failed": "日程尚未确认删除",
            "cancelled": "删除日程已取消",
            "replanning": "日程删除需要重新确认",
        },
        "location.current": {"active": "正在获取当前位置", "complete": "当前位置已获取"},
        "geocode.resolve": {"active": "正在确认地点位置", "complete": "地点位置已确认"},
        "geocode.reverse": {"active": "正在确认当前位置", "complete": "当前位置已确认"},
        "places.search": {"active": "正在搜索地点", "complete": "地点搜索已完成"},
        "places.search_nearby": {"active": "正在搜索附近地点", "complete": "附近地点已找到"},
        "places.detail": {"active": "正在查看地点详情", "complete": "地点详情已获取"},
        "routes.walk": {"active": "正在规划步行路线", "complete": "步行路线已规划"},
        "routes.drive": {"active": "正在规划驾车路线", "complete": "驾车路线已规划"},
        "routes.transit": {"active": "正在规划公共交通路线", "complete": "公共交通路线已规划"},
        "routes.distance": {"active": "正在计算路线距离", "complete": "路线距离已计算"},
        "travel.hotel.search": {
            "preparing": "正在准备查询酒店",
            "active": "正在查询飞猪酒店和报价",
            "complete": "飞猪酒店候选已查到",
            "failed": "酒店查询遇到问题",
            "cancelled": "酒店查询已停止",
            "replanning": "正在核对酒店候选",
        },
        "notify.user": {"active": "正在发送通知", "complete": "通知已提交给系统"},
        "file.list": {"active": "正在查看工作区文件", "complete": "工作区文件已查看"},
        "capability.search": {"active": "正在选择合适的处理方式", "complete": "处理方式已找到"},
        "deliverables.status": {"active": "正在核对还有哪些事没做完", "complete": "任务进度已核对"},
        "deliverables.verify": {"active": "正在核对实际完成结果", "complete": "完成结果已核对"},
        "file.read": {"active": "正在读取文件", "complete": "文件内容已读取"},
        "artifact.write_text": {"active": "正在保存结果", "complete": "结果已保存"},
        "document.parse": {"active": "正在解析文档", "complete": "文档已解析"},
        "data.analyze": {"active": "正在分析数据", "complete": "数据分析已完成"},
        "calculate.deterministic": {"active": "正在计算并核对结果", "complete": "计算结果已核对"},
        "web.fetch": {"active": "正在读取网络资料", "complete": "网络资料已读取"},
        "web.search": {"active": "正在搜索公开资料", "complete": "公开资料已搜索"},
        "image.ocr": {"active": "正在识别图片文字", "complete": "图片文字已识别"},
        "pdf.extract_text": {"active": "正在提取 PDF 文本", "complete": "PDF 文本已提取"},
        "docs.library.resolve": {"active": "正在定位技术文档库", "complete": "技术文档库已定位"},
        "docs.query": {"active": "正在查询技术文档", "complete": "技术文档已查询"},
        "feishu.calendar.agenda": {"active": "正在查看飞书日程", "complete": "飞书日程已查看"},
        "feishu.contact.search": {"active": "正在搜索飞书联系人", "complete": "飞书联系人已查询"},
        "feishu.message.search": {"active": "正在搜索飞书消息", "complete": "飞书消息已搜索"},
        "feishu.docs.search": {"active": "正在搜索飞书文档", "complete": "飞书文档已搜索"},
        "feishu.tasks.list": {"active": "正在查看飞书任务", "complete": "飞书任务已查看"},
        "feishu.mail.search": {"active": "正在搜索飞书邮件", "complete": "飞书邮件已搜索"},
        "dingtalk.calendar.agenda": {"active": "正在查看钉钉日程", "complete": "钉钉日程已查看"},
        "dingtalk.contact.search": {"active": "正在搜索钉钉联系人", "complete": "钉钉联系人已查询"},
        "dingtalk.message.search": {"active": "正在搜索钉钉消息", "complete": "钉钉消息已搜索"},
        "dingtalk.docs.search": {"active": "正在搜索钉钉文档", "complete": "钉钉文档已搜索"},
        "dingtalk.tasks.list": {"active": "正在查看钉钉待办", "complete": "钉钉待办已查看"},
        "dingtalk.mail.search": {"active": "正在搜索钉钉邮件", "complete": "钉钉邮件已搜索"},
        "materials.inspect": {"active": "正在读取任务附件", "complete": "任务附件已读取"},
        "image.inspect": {"active": "正在查看图片信息", "complete": "图片信息已核对"},
        "image.transform": {"active": "正在处理图片", "complete": "图片已处理并核验"},
        "document.docx.inspect": {"active": "正在读取 Word 文档", "complete": "Word 文档内容已核对"},
        "document.docx.generate": {"active": "正在生成 Word 文档", "complete": "Word 文档已生成并核验"},
        "document.scan_pdf": {"active": "正在制作扫描 PDF", "complete": "扫描 PDF 已生成"},
        "deliverables.plan": {"active": "正在安排交付清单", "complete": "交付清单已安排"},
        "deliverables.publish": {"active": "正在整理准备资料", "complete": "准备资料已生成"},
        "journal.append": {"active": "正在记录内容", "complete": "内容已记录"},
    }
    fallback = {
        "preparing": "正在准备下一步",
        "active": "正在处理下一步",
        "complete": "这一步已完成",
        "failed": "这一步遇到问题",
        "cancelled": "这一步已取消",
        "replanning": "这一步需要换个方案",
    }
    stage_copy = copies.get(capability, {})
    if stage in stage_copy:
        return stage_copy[stage]
    if stage == "preparing" and "active" in stage_copy:
        return stage_copy["active"]
    return fallback.get(stage, fallback["active"])


def upsert_timeline_item(
    conn: sqlite3.Connection,
    *,
    task_id: str,
    source_key: str,
    kind: str,
    presentation_state: str,
    title: str,
    summary: Optional[str],
    payload: Dict[str, Any],
    source_type: str,
    source_id: Optional[str],
    attention_level: str,
    now: str,
) -> Tuple[str, Optional[int]]:
    payload_json = canonical_json(payload)
    existing = conn.execute(
        "SELECT * FROM task_timeline_items WHERE task_id = ? AND source_key = ?",
        (task_id, source_key),
    ).fetchone()

    if existing is None:
        item_id = stable_id("tl", task_id, source_key)
        order_row = conn.execute(
            "SELECT COALESCE(MAX(display_order), 0) + 1 FROM task_timeline_items WHERE task_id = ?",
            (task_id,),
        ).fetchone()
        display_order = int(order_row[0])
        revision = 1
        conn.execute(
            """
            INSERT INTO task_timeline_items
            (id, task_id, display_order, kind, presentation_state, title, summary,
             payload_json, source_type, source_id, source_key, schema_version,
             revision, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
            """,
            (
                item_id,
                task_id,
                display_order,
                kind,
                presentation_state,
                title,
                summary,
                payload_json,
                source_type,
                source_id,
                source_key,
                revision,
                now,
                now,
            ),
        )
    else:
        item_id = str(existing["id"])
        unchanged = (
            existing["kind"] == kind
            and existing["presentation_state"] == presentation_state
            and existing["title"] == title
            and existing["summary"] == summary
            and existing["payload_json"] == payload_json
            and existing["source_type"] == source_type
            and existing["source_id"] == source_id
        )
        if unchanged:
            return item_id, None
        revision = int(existing["revision"]) + 1
        conn.execute(
            """
            UPDATE task_timeline_items
            SET kind = ?, presentation_state = ?, title = ?, summary = ?,
                payload_json = ?, source_type = ?, source_id = ?, revision = ?,
                updated_at = ?
            WHERE id = ?
            """,
            (
                kind,
                presentation_state,
                title,
                summary,
                payload_json,
                source_type,
                source_id,
                revision,
                now,
                item_id,
            ),
        )

    public_payload = public_timeline_event_payload(
        timeline_item_id=item_id,
        kind=kind,
        presentation_state=presentation_state,
        title=title,
        summary=summary,
        payload=payload,
        revision=revision,
    )
    event_source_key = f"{source_key}:revision:{revision}"
    event_id = stable_id("pe", task_id, event_source_key)
    cursor = conn.execute(
        """
        INSERT OR IGNORE INTO presentation_events
        (id, task_id, timeline_item_id, operation, public_payload_json,
         attention_level, source_key, created_at)
        VALUES (?, ?, ?, 'UPSERT', ?, ?, ?, ?)
        """,
        (
            event_id,
            task_id,
            item_id,
            canonical_json(public_payload),
            attention_level,
            event_source_key,
            now,
        ),
    )
    if cursor.rowcount == 0:
        row = conn.execute(
            "SELECT seq FROM presentation_events WHERE task_id = ? AND source_key = ?",
            (task_id, event_source_key),
        ).fetchone()
        return item_id, int(row["seq"]) if row is not None else None
    return item_id, int(cursor.lastrowid)


def project_timeline_projection(
    *,
    kind: str,
    presentation_state: str,
    title: str,
    summary: Optional[str],
    payload: Dict[str, Any],
) -> Tuple[str, Optional[str], Dict[str, Any]]:
    """Return the explicit public product view of one durable Timeline row."""

    raw_payload = dict(payload)
    capability = raw_payload.get("capability")
    stage = {
        "ACTIVE": "active",
        "COMPLETE": "complete",
        "FAILED": "failed",
        "INFO": "replanning",
    }.get(presentation_state.upper())

    clean_existing_title = str(title).strip()
    if clean_existing_title and not _looks_like_internal_public_text(clean_existing_title):
        safe_title = clean_existing_title[:240]
    elif kind.upper() == "TOOL_ACTIVITY" and isinstance(capability, str) and capability and stage:
        safe_title = capability_activity_title(capability, stage)
    else:
        safe_title = project_public_text(
            title,
            kind=kind,
            presentation_state=presentation_state,
            fallback=_default_public_title(kind, presentation_state),
        ) or _default_public_title(kind, presentation_state)

    safe_summary = project_public_text(
        summary,
        kind=kind,
        presentation_state=presentation_state,
        fallback=_default_public_summary(kind, presentation_state),
    )
    safe_payload = project_public_payload(kind, raw_payload)
    return safe_title, safe_summary, safe_payload


def public_timeline_event_payload(
    *,
    timeline_item_id: str,
    kind: str,
    presentation_state: str,
    title: str,
    summary: Optional[str],
    payload: Dict[str, Any],
    revision: int,
) -> Dict[str, Any]:
    safe_title, safe_summary, safe_payload = project_timeline_projection(
        kind=kind,
        presentation_state=presentation_state,
        title=title,
        summary=summary,
        payload=payload,
    )
    return {
        "timeline_item_id": timeline_item_id,
        "kind": kind,
        "presentation_state": presentation_state,
        "title": safe_title,
        "summary": safe_summary,
        "payload": safe_payload,
        "revision": revision,
    }


def project_public_result(value: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(value, dict):
        return None
    summary = value.get("summary")
    safe_summary = project_public_text(
        summary if isinstance(summary, str) else None,
        kind="RESULT",
        presentation_state="COMPLETE",
        fallback=_default_public_summary("RESULT", "COMPLETE"),
    )
    return {"summary": safe_summary} if safe_summary is not None else None


def timeline_item_dict(row: sqlite3.Row) -> Dict[str, Any]:
    kind = str(row["kind"])
    title, summary, payload = project_timeline_projection(
        kind=kind,
        presentation_state=str(row["presentation_state"]),
        title=str(row["title"]),
        summary=row["summary"],
        payload=json.loads(row["payload_json"]),
    )
    return {
        "timeline_item_id": row["id"],
        "task_id": row["task_id"],
        "display_order": row["display_order"],
        "kind": row["kind"],
        "presentation_state": row["presentation_state"],
        "title": title,
        "summary": summary,
        "payload": payload,
        "revision": row["revision"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }
