"""Bounded semantic DOCX inspect/generate capabilities.

The production profile is deliberately smaller than a general Word engine:
- inspect: verified TaskAsset only; bounded core text/paragraphs, direct run flags,
  paragraph style ids, package/core properties and explicit unsupported-feature signals.
- generate: deterministic lightweight OOXML with visual title/section hierarchy,
  ordinary paragraphs, whole-paragraph bold emphasis and literal bullet paragraphs.

No arbitrary existing-DOCX editing, semantic Word heading/list reconstruction,
true tables, formulas, comments, tracked changes or pixel-perfect layout is claimed.
"""
from __future__ import annotations

import hashlib
import io
import json
import re
import zipfile
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Tuple
from xml.etree import ElementTree as ET

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .docx_package import (
    DOCX_MIME,
    MAX_DOCX_XML_ENTRY_BYTES,
    validate_docx_package,
)
from .execution_contracts import ExecutionProfile, ExecutionVerification
from .function_execution_worker import FunctionToolError, TaskScopedFunction
from .planner_contracts import CapabilitySpec
from .task_assets import TaskAssetStore


INSPECT_ID = "document.docx.inspect"
GENERATE_ID = "document.docx.generate"
FORMAT_PROFILE = "bounded_ooxml_v1"

MAX_SEMANTIC_INPUT_BYTES = 16 * 1024 * 1024
MAX_GENERATED_DOCX_BYTES = 8 * 1024 * 1024
MAX_INSPECT_CHARS = 50_000
DEFAULT_INSPECT_CHARS = 20_000
MAX_RETURN_PARAGRAPHS = 80
MAX_PARAGRAPH_RETURN_CHARS = 800
MAX_GENERATE_TOTAL_CHARS = 80_000
MAX_SECTIONS = 20
MAX_PARAGRAPHS_PER_SECTION = 30
MAX_BULLETS_PER_SECTION = 30

W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
CP_NS = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
DC_NS = "http://purl.org/dc/elements/1.1/"
XML_NS = "http://www.w3.org/XML/1998/namespace"
MATH_NS = "http://schemas.openxmlformats.org/officeDocument/2006/math"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
CONTENT_TYPES_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
OFFICE_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
CORE_REL = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
WORD_MAIN_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
CORE_CONTENT_TYPE = "application/vnd.openxmlformats-package.core-properties+xml"

ET.register_namespace("w", W_NS)
ET.register_namespace("cp", CP_NS)
ET.register_namespace("dc", DC_NS)


INSPECT_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "file_id": {"type": "string", "minLength": 1, "maxLength": 100},
        "text_offset": {
            "type": "integer", "minimum": 0, "maximum": 64 * 1024 * 1024,
            "description": "从上次 readback.next_text_offset 或 planner_next_read 继续读取；同一文件同一窗口不会产生新信息。",
        },
        "max_chars": {
            "type": "integer",
            "minimum": 256,
            "maximum": MAX_INSPECT_CHARS,
        },
    },
    "required": ["file_id"],
    "additionalProperties": False,
}

GENERATE_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "output_name": {"type": "string", "minLength": 1, "maxLength": 140},
        "title": {"type": "string", "minLength": 1, "maxLength": 300},
        "sections": {
            "type": "array",
            "maxItems": MAX_SECTIONS,
            "items": {
                "type": "object",
                "properties": {
                    "heading": {"type": "string", "minLength": 1, "maxLength": 300},
                    "paragraphs": {
                        "type": "array",
                        "maxItems": MAX_PARAGRAPHS_PER_SECTION,
                        "items": {
                            "type": "object",
                            "properties": {
                                "text": {"type": "string", "minLength": 1, "maxLength": 4000},
                                "bold": {"type": "boolean"},
                            },
                            "required": ["text"],
                            "additionalProperties": False,
                        },
                    },
                    "bullets": {
                        "type": "array",
                        "maxItems": MAX_BULLETS_PER_SECTION,
                        "items": {"type": "string", "minLength": 1, "maxLength": 1000},
                    },
                },
                "required": ["heading", "paragraphs", "bullets"],
                "additionalProperties": False,
            },
        },
        "item_id": {"type": "string", "minLength": 1, "maxLength": 64},
    },
    "required": ["output_name", "title", "sections"],
    "additionalProperties": False,
}


class DocxSemanticError(RuntimeError):
    def __init__(self, code: str, message: str, *, error_kind: str = "model_correctable") -> None:
        super().__init__(message)
        self.code = code
        self.error_kind = error_kind


def _qn(local: str) -> str:
    return f"{{{W_NS}}}{local}"


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def _namespace(tag: str) -> str:
    return tag[1:].split("}", 1)[0] if tag.startswith("{") and "}" in tag else ""


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _semantic_fingerprint(paragraphs: list[str]) -> str:
    canonical = json.dumps(paragraphs, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _bounded_text(value: Any, *, field: str, maximum: int, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise DocxSemanticError("INVALID_PAYLOAD", f"{field} must be text")
    text = value.strip()
    if (not allow_empty and not text) or len(text) > maximum:
        raise DocxSemanticError("INVALID_PAYLOAD", f"{field} must be bounded non-empty text")
    if "\x00" in text:
        raise DocxSemanticError("INVALID_PAYLOAD", f"{field} contains NUL")
    return text


def _exact_object(value: Any, *, allowed: set[str], required: set[str], field: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise DocxSemanticError("INVALID_PAYLOAD", f"{field} must be an object")
    keys = set(value)
    if not required <= keys or not keys <= allowed:
        raise DocxSemanticError("INVALID_PAYLOAD", f"{field} has missing or unexpected fields")
    return dict(value)


def _bounded_int(value: Any, *, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise DocxSemanticError("INVALID_PAYLOAD", f"{field} must be an integer in {minimum}..{maximum}")
    return value


def _normalize_output_name(value: Any) -> str:
    name = _bounded_text(value, field="output_name", maximum=140)
    if re.search(r"[\\/\x00-\x1f\x7f:]", name):
        raise DocxSemanticError("INVALID_PAYLOAD", "output_name must be a plain filename")
    if name.lower().endswith(".docx"):
        return name
    if "." in Path(name).name:
        raise DocxSemanticError("INVALID_PAYLOAD", "output_name must use .docx or no extension")
    return name + ".docx"


def validate_inspect_arguments(value: Any) -> Dict[str, Any]:
    obj = _exact_object(
        value,
        allowed={"file_id", "max_chars", "text_offset"},
        required={"file_id"},
        field="document.docx.inspect arguments",
    )
    file_id = _bounded_text(obj["file_id"], field="file_id", maximum=100)
    try:
        TaskAssetStore.validate_id(file_id)
    except ValueError as exc:
        raise DocxSemanticError("INVALID_PAYLOAD", "file_id is not a valid TaskAsset identifier") from exc
    max_chars = obj.get("max_chars", DEFAULT_INSPECT_CHARS)
    max_chars = _bounded_int(max_chars, field="max_chars", minimum=256, maximum=MAX_INSPECT_CHARS)
    text_offset = _bounded_int(obj.get("text_offset", 0), field="text_offset", minimum=0, maximum=64 * 1024 * 1024)
    return {"file_id": file_id, "max_chars": max_chars, "text_offset": text_offset}


def validate_generate_arguments(value: Any) -> Dict[str, Any]:
    obj = _exact_object(
        value,
        allowed={"output_name", "title", "sections", "item_id"},
        required={"output_name", "title", "sections"},
        field="document.docx.generate arguments",
    )
    output_name = _normalize_output_name(obj["output_name"])
    title = _bounded_text(obj["title"], field="title", maximum=300)
    sections_value = obj["sections"]
    if not isinstance(sections_value, list) or len(sections_value) > MAX_SECTIONS:
        raise DocxSemanticError("INVALID_PAYLOAD", f"sections must contain at most {MAX_SECTIONS} items")

    sections = []
    total_chars = len(title)
    for index, raw_section in enumerate(sections_value):
        section = _exact_object(
            raw_section,
            allowed={"heading", "paragraphs", "bullets"},
            required={"heading", "paragraphs", "bullets"},
            field=f"sections[{index}]",
        )
        heading = _bounded_text(section["heading"], field=f"sections[{index}].heading", maximum=300)
        paragraphs_value = section["paragraphs"]
        bullets_value = section["bullets"]
        if not isinstance(paragraphs_value, list) or len(paragraphs_value) > MAX_PARAGRAPHS_PER_SECTION:
            raise DocxSemanticError(
                "INVALID_PAYLOAD",
                f"sections[{index}].paragraphs exceeds {MAX_PARAGRAPHS_PER_SECTION}",
            )
        if not isinstance(bullets_value, list) or len(bullets_value) > MAX_BULLETS_PER_SECTION:
            raise DocxSemanticError(
                "INVALID_PAYLOAD",
                f"sections[{index}].bullets exceeds {MAX_BULLETS_PER_SECTION}",
            )
        paragraphs = []
        for p_index, raw_paragraph in enumerate(paragraphs_value):
            paragraph = _exact_object(
                raw_paragraph,
                allowed={"text", "bold"},
                required={"text"},
                field=f"sections[{index}].paragraphs[{p_index}]",
            )
            text = _bounded_text(
                paragraph["text"],
                field=f"sections[{index}].paragraphs[{p_index}].text",
                maximum=4000,
            )
            bold = paragraph.get("bold", False)
            if not isinstance(bold, bool):
                raise DocxSemanticError("INVALID_PAYLOAD", "paragraph bold must be boolean")
            paragraphs.append({"text": text, "bold": bold})
            total_chars += len(text)
        bullets = []
        for b_index, raw_bullet in enumerate(bullets_value):
            bullet = _bounded_text(
                raw_bullet,
                field=f"sections[{index}].bullets[{b_index}]",
                maximum=1000,
            )
            bullets.append(bullet)
            total_chars += len(bullet) + 2
        total_chars += len(heading)
        sections.append({"heading": heading, "paragraphs": paragraphs, "bullets": bullets})

    if total_chars > MAX_GENERATE_TOTAL_CHARS:
        raise DocxSemanticError(
            "INVALID_PAYLOAD",
            f"generated document text exceeds {MAX_GENERATE_TOTAL_CHARS} characters",
        )

    result: Dict[str, Any] = {
        "output_name": output_name,
        "title": title,
        "sections": sections,
    }
    if "item_id" in obj:
        item_id = _bounded_text(obj["item_id"], field="item_id", maximum=64)
        try:
            TaskAssetStore.validate_id(item_id)
        except ValueError as exc:
            raise DocxSemanticError("INVALID_PAYLOAD", "item_id is not a valid identifier") from exc
        result["item_id"] = item_id
    return result


def _expected_generated_paragraphs(args: Mapping[str, Any]) -> list[str]:
    paragraphs = [str(args["title"])]
    for section in args["sections"]:
        paragraphs.append(str(section["heading"]))
        paragraphs.extend(str(item["text"]) for item in section["paragraphs"])
        paragraphs.extend("• " + str(item) for item in section["bullets"])
    return paragraphs


def _xml_bytes(root: ET.Element) -> bytes:
    return ET.tostring(root, encoding="utf-8", xml_declaration=True, short_empty_elements=True)


def _add_run(paragraph: ET.Element, text: str, *, bold: bool = False, size_half_points: Optional[int] = None) -> None:
    run = ET.SubElement(paragraph, _qn("r"))
    if bold or size_half_points is not None:
        properties = ET.SubElement(run, _qn("rPr"))
        if bold:
            ET.SubElement(properties, _qn("b"))
        if size_half_points is not None:
            size = ET.SubElement(properties, _qn("sz"))
            size.set(_qn("val"), str(size_half_points))
    text_node = ET.SubElement(run, _qn("t"))
    text_node.set(f"{{{XML_NS}}}space", "preserve")
    text_node.text = text


def _add_paragraph(
    body: ET.Element,
    text: str,
    *,
    bold: bool = False,
    size_half_points: Optional[int] = None,
    left_indent_twips: Optional[int] = None,
    space_after_twips: Optional[int] = None,
) -> None:
    paragraph = ET.SubElement(body, _qn("p"))
    if left_indent_twips is not None or space_after_twips is not None:
        ppr = ET.SubElement(paragraph, _qn("pPr"))
        if left_indent_twips is not None:
            indent = ET.SubElement(ppr, _qn("ind"))
            indent.set(_qn("left"), str(left_indent_twips))
        if space_after_twips is not None:
            spacing = ET.SubElement(ppr, _qn("spacing"))
            spacing.set(_qn("after"), str(space_after_twips))
    _add_run(paragraph, text, bold=bold, size_half_points=size_half_points)


def _document_xml(args: Mapping[str, Any]) -> bytes:
    document = ET.Element(_qn("document"))
    body = ET.SubElement(document, _qn("body"))
    _add_paragraph(body, str(args["title"]), bold=True, size_half_points=36, space_after_twips=240)
    for section in args["sections"]:
        _add_paragraph(body, str(section["heading"]), bold=True, size_half_points=28, space_after_twips=120)
        for paragraph in section["paragraphs"]:
            _add_paragraph(
                body,
                str(paragraph["text"]),
                bold=bool(paragraph["bold"]),
                size_half_points=22,
                space_after_twips=100,
            )
        for bullet in section["bullets"]:
            _add_paragraph(
                body,
                "• " + str(bullet),
                size_half_points=22,
                left_indent_twips=360,
                space_after_twips=60,
            )
    section_properties = ET.SubElement(body, _qn("sectPr"))
    page_size = ET.SubElement(section_properties, _qn("pgSz"))
    page_size.set(_qn("w"), "11906")
    page_size.set(_qn("h"), "16838")
    margins = ET.SubElement(section_properties, _qn("pgMar"))
    for key, value in {"top": "1440", "right": "1440", "bottom": "1440", "left": "1440"}.items():
        margins.set(_qn(key), value)
    return _xml_bytes(document)


def _content_types_xml() -> bytes:
    root = ET.Element(f"{{{CONTENT_TYPES_NS}}}Types")
    default_rels = ET.SubElement(root, f"{{{CONTENT_TYPES_NS}}}Default")
    default_rels.set("Extension", "rels")
    default_rels.set("ContentType", "application/vnd.openxmlformats-package.relationships+xml")
    default_xml = ET.SubElement(root, f"{{{CONTENT_TYPES_NS}}}Default")
    default_xml.set("Extension", "xml")
    default_xml.set("ContentType", "application/xml")
    document = ET.SubElement(root, f"{{{CONTENT_TYPES_NS}}}Override")
    document.set("PartName", "/word/document.xml")
    document.set("ContentType", WORD_MAIN_CONTENT_TYPE)
    core = ET.SubElement(root, f"{{{CONTENT_TYPES_NS}}}Override")
    core.set("PartName", "/docProps/core.xml")
    core.set("ContentType", CORE_CONTENT_TYPE)
    return _xml_bytes(root)


def _package_rels_xml() -> bytes:
    root = ET.Element(f"{{{REL_NS}}}Relationships")
    document = ET.SubElement(root, f"{{{REL_NS}}}Relationship")
    document.set("Id", "rId1")
    document.set("Type", OFFICE_REL)
    document.set("Target", "word/document.xml")
    core = ET.SubElement(root, f"{{{REL_NS}}}Relationship")
    core.set("Id", "rId2")
    core.set("Type", CORE_REL)
    core.set("Target", "docProps/core.xml")
    return _xml_bytes(root)


def _core_properties_xml(title: str) -> bytes:
    root = ET.Element(f"{{{CP_NS}}}coreProperties")
    title_node = ET.SubElement(root, f"{{{DC_NS}}}title")
    title_node.text = title
    creator = ET.SubElement(root, f"{{{DC_NS}}}creator")
    creator.text = "小卷"
    modified_by = ET.SubElement(root, f"{{{CP_NS}}}lastModifiedBy")
    modified_by.text = "小卷"
    return _xml_bytes(root)


def _zip_write(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 0
    info.external_attr = 0o600 << 16
    archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def render_docx(arguments: Mapping[str, Any]) -> bytes:
    args = validate_generate_arguments(dict(arguments))
    entries = [
        ("[Content_Types].xml", _content_types_xml()),
        ("_rels/.rels", _package_rels_xml()),
        ("docProps/core.xml", _core_properties_xml(str(args["title"]))),
        ("word/document.xml", _document_xml(args)),
    ]
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in entries:
            _zip_write(archive, name, data)
    value = buffer.getvalue()
    if not value or len(value) > MAX_GENERATED_DOCX_BYTES:
        raise DocxSemanticError("OUTPUT_TOO_LARGE", "generated DOCX exceeds bounded output size")
    return value


def _truthy_direct_property(node: Optional[ET.Element]) -> bool:
    if node is None:
        return False
    value = node.attrib.get(_qn("val"), "true").strip().lower()
    return value not in {"0", "false", "off", "no"}


def _visible_text(node: ET.Element) -> str:
    local = _local(node.tag)
    if node.tag == _qn("del") or local in {"delText"}:
        return ""
    if node.tag == _qn("t"):
        return node.text or ""
    if node.tag == _qn("tab"):
        return "\t"
    if node.tag in {_qn("br"), _qn("cr")}:
        return "\n"
    return "".join(_visible_text(child) for child in list(node))


def _read_xml_entry(archive: zipfile.ZipFile, name: str) -> Optional[bytes]:
    try:
        info = archive.getinfo(name)
    except KeyError:
        return None
    if info.file_size > MAX_DOCX_XML_ENTRY_BYTES:
        raise DocxSemanticError("RESOURCE_LIMIT", f"{name} exceeds semantic XML bound", error_kind="terminal")
    try:
        return archive.read(info)
    except (zipfile.BadZipFile, RuntimeError, OSError) as exc:
        raise DocxSemanticError("DOCX_PACKAGE_INVALID", f"cannot read {name}", error_kind="terminal") from exc


def _core_properties(archive: zipfile.ZipFile) -> Dict[str, str]:
    raw = _read_xml_entry(archive, "docProps/core.xml")
    if raw is None:
        return {}
    upper = raw.upper()
    if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
        raise DocxSemanticError("DOCX_PACKAGE_INVALID", "core properties contain unsafe XML", error_kind="terminal")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        raise DocxSemanticError("DOCX_PACKAGE_INVALID", "core properties XML is malformed", error_kind="terminal") from exc
    allowed = {
        "title",
        "creator",
        "subject",
        "description",
        "keywords",
        "category",
        "language",
        "lastModifiedBy",
    }
    result: Dict[str, str] = {}
    for node in root.iter():
        local = _local(node.tag)
        if local in allowed and isinstance(node.text, str) and node.text.strip():
            result[local] = node.text.strip()[:500]
    return result


def inspect_docx_bytes(
    data: bytes, *, max_chars: int = DEFAULT_INSPECT_CHARS, text_offset: int = 0
) -> Dict[str, Any]:
    max_chars = _bounded_int(max_chars, field="max_chars", minimum=256, maximum=MAX_INSPECT_CHARS)
    text_offset = _bounded_int(text_offset, field="text_offset", minimum=0, maximum=64 * 1024 * 1024)
    if not data or len(data) > MAX_SEMANTIC_INPUT_BYTES:
        raise DocxSemanticError("INPUT_TOO_LARGE", "DOCX exceeds semantic inspection byte bound")
    try:
        package = validate_docx_package(data)
    except ValueError as exc:
        raise DocxSemanticError("DOCX_PACKAGE_INVALID", str(exc), error_kind="terminal") from exc

    try:
        archive = zipfile.ZipFile(io.BytesIO(data), "r")
    except zipfile.BadZipFile as exc:
        raise DocxSemanticError("DOCX_PACKAGE_INVALID", "DOCX ZIP cannot be reopened", error_kind="terminal") from exc
    try:
        raw_document = _read_xml_entry(archive, "word/document.xml")
        if raw_document is None:
            raise DocxSemanticError("DOCX_PACKAGE_INVALID", "word/document.xml is missing", error_kind="terminal")
        try:
            root = ET.fromstring(raw_document)
        except ET.ParseError as exc:
            raise DocxSemanticError("DOCX_PACKAGE_INVALID", "word/document.xml is malformed", error_kind="terminal") from exc

        paragraphs: list[str] = []
        direct_bold_run_count = 0
        direct_italic_run_count = 0
        paragraph_style_ids: set[str] = set()
        numbering_paragraph_count = 0

        for paragraph in root.iter(_qn("p")):
            text = _visible_text(paragraph).strip()
            if text:
                paragraphs.append(text)
            ppr = paragraph.find(_qn("pPr"))
            if ppr is not None:
                style = ppr.find(_qn("pStyle"))
                if style is not None:
                    value = style.attrib.get(_qn("val"))
                    if isinstance(value, str) and value.strip():
                        paragraph_style_ids.add(value.strip()[:120])
                if ppr.find(_qn("numPr")) is not None:
                    numbering_paragraph_count += 1

        for run in root.iter(_qn("r")):
            rpr = run.find(_qn("rPr"))
            if rpr is None:
                continue
            if _truthy_direct_property(rpr.find(_qn("b"))):
                direct_bold_run_count += 1
            if _truthy_direct_property(rpr.find(_qn("i"))):
                direct_italic_run_count += 1

        table_count = sum(1 for _ in root.iter(_qn("tbl")))
        tracked_changes = any(
            node.tag in {_qn("ins"), _qn("del"), _qn("moveFrom"), _qn("moveTo")}
            for node in root.iter()
        )
        comments = (
            "word/comments.xml" in archive.namelist()
            or any(node.tag == _qn("commentReference") for node in root.iter())
        )
        drawings = any(_local(node.tag) in {"drawing", "pict", "object"} for node in root.iter())
        equations = any(
            _namespace(node.tag) == MATH_NS and _local(node.tag) in {"oMath", "oMathPara"}
            for node in root.iter()
        )
        headers_footers = any(
            name.startswith("word/header") or name.startswith("word/footer")
            for name in archive.namelist()
        )
        footnotes_endnotes = any(name in {"word/footnotes.xml", "word/endnotes.xml"} for name in archive.namelist())
        hyperlinks = any(node.tag == _qn("hyperlink") for node in root.iter())

        detected_features = ["paragraphs"]
        if direct_bold_run_count:
            detected_features.append("direct_bold")
        if direct_italic_run_count:
            detected_features.append("direct_italic_markup")
        if paragraph_style_ids:
            detected_features.append("paragraph_style_ids")
        if numbering_paragraph_count:
            detected_features.append("numbering_properties")
        if table_count:
            detected_features.append("tables")
        if comments:
            detected_features.append("comments")
        if tracked_changes:
            detected_features.append("tracked_changes")
        if drawings:
            detected_features.append("drawings_or_objects")
        if equations:
            detected_features.append("equations")
        if headers_footers:
            detected_features.append("headers_or_footers")
        if footnotes_endnotes:
            detected_features.append("footnotes_or_endnotes")
        if hyperlinks:
            detected_features.append("hyperlinks_as_text")

        unsupported = []
        warnings = []
        if table_count:
            unsupported.append("table_structure_reconstruction")
            warnings.append("检测到 Word 表格；核心文字可读取，但不重建表格行列/合并结构。")
        if numbering_paragraph_count:
            unsupported.append("semantic_numbering_reconstruction")
            warnings.append("检测到编号属性；本能力不保证重建 Word 编号/列表语义。")
        if comments:
            unsupported.append("comments_content")
            warnings.append("检测到批注；本能力不读取或解释批注正文。")
        if tracked_changes:
            unsupported.append("tracked_changes_semantics")
            warnings.append("检测到修订标记；删除文本被排除，但不重建修订历史。")
        if drawings:
            unsupported.append("drawing_object_semantics")
            warnings.append("检测到图形/对象；本能力不理解其视觉或嵌入对象语义。")
        if equations:
            unsupported.append("formula_semantics")
            warnings.append("检测到公式；本能力不解析公式语义。")
        if headers_footers:
            unsupported.append("headers_footers_text")
            warnings.append("检测到页眉/页脚；当前核心文本只读取主文档。")
        if footnotes_endnotes:
            unsupported.append("footnotes_endnotes_text")
            warnings.append("检测到脚注/尾注；当前核心文本只读取主文档。")
        if direct_italic_run_count:
            warnings.append("direct_italic_run_count 只表示 OOXML 直接格式标记存在，不承诺混合 CJK 的视觉斜体保真。")

        full_text = "\n".join(paragraphs)
        if text_offset > len(full_text):
            raise DocxSemanticError("INVALID_PAYLOAD", "text_offset is beyond the document text")
        selected_text = full_text[text_offset:text_offset + max_chars]
        window_end = text_offset + len(selected_text)
        selected_paragraphs = paragraphs if text_offset == 0 else selected_text.splitlines()
        returned_paragraphs = []
        paragraph_text_truncated_count = 0
        for paragraph in selected_paragraphs[:MAX_RETURN_PARAGRAPHS]:
            if len(paragraph) > MAX_PARAGRAPH_RETURN_CHARS:
                returned_paragraphs.append(paragraph[:MAX_PARAGRAPH_RETURN_CHARS])
                paragraph_text_truncated_count += 1
            else:
                returned_paragraphs.append(paragraph)

        return {
            "package": package,
            "text": selected_text,
            "text_offset": text_offset,
            "total_chars": len(full_text),
            "next_text_offset": window_end if window_end < len(full_text) else None,
            "text_sha256": _sha256(full_text.encode("utf-8")),
            "semantic_fingerprint": _semantic_fingerprint(paragraphs),
            "truncated": text_offset > 0 or window_end < len(full_text),
            "paragraphs": returned_paragraphs,
            "paragraph_count": len(paragraphs),
            "paragraphs_returned": len(returned_paragraphs),
            "paragraphs_truncated": text_offset > 0 or len(paragraphs) > len(returned_paragraphs),
            "paragraph_text_truncated_count": paragraph_text_truncated_count,
            "structure": {
                "table_count": table_count,
                "numbering_paragraph_count": numbering_paragraph_count,
                "direct_bold_run_count": direct_bold_run_count,
                "direct_italic_run_count": direct_italic_run_count,
                "paragraph_style_ids": sorted(paragraph_style_ids)[:32],
                "paragraph_style_id_count": len(paragraph_style_ids),
            },
            "properties": _core_properties(archive),
            "features": {
                "supported_scope": [
                    "main_document_core_text",
                    "paragraph_boundaries",
                    "direct_bold_italic_marker_counts",
                    "raw_paragraph_style_ids",
                    "package_structure_counts",
                    "bounded_core_properties",
                ],
                "detected": detected_features,
                "unsupported_detected": unsupported,
            },
            "warnings": warnings,
            "format_profile": FORMAT_PROFILE,
        }
    finally:
        archive.close()


class DocxSemanticTools:
    def __init__(self, assets: TaskAssetStore) -> None:
        self.assets = assets

    def _input(self, dispatch: Mapping[str, Any], file_id: str) -> Tuple[Path, Dict[str, Any], str]:
        task_id = dispatch.get("task_id")
        action_id = dispatch.get("action_id")
        if not isinstance(task_id, str) or not task_id or not isinstance(action_id, str) or not action_id:
            raise DocxSemanticError("INVALID_DISPATCH", "Runtime dispatch identity is missing", error_kind="terminal")
        try:
            path = self.assets.file_path(task_id, file_id)
            item = self.assets.get(file_id)
        except (KeyError, ValueError) as exc:
            raise DocxSemanticError("INPUT_NOT_FOUND", "DOCX is not available to the current Task") from exc
        if item.get("media_type") != DOCX_MIME:
            raise DocxSemanticError("UNSUPPORTED_MEDIA_TYPE", "TaskAsset is not a DOCX")
        if not str(item.get("name") or "").lower().endswith(".docx"):
            raise DocxSemanticError("INPUT_IDENTITY_MISMATCH", "DOCX TaskAsset filename is inconsistent", error_kind="terminal")
        size = path.stat().st_size
        if not 0 < size <= MAX_SEMANTIC_INPUT_BYTES:
            raise DocxSemanticError("INPUT_TOO_LARGE", "DOCX exceeds semantic inspection byte bound")
        data = path.read_bytes()
        digest = _sha256(data)
        if size != item.get("size_bytes") or digest != item.get("sha256"):
            raise DocxSemanticError("INPUT_INTEGRITY_FAILED", "DOCX TaskAsset integrity changed", error_kind="terminal")
        return path, item, digest

    @staticmethod
    def _output_id(task_id: str, action_id: str) -> str:
        return "out_" + hashlib.sha256((task_id + ":" + action_id + ":" + DOCX_MIME).encode()).hexdigest()[:32]

    def inspect(self, dispatch: Dict[str, Any], arguments: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_inspect_arguments(arguments)
        path, item, digest = self._input(dispatch, args["file_id"])
        before = path.read_bytes()
        readback = inspect_docx_bytes(before, max_chars=args["max_chars"], text_offset=args["text_offset"])
        if _sha256(path.read_bytes()) != digest:
            raise DocxSemanticError("INPUT_INTEGRITY_FAILED", "DOCX inspect modified source bytes", error_kind="terminal")
        return {
            "file_id": args["file_id"],
            "name": item["name"],
            "media_type": item["media_type"],
            "size_bytes": item["size_bytes"],
            "sha256": digest,
            "max_chars": args["max_chars"],
            "text_offset": args["text_offset"],
            "readback": readback,
            "verified": True,
            "engine": "stdlib-ooxml",
        }

    def generate(self, dispatch: Dict[str, Any], arguments: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_generate_arguments(arguments)
        task_id = dispatch.get("task_id")
        action_id = dispatch.get("action_id")
        if not isinstance(task_id, str) or not task_id or not isinstance(action_id, str) or not action_id:
            raise DocxSemanticError("INVALID_DISPATCH", "Runtime dispatch identity is missing", error_kind="terminal")

        expected_paragraphs = _expected_generated_paragraphs(args)
        expected_fingerprint = _semantic_fingerprint(expected_paragraphs)
        existing_id = self._output_id(task_id, action_id)
        try:
            existing = self.assets.get(existing_id)
        except KeyError:
            existing = None
        if existing is not None:
            metadata = existing.get("metadata") if isinstance(existing.get("metadata"), dict) else {}
            if (
                existing.get("media_type") != DOCX_MIME
                or existing.get("name") != args["output_name"]
                or metadata.get("action_id") != action_id
                or metadata.get("format_profile") != FORMAT_PROFILE
                or metadata.get("semantic_fingerprint") != expected_fingerprint
            ):
                raise DocxSemanticError(
                    "OUTPUT_VERIFICATION_FAILED",
                    "existing DOCX artifact provenance mismatches replayed Action",
                    error_kind="terminal",
                )
            try:
                stored_path = self.assets.verify_unit_file(task_id, action_id, existing_id)
            except (KeyError, ValueError) as exc:
                raise DocxSemanticError(
                    "OUTPUT_VERIFICATION_FAILED",
                    "existing DOCX artifact failed immutable readback",
                    error_kind="terminal",
                ) from exc
            stored = stored_path.read_bytes()
            stored_hash = _sha256(stored)
            stored_readback = inspect_docx_bytes(stored, max_chars=MAX_INSPECT_CHARS)
            if existing.get("sha256") != stored_hash or stored_readback["semantic_fingerprint"] != expected_fingerprint:
                raise DocxSemanticError(
                    "OUTPUT_VERIFICATION_FAILED",
                    "existing DOCX artifact failed semantic/hash replay verification",
                    error_kind="terminal",
                )
            return {
                "file": existing,
                "output_sha256": stored_hash,
                "generated_sha256": stored_hash,
                "semantic_fingerprint": expected_fingerprint,
                "readback": stored_readback,
                "replayed_artifact": True,
                "verified": True,
                "engine": "stdlib-ooxml",
                "format_profile": FORMAT_PROFILE,
            }

        generated = render_docx(args)
        generated_hash = _sha256(generated)
        readback = inspect_docx_bytes(generated, max_chars=MAX_INSPECT_CHARS)
        if readback["semantic_fingerprint"] != expected_fingerprint:
            raise DocxSemanticError("SEMANTIC_READBACK_MISMATCH", "generated DOCX semantic readback mismatches requested content", error_kind="terminal")
        if readback["features"]["unsupported_detected"]:
            raise DocxSemanticError("UNSUPPORTED_OUTPUT_STRUCTURE", "generated DOCX unexpectedly contains unsupported structures", error_kind="terminal")

        metadata = {
            "status": "ready",
            "label": "DOCX 已生成 · 已完成结构与语义读回核验",
            "effect": "local_file_generated",
            "verification_scope": "docx_package_and_semantic_readback",
            "format_profile": FORMAT_PROFILE,
            "semantic_fingerprint": expected_fingerprint,
            "generated_sha256": generated_hash,
            "unsupported_features": [],
        }
        if "item_id" in args:
            metadata["item_id"] = args["item_id"]
        item = self.assets.publish_bytes(
            task_id=task_id,
            action_id=action_id,
            name=args["output_name"],
            media_type=DOCX_MIME,
            data=generated,
            category="document",
            metadata=metadata,
        )
        try:
            stored_path = self.assets.verify_unit_file(task_id, action_id, item["id"])
        except (KeyError, ValueError) as exc:
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "generated DOCX is not bound to the exact Task/Action", error_kind="terminal") from exc
        stored = stored_path.read_bytes()
        stored_hash = _sha256(stored)
        stored_readback = inspect_docx_bytes(stored, max_chars=MAX_INSPECT_CHARS)
        if item.get("sha256") != stored_hash or stored_readback["semantic_fingerprint"] != expected_fingerprint:
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "stored DOCX failed semantic/hash readback", error_kind="terminal")
        return {
            "file": item,
            "output_sha256": stored_hash,
            "generated_sha256": generated_hash,
            "semantic_fingerprint": expected_fingerprint,
            "readback": stored_readback,
            "replayed_artifact": False,
            "verified": True,
            "engine": "stdlib-ooxml",
            "format_profile": FORMAT_PROFILE,
        }

    def verify_inspection_result(self, action: Dict[str, Any], output: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_inspect_arguments(action.get("payload"))
        path, item, digest = self._input(action, args["file_id"])
        fresh = inspect_docx_bytes(path.read_bytes(), max_chars=args["max_chars"], text_offset=args["text_offset"])
        if (
            output.get("file_id") != args["file_id"]
            or output.get("sha256") != digest
            or output.get("size_bytes") != item.get("size_bytes")
            or output.get("media_type") != DOCX_MIME
            or output.get("readback") != fresh
        ):
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "DOCX inspect result did not match independent readback", error_kind="terminal")
        return {
            "capability": INSPECT_ID,
            "file_id": args["file_id"],
            "name": item["name"],
            "media_type": DOCX_MIME,
            "size_bytes": item["size_bytes"],
            "sha256": digest,
            "max_chars": args["max_chars"],
            "text_offset": args["text_offset"],
            "readback": fresh,
            "verification": {
                "method": "ooxml_source_reparse",
                "integrity_scope": "task_scope+asset_hash+package_structure+semantic_readback",
            },
        }

    def verify_generate_result(self, action: Dict[str, Any], output: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_generate_arguments(action.get("payload"))
        expected_fingerprint = _semantic_fingerprint(_expected_generated_paragraphs(args))
        file_value = output.get("file")
        if not isinstance(file_value, dict) or file_value.get("media_type") != DOCX_MIME:
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "DOCX generate result is missing artifact descriptor", error_kind="terminal")
        metadata = file_value.get("metadata")
        if not isinstance(metadata, dict) or metadata.get("action_id") != action.get("action_id"):
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "DOCX artifact is not bound to exact Action", error_kind="terminal")
        if metadata.get("format_profile") != FORMAT_PROFILE or metadata.get("semantic_fingerprint") != expected_fingerprint:
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "DOCX artifact provenance metadata mismatches Action", error_kind="terminal")
        try:
            path = self.assets.verify_unit_file(str(action["task_id"]), str(action["action_id"]), str(file_value.get("id")))
        except (KeyError, ValueError) as exc:
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "DOCX artifact failed Task/Action readback", error_kind="terminal") from exc
        data = path.read_bytes()
        digest = _sha256(data)
        fresh = inspect_docx_bytes(data, max_chars=MAX_INSPECT_CHARS)
        if (
            digest != file_value.get("sha256")
            or digest != output.get("output_sha256")
            or output.get("semantic_fingerprint") != expected_fingerprint
            or fresh["semantic_fingerprint"] != expected_fingerprint
            or output.get("readback") != fresh
        ):
            raise DocxSemanticError("OUTPUT_VERIFICATION_FAILED", "DOCX artifact hash/semantic readback mismatch", error_kind="terminal")
        return {
            "capability": GENERATE_ID,
            "file": file_value,
            "output_sha256": digest,
            "semantic_fingerprint": expected_fingerprint,
            "readback": fresh,
            "verification": {
                "method": "ooxml_artifact_reparse",
                "integrity_scope": "action_binding+artifact_hash+package_structure+exact_semantic_fingerprint",
            },
        }


class DocxSemanticAdapter:
    source_kind = "task_material"

    def __init__(self, capability_id: str, tools: DocxSemanticTools, *, read_only: bool) -> None:
        self.capability_id = capability_id
        self.tools = tools
        self.read_only = read_only
        self.replay_safe = True
        self.execution_profile = ExecutionProfile(
            timeout_seconds=30,
            idempotency_mode="NATURAL_READ_ONLY" if read_only else "EXACT_INPUT",
            retry_mode="SAFE_WITH_SAME_KEY",
            verification_mode="DOCX_SOURCE_READBACK" if read_only else "DOCX_ARTIFACT_READBACK",
            reconciliation_mode="SAFE_REREAD" if read_only else "REPLAY_SAME_ATTEMPT",
            max_attempts=1 if read_only else 2,
            retry_backoff_seconds=1,
        )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "source": {"kind": self.source_kind, "capability": self.capability_id},
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            kind = output.get("error_kind")
            outcome = (
                "MODEL_CORRECTABLE_FAILURE" if kind == "model_correctable"
                else "TRANSIENT_FAILURE" if kind == "transient"
                else "TERMINAL_FAILURE"
            )
            code = output.get("error_code")
            detail = error or "DOCX operation failed"
            if isinstance(code, str) and code:
                detail = f"{code}: {detail}"
            return ExecutionVerification(outcome=outcome, error=detail)
        try:
            if self.capability_id == INSPECT_ID:
                observation = self.tools.verify_inspection_result(action, output)
                summary = None
            elif self.capability_id == GENERATE_ID:
                observation = self.tools.verify_generate_result(action, output)
                file_value = observation.get("file")
                name = file_value.get("name") if isinstance(file_value, dict) else None
                summary = f"DOCX 已生成并核验：{name}。" if isinstance(name, str) and name else "DOCX 已生成并完成读回核验。"
            else:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="unknown DOCX capability adapter identity")
        except DocxSemanticError as exc:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error=f"{exc.code}: {exc}")
        except Exception as exc:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=f"DOCX verifier failed closed: {type(exc).__name__}",
            )
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=summary,
        )


def readiness() -> Dict[str, Any]:
    sample = {
        "output_name": "self-test.docx",
        "title": "DOCX Self Test 小卷",
        "sections": [
            {
                "heading": "Section",
                "paragraphs": [{"text": "中文 English core text", "bold": True}],
                "bullets": ["Bullet item"],
            }
        ],
    }
    try:
        first = render_docx(sample)
        second = render_docx(sample)
        if first != second:
            raise RuntimeError("deterministic DOCX self-test bytes differ")
        expected = _semantic_fingerprint(_expected_generated_paragraphs(validate_generate_arguments(sample)))
        readback = inspect_docx_bytes(first, max_chars=4096)
        if readback.get("semantic_fingerprint") != expected:
            raise RuntimeError("DOCX semantic self-test mismatch")
        if readback.get("features", {}).get("unsupported_detected"):
            raise RuntimeError("DOCX self-test emitted unsupported structure")
    except Exception as exc:
        return {
            "ready": False,
            "reason": type(exc).__name__,
            "network": False,
            "credentials": False,
            "new_dependencies": False,
        }
    return {
        "ready": True,
        "engine": "python-stdlib-ooxml",
        "format_profile": FORMAT_PROFILE,
        "network": False,
        "credentials": False,
        "new_dependencies": False,
        "deterministic_generation": True,
        "limits": {
            "max_input_bytes": MAX_SEMANTIC_INPUT_BYTES,
            "max_generated_bytes": MAX_GENERATED_DOCX_BYTES,
            "max_inspect_chars": MAX_INSPECT_CHARS,
            "max_return_paragraphs": MAX_RETURN_PARAGRAPHS,
            "max_return_paragraph_chars": MAX_PARAGRAPH_RETURN_CHARS,
            "max_generate_chars": MAX_GENERATE_TOTAL_CHARS,
            "max_sections": MAX_SECTIONS,
            "max_paragraphs_per_section": MAX_PARAGRAPHS_PER_SECTION,
            "max_bullets_per_section": MAX_BULLETS_PER_SECTION,
        },
        "unsupported": [
            "arbitrary_existing_docx_editing",
            "true_table_generation",
            "semantic_heading_style_guarantee",
            "semantic_numbering_list_guarantee",
            "formula_semantics",
            "comments",
            "tracked_changes",
            "pixel_perfect_word_layout",
            "mixed_cjk_rich_typography_fidelity",
        ],
    }


def register_docx_semantic_capabilities(
    registry: CapabilityRegistry,
    *,
    assets: TaskAssetStore,
) -> Tuple[Dict[str, TaskScopedFunction], Dict[str, Any]]:
    health = readiness()
    if health.get("ready") is not True:
        return {}, health
    tools = DocxSemanticTools(assets)

    inspect_spec = CapabilitySpec(
        name=INSPECT_ID,
        description=(
            "读取当前任务已绑定或已验证祖先成果中的 DOCX：验证 OOXML package，并返回有界核心文本、段落、直接粗体/斜体标记计数、原始段落 style id、核心属性与不支持特征提示。"
            "不接受任意主机路径，不重建表格/编号/批注/修订/公式/视觉布局。"
        ),
        arguments_schema=INSPECT_SCHEMA,
        post_verify_mode="REPLAN_REQUIRED",
    )
    generate_spec = CapabilitySpec(
        name=GENERATE_ID,
        description=(
            "生成一个可下载的轻量 DOCX 成果：标题、分节标题、普通段落、整段粗体和视觉 bullet 段落；生成后会重新解析 OOXML 并逐内容指纹核验。"
            "不用于编辑已有 DOCX，不承诺 true tables、Word Heading/list 语义、公式、批注、修订、像素级排版或混合 CJK 丰富字体保真。"
        ),
        arguments_schema=GENERATE_SCHEMA,
        post_verify_mode="COMPLETE_ALLOWED",
    )

    registry.register(
        RegisteredCapability(
            spec=inspect_spec,
            adapter=DocxSemanticAdapter(INSPECT_ID, tools, read_only=True),
            source=CapabilitySourceTarget(
                kind="task_material",
                tool_name=INSPECT_ID,
                metadata={
                    "execution_plane": "host",
                    "foreground_policy": "background_only",
                    "read_only": True,
                    "effect": "read",
                    "operation": "read",
                    "domains": ["document", "files", "task"],
                    "deterministic": True,
                    "network": False,
                    "verification": "ooxml_source_reparse",
                    "format_profile": FORMAT_PROFILE,
                },
            ),
            tags=("docx", "word", "document", "inspect", "read", "paragraphs", "ooxml"),
            loading="always_visible",
        )
    )
    registry.register(
        RegisteredCapability(
            spec=generate_spec,
            adapter=DocxSemanticAdapter(GENERATE_ID, tools, read_only=False),
            source=CapabilitySourceTarget(
                kind="task_material",
                tool_name=GENERATE_ID,
                metadata={
                    "execution_plane": "host",
                    "foreground_policy": "background_only",
                    "read_only": False,
                    "effect": "local_file",
                    "operation": "write",
                    "domains": ["document", "files", "task"],
                    "deterministic": True,
                    "network": False,
                    "verification": "ooxml_artifact_reparse",
                    "format_profile": FORMAT_PROFILE,
                },
            ),
            tags=("docx", "word", "document", "generate", "write", "artifact", "ooxml"),
            loading="always_visible",
        )
    )

    def wrap(function):
        def scoped(dispatch: Dict[str, Any], args: Dict[str, Any]) -> Dict[str, Any]:
            try:
                return function(dispatch, args)
            except DocxSemanticError as exc:
                raise FunctionToolError(
                    str(exc),
                    error_kind=exc.error_kind,
                    output={"error_code": exc.code},
                ) from exc
            except (KeyError, ValueError, TypeError) as exc:
                raise FunctionToolError(
                    "DOCX operation rejected malformed direct payload",
                    error_kind="model_correctable",
                    output={"error_code": "INVALID_PAYLOAD"},
                ) from exc
        return TaskScopedFunction(scoped)

    return {
        INSPECT_ID: wrap(tools.inspect),
        GENERATE_ID: wrap(tools.generate),
    }, health
