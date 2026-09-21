"""Fail-closed current-Task capability policy derived from durable user intent.

Product/provider authorization remains in the Task's policy_snapshot. This
module adds the narrower effective Task restrictions expressed by the user
inside the Task goal and later UserTurns. It is deterministic and reconstructible
from durable inputs, so a model/tool choice never grants itself authority.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Sequence

from .capability_registry import CapabilityRegistry
from .planner_contracts import CapabilitySpec


TASK_DENIED = "TASK_DENIED"


class TaskCapabilityDeniedError(RuntimeError):
    reason_code = TASK_DENIED

    def __init__(self, capability_id: str, detail: str) -> None:
        super().__init__(f"{TASK_DENIED}: {capability_id}: {detail}")
        self.capability_id = capability_id
        self.detail = detail

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

DOMAIN_TERMS = {
    "device": ("calendar", "reminder", "alarm", "contacts", "contact", "notification", "notify", "日历", "日程", "闹钟", "提醒", "联系人", "通知"),
    "communication": ("email", "mail", "message", "chat", "邮件", "消息", "会话", "收件人"),
    "work": ("docs", "sheets", "tasks", "knowledge", "approval", "飞书", "钉钉", "知识库", "技术文档"),
    "web": ("web", "browser", "search", "网页", "搜索", "联网", "网站"),
    "files": ("file", "artifact", "archive", "data", "文件", "写入", "目录", "归档"),
    "document": ("document", "pdf", "ocr", "扫描", "简历", "合并", "选页", "文字识别", "报告"),
    "media": ("image", "audio", "video", "图片", "音频", "视频", "压缩"),
    "location": ("location", "places", "geocode", "routes", "weather", "maps", "coords", "coordinate", "定位", "位置", "地图", "路线", "地点", "天气", "高德", "坐标"),
    "travel": ("hotel", "train", "flight", "ticket", "travel", "酒店", "火车", "航班", "门票", "行程"),
    "commerce": ("commerce", "product", "restaurant", "cart", "order", "商品", "餐厅", "购物车", "外卖", "下单"),
    "payment": ("payment", "refund", "pay", "charge", "支付", "付款", "扣款", "退款"),
    "content": ("douyin", "bilibili", "xiaohongshu", "zhihu", "抖音", "b站", "小红书", "知乎", "发布"),
    "entertainment": ("music", "podcast", "playback", "播放", "音乐", "播客"),
    "app_control": ("handoff", "app.open", "deeplink", "foreground", "打开应用", "唤端", "接管"),
    "task": ("materials", "deliverables", "成果", "交付", "材料", "报告"),
}

# User clauses need noun-like scope terms only. Operation verbs such as
# "write/publish/order" must not accidentally narrow a global prohibition or
# revocation to one domain.
POLICY_DOMAIN_TERMS = {
    "device": ("calendar", "reminder", "alarm", "contacts", "contact", "notification", "notify", "日历", "日程", "闹钟", "提醒", "联系人", "通知"),
    "communication": ("email", "mail", "message", "chat", "邮件", "消息", "会话", "收件人"),
    "work": ("docs", "sheets", "tasks", "knowledge", "approval", "飞书", "钉钉", "知识库", "技术文档"),
    "web": ("web", "browser", "网页", "联网", "网站"),
    "files": ("file", "artifact", "archive", "文件", "目录", "归档"),
    "document": ("document", "pdf", "ocr", "扫描", "简历", "文档", "报告"),
    "media": ("image", "audio", "video", "图片", "音频", "视频"),
    "location": ("location", "places", "geocode", "routes", "weather", "maps", "coords", "coordinate", "定位", "位置", "地图", "路线", "地点", "天气", "高德", "坐标"),
    "travel": ("hotel", "train", "flight", "ticket", "travel", "酒店", "火车", "航班", "门票", "行程"),
    "commerce": ("commerce", "product", "restaurant", "cart", "商品", "餐厅", "购物车", "外卖"),
    "payment": ("payment", "账单", "款项", "支付方式"),
    "content": ("douyin", "bilibili", "xiaohongshu", "zhihu", "抖音", "b站", "小红书", "知乎"),
    "entertainment": ("music", "podcast", "音乐", "播客"),
    "app_control": ("app", "foreground", "应用", "前台"),
    "task": ("materials", "deliverables", "成果", "交付", "材料"),
}

NAME_OPERATION_ALIASES = {
    "query": "read", "read": "read", "search": "read", "fetch": "read",
    "list": "read", "inspect": "read", "status": "read", "get": "read",
    "lookup": "read", "resolve": "read", "freebusy": "availability",
    "availability": "availability", "create": "create", "add": "create",
    "write": "write", "append": "write", "update": "modify", "modify": "modify",
    "edit": "modify", "pause": "modify", "resume": "modify", "delete": "delete", "remove": "delete", "cancel": "delete",
    "send": "send", "forward": "send", "reply": "send", "notify": "send", "publish": "publish",
    "upload": "publish", "pay": "pay", "charge": "pay", "refund": "pay",
    "book": "book", "reserve": "book", "order": "book",
}

# Exact built-in capabilities whose operation cannot be inferred from the
# final noun token alone. Keep this table narrow; `completion` is not a
# globally reusable modify verb.
EXACT_OPERATION_OVERRIDES = {
    "reminder.set_completion": "modify",
    "location.current": "read",
}

# Exact built-in capability domains that must not inherit incidental nouns from
# their descriptions (for example "contact" methods being described as document
# fields or search/readback language).
EXACT_DOMAIN_OVERRIDES = {
    "contacts.query": ("device",),
    "contacts.create": ("device",),
    "contacts.update": ("device",),
}

READ_OPERATIONS = frozenset({"read", "availability"})
WRITE_OPERATIONS = frozenset({"create", "write", "modify", "delete", "send", "publish", "pay", "book"})
ALL_OPERATIONS = READ_OPERATIONS | WRITE_OPERATIONS

GOAL_OPERATION_TERMS = {
    "read": ("查询", "查看", "查一下", "查找", "读取", "读一下", "了解", "query", "read", "look up", "show me"),
    "availability": ("忙闲", "空闲", "有空", "有没有空", "freebusy", "free busy", "availability", "available"),
    "create": ("创建", "新建", "添加", "加入", "加到", "create", "add"),
    "write": ("写入", "保存", "write", "save"),
    "modify": (
        "修改", "更新", "编辑", "改动", "暂停", "恢复",
        "标记为完成", "标记完成", "完成这个提醒", "改回未完成", "恢复为未完成", "取消完成状态",
        "modify", "update", "edit", "pause", "resume",
    ),
    "delete": ("删除", "移除", "取消", "delete", "remove", "cancel"),
    "send": ("发送", "发给", "转发", "回复", "send", "forward", "reply"),
    "publish": ("发布", "导出", "publish", "export"),
    "pay": ("支付", "付款", "扣款", "退款", "pay", "payment", "charge", "refund"),
    "book": ("预订", "预定", "预约", "下单", "订票", "订酒店", "book", "reserve", "reservation", "order"),
}

NEGATION_MARKERS = (
    "不要", "不得", "禁止", "别", "不许", "不允许", "不能", "不可", "不可以",
    "do not", "don't", "must not", "never",
)
READ_ONLY_MARKERS = ("只读", "仅查询", "只查询", "仅查看", "只查看", "不要改动", "不要修改任何", "read only", "read-only")
ALLOW_MARKERS = ("可以", "允许", "准许", "can ", "may ", "allow ", "allowed to", "okay to", "ok to")
ALLOW_REVOCATION_MARKERS = ("放开", "解除限制", "取消限制", "撤销限制", "不再禁止", "恢复允许")

# Contrast conjunctions are semantic directive boundaries even when the user
# omits punctuation. Keep longer markers first and avoid splitting the common
# "不但..." construction at its 但 character.
_DIRECTIVE_SEPARATOR_RE = re.compile(
    r"[，,。；;\n]+|(?<!不)(?:但是|不过|然而|可是|但)|\b(?:but|however)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class CapabilitySemantics:
    operation: str
    effect: str
    domains: frozenset[str]
    operation_is_generic: bool = False


@dataclass(frozen=True)
class PolicyDirective:
    mode: str
    operations: frozenset[str]
    domains: frozenset[str]
    source_text: str
    families: frozenset[str] = frozenset()
    except_titles: frozenset[str] = frozenset()


@dataclass(frozen=True)
class CapabilityPolicyDecision:
    allowed: bool
    reason_code: Optional[str]
    operation: str
    domains: tuple[str, ...]
    detail: Optional[str] = None


def domains_for(spec: CapabilitySpec, registry: Optional[CapabilityRegistry] = None) -> List[str]:
    name = spec.name.lower()
    if name in EXACT_DOMAIN_OVERRIDES:
        return list(EXACT_DOMAIN_OVERRIDES[name])
    tags: Iterable[str] = ()
    metadata: Dict[str, Any] = {}
    if registry is not None and name in registry:
        entry = registry.get(name)
        tags = entry.tags
        metadata = entry.source.metadata
    explicit = metadata.get("domains", metadata.get("domain"))
    if isinstance(explicit, str) and explicit in DOMAIN_LABELS:
        return [explicit]
    if isinstance(explicit, (list, tuple)):
        values = [str(value) for value in explicit if str(value) in DOMAIN_LABELS]
        if values:
            return sorted(set(values))
    corpus = " ".join((name.replace(".", " "), spec.description[:500], *tags)).lower()
    domains = [domain for domain, terms in DOMAIN_TERMS.items() if any(term in corpus for term in terms)]
    return domains or ["work"]


def _entry_read_only(spec: CapabilitySpec, registry: Optional[CapabilityRegistry]) -> Optional[bool]:
    if registry is None or spec.name not in registry:
        return None
    entry = registry.get(spec.name)
    metadata = entry.source.metadata
    value = metadata.get("read_only")
    if isinstance(value, bool):
        return value
    effect = str(metadata.get("effect") or "").lower()
    if effect == "read":
        return True
    profile = getattr(entry.adapter, "execution_profile", None)
    if getattr(profile, "idempotency_mode", None) == "NATURAL_READ_ONLY":
        return True
    if effect in {"write", "side_effect", "local_file", "external_write"}:
        return False
    return None


def capability_semantics(spec: CapabilitySpec, registry: Optional[CapabilityRegistry] = None) -> CapabilitySemantics:
    operation: Optional[str] = None
    operation_is_generic = False
    if registry is not None and spec.name in registry:
        metadata = registry.get(spec.name).source.metadata
        explicit_operation = metadata.get("operation")
        if isinstance(explicit_operation, str) and explicit_operation in ALL_OPERATIONS:
            operation = explicit_operation
    if operation is None:
        operation = EXACT_OPERATION_OVERRIDES.get(spec.name.lower())
    if operation is None:
        parts = [part for part in re.split(r"[._:/-]+", spec.name.lower()) if part]
        for part in reversed(parts):
            operation = NAME_OPERATION_ALIASES.get(part)
            if operation is not None:
                break
    read_only = _entry_read_only(spec, registry)
    if operation is None:
        operation = "read" if read_only is True else "write" if read_only is False else "unknown"
        operation_is_generic = True
    effect = "read" if operation in READ_OPERATIONS or read_only is True else "write" if operation in WRITE_OPERATIONS or read_only is False else "unknown"
    return CapabilitySemantics(
        operation=operation,
        effect=effect,
        domains=frozenset(domains_for(spec, registry)),
        operation_is_generic=operation_is_generic,
    )


def operation_signals(text: str) -> set[str]:
    lowered = text.lower()
    return {operation for operation, terms in GOAL_OPERATION_TERMS.items() if any(term in lowered for term in terms)}


def _domains_in_text(text: str) -> frozenset[str]:
    lowered = text.lower()
    return frozenset(domain for domain, terms in POLICY_DOMAIN_TERMS.items() if any(term in lowered for term in terms))


def _is_allow_clause(clause: str) -> bool:
    lowered = clause.lower()
    revocation_present = any(marker in lowered for marker in ALLOW_REVOCATION_MARKERS)
    # Treat an exact revocation idiom (for example "不再禁止创建") as ALLOW,
    # but never let the revocation word hide a separate negation such as
    # "不要放开创建". Remove only the recognized idiom, then re-check deny.
    without_revocation = lowered
    for marker in ALLOW_REVOCATION_MARKERS:
        without_revocation = without_revocation.replace(marker, "")
    if any(marker in without_revocation for marker in NEGATION_MARKERS):
        return False
    if revocation_present:
        return True
    # A negated permission such as "不允许创建" is a deny, not an allow.
    if any(marker in lowered for marker in NEGATION_MARKERS):
        return False
    return any(marker in lowered for marker in ALLOW_MARKERS)


# Domains are discovery buckets, not entity authorization scopes. In
# particular, denying a calendar write must not deny an explicitly requested
# reminder write. Unknown/custom device families remain conservative.
NATIVE_FAMILY_TERMS = {
    "calendar": ("calendar", "日历", "日程"),
    "reminder": ("reminder", "提醒"),
    "alarm": ("alarm", "闹钟"),
    "contacts": ("contact", "联系人", "通讯录"),
    "notify": ("notify", "notification", "通知"),
    "location": ("location", "定位", "当前位置"),
}


def _families_in_text(text: str) -> frozenset[str]:
    lowered = text.lower()
    return frozenset(family for family, terms in NATIVE_FAMILY_TERMS.items()
                     if any(term in lowered for term in terms))


def _declared_create_titles(text: str) -> Dict[str, set[str]]:
    # Only a literal name in an affirmative user create clause is an authority
    # source. Pronouns in an exception cannot invent a new authorized object.
    result: Dict[str, set[str]] = {}
    for clause in re.split(r"[。；;\n]", text):
        if not any(word in clause for word in ("创建", "新建", "添加", "create ")):
            continue
        if any(marker in clause.lower() for marker in NEGATION_MARKERS):
            continue
        families = _families_in_text(clause)
        if len(families) != 1:
            continue
        names = re.findall(r'(?:标题(?:叫|为|是)?|名为|名叫|叫)\s*[：:]?\s*[“「\"]([^”」\"]{1,300})[”」\"]', clause)
        if names:
            result.setdefault(next(iter(families)), set()).update(names)
    return result


def directives_from_text(
    text: str, *, declared_titles: Optional[Dict[str, set[str]]] = None
) -> List[PolicyDirective]:
    directives: List[PolicyDirective] = []
    targets = declared_titles if declared_titles is not None else _declared_create_titles(text)
    for raw_clause in _DIRECTIVE_SEPARATOR_RE.split(text):
        clause = raw_clause.strip()
        if not clause:
            continue
        lowered = clause.lower()
        domains = _domains_in_text(clause)
        families = _families_in_text(clause)
        operations = operation_signals(clause)
        # "不要创建日历、闹钟或通知" also denies notification delivery,
        # whose semantic operation is send, not create.
        if "notify" in families:
            operations.add("send")
        if any(marker in lowered for marker in READ_ONLY_MARKERS):
            directives.append(PolicyDirective("DENY", WRITE_OPERATIONS, domains, clause, families))
            continue
        if not operations:
            continue
        if _is_allow_clause(clause):
            directives.append(PolicyDirective("ALLOW", frozenset(operations), domains, clause, families))
            continue
        if any(marker in lowered for marker in NEGATION_MARKERS):
            except_titles: frozenset[str] = frozenset()
            if ("create" in operations and len(families) == 1
                    and "除" in clause and ("以外" in clause or "之外" in clause)):
                family = next(iter(families))
                known = targets.get(family, set())
                literal = re.search(r'除\s*[“「\"]([^”」\"]+)[”」\"]', clause)
                if literal and literal.group(1) in known:
                    except_titles = frozenset({literal.group(1)})
                elif not literal and ("这条" in clause or "这一条" in clause) and len(known) == 1:
                    except_titles = frozenset(known)
            directives.append(PolicyDirective(
                "DENY", frozenset(operations), domains, clause, families, except_titles))
    return directives


def user_turn_texts(events: Sequence[Dict[str, Any]]) -> List[str]:
    result: List[str] = []
    for event in events:
        if str(event.get("event_type", "")).upper() != "USER_TURN":
            continue
        if str(event.get("status", "")).upper() == "IGNORED":
            continue
        payload = event.get("payload") or {}
        content = payload.get("content") if isinstance(payload, dict) else None
        text = content.get("text") if isinstance(content, dict) else content if isinstance(content, str) else None
        if isinstance(text, str) and text.strip():
            result.append(text.strip())
    return result


class EffectiveTaskCapabilityPolicy:
    def __init__(self, directives: Sequence[PolicyDirective]) -> None:
        self.directives = tuple(directives)

    @classmethod
    def from_texts(cls, texts: Sequence[str]) -> "EffectiveTaskCapabilityPolicy":
        directives: List[PolicyDirective] = []
        declared: Dict[str, set[str]] = {}
        for text in texts:
            if isinstance(text, str) and text.strip():
                for family, titles in _declared_create_titles(text).items():
                    declared.setdefault(family, set()).update(titles)
                directives.extend(directives_from_text(text, declared_titles=declared))
        return cls(directives)

    @classmethod
    def from_task(cls, task: Dict[str, Any], events: Sequence[Dict[str, Any]]) -> "EffectiveTaskCapabilityPolicy":
        return cls.from_texts([str(task.get("goal") or ""), *user_turn_texts(events)])

    def decide(
        self, spec: CapabilitySpec, registry: Optional[CapabilityRegistry] = None,
        *, arguments: Optional[Dict[str, Any]] = None,
        prior_created_titles: Sequence[str] = (),
    ) -> CapabilityPolicyDecision:
        semantics = capability_semantics(spec, registry)
        family = spec.name.split(".", 1)[0]
        if family not in NATIVE_FAMILY_TERMS:
            family = ""
        if semantics.operation_is_generic and semantics.effect != "read":
            target_operations: Sequence[str] = sorted(WRITE_OPERATIONS)
        else:
            target_operations = [semantics.operation]

        states: Dict[str, tuple[str, PolicyDirective]] = {}
        for directive in self.directives:
            if directive.domains and not (directive.domains & semantics.domains):
                continue
            if directive.families and family and family not in directive.families:
                continue
            for operation in target_operations:
                if operation in directive.operations:
                    mode = directive.mode
                    if operation == "create" and directive.except_titles and family in directive.families:
                        # Discovery may expose a constrained capability. Execution
                        # must provide the exact user-authorized name and cannot
                        # create a second object under a new Action identity.
                        if arguments is None:
                            mode = "ALLOW"
                        elif (arguments.get("title") in directive.except_titles
                              and arguments.get("title") not in prior_created_titles):
                            mode = "ALLOW"
                    states[operation] = (mode, directive)
        denied = [(operation, value[1]) for operation, value in states.items() if value[0] == "DENY"]
        if denied:
            operation, directive = denied[-1]
            scope = ",".join(sorted(directive.domains)) if directive.domains else "all"
            return CapabilityPolicyDecision(
                allowed=False,
                reason_code=TASK_DENIED,
                operation=semantics.operation,
                domains=tuple(sorted(semantics.domains)),
                detail=f"TASK_DENIED operation={operation} scope={scope}",
            )
        return CapabilityPolicyDecision(
            allowed=True,
            reason_code=None,
            operation=semantics.operation,
            domains=tuple(sorted(semantics.domains)),
        )

    def model_view(self) -> List[Dict[str, Any]]:
        return [{"mode": item.mode, "operations": sorted(item.operations),
                 "domains": sorted(item.domains), "families": sorted(item.families),
                 **({"except_exact_titles": sorted(item.except_titles), "max_creations_per_title": 1}
                    if item.except_titles else {})}
                for item in self.directives]

    def allows(self, spec: CapabilitySpec, registry: Optional[CapabilityRegistry] = None) -> bool:
        return self.decide(spec, registry).allowed

    def filter_specs(self, specs: Sequence[CapabilitySpec], registry: Optional[CapabilityRegistry] = None) -> List[CapabilitySpec]:
        return [spec for spec in specs if self.allows(spec, registry)]
