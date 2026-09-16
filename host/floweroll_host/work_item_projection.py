"""Outcome-aware work-item projection over the existing durable Runtime.

No second execution state machine or shadow Task is created here. Plans live in
TaskAssetStore, actions/verification live in Runtime, files remain immutable.
This is NOT a general same-Task parallel scheduler.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import replace
from datetime import datetime
from typing import Any, Dict, List, Optional
from zoneinfo import ZoneInfo

from .planner_contracts import PlannerDecision

COMPLETION_RULES = {"document", "draft", "reservation", "payment", "email_sent", "calendar_event", "reminder", "alarm"}
STATE_LABELS = {
    "pending": "待处理", "running": "正在处理", "completed": "已完成",
    "needs_input": "需要补充信息", "needs_review": "待核对草稿",
    "handoff_required": "需要你继续", "blocked": "等待相关事项", "failed": "需要重试",
    "waiting_approval": "需要你确认", "cancelled": "已停止",
}
# Only real, already-defined adapter verification contracts are enabled.
# Future booking/payment/email adapters must add their own verified receipt
# contract. A file/link/untyped success can NEVER satisfy those outcomes.
_VERIFIED_NATIVE = {"reminder": ("reminder.create", "reminder_id"), "alarm": ("alarm.create", "alarm_id"),
                    "calendar_event": ("calendar.create", "event_id")}


def verifies_effect(rule: str, observation: Dict[str, Any]) -> bool:
    contract = _VERIFIED_NATIVE.get(rule)
    if contract is None:
        return False
    capability, identifier = contract
    data = observation.get("data", {})
    return observation.get("capability") == capability and isinstance(data.get(identifier), str) and bool(data[identifier].strip())


def project_work_items(plan: Optional[Dict[str, Any]], outputs: List[Dict[str, Any]],
                       observations: List[Dict[str, Any]], *, open_action: Optional[Dict[str, Any]] = None,
                       failure_action: Optional[Dict[str, Any]] = None,
                       item_actions: Optional[Dict[str, Dict[str, Any]]] = None) -> Dict[str, Any]:
    if not plan:
        return {"items": [], "total": 0, "completed": 0, "state": "unplanned", "ready_item_ids": [],
                "all_required_completed": False, "strict_unfinished_ids": []}
    by_action = {row["action_id"]: row for row in observations if row.get("action_id")}
    items: List[Dict[str, Any]] = []
    for item in plan["items"]:
        iid = item["id"]
        rule = item.get("completion_rule", "document")
        artifacts = [out for out in outputs if out.get("metadata", {}).get("item_id") == iid]
        latest = artifacts[-1] if artifacts else None
        meta = latest.get("metadata", {}) if latest else {}
        state, reason = "pending", None
        result_summary = None
        evidence_actions: List[str] = []
        if latest:
            status = meta.get("status", "ready")
            if rule in {"document", "draft"}:
                if status == "ready" or (rule == "draft" and status == "draft"):
                    state = "completed"
                    evidence_actions = [meta["action_id"]] if meta.get("action_id") else []
                elif status == "needs_input": state = "needs_input"
                elif status == "handoff_required": state = "handoff_required"
                else: state = "needs_review"
            else:
                state = "needs_input" if meta.get("missing_information") else "handoff_required"
                reason = "准备资料已保留，这项操作还未完成。"
        for row in observations:
            if rule == "calendar_event" and verifies_effect(rule, row) and row.get("data", {}).get("item_id") == iid:
                state, reason = "completed", None
                evidence_actions = [row["action_id"]]
                data = row["data"]
                start = datetime.fromisoformat(data["start_at"].replace("Z", "+00:00")).astimezone(ZoneInfo(data["time_zone"]))
                end = datetime.fromisoformat(data["end_at"].replace("Z", "+00:00")).astimezone(ZoneInfo(data["time_zone"]))
                result_summary = f"{data['title']} · {start:%Y年%m月%d日 %H:%M} → {end:%m月%d日 %H:%M} · {('北京时间' if data['time_zone'] == 'Asia/Shanghai' else data['time_zone'])} · {data['calendar_name']}"
                if data.get("location"):
                    result_summary += " · " + data["location"]
            if row.get("capability") != "deliverables.verify": continue
            data = row.get("data", {})
            evidence = by_action.get(data.get("evidence_action_id"), {})
            if (data.get("item_id") == iid and data.get("completion_rule") == rule and verifies_effect(rule, evidence)
                    and (rule != "calendar_event" or evidence.get("data", {}).get("item_id") == iid)):
                state, reason = "completed", None
                evidence_actions = [evidence["action_id"]]
        action = (item_actions or {}).get(iid)
        if open_action and open_action.get("payload", {}).get("item_id") == iid:
            action = action or open_action
        if action and action.get("waiting_input"):
            state, reason = "waiting_approval", "确认后继续，已完成的成果会保留。"
        elif action and action.get("status", "executing").lower() in {"dispatched", "executing", "verifying", "reconciling"}:
            state = "running"
            reason = "正在核对执行结果。" if action.get("status") in {"verifying", "reconciling"} else None
        elif action and action.get("status", "").lower() in {"failed", "cancelled", "retry_wait"} and state != "completed":
            status = action["status"].lower()
            state = "pending" if status == "retry_wait" else status
            reason = "正在等待重试。" if status == "retry_wait" else "上次处理未完成，已有成果会保留。"
        elif action and action.get("status") == "blocked" and state != "completed":
            state, reason = "blocked", "等待相关事项恢复。"
        elif failure_action and failure_action.get("payload", {}).get("item_id") == iid and state != "completed":
            state = "failed"
            reason = str(failure_action.get("error") or failure_action.get("error_text") or "上次尝试未完成，需要修正后继续。")[:400]
        if rule not in {"document", "draft"} and state == "pending":
            reason = "准备就绪后继续完成这项操作。"
        items.append({
            "id": iid, "title": item["title"], "depends_on": list(item.get("depends_on", [])),
            "completion_rule": rule, "strict_completion": "completion_rule" in item,
            "state": state, "label": STATE_LABELS[state], "reason": reason,
            "result_summary": result_summary,
            "file_ids": [out["id"] for out in artifacts], "evidence_action_ids": evidence_actions,
            "missing_information": [str(x)[:200] for x in meta.get("missing_information", [])[:12]],
        })
    # Fixed point handles reverse-order DAGs. A file can exist while its work
    # item still cannot be considered complete due to a missing prerequisite.
    by_id = {item["id"]: item for item in items}
    for item in items:
        if item['completion_rule'] not in {'document', 'draft'} and item['state'] in {'pending', 'handoff_required'}:
            missing = list(dict.fromkeys([*item['missing_information'],
                *(text for dep in item['depends_on'] for text in by_id.get(dep, {}).get('missing_information', []))]))[:12]
            if missing:
                item.update(state='needs_input', label=STATE_LABELS['needs_input'], missing_information=missing,
                            reason='准备资料已保留，实际操作仍需这些信息。')
    for _ in items:
        changed = False
        for item in items:
            unmet = [dep for dep in item["depends_on"] if by_id.get(dep, {}).get("state") != "completed"]
            if unmet and item["state"] in {"pending", "completed"}:
                item.update(state="blocked", label=STATE_LABELS["blocked"], reason="等待：" + "、".join(by_id[d]["title"] for d in unmet if d in by_id))
                changed = True
        if not changed: break
    done = sum(item["state"] == "completed" for item in items)
    ready = [item["id"] for item in items if item["state"] in {"pending", "failed"} and
             all(by_id.get(dep, {}).get("state") == "completed" for dep in item["depends_on"])]
    strict_unfinished = [item["id"] for item in items if item["strict_completion"] and item["state"] != "completed"]
    state = "completed" if done == len(items) else (
        "running" if any(item["state"] == "running" for item in items) else
        "needs_user" if any(item["state"] in {"needs_input", "needs_review", "handoff_required", "waiting_approval"} for item in items) else "in_progress")
    result = {"items": items, "total": len(items), "completed": done, "state": state,
              "ready_item_ids": ready, "all_required_completed": done == len(items),
              "strict_unfinished_ids": strict_unfinished,
              "progress_kind": "verified_work_items_not_elapsed_time"}
    result["revision"] = hashlib.sha256(json.dumps(result, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:20]
    return result


def guard_completion(decision: PlannerDecision, *, summary: Dict[str, Any],
                     observations: List[Dict[str, Any]], pending_clarification: Optional[Dict[str, Any]],
                     available_names: set[str]) -> PlannerDecision:
    """Fail closed on premature COMPLETE for explicit outcome plans.

    First surface deterministic unfinished state through a normal read Action;
    never repeatedly ask permission for safe work. If user-only information or
    an external handoff is all that remains, expose one durable clarification.
    Legacy plans without explicit completion contracts keep existing behavior.
    """
    if (decision.decision_type == "EXECUTE" and decision.on_verified == "COMPLETE"
            and summary.get("strict_unfinished_ids")):
        # One successful Action must not silently close a multi-outcome Task.
        return replace(decision, on_verified="REPLAN")
    if decision.decision_type != "COMPLETE" or not summary.get("strict_unfinished_ids"):
        return decision
    unfinished = [item for item in summary["items"] if item["id"] in summary["strict_unfinished_ids"]]
    common = dict(action=None, on_verified=None, completion=None, wait=None, clarification=None,
                  stop_reason=None, cancellation=None)
    runnable = set(summary["ready_item_ids"]) & {item["id"] for item in unfinished}
    if runnable and "deliverables.status" in available_names:
        previous = next((row for row in reversed(observations) if row.get("capability") == "deliverables.status"), None)
        if previous is None or previous.get("data", {}).get("revision") != summary.get("revision"):
            return replace(decision, **{**common, "decision_type": "EXECUTE", "action": {
                "capability": "deliverables.status", "arguments": {}}, "on_verified": "REPLAN",
                "interpreted_goal_summary": "检查尚未完成的交付项并继续处理"})
        # A planner repeatedly claiming COMPLETE despite identical evidence must
        # not cause an infinite polling loop or a fake successful Task.
        return replace(decision, **{**common, "decision_type": "STOP",
            "stop_reason": "还有未完成事项：" + "、".join(item["title"] for item in unfinished) + "。已生成的结果已保留，可以从未完成事项继续。"})
    if pending_clarification:
        return replace(decision, **{**common, "decision_type": "WAIT",
            "wait": {"kind": "user_input", "resume_at": None, "condition": None},
            "state_update": {**(decision.state_update or {}), "pending_clarification": "KEEP"}})
    missing = list(dict.fromkeys(text for item in unfinished for text in item["missing_information"]))[:8]
    names = "、".join(item["title"] for item in unfinished)
    detail = "还需要补充：" + "；".join(missing) if missing else "这些事项尚未确认完成，需要继续操作或调整要求。"
    question = f"已完成 {summary['completed']}/{summary['total']} 项。{names}尚未完成。{detail}"
    return replace(decision, **{**common, "decision_type": "CLARIFY",
        "clarification": {"question": question[:1000], "suggested_options": [], "accepts_text": True,
                          "reason": "unfinished_deliverables"},
        "state_update": {**(decision.state_update or {}), "pending_clarification": None}})
