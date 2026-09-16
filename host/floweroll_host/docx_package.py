"""Bounded OOXML/DOCX package validation for task material admission.

This module validates container/package structure only. It deliberately does not
claim rich Word semantics such as heading/list/table/comment/tracked-change
fidelity, which belongs to the later CAP-012 semantic capability slice.
"""
from __future__ import annotations

import io
import zipfile
from typing import Any, Dict
from xml.etree import ElementTree as ET

DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
MAX_DOCX_ENTRIES = 512
MAX_DOCX_ENTRY_BYTES = 24 * 1024 * 1024
MAX_DOCX_EXPANDED_BYTES = 48 * 1024 * 1024
MAX_DOCX_XML_ENTRY_BYTES = 8 * 1024 * 1024
MAX_DOCX_XML_TOTAL_BYTES = 16 * 1024 * 1024

_CONTENT_TYPES_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
_PACKAGE_RELS_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
_WORD_MAIN_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
_WORD_NAMESPACES = {
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "http://purl.oclc.org/ooxml/wordprocessingml/main",
}
_OFFICE_DOCUMENT_REL_TYPES = {
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
    "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument",
}
_REQUIRED = {"[Content_Types].xml", "_rels/.rels", "word/document.xml"}


def _parse_xml(data: bytes, *, label: str) -> ET.Element:
    upper = data.upper()
    if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
        raise ValueError(f"DOCX {label} 包含不允许的 XML 实体/DOCTYPE。")
    try:
        return ET.fromstring(data)
    except ET.ParseError as exc:
        raise ValueError(f"DOCX {label} XML 无法解析。") from exc


def _safe_entry_name(name: str) -> bool:
    if not name or "\\" in name or "\x00" in name or name.startswith("/"):
        return False
    parts = name.split("/")
    # A trailing empty segment is allowed only for directory entries; interior
    # empty/dot/parent segments are never valid package paths.
    check = parts[:-1] if name.endswith("/") else parts
    return all(part not in {"", ".", ".."} for part in check)


def validate_docx_package(data: bytes) -> Dict[str, Any]:
    """Return bounded structural evidence for a genuine DOCX package.

    Every archive member is streamed to EOF (without extracting to disk) after
    central-directory size checks. This verifies CRC/compressed-stream integrity
    while keeping entry count, per-entry expansion, aggregate expansion and XML
    parsing inside explicit limits.
    """
    if not data.startswith(b"PK\x03\x04"):
        raise ValueError("DOCX 不是有效的 ZIP/OOXML 容器。")
    try:
        archive = zipfile.ZipFile(io.BytesIO(data), "r")
        infos = archive.infolist()
    except (zipfile.BadZipFile, OSError, ValueError) as exc:
        raise ValueError("DOCX 不是有效的 ZIP/OOXML 容器。") from exc

    try:
        if not infos or len(infos) > MAX_DOCX_ENTRIES:
            raise ValueError(f"DOCX package 条目数超过上限 {MAX_DOCX_ENTRIES}。")

        seen: set[str] = set()
        seen_folded: set[str] = set()
        expanded_total = 0
        xml_total = 0
        xml_entries: Dict[str, bytes] = {}

        for info in infos:
            name = info.filename
            if not _safe_entry_name(name):
                raise ValueError("DOCX package 包含不安全的 entry 路径。")
            folded = name.casefold()
            if name in seen or folded in seen_folded:
                raise ValueError("DOCX package 包含重复 entry。")
            seen.add(name)
            seen_folded.add(folded)
            if info.flag_bits & 0x1:
                raise ValueError("DOCX package 不能包含加密 entry。")
            if info.is_dir():
                continue
            if info.file_size < 0 or info.file_size > MAX_DOCX_ENTRY_BYTES:
                raise ValueError("DOCX package 单个 entry 展开后过大。")
            expanded_total += info.file_size
            if expanded_total > MAX_DOCX_EXPANDED_BYTES:
                raise ValueError("DOCX package 展开体积超过安全上限。")

            is_xml = name.lower().endswith((".xml", ".rels"))
            if is_xml:
                if info.file_size > MAX_DOCX_XML_ENTRY_BYTES:
                    raise ValueError("DOCX XML entry 超过安全上限。")
                xml_total += info.file_size
                if xml_total > MAX_DOCX_XML_TOTAL_BYTES:
                    raise ValueError("DOCX XML 总展开体积超过安全上限。")

            actual = 0
            captured = bytearray()
            try:
                with archive.open(info, "r") as stream:
                    while True:
                        chunk = stream.read(64 * 1024)
                        if not chunk:
                            break
                        actual += len(chunk)
                        if actual > info.file_size or actual > MAX_DOCX_ENTRY_BYTES:
                            raise ValueError("DOCX package entry 实际展开体积异常。")
                        if is_xml:
                            captured.extend(chunk)
            except (zipfile.BadZipFile, RuntimeError, OSError) as exc:
                raise ValueError("DOCX package 压缩数据损坏。") from exc
            if actual != info.file_size:
                raise ValueError("DOCX package entry 展开体积与目录记录不一致。")
            if is_xml:
                xml_entries[name] = bytes(captured)

        missing = sorted(_REQUIRED - seen)
        if missing:
            raise ValueError("DOCX package 缺少必要 OOXML entry：" + "、".join(missing))

        content_types = _parse_xml(xml_entries["[Content_Types].xml"], label="[Content_Types].xml")
        if content_types.tag != f"{{{_CONTENT_TYPES_NS}}}Types":
            raise ValueError("DOCX [Content_Types].xml 根节点无效。")
        overrides = [
            node for node in content_types.findall(f"{{{_CONTENT_TYPES_NS}}}Override")
            if node.attrib.get("PartName") == "/word/document.xml"
        ]
        if len(overrides) != 1 or overrides[0].attrib.get("ContentType") != _WORD_MAIN_CONTENT_TYPE:
            raise ValueError("DOCX 主文档 Content-Type 与 WordprocessingML 不匹配。")

        package_rels = _parse_xml(xml_entries["_rels/.rels"], label="_rels/.rels")
        if package_rels.tag != f"{{{_PACKAGE_RELS_NS}}}Relationships":
            raise ValueError("DOCX package relationship 根节点无效。")
        office_links = [
            node for node in package_rels.findall(f"{{{_PACKAGE_RELS_NS}}}Relationship")
            if node.attrib.get("Type") in _OFFICE_DOCUMENT_REL_TYPES
        ]
        if len(office_links) != 1:
            raise ValueError("DOCX package 必须且只能有一个 officeDocument relationship。")
        office_link = office_links[0]
        if office_link.attrib.get("TargetMode", "Internal").lower() == "external":
            raise ValueError("DOCX officeDocument relationship 不能指向外部资源。")
        if office_link.attrib.get("Target", "").lstrip("/") != "word/document.xml":
            raise ValueError("DOCX officeDocument relationship 未指向 word/document.xml。")

        document = _parse_xml(xml_entries["word/document.xml"], label="word/document.xml")
        if not (document.tag.startswith("{")
                and document.tag.split("}", 1)[0][1:] in _WORD_NAMESPACES
                and document.tag.rsplit("}", 1)[-1] == "document"):
            raise ValueError("DOCX word/document.xml 不是受支持的 WordprocessingML document。")

        document_rels = xml_entries.get("word/_rels/document.xml.rels")
        if document_rels is not None:
            rel_root = _parse_xml(document_rels, label="word/_rels/document.xml.rels")
            if rel_root.tag != f"{{{_PACKAGE_RELS_NS}}}Relationships":
                raise ValueError("DOCX 主文档 relationship 根节点无效。")

        return {
            "format": "docx",
            "package_verified": True,
            "entry_count": len(infos),
            "expanded_bytes": expanded_total,
            "main_part": "word/document.xml",
            "main_content_type": _WORD_MAIN_CONTENT_TYPE,
        }
    finally:
        archive.close()
