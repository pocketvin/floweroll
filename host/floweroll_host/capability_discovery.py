"""Progressive capability discovery above provider transports.

The complete registry remains in Host memory. Model requests receive a bounded
working set plus a small category index. Search is a normal read-only Action;
its verified Observation (not a process cache) restores revealed IDs on restart.
Discovery NEVER grants authority or promotes an unready provider.
"""
from __future__ import annotations

import math
import re
from dataclasses import replace
from typing import Any, Callable, Dict, List, Optional, Sequence

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .docx_package import DOCX_MIME
from .discovery_progress import catalog_fingerprint
from .work_units import batch_capability_spec, SAFE_CAPABILITIES
from .function_execution_worker import FunctionToolError, TaskScopedFunction
from .function_tool_adapter import FunctionToolAdapter
from .planner_contracts import CapabilitySpec, DecisionContext
from .task_capability_policy import (
    EffectiveTaskCapabilityPolicy,
    capability_semantics as task_capability_semantics,
    domains_for as task_domains_for,
)

SEARCH_ID = "capability.search"
DEFAULT_SCHEMA_LIMIT = 8
SEARCH_LIMIT_MIN = 1
SEARCH_LIMIT_MAX = 6
SEARCH_LIMIT_DEFAULT = SEARCH_LIMIT_MAX
DOMAIN_LABELS = {
    "device": "手机日历、提醒、闹钟、联系人、定位和通知",
    "communication": "邮件、消息、会话与收件人",
    "work": "文档、表格、任务、知识库和审批",
    "web": "网页搜索、读取、下载和浏览器",
    "files": "文件读取、写入、转换和归档",
    "document": "PDF、扫描、文字识别和文档处理",
    "media": "图片、音频、视频处理",
    "location": "地点、天气、地图、路线和导航",
    "travel": "火车、航班、酒店和门票",
    "commerce": "商品、餐饮、购物车和订单",
    "payment": "报价、支付授权和退款",
    "content": "内容平台、检索和发布",
    "entertainment": "音乐、视频、播客播放",
    "app_control": "用户主动打开应用、目标页和结果交接",
    "task": "本任务的材料、交付计划与成果",
}
_DOMAIN_TERMS = {
    "device": ("calendar", "reminder", "alarm", "contacts", "contact", "notification", "notify", "日历", "日程", "闹钟", "提醒", "联系人"),
    "communication": ("email", "mail", "message", "chat", "邮件", "消息", "会话", "收件人"),
    "work": ("docs", "sheets", "tasks", "knowledge", "approval", "飞书", "钉钉", "知识库", "技术文档"),
    "web": ("web", "browser", "search", "网页", "搜索", "联网", "网站"),
    "files": ("file", "artifact", "archive", "data", "文件", "写入", "目录", "归档"),
    "document": ("document", "pdf", "ocr", "扫描", "简历", "合并", "选页", "文字识别"),
    "media": ("image", "audio", "video", "图片", "音频", "视频", "压缩"),
    "location": ("location", "places", "geocode", "routes", "weather", "maps", "coords", "coordinate", "定位", "位置", "地图", "路线", "地点", "天气", "高德", "坐标"),
    "travel": ("hotel", "train", "flight", "ticket", "travel", "酒店", "火车", "航班", "门票", "行程"),
    "commerce": ("commerce", "product", "restaurant", "cart", "商品", "餐厅", "购物车", "外卖"),
    "payment": ("payment", "refund", "支付", "退款"),
    "content": ("douyin", "bilibili", "xiaohongshu", "zhihu", "抖音", "b站", "小红书", "知乎"),
    "entertainment": ("music", "podcast", "playback", "播放", "音乐", "播客"),
    "app_control": ("handoff", "app.open", "deeplink", "foreground", "打开应用", "唤端", "接管"),
    "task": ("materials", "deliverables", "成果", "交付", "材料"),
}

_READ_OPERATIONS = {"read", "availability"}

# `device` is deliberately broad for policy, but retrieval still needs to avoid
# treating every native read/write as equally relevant once the user names a
# concrete Apple-domain entity. Keep this semantic family table bounded and
# provider-independent; it affects ranking only and grants no capability.
_NATIVE_DEVICE_ENTITY_TERMS = {
    "alarm": ("alarm", "闹钟"),
    "calendar": ("calendar", "日历", "日程"),
    "reminder": ("reminder", "提醒"),
    "contacts": ("contacts", "contact", "联系人", "通讯录"),
    "notify": ("notify", "notification", "通知"),
    "location": ("location", "定位", "位置", "当前位置", "我现在在哪", "现在在哪", "在哪"),
}


def _native_device_entity_signals(query: str) -> set[str]:
    lowered = query.lower()
    return {
        family
        for family, terms in _NATIVE_DEVICE_ENTITY_TERMS.items()
        if any(term in lowered for term in terms)
    }


def _native_device_entity_family(
    spec: CapabilitySpec, registry: CapabilityRegistry
) -> Optional[str]:
    # Registry-backed tools may have been explicitly discovered/selected from a
    # provider page. Do not demote that durable discovery merely because its
    # broad native family differs from the current noun phrase. This affinity
    # is only for the built-in native surface that otherwise shares one coarse
    # `device` domain.
    if spec.name in registry:
        return None
    family = spec.name.lower().split(".", 1)[0]
    return family if family in _NATIVE_DEVICE_ENTITY_TERMS else None


_GOAL_OPERATION_TERMS = {
    "read": ("查询", "查看", "查一下", "查找", "读取", "读一下", "了解", "query", "read", "look up", "show me"),
    "availability": ("忙闲", "空闲", "有空", "有没有空", "freebusy", "free busy", "availability", "available"),
    "create": ("创建", "新建", "添加", "加入", "加到", "create", "add"),
    "modify": (
        "修改", "更新", "编辑", "改动", "暂停", "恢复",
        "标记为完成", "标记完成", "完成这个提醒", "改回未完成", "恢复为未完成", "取消完成状态",
        "modify", "update", "edit", "pause", "resume",
    ),
    "delete": ("删除", "移除", "取消", "delete", "remove", "cancel"),
    "send": ("发送", "发给", "转发", "回复", "send", "forward", "reply"),
    "publish": ("报告", "html", "导出", "发布", "publish", "report", "export"),
    "pay": ("支付", "付款", "扣款", "退款", "pay", "payment", "charge", "refund"),
    "book": ("预订", "预定", "预约", "下单", "订票", "订酒店", "book", "reserve", "reservation", "order"),
}
def _capability_operation(spec: CapabilitySpec, registry: CapabilityRegistry) -> str:
    """Classify retrieval semantics through the shared Task policy semantics."""
    return task_capability_semantics(spec, registry).operation


_REMINDER_COMPLETION_STATE_TERMS = (
    "标记为完成", "标记完成", "完成这个提醒", "改回未完成", "恢复为未完成", "完成状态",
    "mark this reminder complete", "mark reminder complete", "uncomplete reminder",
)


_REMINDER_GENERAL_UPDATE_TERMS = (
    "修改", "更新", "编辑", "改到", "改成", "改为", "换成", "标题", "备注", "优先级", "到期",
    "modify", "update", "edit", "title", "notes", "priority", "due",
)
_REMINDER_EXISTING_TARGET_TERMS = ("这个提醒", "该提醒", "现有提醒", "这条提醒", "this reminder", "existing reminder")
_REMINDER_REMOVE_TERMS = (
    "删除这个提醒", "删除该提醒", "删除提醒", "移除这个提醒", "移除该提醒", "移除提醒",
    "delete this reminder", "delete reminder", "remove this reminder", "remove reminder",
)


def _reminder_management_relevance(spec: CapabilitySpec, query: str) -> int:
    name = spec.name.lower()
    if not name.startswith("reminder."):
        return 0
    lowered = query.lower()
    if "提醒" not in lowered and "reminder" not in lowered:
        return 0
    completion_intent = any(term in lowered for term in _REMINDER_COMPLETION_STATE_TERMS)
    if completion_intent:
        if name == "reminder.set_completion":
            return 140
        if name == "reminder.update":
            return -80
        return -20
    remove_intent = any(term in lowered for term in _REMINDER_REMOVE_TERMS)
    if remove_intent:
        if name == "reminder.remove":
            return 120
        if name in {"reminder.create", "reminder.update", "reminder.set_completion"}:
            return -60
    update_intent = any(term in lowered for term in _REMINDER_GENERAL_UPDATE_TERMS)
    if update_intent:
        if name == "reminder.update":
            return 100
        if name == "reminder.set_completion":
            return -35
        if name == "reminder.create" and any(term in lowered for term in _REMINDER_EXISTING_TARGET_TERMS):
            return -70
    return 0


_CONTACTS_QUERY_TERMS = (
    "查联系人", "查一下联系人", "查看联系人", "查找联系人", "找联系人", "通讯录里找", "通讯录中找",
    "联系人查询", "lookup contact", "look up contact", "read contact", "query contact",
)
_CONTACTS_CREATE_TERMS = (
    "创建联系人", "新建联系人", "添加联系人", "加联系人", "create contact", "add contact",
)
_CONTACTS_UPDATE_TERMS = (
    "修改联系人", "更新联系人", "编辑联系人", "改联系人", "update contact", "edit contact",
)


def _contacts_management_relevance(spec: CapabilitySpec, query: str) -> int:
    name = spec.name.lower()
    if not name.startswith("contacts."):
        return 0
    lowered = query.lower()
    if not any(term in lowered for term in _NATIVE_DEVICE_ENTITY_TERMS["contacts"]):
        return 0

    if any(term in lowered for term in _CONTACTS_CREATE_TERMS):
        if name == "contacts.create":
            return 140
        if name == "contacts.query":
            return -20
        if name == "contacts.update":
            return -60

    if any(term in lowered for term in _CONTACTS_UPDATE_TERMS):
        if name == "contacts.update":
            return 140
        if name == "contacts.query":
            return 20
        if name == "contacts.create":
            return -60

    if any(term in lowered for term in _CONTACTS_QUERY_TERMS) or (
        ("contact" in lowered or "联系人" in lowered or "通讯录" in lowered)
        and any(term in lowered for term in ("查", "找", "lookup", "look up", "query", "read", "show"))
    ):
        if name == "contacts.query":
            return 140
        if name in {"contacts.create", "contacts.update"}:
            return -70
    return 0


def _goal_operation_signals(query: str) -> set[str]:
    lowered = query.lower()
    signals = {
        operation
        for operation, terms in _GOAL_OPERATION_TERMS.items()
        if any(term in lowered for term in terms)
    }
    # "取消这个提醒的完成状态" means desired-state modification, not deletion.
    # Keep this narrow to explicit Reminder completion-state language so normal
    # cancel/delete requests retain their existing semantics.
    if ("提醒" in lowered or "reminder" in lowered) and any(
        term in lowered for term in _REMINDER_COMPLETION_STATE_TERMS
    ):
        signals.add("modify")
        signals.discard("delete")
    return signals


def _tokens(text: str) -> set[str]:
    text = text.lower()
    result = set(re.findall(r"[a-z0-9_]+", text))
    # Chinese bigrams avoid a model/embedding call solely for tool retrieval.
    for run in re.findall(r"[\u3400-\u9fff]+", text):
        if len(run) == 1:
            result.add(run)
        result.update(run[i:i + 2] for i in range(len(run) - 1))
    return result


def domains_for(spec: CapabilitySpec, registry: Optional[CapabilityRegistry] = None) -> List[str]:
    return task_domains_for(spec, registry)


def _allowed(specs: Sequence[CapabilitySpec], policy: Dict[str, Any]) -> List[CapabilitySpec]:
    names = policy.get("allowed_capabilities")
    if names is None:
        return list(specs)
    allowed_names = {name for name in names if isinstance(name, str)}
    return [spec for spec in specs if spec.name in allowed_names]


def category_index(specs: Sequence[CapabilitySpec], registry: CapabilityRegistry) -> List[Dict[str, Any]]:
    counts: Dict[str, int] = {}
    for spec in specs:
        if spec.name == SEARCH_ID:
            continue
        for domain in domains_for(spec, registry):
            counts[domain] = counts.get(domain, 0) + 1
    return [{"domain": name, "description": DOMAIN_LABELS[name], "ready_count": count}
            for name, count in sorted(counts.items())]


_CALC_EXTERNAL_TERMS = (
    "美元", "人民币", "欧元", "日元", "港币", "英镑", "汇率", "汇价", "usd", "cny", "jpy", "eur", "hkd", "gbp",
    "驾车距离", "步行距离", "路线距离", "导航", "路程", "开车多远", "驾车", "打车距离",
    "个税", "所得税", "税务", "交多少税", "税率", "法律", "律师", "违约金",
    "贷款", "利率", "股票", "基金", "实时价格", "最新价格", "现价",
)
_CALC_FUZZY_TIME_TERMS = ("明天", "后天", "大后天", "下周", "下个月", "今天", "今晚", "本周", "月底")
_CALC_ZONE_TERMS = ("东京", "上海", "纽约", "utc", "asia/tokyo", "asia/shanghai", "america/new_york")


def _deterministic_calc_relevance(query: str) -> int:
    """Return a narrow retrieval boost for the existing deterministic contract.

    This is retrieval only: it never parses/executes the calculation. Strong
    negatives keep external-data/business-rule/fuzzy goals away from the local
    deterministic tool even if they contain words such as "算" or "多少".
    """
    lowered = query.lower()
    if any(term in lowered for term in _CALC_EXTERNAL_TERMS):
        return -1000
    if any(term in lowered for term in _CALC_FUZZY_TIME_TERMS):
        return -1000
    iso_dates = re.findall(r"\b\d{4}-\d{2}-\d{2}\b", lowered)
    if len(iso_dates) >= 2 and re.search(r"相差(?:多少|几)天|差(?:多少|几)天|间隔(?:多少|几)天", lowered):
        # Current production has date_add but intentionally no date_diff.
        return -1000

    if "%" in query or "％" in query or "百分之" in query or "百分比" in query:
        return 100
    if re.search(r"(?<![\w.])[+-]?\d+(?:\.\d+)?\s*(?:[*/×÷])\s*[+-]?\d+(?:\.\d+)?(?![\w.])", query):
        return 100
    if re.search(r"\d+(?:\.\d+)?\s+[+-]\s+\d+(?:\.\d+)?", query):
        return 100

    has_conversion_word = any(term in lowered for term in ("换算", "转换", "等于多少", "等于几"))
    has_supported_unit = bool(re.search(
        r"\d+(?:\.\d+)?\s*(?:mm|cm|km|m|in|ft|yd|mi|mg|kg|g|oz|lb|ml|l|m3|ms|min|day)\b",
        lowered,
    )) or any(term in query for term in ("摄氏", "华氏", "开尔文"))
    if has_conversion_word and has_supported_unit:
        return 100

    if iso_dates and re.search(r"(?:往后|往前|之后|以前|加|减|后|前)\s*\d+\s*(?:天|周|星期|个月|月|年)", query):
        return 100

    has_zone = any(term in lowered for term in _CALC_ZONE_TERMS)
    if has_zone and any(term in lowered for term in ("换算", "转换")) and re.search(r"\b\d{1,2}:\d{2}\b", lowered):
        return 100
    if has_zone and any(term in query for term in ("相差多久", "时间差", "相差多长时间")) and len(re.findall(r"\b\d{1,2}:\d{2}\b", lowered)) >= 2:
        return 100

    return 0


def _current_location_relevance(query: str) -> int:
    lowered = query.lower()
    explicit_markers = (
        "我现在在哪", "现在在哪", "当前位置", "我的位置", "现在的位置", "当前的位置",
        "我这里", "从我这", "附近", "current location", "where am i", "near me",
        "from my location",
    )
    if any(marker in lowered for marker in explicit_markers):
        return 160
    travel_markers = (
        "怎么去", "怎么走", "怎么出行", "出行", "路线", "交通", "前往", "去西藏", "进藏",
        "how to get", "how do i get", "route", "travel to",
    )
    if any(marker in lowered for marker in travel_markers):
        return 90
    if _unqualified_weather_query(lowered):
        return 90
    return -1000


def _unqualified_weather_query(query: str) -> bool:
    """Only infer device location for an unqualified weather request.

    Remaining destination/context words prevent automatic location priority;
    ambiguous or named-place requests remain available to the normal Planner.
    No place-name list or additional external geocoding call is needed here.
    """
    if not any(word in query for word in ("天气", "weather", "气温", "温度")):
        return False
    remainder = query.lower()
    chinese_fillers = (
        "帮我", "给我", "请问", "查一下", "查询", "查看", "看看", "看一下", "告诉我",
        "明天", "今天", "后天", "今晚", "明晚", "这周", "本周", "下周", "周末",
        "天气预报", "天气", "气温", "温度", "怎么样", "如何", "多少", "几度",
        "会下雨吗", "下雨吗", "好不好", "一下", "现在", "未来", "最近", "几天",
        "请", "的", "吗", "呢", "呀", "吧",
    )
    for filler in chinese_fillers:
        remainder = remainder.replace(filler, "")
    remainder = re.sub(
        r"\b(?:what|is|s|the|will|be|how|check|show|me|please|weather|forecast|"
        r"temperature|today|tomorrow|tonight|next|this|week|weekend|days?|like)\b",
        "", remainder,
    )
    return not re.sub(r"[\s\d，。！？?,.!:：'’\-]+", "", remainder)


def _implicit_location_bundle(query: str) -> List[str]:
    """Return a bounded fast-path tool set for goals that need current location."""
    lowered = query.lower()
    weather_intent = any(marker in lowered for marker in ("天气", "weather", "气温", "温度"))
    travel_intent = any(marker in lowered for marker in (
        "怎么去", "怎么走", "怎么出行", "出行", "路线", "交通", "前往", "去西藏", "进藏",
        "how to get", "how do i get", "route", "travel to",
    ))
    if not (weather_intent or travel_intent) or _current_location_relevance(query) <= 0:
        return []
    bundle = ["location.current", "coords.convert", "geocode.reverse"]
    if weather_intent:
        bundle.append("weather.query")
    if travel_intent:
        bundle.append("web.search")
    return bundle


def rank_capabilities(specs: Sequence[CapabilitySpec], query: str, registry: CapabilityRegistry) -> List[CapabilitySpec]:
    query_tokens = _tokens(query[:6000])
    operation_signals = _goal_operation_signals(query)
    device_entities = _native_device_entity_signals(query)
    scored = []
    for spec in specs:
        name_tokens = _tokens(spec.name)
        description_tokens = _tokens(spec.description[:1000])
        score = 6 * len(query_tokens & name_tokens) + len(query_tokens & description_tokens)
        # Prefer an explicit output-format contract over incidental mentions in
        # descriptions (e.g. PDF extraction cannot generate a new PDF report).
        # Specialized scan/merge/page-selection requests retain their own route.
        lowered = query.lower()
        output_request = (any(word in lowered for word in ('生成', '导出', '转换', '转成', '以pdf', '用pdf', 'generate', 'export'))
                          and not any(word in lowered for word in ('扫描', '合并', '重排', '选页', 'scan', 'merge')))
        output_formats = set()
        for field in ('output_format', 'target_format'):
            output_formats.update(str(value).lower() for value in
                                  spec.arguments_schema.get('properties', {}).get(field, {}).get('enum', []))
        if output_request and any(fmt in lowered for fmt in output_formats):
            score += 140
        for domain in domains_for(spec, registry):
            if any(term in query.lower() for term in _DOMAIN_TERMS[domain]):
                score += 6
        if spec.name.lower() in query.lower():
            score += 30
        operation = _capability_operation(spec, registry)
        if operation in operation_signals:
            score += 38 if operation == "availability" else 28
        elif operation in _READ_OPERATIONS and "read" in operation_signals:
            score += 22
        native_family = _native_device_entity_family(spec, registry)
        if device_entities and native_family is not None:
            # A small positive tie-break is enough for the named family; the
            # stronger mismatch penalty prevents unrelated built-in device
            # reads from winning solely on operation/domain score.
            score += 2 if native_family in device_entities else -12
        if spec.name == "calculate.deterministic":
            score += _deterministic_calc_relevance(query)
        if spec.name == "location.current":
            score += _current_location_relevance(query)
        score += _reminder_management_relevance(spec, query)
        score += _contacts_management_relevance(spec, query)
        # Slightly prefer focused descriptions; large generic schemas should not
        # win merely by listing every word in a capability catalog.
        score /= 1 + math.log1p(len(description_tokens)) / 30
        scored.append((score, spec.name, spec))
    return [spec for _, _, spec in sorted(scored, key=lambda item: (-item[0], item[1]))]


class CapabilityContextSelector:
    def __init__(self, registry: CapabilityRegistry, *, max_schemas: int = DEFAULT_SCHEMA_LIMIT,
                 ready_specs: Optional[Callable[[], List[CapabilitySpec]]] = None):
        if not 3 <= max_schemas <= 12:
            raise ValueError("working tool set must contain 3–12 schemas")
        self.registry = registry
        self.max_schemas = max_schemas
        self.ready_specs = ready_specs

    def apply(self, context: DecisionContext) -> DecisionContext:
        eligible = list(context.capabilities)
        if self.ready_specs is not None:
            ready = {spec.name for spec in self.ready_specs()}
            eligible = [spec for spec in eligible if spec.name in ready]
        if not context.policy_view.get("effective_task_policy_applied", False):
            policy_texts = [context.raw_goal]
            for turn in context.user_turns:
                content = turn.get("content", {})
                if isinstance(content, dict) and isinstance(content.get("text"), str):
                    policy_texts.append(content["text"])
                elif isinstance(content, str):
                    policy_texts.append(content)
            effective_policy = EffectiveTaskCapabilityPolicy.from_texts(policy_texts)
            eligible = effective_policy.filter_specs(eligible, self.registry)
        by_id = {spec.name: spec for spec in eligible}
        if SEARCH_ID not in by_id:
            # Never silently hide actions when no recovery/discovery route exists.
            return context
        catalog_key = catalog_fingerprint(eligible)
        discovery_state = context.runtime_context.get('capability_discovery_state') or {}
        search_allowed = (discovery_state.get('catalog_key') != catalog_key
                          or discovery_state.get('search_allowed', True))
        observed_ids = {row.get('capability') for row in context.verified_observations
                        if row.get('capability') not in {SEARCH_ID, 'work.execute'}}
        query_parts = [context.raw_goal, context.normalized_goal or "", " ".join(context.plan[-3:])]
        for turn in context.user_turns[-2:]:
            content = turn.get("content", {})
            if isinstance(content, dict):
                query_parts.append(str(content.get("text", "")))
            elif isinstance(content, str):
                query_parts.append(content)
        query_text = " ".join(query_parts)
        ranked = rank_capabilities([s for s in eligible if s.name != SEARCH_ID], query_text, self.registry)
        selected: List[str] = []
        if context.runtime_context.get("task_materials", {}).get("plan") and "deliverables.status" in by_id:
            selected.append("deliverables.status")
        material_plan = context.runtime_context.get("task_materials", {}).get("plan") or {}
        if len(material_plan.get("items", [])) >= 2 and "work.execute" in by_id:
            selected.append("work.execute")
        location_bundle = _implicit_location_bundle(query_text)
        location_observed = any(
            row.get("capability") == "location.current"
            for row in context.verified_observations
        )
        if location_bundle and location_observed and "work.execute" in by_id and "work.execute" not in selected:
            selected.append("work.execute")
        for name in location_bundle:
            if location_observed and name == "location.current":
                continue
            if name in by_id and name not in selected and name not in observed_ids:
                selected.append(name)
        # Reuse a bounded union of recently revealed capabilities instead of
        # forgetting every page except the last one. Rank that union against
        # the current goal so an old discovery cannot crowd out newly relevant
        # tools. It is reconstructed from durable verified observations and
        # therefore survives Host restart without a separate cache.
        searches = [row for row in context.verified_observations if row.get("capability") == SEARCH_ID]
        if searches:
            discovered: List[str] = []
            for row in reversed(searches[-8:]):
                for name in row.get("data", {}).get("selected_capability_ids", []):
                    if name in by_id and name not in discovered:
                        discovered.append(name)
            ranked_ids = [spec.name for spec in ranked]
            discovery_order = {name: index for index, name in enumerate(discovered)}
            discovered.sort(
                key=lambda name: (
                    ranked_ids.index(name) if name in ranked_ids else len(ranked_ids),
                    discovery_order[name],
                )
            )
            # Preserve the top result of each recently requested subgoal rather
            # than reranking every page solely against the original large goal.
            # Recent results take precedence over already completed fast paths.
            heads = []
            for row in reversed(searches[-8:]):
                ids = row.get('data', {}).get('selected_capability_ids', [])
                head = next((name for name in ids if name in by_id
                             and name not in {SEARCH_ID, 'work.execute'}), None)
                if head and head not in heads:
                    heads.append(head)
            preferred = list(dict.fromkeys(heads + discovered))
            discovery_budget = max(1, self.max_schemas - 3)
            selected = list(dict.fromkeys(preferred[:discovery_budget] + selected))
        failure = context.last_semantic_failure or {}
        failed_id = failure.get("capability")
        if failed_id in by_id and failed_id not in selected:
            selected.append(failed_id)
        materials = context.runtime_context.get("task_materials", {})
        material_inputs = [row for row in materials.get("inputs", []) if isinstance(row, dict)]
        docx_inputs = [row for row in material_inputs if row.get("media_type") == DOCX_MIME]
        non_docx_inputs = [row for row in material_inputs if row.get("media_type") != DOCX_MIME]
        image_inputs = [
            row for row in material_inputs
            if isinstance(row.get("media_type"), str) and row["media_type"].startswith("image/")
        ]
        material_path_readers = {"image.ocr", "pdf.extract_text"}
        material_reader_available = any(
            name in by_id for name in {"materials.inspect", "document.scan_pdf"}
        )
        material_goal = (context.normalized_goal or context.raw_goal or "").lower()
        scan_pdf_requested = (
            bool(image_inputs)
            and len(image_inputs) == len(material_inputs)
            and "document.scan_pdf" in by_id
            and any(marker in material_goal for marker in (
                "扫描", "扫描件", "scan", "pdf", "合成pdf", "合成 pdf", "转成pdf", "转成 pdf",
            ))
        )
        scan_pdf_observed = any(
            row.get("capability") == "document.scan_pdf"
            for row in context.verified_observations
        )
        if scan_pdf_requested and not scan_pdf_observed:
            selected = ["document.scan_pdf", *[
                name for name in selected if name != "document.scan_pdf"
            ]]
        # When an image-specific capability is already among the top three
        # semantic matches, prefer that bounded structural/transform route over
        # the generic material reader for an image-only task. This keeps OCR or
        # ambiguous "read the image" prompts on materials.inspect (where image.*
        # does not rank highly), while resize/crop/format/metadata prompts expose
        # the purpose-built schema first without pinning image tools globally.
        image_specialist_id = None
        if image_inputs and len(image_inputs) == len(material_inputs):
            for position, spec in enumerate(ranked[:3]):
                if spec.name in {"image.inspect", "image.transform"}:
                    image_specialist_id = spec.name
                    if image_specialist_id in by_id and image_specialist_id not in selected:
                        selected.append(image_specialist_id)
                    break
        image_only_specialized = image_specialist_id is not None and len(image_inputs) == len(material_inputs)
        docx_inspect_id = "document.docx.inspect"
        docx_inspected = any(
            row.get("capability") == docx_inspect_id
            for row in context.verified_observations
        )
        if docx_inputs and docx_inspect_id in by_id and not docx_inspected:
            selected.append(docx_inspect_id)
        generic_material_needed = (bool(non_docx_inputs) or not (
            docx_inputs and docx_inspect_id in by_id
        )) and not image_only_specialized and not scan_pdf_requested
        if generic_material_needed and material_inputs and not any(
            row.get("capability") == "materials.inspect"
            for row in context.verified_observations
        ):
            if "materials.inspect" in by_id and "materials.inspect" not in selected:
                selected.append("materials.inspect")
        for spec in ranked:
            # For DOCX-only material input, the dedicated bounded OOXML reader is
            # the safe semantic route. The generic material reader treats unknown
            # binaries as UTF-8 text and must not be reintroduced by ranking.
            if docx_inputs and not non_docx_inputs and docx_inspect_id in by_id and spec.name == "materials.inspect":
                continue
            if image_only_specialized and spec.name == "materials.inspect":
                continue
            if scan_pdf_requested and spec.name == "materials.inspect":
                continue
            # TaskAsset-backed inputs must not be routed through generic
            # HostWorkspace path readers. Those tools cannot consume file_id
            # identity and were a source of wrong-path + duplicate OCR loops.
            if material_inputs and material_reader_available and spec.name in material_path_readers:
                continue
            if location_bundle and location_observed and spec.name == "location.current":
                continue
            if spec.name not in selected:
                selected.append(spec.name)
        if material_inputs and material_reader_available:
            selected = [name for name in selected if name not in material_path_readers]
        # Discovery is a fallback, not the default first candidate. Keep one
        # bounded slot for it while placing recalled task capabilities first.
        selected = [name for name in selected if name != SEARCH_ID]
        # Discovery in a batch consumes the SAME budget. A tool having run once
        # does not mean every use is complete (e.g. weather for a second city).
        selected = selected[:self.max_schemas - (1 if search_allowed else 0)]
        if search_allowed:
            selected.append(SEARCH_ID)
        safe_selected = [n for n in selected if n in SAFE_CAPABILITIES]
        if 'work.execute' in by_id and (len(safe_selected) >= 2 or (searches and SEARCH_ID in selected)):
            if 'work.execute' not in selected:
                if len(selected) < self.max_schemas:
                    selected.insert(max(0, len(selected) - (1 if search_allowed else 0)), 'work.execute')
                else:
                    selected[len(selected) - (2 if search_allowed else 1)] = 'work.execute'
        if not any(n in SAFE_CAPABILITIES for n in selected):
            selected = [n for n in selected if n != 'work.execute']
        selected_specs = [by_id[name] for name in selected]
        selected_specs = [batch_capability_spec(s, selected_specs) if s.name == 'work.execute' else s for s in selected_specs]
        # Data only, no provider URLs, credentials, private paths or large schemas.
        instruction = (
            "当前任务已有图片材料，document.scan_pdf 已直接覆盖扫描 PDF + 单次逐页 OCR；"
            "不要先 capability.search，也不要把 TaskAsset 传给 pdf.extract_text/image.ocr。"
            if scan_pdf_requested and not scan_pdf_observed else
            "当前工具只是工作集。缺少某项能力时先用 capability.search 按领域/关键词找，不要直接说做不了。"
            "发现结果只从已授权可执行能力中选择；搜索不会授予新权限。简单任务可直接使用当前已显示工具，不必先搜索。"
        )
        if not search_allowed:
            instruction = ("能力发现已达到无业务进展预算或连续返回已知候选。不要换关键词、翻页或嵌套搜索。"
                           "先执行已显示的独立事项；当前无法实现的部分明确报告缺口，不得伪称整个任务完成。")
        routing = {
            "domains": category_index(eligible, self.registry),
            "ready_capability_count": len(eligible) - 1,
            "visible_schema_count": len(selected),
            "schema_limit": self.max_schemas,
            "has_more_capabilities": len(eligible) > len(selected),
            "discovery": SEARCH_ID if search_allowed else None,
            "search_allowed": search_allowed,
            "recent_searches": (discovery_state.get("pages") or [])[-8:],
            "instruction": instruction,
        }
        return replace(context, capabilities=selected_specs,
                       policy_view={**context.policy_view, "allowed_capabilities": selected},
                       runtime_context={**context.runtime_context, "capability_catalog": routing})


def register_capability_discovery(registry: CapabilityRegistry, storage: Any,
                                  ready_specs: Callable[[], List[CapabilitySpec]]) -> Dict[str, TaskScopedFunction]:
    def discover(dispatch: Dict[str, Any], arguments: Dict[str, Any]) -> Dict[str, Any]:
        task = storage.get_task(dispatch["task_id"])
        if task is None:
            raise FunctionToolError("任务不存在。", error_kind="model_correctable")
        query = arguments.get("query", "")
        domain = arguments.get("domain", "all")
        offset = arguments.get("offset", 0)
        limit = arguments.get("limit", SEARCH_LIMIT_DEFAULT)
        if not isinstance(query, str) or len(query) > 1000 or domain not in {"all", *DOMAIN_LABELS}:
            raise FunctionToolError("请使用有效领域和不超过1000字符的查询。", error_kind="model_correctable")
        if isinstance(offset, bool) or not isinstance(offset, int) or not 0 <= offset <= 100000:
            raise FunctionToolError("offset 无效。", error_kind="model_correctable")
        if (isinstance(limit, bool) or not isinstance(limit, int)
                or not SEARCH_LIMIT_MIN <= limit <= SEARCH_LIMIT_MAX):
            raise FunctionToolError(
                f"每次只发现{SEARCH_LIMIT_MIN}–{SEARCH_LIMIT_MAX}项能力。",
                error_kind="model_correctable",
            )
        effective_policy = EffectiveTaskCapabilityPolicy.from_task(task, storage.inbox_events(dispatch["task_id"]))
        eligible = effective_policy.filter_specs(
            [spec for spec in _allowed(ready_specs(), task["policy_snapshot"]) if spec.name != SEARCH_ID],
            registry,
        )
        matching = [spec for spec in eligible if domain == "all" or domain in domains_for(spec, registry)]
        ranked = rank_capabilities(matching, query, registry) if query.strip() else sorted(matching, key=lambda spec: spec.name)
        page = ranked[offset:offset + limit]
        result = {
            "query": query, "domain": domain,
            "domains": category_index(eligible, registry),
            "matches": [{"capability_id": spec.name, "description": spec.description[:220],
                         "domains": domains_for(spec, registry)} for spec in page],
            "selected_capability_ids": [spec.name for spec in page],
            "total_candidates": len(matching), "offset": offset,
            "next_offset": offset + len(page) if offset + len(page) < len(ranked) else None,
            "has_more": offset + len(page) < len(ranked),
            "notice": "这些能力的参数将在下一轮工作集中展开。结果按相关性排序而非完整匹配；无合适项可换关键词、领域或继续翻页。未登录/不可执行能力不会被假装成可用。",
        }

        return storage.record_capability_search(dispatch['task_id'], catalog_fingerprint(eligible), result)

    spec = CapabilitySpec(name=SEARCH_ID,
        description="按领域和自然语言关键词发现本任务已授权、当前可执行的能力；只返回小批候选，下一轮展开参数。未显示不等于不存在，简单任务无需额外搜索。",
        arguments_schema={"type": "object", "properties": {
            "query": {"type": "string"}, "domain": {"type": "string", "enum": ["all", *DOMAIN_LABELS]},
            "offset": {"type": "integer", "minimum": 0},
            "limit": {"type": "integer", "minimum": SEARCH_LIMIT_MIN, "maximum": SEARCH_LIMIT_MAX}},
            "required": ["query"], "additionalProperties": False}, post_verify_mode="REPLAN_REQUIRED")
    registry.register(RegisteredCapability(spec=spec,
        adapter=FunctionToolAdapter(capability_id=SEARCH_ID, source_kind="host_internal", timeout_seconds=5),
        source=CapabilitySourceTarget(kind="host_internal", tool_name=SEARCH_ID,
                                      metadata={"read_only": True, "foreground_policy": "background_only"}),
        tags=("discovery",), loading="always_visible"))
    return {SEARCH_ID: TaskScopedFunction(discover)}
