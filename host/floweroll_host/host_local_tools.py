from __future__ import annotations

import csv
import hashlib
import html
import json
import os
import re
import statistics
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .function_execution_worker import FunctionExecutor, FunctionToolError
from .function_tool_adapter import FunctionToolAdapter
from .planner_contracts import CapabilitySpec


_DEFAULT_MAX_CHARS = 20_000
_HARD_MAX_CHARS = 80_000
_MAX_ANALYSIS_ROWS = 5_000


class _HTMLTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: List[str] = []
        self._hidden_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag.lower() in {"script", "style", "noscript"}:
            self._hidden_depth += 1
        elif tag.lower() in {"p", "br", "li", "div", "section", "article", "tr", "h1", "h2", "h3", "h4"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"script", "style", "noscript"} and self._hidden_depth:
            self._hidden_depth -= 1
        elif tag.lower() in {"p", "li", "div", "section", "article", "tr", "h1", "h2", "h3", "h4"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._hidden_depth == 0:
            self.parts.append(data)

    def text(self) -> str:
        value = html.unescape("".join(self.parts))
        value = re.sub(r"[ \t]+", " ", value)
        value = re.sub(r"\n\s*\n\s*\n+", "\n\n", value)
        return value.strip()


class HostWorkspace:
    """Bounded Mac Host workspace for Planner-visible local capabilities."""

    def __init__(self, root: Path) -> None:
        self.root = root.expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def resolve(self, raw_path: str, *, must_exist: bool = False) -> Path:
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise FunctionToolError("path must be a non-empty relative path", error_kind="model_correctable")
        requested = Path(raw_path.strip())
        if requested.is_absolute():
            raise FunctionToolError("absolute paths are not allowed", error_kind="model_correctable")
        resolved = (self.root / requested).resolve()
        try:
            resolved.relative_to(self.root)
        except ValueError as exc:
            raise FunctionToolError("path escapes the Host workspace", error_kind="model_correctable") from exc
        if must_exist and not resolved.exists():
            raise FunctionToolError(
                f"workspace path does not exist: {raw_path}",
                error_kind="model_correctable",
            )
        return resolved

    def relative(self, path: Path) -> str:
        return str(path.resolve().relative_to(self.root))


class HostLocalToolSet:
    def __init__(self, root: Path) -> None:
        self.workspace = HostWorkspace(root)

    def file_list(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        path = self.workspace.resolve(arguments.get("path", "."), must_exist=True)
        if not path.is_dir():
            raise FunctionToolError("file.list path must be a directory", error_kind="model_correctable")
        recursive = bool(arguments.get("recursive", False))
        limit = _bounded_int(arguments.get("limit"), default=100, minimum=1, maximum=500)
        iterator: Iterable[Path] = path.rglob("*") if recursive else path.iterdir()
        items: List[Dict[str, Any]] = []
        for entry in sorted(iterator, key=lambda item: str(item).lower()):
            if len(items) >= limit:
                break
            try:
                stat = entry.stat()
            except OSError:
                continue
            items.append(
                {
                    "path": self.workspace.relative(entry),
                    "kind": "directory" if entry.is_dir() else "file",
                    "size_bytes": stat.st_size if entry.is_file() else None,
                }
            )
        return {
            "root": self.workspace.relative(path) if path != self.workspace.root else ".",
            "items": items,
            "truncated": len(items) >= limit,
            "_completion_summary": f"已列出工作区中的 {len(items)} 个项目。",
        }

    def file_read(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        path = self.workspace.resolve(arguments["path"], must_exist=True)
        if not path.is_file():
            raise FunctionToolError("file.read path must be a file", error_kind="model_correctable")
        max_chars = _bounded_int(
            arguments.get("max_chars"),
            default=_DEFAULT_MAX_CHARS,
            minimum=256,
            maximum=_HARD_MAX_CHARS,
        )
        raw = path.read_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise FunctionToolError(
                "file.read supports UTF-8 text; use document.parse for supported structured files",
                error_kind="model_correctable",
            ) from exc
        content = text[:max_chars]
        return {
            "path": self.workspace.relative(path),
            "size_bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "content": content,
            "truncated": len(text) > max_chars,
            "_completion_summary": f"已读取 {self.workspace.relative(path)}。",
        }

    def write_text(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        path = self.workspace.resolve(arguments["path"])
        content = arguments["content"]
        if not isinstance(content, str):
            raise FunctionToolError("content must be text", error_kind="model_correctable")
        overwrite = bool(arguments.get("overwrite", False))
        encoded = content.encode("utf-8")
        expected_sha = hashlib.sha256(encoded).hexdigest()
        if path.exists():
            if not path.is_file():
                raise FunctionToolError("target exists and is not a file", error_kind="model_correctable")
            existing = path.read_bytes()
            if hashlib.sha256(existing).hexdigest() == expected_sha:
                return {
                    "path": self.workspace.relative(path),
                    "size_bytes": len(existing),
                    "sha256": expected_sha,
                    "verified": True,
                    "idempotent_replay": True,
                    "_completion_summary": f"文件 {self.workspace.relative(path)} 已存在且内容一致。",
                }
            if not overwrite:
                raise FunctionToolError(
                    "target file already exists with different content; set overwrite=true only when the user intends replacement",
                    error_kind="model_correctable",
                )
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_name(path.name + ".floweroll-tmp")
        temp.write_bytes(encoded)
        os.replace(temp, path)
        readback = path.read_bytes()
        actual_sha = hashlib.sha256(readback).hexdigest()
        if actual_sha != expected_sha:
            raise FunctionToolError("write verification failed")
        return {
            "path": self.workspace.relative(path),
            "size_bytes": len(readback),
            "sha256": actual_sha,
            "verified": True,
            "idempotent_replay": False,
            "_completion_summary": f"已写入并核验 {self.workspace.relative(path)}。",
        }

    def document_parse(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        path = self.workspace.resolve(arguments["path"], must_exist=True)
        if not path.is_file():
            raise FunctionToolError("document.parse path must be a file", error_kind="model_correctable")
        max_chars = _bounded_int(
            arguments.get("max_chars"),
            default=_DEFAULT_MAX_CHARS,
            minimum=256,
            maximum=_HARD_MAX_CHARS,
        )
        suffix = path.suffix.lower()
        if suffix in {".txt", ".md", ".log", ".py", ".swift", ".js", ".ts", ".jsonl"}:
            text = path.read_text(encoding="utf-8")
            return _text_parse_result(self.workspace.relative(path), text, max_chars, "text")
        if suffix == ".json":
            value = json.loads(path.read_text(encoding="utf-8"))
            pretty = json.dumps(value, ensure_ascii=False, indent=2)
            result = _text_parse_result(self.workspace.relative(path), pretty, max_chars, "json")
            result["structured"] = _bounded_json(value)
            return result
        if suffix in {".csv", ".tsv"}:
            delimiter = "\t" if suffix == ".tsv" else ","
            rows = _read_tabular(path, delimiter=delimiter, limit=200)
            return {
                "path": self.workspace.relative(path),
                "format": suffix.lstrip("."),
                "columns": list(rows[0]) if rows else [],
                "row_preview": rows[:50],
                "preview_count": min(len(rows), 50),
                "_completion_summary": f"已解析 {self.workspace.relative(path)} 的表格结构。",
            }
        if suffix in {".html", ".htm"}:
            parser = _HTMLTextExtractor()
            parser.feed(path.read_text(encoding="utf-8", errors="replace"))
            return _text_parse_result(self.workspace.relative(path), parser.text(), max_chars, "html")
        raise FunctionToolError(
            "document.parse currently supports txt/md/log/code/json/jsonl/csv/tsv/html files",
            error_kind="model_correctable",
            output={"suffix": suffix or None},
        )

    def data_analyze(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        path = self.workspace.resolve(arguments["path"], must_exist=True)
        if not path.is_file():
            raise FunctionToolError("data.analyze path must be a file", error_kind="model_correctable")
        suffix = path.suffix.lower()
        if suffix in {".csv", ".tsv"}:
            rows = _read_tabular(path, delimiter="\t" if suffix == ".tsv" else ",", limit=_MAX_ANALYSIS_ROWS)
        elif suffix == ".json":
            value = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
                raise FunctionToolError(
                    "data.analyze JSON input must be an array of objects",
                    error_kind="model_correctable",
                )
            rows = [dict(item) for item in value[:_MAX_ANALYSIS_ROWS]]
        else:
            raise FunctionToolError(
                "data.analyze currently supports CSV, TSV, or JSON array-of-object files",
                error_kind="model_correctable",
            )
        summary = _summarize_rows(rows)
        return {
            "path": self.workspace.relative(path),
            **summary,
            "truncated": len(rows) >= _MAX_ANALYSIS_ROWS,
            "_completion_summary": f"已分析 {summary['row_count']} 行数据。",
        }


def register_host_local_capabilities(
    registry: CapabilityRegistry,
    *,
    root: Path,
) -> Tuple[Dict[str, FunctionExecutor], HostLocalToolSet]:
    tools = HostLocalToolSet(root)
    definitions: List[Tuple[CapabilitySpec, FunctionToolAdapter, FunctionExecutor, tuple[str, ...], str]] = [
        (
            CapabilitySpec(
                name="file.list",
                description="列出小卷专用 Mac 工作区中的文件/目录。只能访问受限工作区，不能浏览任意本机路径。",
                arguments_schema={
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "recursive": {"type": "boolean"},
                        "limit": {"type": "integer"},
                    },
                    "required": ["path"],
                    "additionalProperties": False,
                },
            ),
            FunctionToolAdapter(capability_id="file.list", source_kind="host_local"),
            tools.file_list,
            ("host", "file", "read"),
            "always_visible",
        ),
        (
            CapabilitySpec(
                name="file.read",
                description="读取小卷专用 Mac 工作区里的 UTF-8 文本文件；路径必须相对工作区。",
                arguments_schema={
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "max_chars": {"type": "integer"},
                    },
                    "required": ["path"],
                    "additionalProperties": False,
                },
            ),
            FunctionToolAdapter(capability_id="file.read", source_kind="host_local"),
            tools.file_read,
            ("host", "file", "read"),
            "always_visible",
        ),
        (
            CapabilitySpec(
                name="artifact.write_text",
                description="把文本结果写入小卷专用 Mac 工作区并读回校验；默认不会覆盖已有不同内容。",
                arguments_schema={
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "content": {"type": "string"},
                        "overwrite": {"type": "boolean"},
                    },
                    "required": ["path", "content"],
                    "additionalProperties": False,
                },
            ),
            FunctionToolAdapter(
                capability_id="artifact.write_text",
                source_kind="host_local",
                read_only=False,
            ),
            tools.write_text,
            ("host", "file", "write", "artifact"),
            "always_visible",
        ),
        (
            CapabilitySpec(
                name="document.parse",
                description="解析小卷专用 Mac 工作区中的文本、JSON、CSV/TSV 或 HTML 文档为受限结构化内容。",
                arguments_schema={
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "max_chars": {"type": "integer"},
                    },
                    "required": ["path"],
                    "additionalProperties": False,
                },
            ),
            FunctionToolAdapter(capability_id="document.parse", source_kind="host_local"),
            tools.document_parse,
            ("host", "document", "parse"),
            "always_visible",
        ),
        (
            CapabilitySpec(
                name="data.analyze",
                description="分析小卷专用 Mac 工作区中的 CSV/TSV 或 JSON 表格，返回行列、缺失值和数值统计。",
                arguments_schema={
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                    "additionalProperties": False,
                },
            ),
            FunctionToolAdapter(capability_id="data.analyze", source_kind="host_local"),
            tools.data_analyze,
            ("host", "data", "analysis"),
            "always_visible",
        ),
    ]
    executors: Dict[str, FunctionExecutor] = {}
    for spec, adapter, executor, tags, loading in definitions:
        registry.register(
            RegisteredCapability(
                spec=spec,
                adapter=adapter,
                source=CapabilitySourceTarget(
                    kind="host_local",
                    tool_name=spec.name,
                    metadata={"workspace_root": str(tools.workspace.root)},
                ),
                tags=tags,
                loading=loading,
            )
        )
        executors[spec.name] = executor
    return executors, tools


def _bounded_int(value: Any, *, default: int, minimum: int, maximum: int) -> int:
    if value is None:
        return default
    if not isinstance(value, int) or isinstance(value, bool):
        raise FunctionToolError("numeric limit must be an integer", error_kind="model_correctable")
    return min(max(value, minimum), maximum)


def _text_parse_result(path: str, text: str, max_chars: int, format_name: str) -> Dict[str, Any]:
    return {
        "path": path,
        "format": format_name,
        "text": text[:max_chars],
        "char_count": len(text),
        "truncated": len(text) > max_chars,
        "_completion_summary": f"已解析 {path}。",
    }


def _bounded_json(value: Any, *, max_items: int = 50, depth: int = 0) -> Any:
    if depth >= 4:
        return "[bounded]"
    if isinstance(value, dict):
        result: Dict[str, Any] = {}
        for key, item in list(value.items())[:max_items]:
            result[str(key)] = _bounded_json(item, max_items=max_items, depth=depth + 1)
        return result
    if isinstance(value, list):
        return [_bounded_json(item, max_items=max_items, depth=depth + 1) for item in value[:max_items]]
    if isinstance(value, str):
        return value[:4000]
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return str(value)[:1000]


def _read_tabular(path: Path, *, delimiter: str, limit: int) -> List[Dict[str, Any]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        rows: List[Dict[str, Any]] = []
        for row in reader:
            rows.append({str(key): value for key, value in row.items() if key is not None})
            if len(rows) >= limit:
                break
        return rows


def _summarize_rows(rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    columns: List[str] = []
    seen = set()
    for row in rows:
        for key in row:
            if key not in seen:
                seen.add(key)
                columns.append(key)
    missing: Dict[str, int] = {key: 0 for key in columns}
    values: Dict[str, List[Any]] = {key: [] for key in columns}
    for row in rows:
        for key in columns:
            value = row.get(key)
            if value is None or (isinstance(value, str) and not value.strip()):
                missing[key] += 1
            else:
                values[key].append(value)

    numeric: Dict[str, Dict[str, Any]] = {}
    unique_counts: Dict[str, int] = {}
    for key in columns:
        unique_counts[key] = len({str(item) for item in values[key][:1000]})
        parsed: List[float] = []
        for item in values[key]:
            if isinstance(item, bool):
                continue
            if isinstance(item, (int, float)):
                parsed.append(float(item))
                continue
            if isinstance(item, str):
                try:
                    parsed.append(float(item.strip()))
                except ValueError:
                    pass
        if parsed and len(parsed) == len(values[key]):
            numeric[key] = {
                "count": len(parsed),
                "min": min(parsed),
                "max": max(parsed),
                "mean": statistics.fmean(parsed),
                "median": statistics.median(parsed),
            }
    return {
        "row_count": len(rows),
        "columns": columns,
        "missing_count": missing,
        "unique_count_sampled": unique_counts,
        "numeric_summary": numeric,
    }
