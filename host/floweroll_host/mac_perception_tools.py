from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Any, Dict, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .function_execution_worker import FunctionExecutor, FunctionToolError
from .function_tool_adapter import FunctionToolAdapter
from .host_local_tools import HostWorkspace
from .planner_contracts import CapabilitySpec


_MAX_TEXT_CHARS = 60_000
_MAX_OCR_BLOCKS = 500
_MAX_PDF_PAGES = 200


def _confidence_summary(blocks: list[Dict[str, Any]]) -> Dict[str, Any]:
    values = [
        float(block['confidence']) for block in blocks
        if isinstance(block, dict)
        and isinstance(block.get('confidence'), (int, float))
        and not isinstance(block.get('confidence'), bool)
        and 0.0 <= float(block['confidence']) <= 1.0
    ]
    if not values:
        return {
            'confidence_mean': None, 'confidence_min': None,
            'low_confidence_block_count': 0,
        }
    return {
        'confidence_mean': round(sum(values) / len(values), 4),
        'confidence_min': round(min(values), 4),
        'low_confidence_block_count': sum(value < 0.60 for value in values),
    }


class MacPerceptionToolSet:
    """macOS Vision/PDFKit capabilities without third-party runtime packages."""

    def __init__(self, *, workspace_root: Path, helper_source: Path, runtime_dir: Path) -> None:
        self.workspace = HostWorkspace(workspace_root)
        self.helper_source = helper_source.resolve()
        self.runtime_dir = runtime_dir.resolve()
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        self._build_lock = threading.Lock()

    def image_ocr(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        path = self.workspace.resolve(arguments["path"], must_exist=True)
        if not path.is_file():
            raise FunctionToolError("image.ocr path must be a file", error_kind="model_correctable")
        if path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".heic", ".tif", ".tiff", ".bmp"}:
            raise FunctionToolError(
                "image.ocr supports PNG/JPEG/HEIC/TIFF/BMP images",
                error_kind="model_correctable",
            )
        value = self._invoke("ocr", path)
        raw_blocks = value.get("blocks")
        blocks = raw_blocks[:_MAX_OCR_BLOCKS] if isinstance(raw_blocks, list) else []
        text = value.get("text") if isinstance(value.get("text"), str) else ""
        text = text[:_MAX_TEXT_CHARS]
        confidence = _confidence_summary(blocks)
        return {
            "path": self.workspace.relative(path),
            "text": text,
            "blocks": blocks,
            "block_count": int(value.get("block_count") or len(blocks)),
            "truncated": len(text) >= _MAX_TEXT_CHARS or len(blocks) >= _MAX_OCR_BLOCKS,
            **confidence,
            "_completion_summary": f"已识别图片中的 {len(blocks)} 个文本块。",
        }

    def pdf_extract_text(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        path = self.workspace.resolve(arguments["path"], must_exist=True)
        if not path.is_file() or path.suffix.lower() != ".pdf":
            raise FunctionToolError("pdf.extract_text requires a PDF file", error_kind="model_correctable")
        value = self._invoke("pdf-text", path)
        return self._bounded_pdf_text(value, public_path=self.workspace.relative(path))

    def pdf_ocr(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """OCR every page of an image-only PDF in the task workspace."""
        path = self.workspace.resolve(arguments["path"], must_exist=True)
        if not path.is_file() or path.suffix.lower() != ".pdf":
            raise FunctionToolError("PDF OCR requires a PDF file", error_kind="model_correctable")
        return self.pdf_ocr_file(path, public_path=self.workspace.relative(path))

    def pdf_ocr_file(
        self, path: Path, *, public_path: str | None = None, timeout_seconds: int = 120
    ) -> Dict[str, Any]:
        """Internal bounded OCR for a trusted PDF path such as a generated temp result.

        This method is intentionally not exposed as a generic path-taking model tool.
        Public callers still go through ``pdf_ocr`` and HostWorkspace confinement.
        """
        path = path.resolve()
        if not path.is_file() or path.suffix.lower() != ".pdf":
            raise FunctionToolError("PDF OCR requires a PDF file", error_kind="model_correctable")
        value = self._invoke("pdf-ocr", path, timeout=max(15, min(int(timeout_seconds), 120)))
        page_count = int(value.get("page_count") or 0)
        raw_pages = value.get("pages")
        pages = raw_pages[:_MAX_PDF_PAGES] if isinstance(raw_pages, list) else []
        bounded_pages = []
        total_blocks = 0
        for item in pages:
            if not isinstance(item, dict):
                continue
            text = item.get("text") if isinstance(item.get("text"), str) else ""
            raw_blocks = item.get("blocks")
            blocks = raw_blocks[:_MAX_OCR_BLOCKS] if isinstance(raw_blocks, list) else []
            total_blocks += len(blocks)
            confidence = _confidence_summary(blocks)
            bounded_pages.append(
                {
                    "page": item.get("page"),
                    "text": text[:8_000],
                    "blocks": blocks,
                    "block_count": int(item.get("block_count") or len(blocks)),
                    "render_width": item.get("render_width"),
                    "render_height": item.get("render_height"),
                    **confidence,
                }
            )
        text = value.get("text") if isinstance(value.get("text"), str) else ""
        text = text[:_MAX_TEXT_CHARS]
        complete = bool(value.get("ocr_complete")) and len(bounded_pages) == page_count
        aggregate = _confidence_summary([
            block for page in bounded_pages for block in page.get('blocks', [])
        ])
        return {
            "path": public_path,
            "page_count": page_count,
            "text": text,
            "pages": bounded_pages,
            "block_count": total_blocks,
            "ocr_complete": complete,
            "ocr_mode": value.get("mode") or "vision_pdf_page_ocr",
            "truncated": page_count > _MAX_PDF_PAGES or len(text) >= _MAX_TEXT_CHARS,
            **aggregate,
            "_completion_summary": f"已逐页 OCR PDF，共 {page_count} 页。",
        }

    def _bounded_pdf_text(self, value: Dict[str, Any], *, public_path: str | None) -> Dict[str, Any]:
        page_count = int(value.get("page_count") or 0)
        raw_pages = value.get("pages")
        pages = raw_pages[:_MAX_PDF_PAGES] if isinstance(raw_pages, list) else []
        bounded_pages = []
        for item in pages:
            if not isinstance(item, dict):
                continue
            text = item.get("text") if isinstance(item.get("text"), str) else ""
            bounded_pages.append(
                {
                    "page": item.get("page"),
                    "text": text[:8_000],
                }
            )
        text = value.get("text") if isinstance(value.get("text"), str) else ""
        text = text[:_MAX_TEXT_CHARS]
        return {
            "path": public_path,
            "page_count": page_count,
            "text": text,
            "pages": bounded_pages,
            "truncated": page_count > _MAX_PDF_PAGES or len(text) >= _MAX_TEXT_CHARS,
            "_completion_summary": f"已提取 PDF 的 {page_count} 页文本。",
        }

    def _invoke(self, command: str, path: Path, *, timeout: int = 45) -> Dict[str, Any]:
        binary = self._ensure_helper()
        try:
            completed = subprocess.run(
                [str(binary), command, str(path)],
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise FunctionToolError("macOS perception helper timed out", error_kind="transient") from exc
        if completed.returncode != 0:
            error = completed.stderr.strip()[:1000] or "macOS perception helper failed"
            raise FunctionToolError(error, error_kind="model_correctable")
        try:
            value = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise FunctionToolError("macOS perception helper returned invalid JSON") from exc
        if not isinstance(value, dict):
            raise FunctionToolError("macOS perception helper returned a non-object")
        return value

    def _ensure_helper(self) -> Path:
        source = self.helper_source.read_bytes()
        digest = hashlib.sha256(source).hexdigest()[:16]
        binary = self.runtime_dir / f"MacPerceptionHelper-{digest}"
        if binary.is_file():
            return binary
        with self._build_lock:
            if binary.is_file():
                return binary
            xcrun = shutil.which("xcrun")
            if not xcrun:
                raise FunctionToolError(
                    "xcrun is required to build the macOS perception helper",
                    error_kind="terminal",
                )
            temp = binary.with_suffix(".tmp")
            command = [
                xcrun,
                "swiftc",
                "-O",
                str(self.helper_source),
                "-framework",
                "AppKit",
                "-framework",
                "Vision",
                "-framework",
                "PDFKit",
                "-o",
                str(temp),
            ]
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=90,
            )
            if completed.returncode != 0:
                temp.unlink(missing_ok=True)
                error = completed.stderr.strip()[:2000] or "swiftc failed"
                raise FunctionToolError(f"could not build macOS perception helper: {error}")
            temp.replace(binary)
        return binary


def register_mac_perception_capabilities(
    registry: CapabilityRegistry,
    *,
    workspace_root: Path,
    helper_source: Path,
    runtime_dir: Path,
) -> Tuple[Dict[str, FunctionExecutor], MacPerceptionToolSet]:
    tools = MacPerceptionToolSet(
        workspace_root=workspace_root,
        helper_source=helper_source,
        runtime_dir=runtime_dir,
    )
    definitions = [
        (
            CapabilitySpec(
                name="image.ocr",
                description="用 Mac 系统 Vision OCR 读取花卷 Host 工作区中的图片文字，返回文本块和置信度。它只接受 HostWorkspace path；任务附件或 document.scan_pdf 生成物不要传这里，优先用 materials.inspect 或 scan_pdf 已返回的 OCR。",
                arguments_schema={
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            tools.image_ocr,
            ("host", "vision", "ocr", "image", "read"),
        ),
        (
            CapabilitySpec(
                name="pdf.extract_text",
                description="用 Mac 系统 PDFKit 提取 Host 工作区中可搜索 PDF 的逐页文本。它不接受 TaskAsset file_id 或生成物路径；任务 PDF 用 materials.inspect，document.scan_pdf 已直接返回逐页 OCR，无需重复读取。",
                arguments_schema={
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            tools.pdf_extract_text,
            ("host", "pdf", "document", "read"),
        ),
    ]
    executors: Dict[str, FunctionExecutor] = {}
    for spec, executor, tags in definitions:
        registry.register(
            RegisteredCapability(
                spec=spec,
                adapter=FunctionToolAdapter(
                    capability_id=spec.name,
                    source_kind="mac_native",
                    read_only=True,
                    timeout_seconds=45,
                ),
                source=CapabilitySourceTarget(
                    kind="mac_native",
                    tool_name=spec.name,
                    metadata={
                        "frameworks": ["Vision", "PDFKit"],
                        "workspace_root": str(tools.workspace.root),
                    },
                ),
                tags=tags,
                loading="always_visible",
            )
        )
        executors[spec.name] = executor
    return executors, tools
