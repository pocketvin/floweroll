from __future__ import annotations

import hashlib
import io
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import warnings
import zipfile
from pathlib import Path
from unittest import mock
from urllib.parse import quote

from floweroll_host.docx_package import DOCX_MIME, validate_docx_package
from floweroll_host.server import create_server
from floweroll_host.storage import Storage
from floweroll_host.task_assets import TaskAssetStore

_CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="{main_content_type}"/>
</Types>
"""
_ROOT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="{target}"{target_mode}/>
</Relationships>
"""
_DOCUMENT_XML = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>小卷 DOCX intake fixture</w:t></w:r></w:p><w:sectPr/></w:body>
</w:document>
"""
_DOCUMENT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
"""
_WORD_MAIN = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"


def make_docx(
    *,
    missing: set[str] | None = None,
    main_content_type: str = _WORD_MAIN,
    target: str = "word/document.xml",
    external_target: bool = False,
    document_xml: str = _DOCUMENT_XML,
    extras: list[tuple[str, bytes]] | None = None,
) -> bytes:
    missing = missing or set()
    entries: list[tuple[str, bytes]] = [
        ("[Content_Types].xml", _CONTENT_TYPES.format(main_content_type=main_content_type).encode()),
        ("_rels/.rels", _ROOT_RELS.format(
            target=target,
            target_mode=' TargetMode="External"' if external_target else "",
        ).encode()),
        ("word/document.xml", document_xml.encode()),
        ("word/_rels/document.xml.rels", _DOCUMENT_RELS.encode()),
    ]
    entries = [(name, body) for name, body in entries if name not in missing]
    entries.extend(extras or [])
    buffer = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, body in entries:
                archive.writestr(name, body)
    return buffer.getvalue()


class DocxPackageValidationTests(unittest.TestCase):
    def test_valid_minimal_package_returns_bounded_structural_evidence(self) -> None:
        raw = make_docx()
        evidence = validate_docx_package(raw)
        self.assertTrue(evidence["package_verified"])
        self.assertEqual(evidence["format"], "docx")
        self.assertEqual(evidence["main_part"], "word/document.xml")
        self.assertEqual(evidence["main_content_type"], _WORD_MAIN)
        self.assertEqual(evidence["entry_count"], 4)
        self.assertGreater(evidence["expanded_bytes"], 0)

    def test_fake_and_structurally_incomplete_packages_fail_closed(self) -> None:
        cases = {
            "not_zip": b"not a docx",
            "missing_content_types": make_docx(missing={"[Content_Types].xml"}),
            "missing_root_rels": make_docx(missing={"_rels/.rels"}),
            "missing_document": make_docx(missing={"word/document.xml"}),
            "wrong_main_content_type": make_docx(main_content_type="application/xml"),
            "wrong_office_target": make_docx(target="word/other.xml"),
            "external_office_target": make_docx(target="https://example.invalid/document.xml", external_target=True),
            "malformed_document_xml": make_docx(document_xml="<w:document>"),
            "path_traversal": make_docx(extras=[("../escape.bin", b"x")]),
            "casefold_duplicate": make_docx(extras=[("WORD/DOCUMENT.XML", b"duplicate")]),
        }
        for label, raw in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                validate_docx_package(raw)

    def test_archive_entry_expansion_and_xml_bounds_are_enforced(self) -> None:
        raw = make_docx(extras=[("word/media/filler.bin", b"A" * 4096)])
        with mock.patch("floweroll_host.docx_package.MAX_DOCX_ENTRIES", 3):
            with self.assertRaises(ValueError):
                validate_docx_package(make_docx())
        with mock.patch("floweroll_host.docx_package.MAX_DOCX_EXPANDED_BYTES", 1024):
            with self.assertRaises(ValueError):
                validate_docx_package(raw)
        with mock.patch("floweroll_host.docx_package.MAX_DOCX_XML_ENTRY_BYTES", 128):
            with self.assertRaises(ValueError):
                validate_docx_package(make_docx())
        with mock.patch("floweroll_host.docx_package.MAX_DOCX_XML_TOTAL_BYTES", 256):
            with self.assertRaises(ValueError):
                validate_docx_package(make_docx())

    def test_doctype_or_entity_declarations_are_rejected(self) -> None:
        xml = """<?xml version="1.0"?><!DOCTYPE w:document [<!ENTITY x "bad">]>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>"""
        with self.assertRaises(ValueError):
            validate_docx_package(make_docx(document_xml=xml))


class DocxTaskAssetStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.storage = Storage(str(Path(self.tmp.name) / "runtime.sqlite3"))
        self.assets = TaskAssetStore(Path(self.tmp.name) / "materials", self.storage)
        self.storage.create_or_get_task(
            task_id="docx-task",
            goal="处理 DOCX",
            invocation_source="unit",
            policy_snapshot={},
            submission_id="docx-submission",
            status="active",
        )

    def tearDown(self) -> None:
        self.assets.close()
        self.tmp.cleanup()

    def test_verified_docx_upload_preserves_identity_manifest_and_bytes(self) -> None:
        raw = make_docx()
        digest = hashlib.sha256(raw).hexdigest()
        item = self.assets.upload(
            file_id="input-docx",
            name="面试简历.DOCX",
            media_type=DOCX_MIME,
            data=raw,
            sha256=digest,
        )
        self.assertEqual(item["name"], "面试简历.DOCX")
        self.assertEqual(item["media_type"], DOCX_MIME)
        self.assertEqual(item["size_bytes"], len(raw))
        self.assertEqual(item["sha256"], digest)
        self.assertTrue(item["metadata"]["package_verified"])
        self.assertEqual(item["metadata"]["origin"], "user_upload")

        self.assets.bind("submission:docx-submission", [item["id"]])
        manifest = self.assets.manifest("docx-task")
        self.assertEqual(len(manifest["inputs"]), 1)
        self.assertEqual(manifest["inputs"][0], item)
        path = self.assets.file_path("docx-task", item["id"])
        self.assertEqual(path.suffix, ".docx")
        self.assertEqual(path.read_bytes(), raw)

    def test_docx_mime_extension_and_package_must_all_agree(self) -> None:
        raw = make_docx()
        digest = hashlib.sha256(raw).hexdigest()
        cases = [
            ("wrong-name", "resume.pdf", DOCX_MIME, raw),
            ("wrong-mime", "resume.docx", "application/pdf", raw),
            ("generic-zip", "resume.docx", "application/zip", raw),
            ("fake-package", "resume.docx", DOCX_MIME, b"PK\x03\x04fake"),
        ]
        for fid, name, media, data in cases:
            with self.subTest(fid=fid), self.assertRaises(ValueError):
                self.assets.upload(
                    file_id=fid,
                    name=name,
                    media_type=media,
                    data=data,
                    sha256=hashlib.sha256(data).hexdigest(),
                )

    def test_future_generated_docx_can_use_generic_verified_output_path(self) -> None:
        raw = make_docx()
        action_id = "future-docx-output"
        self.storage.create_action(
            action_id=action_id,
            task_id="docx-task",
            step_index=1,
            action_type="test.material.docx-output",
            payload={},
            expected={},
            idempotency_key="future-docx-output",
            on_verified="REPLAN",
        )
        item = self.assets.publish_bytes(
            task_id="docx-task",
            action_id=action_id,
            name="生成结果.docx",
            media_type=DOCX_MIME,
            data=raw,
            category="document",
            metadata={"label": "DOCX 已生成"},
        )
        self.assertTrue(item["metadata"]["package_verified"])
        self.assertEqual(self.assets.verify_unit_file("docx-task", action_id, item["id"]).suffix, ".docx")
        self.storage.record_verified_observation(
            task_id="docx-task",
            action_id=action_id,
            capability="test.material.docx-output",
            data={"file_id": item["id"], "sha256": item["sha256"]},
        )
        delivered = self.assets.manifest("docx-task")["outputs"]
        self.assertEqual([row["id"] for row in delivered], [item["id"]])
        self.assertEqual(self.assets.file_path("docx-task", item["id"]).read_bytes(), raw)

        with self.assertRaises(ValueError):
            self.assets.publish_bytes(
                task_id="docx-task",
                action_id="bad-docx-output",
                name="bad.docx",
                media_type=DOCX_MIME,
                data=b"not OOXML",
                category="document",
                metadata={},
            )


class DocxHTTPIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.server = create_server(
            "127.0.0.1",
            0,
            str(root / "runtime.sqlite3"),
            auth_token="test-pair-token",
            task_asset_root=root / "materials",
        )
        self.server.app.supervisor.stop()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.tmp.cleanup()

    def request(self, path: str, *, data: bytes | dict | None = None, headers: dict[str, str] | None = None):
        request_headers = {"Authorization": "Bearer test-pair-token"}
        request_headers.update(headers or {})
        if isinstance(data, dict):
            data = json.dumps(data).encode()
            request_headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.url + path, data=data, headers=request_headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as result:
                # HTTP field names are case-insensitive. Keep HTTPMessage's
                # lookup semantics when the ASGI server emits lowercase names.
                return result.status, result.read(), result.headers
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read(), exc.headers

    def test_user_docx_upload_manifest_and_authenticated_download_roundtrip(self) -> None:
        raw = make_docx()
        digest = hashlib.sha256(raw).hexdigest()
        status, body, _ = self.request(
            "/v1/files",
            data=raw,
            headers={
                "Content-Type": DOCX_MIME,
                "X-File-ID": "http-docx",
                "X-File-Name": quote("候选人资料.docx"),
                "X-Content-SHA256": digest,
            },
        )
        self.assertEqual(status, 201, body)
        uploaded = json.loads(body)
        self.assertEqual(uploaded["media_type"], DOCX_MIME)
        self.assertEqual(uploaded["sha256"], digest)
        self.assertEqual(uploaded["size_bytes"], len(raw))
        self.assertTrue(uploaded["metadata"]["package_verified"])

        status, body, _ = self.request("/v1/tasks", data={
            "submission_id": "docx-http-submission",
            "input": {"kind": "text", "text": "读取这个 Word 文件", "attachment_ids": ["http-docx"]},
            "invocation_source": "unit",
        })
        self.assertEqual(status, 201, body)
        task_id = json.loads(body)["task_id"]

        status, body, _ = self.request(f"/v1/tasks/{task_id}/materials")
        self.assertEqual(status, 200, body)
        material = json.loads(body)["inputs"][0]
        self.assertEqual(material["name"], "候选人资料.docx")
        self.assertEqual(material["media_type"], DOCX_MIME)
        self.assertEqual(material["sha256"], digest)
        self.assertEqual(material["size_bytes"], len(raw))

        status, body, headers = self.request(f"/v1/tasks/{task_id}/files/http-docx")
        self.assertEqual(status, 200)
        self.assertEqual(body, raw)
        self.assertEqual(headers.get("Content-Type"), DOCX_MIME)
        self.assertEqual(headers.get("X-Content-SHA256"), digest)
        self.assertIn(".docx", headers.get("Content-Disposition", ""))

    def test_future_generated_docx_download_uses_existing_verified_http_path(self) -> None:
        status, body, _ = self.request("/v1/tasks", data={
            "submission_id": "docx-generated-submission",
            "input": {"kind": "text", "text": "生成 Word 文件", "attachment_ids": []},
            "invocation_source": "unit",
        })
        self.assertEqual(status, 201, body)
        task_id = json.loads(body)["task_id"]
        action_id = "future-generated-docx"
        self.server.app.storage.create_action(
            action_id=action_id, task_id=task_id, step_index=1,
            action_type="test.material.docx-output", payload={}, expected={},
            idempotency_key=action_id, on_verified="REPLAN",
        )
        raw = make_docx()
        item = self.server.app.task_assets.publish_bytes(
            task_id=task_id, action_id=action_id, name="未来生成结果.docx",
            media_type=DOCX_MIME, data=raw, category="document", metadata={"label": "DOCX 已生成"},
        )
        self.server.app.storage.record_verified_observation(
            task_id=task_id, action_id=action_id, capability="test.material.docx-output",
            data={"file_id": item["id"], "sha256": item["sha256"]},
        )

        status, body, _ = self.request(f"/v1/tasks/{task_id}/materials")
        self.assertEqual(status, 200, body)
        output = json.loads(body)["outputs"][0]
        self.assertEqual(output["name"], "未来生成结果.docx")
        self.assertEqual(output["media_type"], DOCX_MIME)
        self.assertTrue(output["metadata"]["package_verified"])

        status, body, headers = self.request(f"/v1/tasks/{task_id}/files/{item['id']}")
        self.assertEqual(status, 200)
        self.assertEqual(body, raw)
        self.assertEqual(headers.get("Content-Type"), DOCX_MIME)
        self.assertIn(".docx", headers.get("Content-Disposition", ""))
        self.assertEqual(headers.get("X-Content-SHA256"), hashlib.sha256(raw).hexdigest())

    def test_http_rejects_fake_docx_and_mime_package_mismatch(self) -> None:
        fake = b"PK\x03\x04not-a-real-package"
        status, body, _ = self.request(
            "/v1/files",
            data=fake,
            headers={
                "Content-Type": DOCX_MIME,
                "X-File-ID": "fake-docx",
                "X-File-Name": "fake.docx",
                "X-Content-SHA256": hashlib.sha256(fake).hexdigest(),
            },
        )
        self.assertEqual(status, 400, body)
        self.assertEqual(json.loads(body)["code"], "INVALID_ATTACHMENT")

        raw = make_docx()
        status, body, _ = self.request(
            "/v1/files",
            data=raw,
            headers={
                "Content-Type": "application/pdf",
                "X-File-ID": "mismatch-docx",
                "X-File-Name": "mismatch.docx",
                "X-Content-SHA256": hashlib.sha256(raw).hexdigest(),
            },
        )
        self.assertEqual(status, 400, body)
        self.assertEqual(json.loads(body)["code"], "INVALID_ATTACHMENT")


if __name__ == "__main__":
    unittest.main()
