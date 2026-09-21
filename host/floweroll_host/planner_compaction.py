"""Deterministic, copy-only Planner projections; durable receipts are untouched.

Only retrieval/document bodies are shortened. Native receipts, target identity,
user constraints, dates, permission state and incomplete work remain authoritative.
"""
from __future__ import annotations

import copy
import json
from dataclasses import replace
from typing import Any

from .observation_projection import project_observations
from .planner_contracts import DecisionContext

_RETRIEVAL = {"web.search", "web.fetch", "docs.query", "docs.library.resolve",
              "document.docx.inspect", "materials.inspect"}
_TEXT_FIELDS = {"text", "body", "snippet", "markdown", "preview", "text_excerpts"}


def json_chars(value: Any) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def _clip_text(value: Any, allowance: list[int], omitted: list[str], path: str = "") -> Any:
    if isinstance(value, dict):
        output = {}
        for key, child in value.items():
            pointer = path + "/" + str(key).replace("~", "~0").replace("/", "~1")
            if key in _TEXT_FIELDS and isinstance(child, str):
                take = min(len(child), max(0, allowance[0]))
                output[key] = child[:take]
                allowance[0] -= take
                if take != len(child):
                    omitted.append(pointer)
            elif key == "text_excerpts" and isinstance(child, list):
                output[key] = []
                for index, text in enumerate(child):
                    if not isinstance(text, str):
                        output[key].append(copy.deepcopy(text))
                        continue
                    take = min(len(text), max(0, allowance[0]))
                    output[key].append(text[:take])
                    allowance[0] -= take
                    if take != len(text):
                        omitted.append(pointer + "/" + str(index))
            else:
                output[key] = _clip_text(child, allowance, omitted, pointer)
        return output
    if isinstance(value, list):
        return [_clip_text(child, allowance, omitted, path + "/" + str(index))
                for index, child in enumerate(value)]
    return copy.deepcopy(value)


_RECOVERY_SEARCH_FIELDS = {
    "query", "domain", "selected_capability_ids", "new_capability_ids",
    "total_candidates", "offset", "next_offset", "has_more", "repeated_page",
    "search_allowed", "searches_remaining", "reason_code",
}


def _search_projection(data: dict) -> dict:
    """Keep discovery progress, not verbose catalog prose already applied by selector."""
    return {key: copy.deepcopy(value) for key, value in data.items() if key in _RECOVERY_SEARCH_FIELDS}


def _hotel_search_projection(data: dict) -> dict:
    """Keep decision-grade hotel facts without replaying full provider cards every round."""
    items = data.get("items") if isinstance(data.get("items"), list) else []
    exact_prices = [
        float(item["price_amount"])
        for item in items
        if isinstance(item, dict)
        and item.get("price_exact") is True
        and isinstance(item.get("price_amount"), (int, float))
        and not isinstance(item.get("price_amount"), bool)
    ]

    # Preserve provider-ranked examples plus at least one POI-text match when available.
    representative: list[dict] = []
    candidates = [item for item in items if isinstance(item, dict) and item.get("provider_poi_text_match") is True]
    candidates.extend(item for item in items if isinstance(item, dict))
    seen: set[str] = set()
    for item in candidates:
        identity = str(item.get("provider_item_id") or item.get("name") or "")
        if identity in seen:
            continue
        seen.add(identity)
        representative.append({
            key: copy.deepcopy(item.get(key))
            for key in (
                "name", "price_amount", "price_raw", "star", "nearby",
                "provider_poi_text_match",
            )
            if item.get(key) is not None
        })
        if len(representative) >= 3:
            break

    output = {
        key: copy.deepcopy(data.get(key))
        for key in (
            "source_kind", "capability", "provider", "currency", "query",
            "item_count", "exact_price_count", "price_data_complete",
            "poi_filter_requested", "poi_filter_verified",
            "proximity_verification_required", "queried_at",
        )
        if data.get(key) is not None
    }
    if exact_prices:
        output["exact_price_range"] = {
            "min": min(exact_prices),
            "max": max(exact_prices),
            "currency": data.get("currency"),
        }
    output["representative_items"] = representative
    output["planner_notice"] = (
        "完整酒店候选仍保存在 durable receipt；这里保留区域、价格范围、代表项和 POI 匹配可信度。"
        "poi_filter_verified=false 时不能宣称所有候选都真实邻近请求 POI。"
    )
    return output


def _weather_projection(data: dict) -> dict | None:
    structured = data.get("structured_content")
    if (not isinstance(structured, dict)
            or not isinstance(structured.get("city"), str)
            or not isinstance(structured.get("forecasts"), list)):
        return None
    forecasts = structured.get("forecasts")
    compact_forecasts = []
    for forecast in forecasts[:7]:
        if not isinstance(forecast, dict):
            continue
        compact_forecasts.append({
            key: copy.deepcopy(forecast.get(key))
            for key in (
                "date", "dayweather", "nightweather", "daytemp", "nighttemp",
                "daywind", "nightwind", "daypower", "nightpower",
            )
            if forecast.get(key) is not None
        })
    output = {
        "source_kind": data.get("source_kind"),
        "server_id": data.get("server_id"),
        "tool_name": data.get("tool_name"),
        "structured_content": {
            "city": structured.get("city"),
            "forecasts": compact_forecasts,
        },
        "planner_projection": "weather_core_forecast",
    }
    if data.get("truncated") is not None:
        output["truncated"] = copy.deepcopy(data.get("truncated"))
    content = data.get("content")
    if isinstance(content, list):
        kept = []
        for block in content:
            redundant = False
            if (isinstance(block, dict) and block.get("type") == "text"
                    and set(block).issubset({"type", "text"})):
                try:
                    redundant = json.loads(block.get("text", "")) == structured
                except (ValueError, TypeError):
                    pass
            if not redundant:
                kept.append(copy.deepcopy(block))
        if kept:
            output["content"] = kept
    return output


def _memory_projection(items: Any) -> Any:
    if not isinstance(items, list):
        return copy.deepcopy(items)
    ranked = [item for item in items if isinstance(item, dict)]
    ranked.sort(
        key=lambda item: float(item.get("score")) if isinstance(item.get("score"), (int, float)) else -1.0,
        reverse=True,
    )
    output = []
    for item in ranked[:3]:
        memory = item.get("memory")
        projected = {}
        if memory is not None:
            projected["memory"] = memory[:260] if isinstance(memory, str) else copy.deepcopy(memory)
        for key in ("memory_id", "score", "categories"):
            if item.get(key) is not None:
                projected[key] = copy.deepcopy(item.get(key))
        output.append(projected)
    return output


def _recovery_docx_projection(data: dict) -> dict:
    """Keep exact document identity + bounded semantic evidence for retry planning."""
    output = copy.deepcopy(data)
    readback = output.get("readback")
    if not isinstance(readback, dict):
        return output
    package = readback.get("package") if isinstance(readback.get("package"), dict) else {}
    features = readback.get("features") if isinstance(readback.get("features"), dict) else {}
    compact_readback = {
        "format_profile": readback.get("format_profile"),
        "semantic_fingerprint": readback.get("semantic_fingerprint"),
        "text_sha256": readback.get("text_sha256"),
        "truncated": readback.get("truncated"),
        "paragraph_count": readback.get("paragraph_count"),
        "paragraphs_truncated": readback.get("paragraphs_truncated"),
        "structure": copy.deepcopy(readback.get("structure")),
        "warnings": copy.deepcopy(readback.get("warnings")),
        "features": {
            "detected": copy.deepcopy(features.get("detected")),
            "unsupported_detected": copy.deepcopy(features.get("unsupported_detected")),
        },
        "package": {
            "format": package.get("format"),
            "main_part": package.get("main_part"),
            "package_verified": package.get("package_verified"),
        },
        "text": readback.get("text"),
        "text_offset": readback.get("text_offset"),
        "total_chars": readback.get("total_chars"),
        "next_text_offset": readback.get("next_text_offset"),
        "planner_projection": "recovery_identity_plus_bounded_text",
    }
    output["readback"] = {k: v for k, v in compact_readback.items() if v is not None}
    return output


def project_evidence(observations: list[dict], *, recovery: bool = False) -> list[dict]:
    """Keep identity-bearing objects; never slice serialized JSON into a preview."""
    rows = project_observations(observations, per_retrieval_chars=1800 if recovery else 5000)
    child_receipts = {
        row.get("observation_id") or row.get("action_id")
        for row in rows if row.get("parent_action_id") and row.get("work_unit_id")
    }
    immutable_windows: dict[tuple, str] = {}
    for row in rows:
        data = row.get("data")
        if not isinstance(data, dict):
            continue
        capability = row.get("capability")
        readback = data.get("readback")
        if (capability == "document.docx.inspect" and data.get("file_id") and data.get("sha256")
                and isinstance(readback, dict)):
            key = (data["file_id"], data["sha256"], readback.get("text_offset", 0),
                   len(readback.get("text", "")), readback.get("semantic_fingerprint"))
            identity = str(row.get("observation_id") or row.get("action_id") or "")
            if key in immutable_windows:
                row["data"] = {
                    "file_id": data["file_id"], "sha256": data["sha256"],
                    "duplicate_of_observation_id": immutable_windows[key],
                    "notice": "同一不可变文件的相同已验证读取窗口；正文在引用的回执中，不要再执行同一读取。",
                }
                continue
            immutable_windows[key] = identity
        if capability == "capability.search":
            row["data"] = _search_projection(data)
            continue
        if capability == "travel.hotel.search":
            row["data"] = _hotel_search_projection(data)
            continue
        if capability == "weather.query":
            weather = _weather_projection(data)
            if weather is not None:
                row["data"] = weather
                continue
        if recovery and capability == "document.docx.inspect":
            data = _recovery_docx_projection(data)
            row["data"] = data
        # Only remove a redundant text transport envelope when JSON equality
        # proves it is the SAME object. Extra provider warnings stay visible.
        structured = data.get("structured_content")
        content = data.get("content")
        if structured is not None and isinstance(content, list):
            kept = []
            for block in content:
                redundant = False
                if (isinstance(block, dict) and block.get("type") == "text"
                        and set(block).issubset({"type", "text"})):
                    try:
                        redundant = json.loads(block.get("text", "")) == structured
                    except (ValueError, TypeError):
                        pass
                if not redundant:
                    kept.append(block)
            if kept:
                data["content"] = kept
            else:
                data.pop("content", None)
        if capability == "work.execute" and isinstance(data.get("units"), list):
            # A parent summary is not a substitute for missing child receipts.
            # Failed, blocked and pending units are NEVER removed.
            detailed = [unit for unit in data["units"] if not (
                unit.get("state") == "completed" and unit.get("receipt_id") in child_receipts)]
            if len(detailed) != len(data["units"]):
                data["child_receipts_in_context"] = [unit["receipt_id"] for unit in data["units"]
                                                     if unit.get("receipt_id") in child_receipts]
                data["units"] = detailed
        if capability == "document.docx.inspect":
            readback = data.get("readback")
            if isinstance(readback, dict) and isinstance(readback.get("text"), str):
                # Paragraph strings repeat the core text. Keep counts, features,
                # unsupported structures, warnings, hashes and original truncation.
                readback.pop("paragraphs", None)
                readback["planner_projection"] = "core_text_with_structure_and_warnings"
        if capability in _RETRIEVAL:
            omitted: list[str] = []
            recovery_allowance = 900 if capability == "document.docx.inspect" else 1400
            data = _clip_text(data, [recovery_allowance if recovery else 12000], omitted)
            if omitted:
                data["planner_text_truncated"] = True
                data["truncated"] = True
                data["planner_omitted_text_paths"] = omitted
                data["planner_notice"] = (
                    "这是有界原文片段，不是完整资料；不得宣称完整解析/全文结论。"
                    "完整回执仍在本任务存储；需要细节时按 file_id 或来源 URL 重新限定读取。"
                )
            if capability == "document.docx.inspect" and isinstance(data.get("readback"), dict):
                visible = data["readback"]
                start = visible.get("text_offset", 0)
                total = visible.get("total_chars")
                end = start + len(visible.get("text", ""))
                if isinstance(total, int) and end < total and data.get("file_id"):
                    data["planner_next_read"] = {
                        "file_id": data["file_id"], "text_offset": end, "max_chars": 8000,
                    }
                    data["planner_read_notice"] = (
                        "需要更多正文时使用 planner_next_read，从本次模型可见窗口末尾继续；"
                        "不要重复 text_offset 相同的 inspect，也不要跳过被提示压缩隐藏的正文。"
                    )
            row["data"] = data
    return rows


def compact_context(context: DecisionContext, *, recovery: bool = False) -> tuple[DecisionContext, dict]:
    """Project only copies; preserve policy and all explicit Task input verbatim."""
    before = json_chars(context.model_view())
    observations = project_evidence(context.verified_observations, recovery=recovery)
    runtime = copy.deepcopy(context.runtime_context)

    discovery_rows = [row for row in observations if row.get("capability") == "capability.search"]
    completed_batch_count = 0
    kept_observations = []
    for row in observations:
        data = row.get("data") if isinstance(row.get("data"), dict) else {}
        if (row.get("capability") == "work.execute"
                and data.get("all_completed") is True
                and data.get("units") == []
                and data.get("completed") == data.get("total")):
            completed_batch_count += 1
            continue
        kept_observations.append(row)
    observations = kept_observations
    if completed_batch_count:
        runtime["completed_work_batch_count"] = completed_batch_count

    if discovery_rows:
        selected_ids: list[str] = []
        recent = []
        for row in discovery_rows:
            data = row.get("data") if isinstance(row.get("data"), dict) else {}
            for capability_id in data.get("new_capability_ids", []) or []:
                if isinstance(capability_id, str) and capability_id not in selected_ids:
                    selected_ids.append(capability_id)
            recent.append({
                key: copy.deepcopy(data.get(key))
                for key in ("query", "domain", "offset", "next_offset", "has_more", "repeated_page")
                if data.get(key) is not None
            })
        runtime["capability_discovery_evidence"] = {
            "attempt_count": len(discovery_rows),
            "recent_searches": recent[-4:],
            "instruction": (
                "能力选择节点已消费完整 discovery 回执。模型不要重复相同关键词/页码；"
                "若 recent_searches 已多次无目标能力，改用已暴露的通用能力或明确说明能力缺口。"
            ),
        }
        observations = [row for row in observations if row.get("capability") != "capability.search"]

    if "relevant_memories" in runtime:
        runtime["relevant_memories"] = _memory_projection(runtime.get("relevant_memories"))

    reads = [row for row in observations if row.get("capability") in _RETRIEVAL]
    if reads:
        runtime["retrieval_progress"] = {
            "verified_read_count": len(reads),
            "recent_reads": [{"observation_id": row.get("observation_id"),
                              "capability": row.get("capability"),
                              "arguments": copy.deepcopy(row.get("arguments", {}))}
                             for row in reads[-6:]],
            "instruction": (
                "先复用已验证回执中的真实正文和数值。片段不是空结果，也不是完整/实时来源。"
                "只补读明确缺项；对不可变文件使用 planner_next_read 游标。"
                "连续同义搜索没有新信息时换来源或完成其他子目标，并明确披露不确定性。"
            ),
        }
    materials = runtime.get("task_materials")
    if isinstance(materials, dict):
        # Raw input SHA/name/MIME, outputs, plan and work_summary are retained.
        # Work-unit summaries repeat verified evidence; retain unfinished entries.
        units = materials.get("work_units")
        if isinstance(units, list):
            available = {row.get("work_unit_id") for row in observations}
            materials["work_units"] = [unit for unit in units
                                       if unit.get("state") != "completed" or unit.get("id") not in available]
    # Full discovery history is durable. Model-visible catalog carries the recent
    # pages; keep only the authoritative budget knobs here instead of a second copy.
    discovery = runtime.get("capability_discovery_state")
    if isinstance(discovery, dict):
        runtime["capability_discovery_state"] = {k: copy.deepcopy(v) for k, v in discovery.items()
                                                if k not in {"pages", "seen_ids"}}
    if recovery:
        # Capability selection already ran before recovery compaction. Repeating
        # the verbose catalog here adds no authority and was a major source of
        # oversized retry prompts on long historical tasks.
        runtime.pop("capability_catalog", None)
        runtime["planner_recovery"] = {
            "mode": "compact_after_transient_failure",
            "instruction": "上次模型请求临时失败。已有业务回执仍有效，不重做已成功操作。先选择下一项可推进工作；资料片段不得当全文，缺项不得伪称完成。",
        }
    compacted = replace(context, verified_observations=observations, runtime_context=runtime)
    metrics = {
        "context_chars_before_compaction": before,
        "context_chars_after_compaction": json_chars(compacted.model_view()),
        "recovery_context": recovery,
    }
    return compacted, metrics
