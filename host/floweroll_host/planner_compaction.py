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
    "has_more", "repeated_page", "search_allowed", "searches_remaining",
}


def _recovery_search_projection(data: dict) -> dict:
    """Keep discovery identity, not verbose catalog prose already applied by selector."""
    return {key: copy.deepcopy(value) for key, value in data.items() if key in _RECOVERY_SEARCH_FIELDS}


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
    for row in rows:
        data = row.get("data")
        if not isinstance(data, dict):
            continue
        capability = row.get("capability")
        if recovery and capability == "capability.search":
            row["data"] = _recovery_search_projection(data)
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
            row["data"] = data
    return rows


def compact_context(context: DecisionContext, *, recovery: bool = False) -> tuple[DecisionContext, dict]:
    """Project only copies; preserve policy and all explicit Task input verbatim."""
    before = json_chars(context.model_view())
    observations = project_evidence(context.verified_observations, recovery=recovery)
    runtime = copy.deepcopy(context.runtime_context)
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
