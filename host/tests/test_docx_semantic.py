from __future__ import annotations

import hashlib
import io
import json
import platform
import subprocess
import tempfile
import unittest
import uuid
import zipfile
from pathlib import Path
from unittest import mock

from floweroll_host.capability_discovery import rank_capabilities
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.docx_package import DOCX_MIME, validate_docx_package
from floweroll_host.docx_semantic import (
    FORMAT_PROFILE,
    GENERATE_ID,
    INSPECT_ID,
    MAX_INSPECT_CHARS,
    DocxSemanticTools,
    inspect_docx_bytes,
    readiness,
    register_docx_semantic_capabilities,
    render_docx,
    validate_generate_arguments,
    validate_inspect_arguments,
)
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.server import create_server
from floweroll_host.storage import Storage
from floweroll_host.task_assets import TaskAssetStore
from floweroll_host.task_capability_policy import EffectiveTaskCapabilityPolicy, capability_semantics
from floweroll_host.task_runtime import TaskRuntime


ROOT = Path(__file__).resolve().parents[2]
D01_DOCX = ROOT / "host/tests/fixtures/docx/roundtrip.docx"


def generate_args(*, name: str = "面试准备.docx") -> dict:
    return {
        "output_name": name,
        "title": "小卷 DOCX 生产验证 / Production Check",
        "sections": [
            {
                "heading": "项目经验",
                "paragraphs": [
                    {"text": "中文段落与 English core text 都必须保留。", "bold": True},
                    {"text": "普通段落保持独立。"},
                ],
                "bullets": ["第一项：Agent", "Second item: Python"],
            }
        ],
    }


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def with_feature_rich_document(base: bytes) -> bytes:
    """Create a package that is valid enough for admission but has unsupported Word features."""
    document = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">
 <w:body>
  <w:p><w:pPr><w:pStyle w:val="Heading1"/><w:numPr/></w:pPr>
   <w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>Styled numbered paragraph</w:t></w:r>
  </w:p>
  <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Table cell text</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
  <w:p><w:ins><w:r><w:t>Inserted text</w:t></w:r></w:ins><w:del><w:r><w:delText>Deleted text</w:delText></w:r></w:del></w:p>
  <w:p><w:r><w:commentReference w:id="0"/></w:r></w:p>
  <w:p><w:r><w:drawing/></w:r></w:p>
  <w:p><m:oMath><m:r><m:t>x+y</m:t></m:r></m:oMath></w:p>
 </w:body>
</w:document>'''
    source = zipfile.ZipFile(io.BytesIO(base), "r")
    entries = {info.filename: source.read(info) for info in source.infolist()}
    source.close()
    entries["word/document.xml"] = document
    entries["word/comments.xml"] = b'''<?xml version="1.0" encoding="UTF-8"?><w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'''
    entries["word/header1.xml"] = b'''<?xml version="1.0" encoding="UTF-8"?><w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:hdr>'''
    entries["word/footnotes.xml"] = b'''<?xml version="1.0" encoding="UTF-8"?><w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'''
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return buffer.getvalue()


class DocxSemanticContractTests(unittest.TestCase):
    def test_readiness_is_dependency_free_deterministic_and_bounded(self) -> None:
        health = readiness()
        self.assertTrue(health["ready"])
        self.assertEqual(health["engine"], "python-stdlib-ooxml")
        self.assertTrue(health["deterministic_generation"])
        self.assertFalse(health["network"])
        self.assertFalse(health["credentials"])
        self.assertFalse(health["new_dependencies"])
        self.assertIn("arbitrary_existing_docx_editing", health["unsupported"])
        self.assertIn("true_table_generation", health["unsupported"])
        self.assertIn("tracked_changes", health["unsupported"])

    def test_registry_contract_profiles_and_semantics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Storage(":memory:")
            assets = TaskAssetStore(Path(tmp) / "materials", store)
            registry = CapabilityRegistry()
            try:
                executors, health = register_docx_semantic_capabilities(registry, assets=assets)
                self.assertTrue(health["ready"])
                self.assertEqual(set(executors), {INSPECT_ID, GENERATE_ID})
                inspect = registry.get(INSPECT_ID)
                generate = registry.get(GENERATE_ID)
                self.assertEqual(inspect.source.kind, "task_material")
                self.assertEqual(inspect.source.metadata["operation"], "read")
                self.assertTrue(inspect.source.metadata["read_only"])
                self.assertEqual(generate.source.metadata["operation"], "write")
                self.assertFalse(generate.source.metadata["read_only"])
                self.assertEqual(generate.source.metadata["effect"], "local_file")
                self.assertIn("document", generate.source.metadata["domains"])
                self.assertEqual(inspect.adapter.execution_profile.verification_mode, "DOCX_SOURCE_READBACK")
                self.assertEqual(generate.adapter.execution_profile.verification_mode, "DOCX_ARTIFACT_READBACK")
                self.assertEqual(generate.adapter.execution_profile.idempotency_mode, "EXACT_INPUT")
                self.assertEqual(inspect.spec.post_verify_mode, "REPLAN_REQUIRED")
                self.assertEqual(generate.spec.post_verify_mode, "COMPLETE_ALLOWED")
                self.assertEqual(capability_semantics(inspect.spec, registry).operation, "read")
                self.assertEqual(capability_semantics(generate.spec, registry).operation, "write")
            finally:
                assets.close()

    def test_registration_fails_closed_when_readiness_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Storage(":memory:")
            assets = TaskAssetStore(Path(tmp) / "materials", store)
            registry = CapabilityRegistry()
            try:
                with mock.patch("floweroll_host.docx_semantic.readiness", return_value={"ready": False, "reason": "self_test_failed"}):
                    executors, health = register_docx_semantic_capabilities(registry, assets=assets)
                self.assertEqual(executors, {})
                self.assertFalse(health["ready"])
                self.assertNotIn(INSPECT_ID, registry)
                self.assertNotIn(GENERATE_ID, registry)
            finally:
                assets.close()

    def test_direct_payload_validation_is_stricter_than_schema_trust(self) -> None:
        valid = validate_generate_arguments(generate_args())
        self.assertEqual(valid["output_name"], "面试准备.docx")
        self.assertEqual(validate_generate_arguments(generate_args(name="结果"))["output_name"], "结果.docx")
        self.assertEqual(validate_inspect_arguments({"file_id": "docx-one"})["max_chars"], 20_000)

        invalid_inspect = [
            [],
            {"file_id": []},
            {"file_id": "../docx"},
            {"file_id": "x", "max_chars": True},
            {"file_id": "x", "max_chars": 255},
            {"file_id": "x", "extra": "no"},
        ]
        for value in invalid_inspect:
            with self.subTest(inspect=value), self.assertRaises(Exception):
                validate_inspect_arguments(value)

        invalid_generate = [
            [],
            {**generate_args(), "tables": []},
            {**generate_args(), "html": "<table/>"},
            {**generate_args(), "output_name": "../result.docx"},
            {**generate_args(), "output_name": "result.pdf"},
            {**generate_args(), "sections": "not-array"},
            {
                **generate_args(),
                "sections": [{"heading": "h", "paragraphs": [{"text": "x", "bold": "yes"}], "bullets": []}],
            },
            {
                **generate_args(),
                "sections": [{"heading": "h", "paragraphs": [{"text": "x", "italic": True}], "bullets": []}],
            },
        ]
        for value in invalid_generate:
            with self.subTest(generate=value), self.assertRaises(Exception):
                validate_generate_arguments(value)

    def test_task_read_only_policy_allows_inspect_denies_generate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Storage(":memory:")
            assets = TaskAssetStore(Path(tmp) / "materials", store)
            registry = CapabilityRegistry()
            try:
                register_docx_semantic_capabilities(registry, assets=assets)
                policy = EffectiveTaskCapabilityPolicy.from_texts(["这个任务只读文档，不要修改或写入文档"])
                self.assertTrue(policy.allows(registry.get(INSPECT_ID).spec, registry))
                self.assertFalse(policy.allows(registry.get(GENERATE_ID).spec, registry))
            finally:
                assets.close()

    def test_discovery_ranks_semantic_ids_without_converter_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Storage(":memory:")
            assets = TaskAssetStore(Path(tmp) / "materials", store)
            registry = CapabilityRegistry()
            try:
                register_docx_semantic_capabilities(registry, assets=assets)
                specs = registry.planner_capabilities()
                generated = rank_capabilities(specs, "帮我生成一个 DOCX Word 文档", registry)
                inspected = rank_capabilities(specs, "读取这个 DOCX Word 文档", registry)
                self.assertEqual(generated[0].name, GENERATE_ID)
                self.assertEqual(inspected[0].name, INSPECT_ID)
                serialized = json.dumps([spec.description for spec in specs], ensure_ascii=False)
                self.assertNotIn("textutil", serialized)
                self.assertNotIn("/usr/bin", serialized)
            finally:
                assets.close()

    def test_presentation_is_semantic_not_converter_copy(self) -> None:
        self.assertEqual(capability_label(INSPECT_ID), "读取 Word 文档")
        self.assertEqual(capability_label(GENERATE_ID), "生成 Word 文档")
        self.assertEqual(capability_activity_title(INSPECT_ID, "active"), "正在读取 Word 文档")
        self.assertEqual(capability_activity_title(GENERATE_ID, "complete"), "Word 文档已生成并核验")


class DocxSemanticPackageTests(unittest.TestCase):
    def test_generation_is_byte_deterministic_valid_and_semantically_exact(self) -> None:
        args = generate_args()
        first = render_docx(args)
        second = render_docx(args)
        self.assertEqual(first, second)
        package = validate_docx_package(first)
        self.assertTrue(package["package_verified"])
        readback = inspect_docx_bytes(first, max_chars=10_000)
        self.assertIn("小卷 DOCX 生产验证", readback["text"])
        self.assertIn("中文段落与 English core text", readback["text"])
        self.assertIn("• 第一项：Agent", readback["text"])
        self.assertEqual(readback["paragraph_count"], 6)
        self.assertEqual(readback["structure"]["table_count"], 0)
        self.assertEqual(readback["structure"]["numbering_paragraph_count"], 0)
        self.assertGreaterEqual(readback["structure"]["direct_bold_run_count"], 3)
        self.assertEqual(readback["features"]["unsupported_detected"], [])
        self.assertEqual(readback["properties"]["title"], args["title"])
        self.assertEqual(readback["properties"]["creator"], "小卷")
        self.assertEqual(readback["format_profile"], FORMAT_PROFILE)

    @unittest.skipUnless(platform.system() == "Darwin", "textutil independent readback requires macOS")
    def test_system_textutil_independently_reads_generated_bilingual_content(self) -> None:
        data = render_docx(generate_args())
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "generated.docx"
            path.write_bytes(data)
            completed = subprocess.run(
                ["/usr/bin/textutil", "-convert", "txt", "-stdout", str(path)],
                capture_output=True,
                timeout=15,
                check=True,
            )
        text = completed.stdout.decode("utf-8")
        self.assertIn("小卷 DOCX 生产验证", text)
        self.assertIn("中文段落与 English core text", text)
        self.assertIn("Second item: Python", text)
        self.assertNotIn("\ufffd", text)

    def test_inspect_real_d01_textutil_docx(self) -> None:
        self.assertTrue(D01_DOCX.is_file())
        readback = inspect_docx_bytes(D01_DOCX.read_bytes(), max_chars=20_000)
        self.assertIn("CAP-012 DOCX 往返验证", readback["text"])
        self.assertIn("中文 item", readback["text"])
        self.assertIn("End paragraph", readback["text"])
        self.assertGreaterEqual(readback["paragraph_count"], 10)
        self.assertGreater(readback["structure"]["direct_bold_run_count"], 0)
        self.assertTrue(readback["package"]["package_verified"])

    def test_inspect_reports_unsupported_features_without_claiming_support(self) -> None:
        data = with_feature_rich_document(render_docx(generate_args()))
        self.assertTrue(validate_docx_package(data)["package_verified"])
        readback = inspect_docx_bytes(data, max_chars=20_000)
        unsupported = set(readback["features"]["unsupported_detected"])
        self.assertTrue({
            "table_structure_reconstruction",
            "semantic_numbering_reconstruction",
            "comments_content",
            "tracked_changes_semantics",
            "drawing_object_semantics",
            "formula_semantics",
            "headers_footers_text",
            "footnotes_endnotes_text",
        } <= unsupported)
        self.assertEqual(readback["structure"]["table_count"], 1)
        self.assertEqual(readback["structure"]["numbering_paragraph_count"], 1)
        self.assertIn("Heading1", readback["structure"]["paragraph_style_ids"])
        self.assertEqual(readback["structure"]["direct_italic_run_count"], 1)
        self.assertIn("Inserted text", readback["text"])
        self.assertNotIn("Deleted text", readback["text"])
        self.assertGreater(len(readback["warnings"]), 0)

    def test_malformed_package_fails_closed(self) -> None:
        for value in (b"not-a-docx", b"PK\x03\x04truncated"):
            with self.subTest(size=len(value)), self.assertRaises(Exception):
                inspect_docx_bytes(value)

    def test_text_and_paragraph_return_are_bounded(self) -> None:
        args = generate_args()
        args["sections"][0]["paragraphs"] = [{"text": "长" * 1000}]
        data = render_docx(args)
        readback = inspect_docx_bytes(data, max_chars=256)
        self.assertTrue(readback["truncated"])
        self.assertEqual(len(readback["text"]), 256)
        self.assertLessEqual(readback["paragraphs_returned"], 80)
        self.assertEqual(max(map(len, readback["paragraphs"])), 800)
        self.assertEqual(readback["paragraph_text_truncated_count"], 1)


class DocxSemanticRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="docx-semantic-")
        self.root = Path(self.tmp.name)
        self.store = Storage(str(self.root / "runtime.sqlite3"))
        self.assets = TaskAssetStore(self.root / "materials", self.store)
        self.registry = CapabilityRegistry()
        self.executors, self.health = register_docx_semantic_capabilities(self.registry, assets=self.assets)
        self.execution = ExecutionRuntime(
            self.store,
            self.registry.execution_adapters(),
            capability_specs=self.registry.planner_capabilities(include_deferred=True),
            capability_registry=self.registry,
        )
        self.worker = FunctionExecutionWorker(self.execution, self.registry, self.executors)
        self.counter = 0

    def tearDown(self) -> None:
        self.assets.close()
        self.tmp.cleanup()

    def create_task(self, *, bind_docx: bool = False, goal: str = "处理 Word 文档") -> tuple[str, str | None]:
        self.counter += 1
        task_id = f"docx-task-{self.counter}"
        submission = f"docx-sub-{self.counter}"
        self.store.create_or_get_task(
            task_id=task_id,
            goal=goal,
            invocation_source="unit",
            policy_snapshot={},
            submission_id=submission,
            status="active",
        )
        file_id = None
        if bind_docx:
            file_id = f"docx-input-{self.counter}"
            raw = render_docx(generate_args(name=f"输入-{self.counter}.docx"))
            self.assets.upload(
                file_id=file_id,
                name=f"输入-{self.counter}.docx",
                media_type=DOCX_MIME,
                data=raw,
                sha256=sha256(raw),
            )
            self.assets.bind("submission:" + submission, [file_id])
        return task_id, file_id

    def action(self, task_id: str, capability: str, payload: dict, *, action_id: str | None = None, on_verified: str = "REPLAN") -> str:
        action_id = action_id or f"{task_id}-{uuid.uuid4().hex[:8]}"
        self.store.create_action(
            action_id=action_id,
            task_id=task_id,
            step_index=1,
            action_type=capability,
            payload=payload,
            expected={},
            idempotency_key=action_id + ":idem",
            on_verified=on_verified,
        )
        return action_id

    def run_action(self, task_id: str, capability: str, payload: dict, *, on_verified: str = "REPLAN") -> tuple[str, dict]:
        action_id = self.action(task_id, capability, payload, on_verified=on_verified)
        self.assertIsNotNone(self.worker.run_once(task_id))
        attempt = self.store.action_attempts(action_id)[0]
        return action_id, attempt

    def test_user_docx_to_inspect_verified_observation_and_source_immutability(self) -> None:
        task_id, file_id = self.create_task(bind_docx=True)
        assert file_id is not None
        source = self.assets.file_path(task_id, file_id)
        before = sha256(source.read_bytes())
        _, attempt = self.run_action(task_id, INSPECT_ID, {"file_id": file_id, "max_chars": 10_000})
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        self.assertEqual(sha256(source.read_bytes()), before)
        observations = self.store.verified_observations(task_id)
        self.assertEqual(len(observations), 1)
        observation = observations[0]["data"]
        self.assertEqual(observation["file_id"], file_id)
        self.assertEqual(observation["sha256"], before)
        self.assertTrue(observation["readback"]["package"]["package_verified"])
        self.assertIn("中文段落与 English core text", observation["readback"]["text"])

    def test_cross_task_docx_inspect_is_denied(self) -> None:
        owner, file_id = self.create_task(bind_docx=True)
        other, _ = self.create_task(bind_docx=False)
        assert file_id is not None
        _, attempt = self.run_action(other, INSPECT_ID, {"file_id": file_id})
        self.assertEqual(attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
        self.assertIn("INPUT_NOT_FOUND", attempt["error"])
        self.assertEqual(self.store.verified_observations(other), [])
        self.assertTrue(self.assets.file_path(owner, file_id).exists())

    def test_malformed_direct_action_is_model_correctable_and_unobserved(self) -> None:
        cases = [
            (INSPECT_ID, {"file_id": []}),
            (INSPECT_ID, {"file_id": "x", "max_chars": True}),
            (GENERATE_ID, {**generate_args(), "tables": []}),
            (GENERATE_ID, {**generate_args(), "output_name": "../../out.docx"}),
        ]
        for index, (capability, payload) in enumerate(cases):
            with self.subTest(index=index):
                task_id, _ = self.create_task(bind_docx=False)
                action_id = self.action(task_id, capability, payload, action_id=f"malformed-docx-{index}")
                self.assertIsNotNone(self.worker.run_once(task_id))
                attempt = self.store.action_attempts(action_id)[0]
                self.assertEqual(attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
                self.assertEqual(attempt["result"]["error_code"], "INVALID_PAYLOAD")
                self.assertEqual(self.store.verified_observations(task_id), [])

    def test_generate_artifact_hidden_before_verification_then_visible_and_reinspectable(self) -> None:
        task_id, _ = self.create_task(bind_docx=False, goal="生成 Word 面试资料")
        action_id = self.action(task_id, GENERATE_ID, generate_args(), action_id="docx-generate-hidden", on_verified="COMPLETE")
        dispatch = self.execution.next_action(task_id, source_kind="task_material")
        self.assertIsNotNone(dispatch)
        executor = self.executors[GENERATE_ID]
        output = executor.invoke(dict(dispatch), dict(dispatch["payload"]))
        self.assertFalse(output["replayed_artifact"])
        self.assertEqual(self.assets.manifest(task_id)["outputs"], [])

        result = self.execution.accept_result(
            task_id=task_id,
            action_id=action_id,
            attempt_id=dispatch["attempt_id"],
            success=True,
            output=output,
            error=None,
        )
        self.assertIsNotNone(result)
        attempt = self.store.action_attempts(action_id)[0]
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        outputs = self.assets.manifest(task_id)["outputs"]
        self.assertEqual(len(outputs), 1)
        artifact = outputs[0]
        self.assertEqual(artifact["media_type"], DOCX_MIME)
        self.assertEqual(artifact["name"], "面试准备.docx")
        self.assertEqual(artifact["metadata"]["format_profile"], FORMAT_PROFILE)
        path = self.assets.file_path(task_id, artifact["id"])
        self.assertEqual(sha256(path.read_bytes()), artifact["sha256"])
        reopened = inspect_docx_bytes(path.read_bytes(), max_chars=10_000)
        self.assertEqual(reopened["semantic_fingerprint"], output["semantic_fingerprint"])
        self.assertEqual(self.store.get_task(task_id)["status"], "completed")

    def test_same_action_executor_replay_reuses_immutable_artifact(self) -> None:
        task_id, _ = self.create_task(bind_docx=False)
        self.action(task_id, GENERATE_ID, generate_args(), action_id="docx-replay")
        dispatch = self.execution.next_action(task_id, source_kind="task_material")
        self.assertIsNotNone(dispatch)
        executor = self.executors[GENERATE_ID]
        first = executor.invoke(dict(dispatch), dict(dispatch["payload"]))
        second = executor.invoke(dict(dispatch), dict(dispatch["payload"]))
        self.assertFalse(first["replayed_artifact"])
        self.assertTrue(second["replayed_artifact"])
        self.assertEqual(first["file"]["id"], second["file"]["id"])
        self.assertEqual(first["output_sha256"], second["output_sha256"])
        self.assertEqual(first["readback"]["semantic_fingerprint"], second["readback"]["semantic_fingerprint"])
        self.assertEqual(self.assets.manifest(task_id)["outputs"], [])

    def test_independent_verifier_rejects_tampered_artifact_before_observation(self) -> None:
        task_id, _ = self.create_task(bind_docx=False)
        action_id = self.action(task_id, GENERATE_ID, generate_args(), action_id="docx-tamper")
        dispatch = self.execution.next_action(task_id, source_kind="task_material")
        self.assertIsNotNone(dispatch)
        output = self.executors[GENERATE_ID].invoke(dict(dispatch), dict(dispatch["payload"]))
        fid = output["file"]["id"]
        path = self.assets.directory / (fid + ".docx")
        path.write_bytes(path.read_bytes() + b"tamper")
        self.execution.accept_result(
            task_id=task_id,
            action_id=action_id,
            attempt_id=dispatch["attempt_id"],
            success=True,
            output=output,
            error=None,
        )
        attempt = self.store.action_attempts(action_id)[0]
        self.assertEqual(attempt["latest_outcome"], "TERMINAL_FAILURE")
        self.assertEqual(self.store.verified_observations(task_id), [])
        self.assertEqual(self.assets.manifest(task_id)["outputs"], [])


class _DocxGeneratePlanner:
    def __init__(self) -> None:
        self.visible_capability_ids: list[list[str]] = []

    def decide(self, request, specs):
        self.visible_capability_ids.append([spec.name for spec in specs])
        return PlannerDecision.from_dict(
            {
                "decision_type": "EXECUTE",
                "interpreted_goal_summary": "生成可下载的 Word 文档",
                "plan_update": ["生成并核验 DOCX"],
                "action": {"capability": GENERATE_ID, "arguments": generate_args()},
                "on_verified": "COMPLETE",
                "clarification": None,
                "wait": None,
                "completion": None,
                "stop_reason": None,
                "cancellation": None,
                "state_update": None,
            },
            specs,
        )


class _DocxInspectPlanner:
    def __init__(self) -> None:
        self.file_id: str | None = None
        self.visible_capability_ids: list[list[str]] = []
        self.calls = 0
        self.saw_verified_text = False

    def decide(self, request, specs):
        self.calls += 1
        self.visible_capability_ids.append([spec.name for spec in specs])
        if self.file_id is None:
            raise AssertionError("DOCX file id was not bound before planning")
        if self.calls == 1:
            return PlannerDecision.from_dict(
                {
                    "decision_type": "EXECUTE",
                    "interpreted_goal_summary": "读取用户提供的 Word 文档",
                    "plan_update": ["读取并核对 DOCX"],
                    "action": {"capability": INSPECT_ID, "arguments": {"file_id": self.file_id, "max_chars": 10000}},
                    "on_verified": "REPLAN",
                    "clarification": None,
                    "wait": None,
                    "completion": None,
                    "stop_reason": None,
                    "cancellation": None,
                    "state_update": None,
                },
                specs,
            )
        serialized = json.dumps(request, ensure_ascii=False)
        self.saw_verified_text = "中文段落与 English core text" in serialized
        return PlannerDecision.from_dict(
            {
                "decision_type": "COMPLETE",
                "interpreted_goal_summary": "已读取 Word 文档核心内容",
                "plan_update": None,
                "action": None,
                "on_verified": None,
                "clarification": None,
                "wait": None,
                "completion": {"summary": "已读取并核对 Word 文档核心内容。"},
                "stop_reason": None,
                "cancellation": None,
                "state_update": None,
            },
            specs,
        )


class DocxSemanticHostIntegrationTests(unittest.TestCase):
    def test_host_registers_ready_docx_capabilities_and_status(self) -> None:
        with tempfile.TemporaryDirectory(prefix="docx-host-") as tmp:
            root = Path(tmp)
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "runtime.sqlite3"),
                task_asset_root=root / "materials",
            )
            server.app.supervisor.stop()
            try:
                self.assertTrue(server.app.docx_semantic_health["ready"])
                self.assertIn(INSPECT_ID, server.app.capability_registry)
                self.assertIn(GENERATE_ID, server.app.capability_registry)
                self.assertIn(INSPECT_ID, server.app.function_executors)
                self.assertIn(GENERATE_ID, server.app.function_executors)
                by_id = {row["capability_id"]: row for row in server.app.capability_status()["capabilities"]}
                self.assertTrue(by_id[INSPECT_ID]["ready"])
                self.assertTrue(by_id[GENERATE_ID]["ready"])
                self.assertEqual(by_id[INSPECT_ID]["source"]["kind"], "task_material")
                self.assertEqual(by_id[GENERATE_ID]["source"]["kind"], "task_material")
            finally:
                server.server_close()
                if server.app.task_assets is not None:
                    server.app.task_assets.close()

    def test_progressive_planner_sees_specialized_docx_inspect_for_bound_attachment(self) -> None:
        with tempfile.TemporaryDirectory(prefix="docx-planner-inspect-") as tmp:
            root = Path(tmp)
            registry = CapabilityRegistry()
            planner = _DocxInspectPlanner()
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "runtime.sqlite3"),
                capability_registry=registry,
                task_asset_root=root / "materials",
                progressive_discovery=True,
                product_policy_snapshot={
                    "allowed_capabilities": [INSPECT_ID, GENERATE_ID, "materials.inspect", "capability.search"]
                },
                task_runtime_factory=lambda storage: TaskRuntime(storage, planner, registry.planner_capabilities()),
            )
            server.app.supervisor.stop()
            try:
                raw = render_docx(generate_args(name="用户附件.docx"))
                file_id = "planner-docx-input"
                server.app.task_assets.upload(
                    file_id=file_id,
                    name="用户附件.docx",
                    media_type=DOCX_MIME,
                    data=raw,
                    sha256=sha256(raw),
                )
                planner.file_id = file_id
                task = server.app.accept_product_task(
                    goal="读取这份 Word 附件并告诉我核心内容",
                    invocation_source="unit",
                    submission_id="docx-planner-inspect",
                    attachment_ids=[file_id],
                )
                task_id = task["task_id"]
                decision = server.app.task_runtime.decide(task_id)
                visible = planner.visible_capability_ids[-1]
                self.assertIn(INSPECT_ID, visible)
                self.assertNotIn("materials.inspect", visible)
                self.assertEqual(decision["action"]["action_type"], INSPECT_ID)
                self.assertIsNotNone(server.app.function_worker.run_once(task_id))
                observation = server.app.storage.verified_observations(task_id)[0]
                self.assertEqual(observation["capability"], INSPECT_ID)
                self.assertIn("中文段落与 English core text", observation["data"]["readback"]["text"] )
                self.assertEqual(server.app.storage.get_task(task_id)["status"], "active")

                completion = server.app.task_runtime.decide(task_id)
                self.assertEqual(completion["decision"]["decision_type"], "COMPLETE")
                self.assertTrue(planner.saw_verified_text)
                self.assertEqual(planner.calls, 2)
                self.assertEqual(server.app.storage.get_task(task_id)["status"], "completed")
            finally:
                server.server_close()
                if server.app.task_assets is not None:
                    server.app.task_assets.close()

    def test_progressive_mixed_materials_keep_docx_and_generic_inspect_routes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="docx-planner-mixed-") as tmp:
            root = Path(tmp)
            registry = CapabilityRegistry()
            planner = _DocxInspectPlanner()
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "runtime.sqlite3"),
                capability_registry=registry,
                task_asset_root=root / "materials",
                progressive_discovery=True,
                product_policy_snapshot={
                    "allowed_capabilities": [INSPECT_ID, GENERATE_ID, "materials.inspect", "capability.search"]
                },
                task_runtime_factory=lambda storage: TaskRuntime(storage, planner, registry.planner_capabilities()),
            )
            server.app.supervisor.stop()
            try:
                raw = render_docx(generate_args(name="混合附件.docx"))
                docx_id = "mixed-docx"
                text_id = "mixed-text"
                server.app.task_assets.upload(
                    file_id=docx_id, name="混合附件.docx", media_type=DOCX_MIME, data=raw, sha256=sha256(raw),
                )
                text = "plain text companion".encode()
                server.app.task_assets.upload(
                    file_id=text_id, name="说明.txt", media_type="text/plain", data=text, sha256=sha256(text),
                )
                planner.file_id = docx_id
                task = server.app.accept_product_task(
                    goal="先读取 Word，同时参考文本附件",
                    invocation_source="unit",
                    submission_id="docx-planner-mixed",
                    attachment_ids=[docx_id, text_id],
                )
                server.app.task_runtime.decide(task["task_id"])
                visible = planner.visible_capability_ids[-1]
                self.assertIn(INSPECT_ID, visible)
                self.assertIn("materials.inspect", visible)
            finally:
                server.server_close()
                if server.app.task_assets is not None:
                    server.app.task_assets.close()

    def test_planner_runtime_to_verified_docx_artifact_end_to_end(self) -> None:
        with tempfile.TemporaryDirectory(prefix="docx-planner-e2e-") as tmp:
            root = Path(tmp)
            registry = CapabilityRegistry()
            planner = _DocxGeneratePlanner()
            server = create_server(
                "127.0.0.1",
                0,
                str(root / "runtime.sqlite3"),
                capability_registry=registry,
                task_asset_root=root / "materials",
                product_policy_snapshot={"allowed_capabilities": [GENERATE_ID, INSPECT_ID]},
                task_runtime_factory=lambda storage: TaskRuntime(storage, planner, registry.planner_capabilities()),
            )
            server.app.supervisor.stop()
            try:
                task = server.app.accept_product_task(
                    goal="给我生成一个 Word 面试准备文档",
                    invocation_source="unit",
                    submission_id="docx-planner-e2e",
                )
                task_id = task["task_id"]
                decision = server.app.task_runtime.decide(task_id)
                self.assertEqual(decision["action"]["action_type"], GENERATE_ID)
                self.assertIn(GENERATE_ID, planner.visible_capability_ids[-1])
                self.assertIn(INSPECT_ID, planner.visible_capability_ids[-1])
                self.assertEqual(server.app.task_assets.manifest(task_id)["outputs"], [])

                self.assertIsNotNone(server.app.function_worker.run_once(task_id))
                completed = server.app.storage.get_task(task_id)
                self.assertEqual(completed["status"], "completed")
                observations = server.app.storage.verified_observations(task_id)
                self.assertEqual(len(observations), 1)
                self.assertEqual(observations[0]["capability"], GENERATE_ID)
                artifact = server.app.task_assets.manifest(task_id)["outputs"][0]
                self.assertEqual(artifact["media_type"], DOCX_MIME)
                path = server.app.task_assets.file_path(task_id, artifact["id"])
                readback = inspect_docx_bytes(path.read_bytes(), max_chars=10_000)
                self.assertEqual(readback["semantic_fingerprint"], observations[0]["data"]["semantic_fingerprint"])
                self.assertIn("中文段落与 English core text", readback["text"])
            finally:
                server.server_close()
                if server.app.task_assets is not None:
                    server.app.task_assets.close()

    def test_run_host_explicit_policy_allowlist_mentions_docx_semantic_ids(self) -> None:
        source = (ROOT / "host/run_host.py").read_text()
        self.assertIn("DOCX_INSPECT_ID", source)
        self.assertIn("DOCX_GENERATE_ID", source)
        self.assertIn("allowed_capabilities", source)


if __name__ == "__main__":
    unittest.main()
