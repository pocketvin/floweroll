"""Copy-only, idempotent projections of durable retrieval evidence.

ContextBuilder and Planner compaction both call this function. A projection is
an input format in its own right: projecting it again must never discard its
body, provenance, or original truncation warning.
"""
from __future__ import annotations

import copy
import json
import re
from typing import Any, Dict, List
from urllib.parse import urlsplit

_RETRIEVAL = {"web.search", "web.fetch", "docs.query", "docs.library.resolve"}
_PROJECTION = "retrieval_evidence_v2"
_TEXT_KEYS = {"text", "body", "snippet", "description", "title", "content",
              "markdown", "preview", "highlights", "text_excerpts"}
_URL_RE = re.compile(r'https?://[^\s<>"\\\)]+')
_SOURCE_SEPARATOR = re.compile(r"\n\s*---\s*\n(?=\s*(?:Title:|URL:))")


def _source_texts(value: Any) -> list[str]:
    """Walk structured MCP results as well as text envelopes and old projections."""
    texts: list[str] = []

    def collect(item: Any, key: str = "", depth: int = 0) -> None:
        if depth > 20 or len(texts) >= 40:
            return
        if isinstance(item, dict):
            # Object-level source identity stays next to its actual text.
            source = item.get("url")
            body = item.get("text") or item.get("body") or item.get("snippet")
            if isinstance(source, str) and isinstance(body, str):
                title = item.get("title")
                text = (f"Title: {title}\n" if isinstance(title, str) else "")
                text += f"URL: {source}\n{body}"
                texts.extend(part.strip() for part in _SOURCE_SEPARATOR.split(text) if part.strip())
                return
            for child_key, child in item.items():
                if isinstance(child, (dict, list)) or child_key in _TEXT_KEYS:
                    collect(child, child_key, depth + 1)
        elif isinstance(item, list):
            for child in item[:40]:
                collect(child, key, depth + 1)
        elif isinstance(item, str) and key in _TEXT_KEYS and item.strip():
            texts.extend(part.strip() for part in _SOURCE_SEPARATOR.split(item) if part.strip())

    collect(value)
    return list(dict.fromkeys(texts))[:20]


def _balanced_excerpts(texts: list[str], budget: int) -> list[str]:
    """Distribute the text budget across sources, rather than only source #1."""
    if not texts or budget <= 0:
        return []
    texts = texts[:min(20, max(1, budget // 160))]
    lengths = [0] * len(texts)
    remaining = budget
    pending = list(range(len(texts)))
    while remaining and pending:
        share = max(1, remaining // len(pending))
        for index in pending:
            take = min(share, len(texts[index]) - lengths[index], remaining)
            lengths[index] += take
            remaining -= take
        pending = [i for i in pending if lengths[i] < len(texts[i])]
    return [text[:length] for text, length in zip(texts, lengths) if length]


def project_observations(
    observations: List[Dict[str, Any]], per_retrieval_chars: int = 5000
) -> List[Dict[str, Any]]:
    if per_retrieval_chars < 1:
        raise ValueError("per_retrieval_chars must be positive")
    projected = []
    for original in observations:
        row = copy.deepcopy(original)
        data = row.get("data", {})
        if row.get("capability") == "capability.search" and isinstance(data, dict):
            row["data"] = {k: data[k] for k in (
                "query", "domain", "selected_capability_ids", "new_capability_ids",
                "total_candidates", "offset", "next_offset", "has_more", "notice",
                "repeated_page", "search_allowed", "searches_remaining", "reason_code") if k in data}
            projected.append(row)
            continue
        if row.get("capability") not in _RETRIEVAL or not isinstance(data, dict):
            projected.append(row)
            continue
        prior_budget = data.get("projection_text_budget")
        if (data.get("planner_projection") == _PROJECTION
                and isinstance(prior_budget, int) and prior_budget <= per_retrieval_chars):
            projected.append(row)
            continue
        encoded = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        if len(encoded) <= per_retrieval_chars:
            projected.append(row)
            continue
        urls = []
        for candidate in _URL_RE.findall(encoded):
            url = candidate.rstrip(".,;")
            try:
                parsed = urlsplit(url)
            except ValueError:
                continue
            if parsed.hostname and not parsed.username and url not in urls and len(url) < 600:
                urls.append(url)
        texts = _source_texts(data)
        row["data"] = {
            "source_kind": data.get("source_kind"),
            "server_id": data.get("server_id"),
            "tool_name": data.get("tool_name"),
            "retrieved_urls": urls[:10],
            "text_excerpts": _balanced_excerpts(texts, per_retrieval_chars),
            "truncated": True,
            "original_char_count": data.get("original_char_count", len(encoded)),
            "planner_projection": _PROJECTION,
            "projection_text_budget": per_retrieval_chars,
            "notice": (
                "以下为各来源的真实正文片段，不只是网址；可引用其中与任务相关的事实，"
                "但片段不代表全文，也不保证来源信息实时有效。先利用已有证据推进；"
                "只有明确缺项时才按来源URL补读，不要重复同义搜索。完整回执保存在本任务Observation。"
            ),
        }
        projected.append(row)
    return projected
