from __future__ import annotations

import hashlib
import json
import platform
import subprocess
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.mac_perception_tools import MacPerceptionToolSet
from floweroll_host.storage import Storage
from floweroll_host.task_assets import TaskAssetStore
from floweroll_host.task_material_tools import register_task_material_capabilities


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "host" / "tests" / "fixtures" / "document_quality"
REAL_CAMERA = FIXTURES / "real_camera"


@unittest.skipUnless(platform.system() == "Darwin", "Vision/PDFKit quality proof requires macOS")
class NativeDocumentQualityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix="document-quality-native-")
        cls.root = Path(cls.temp.name)
        cls.synthetic = cls.root / "synthetic"
        cls.synthetic.mkdir()
        subprocess.run(
            ["/usr/bin/xcrun", "swift", str(FIXTURES / "SyntheticDocumentFixtures.swift"), str(cls.synthetic)],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        cls.workshop = cls.root / "DocumentWorkshop"
        subprocess.run(
            ["/usr/bin/xcrun", "swiftc", "-O", str(ROOT / "host/native_helpers/DocumentWorkshop.swift"), "-o", str(cls.workshop)],
            check=True,
            capture_output=True,
            text=True,
            timeout=90,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def run_workshop(self, path: Path, *, scan: bool = True) -> dict:
        output = self.root / f"{uuid.uuid4().hex}.pdf"
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        request = {
            "operation": "images_to_pdf",
            "paths": [str(path)],
            "output": str(output),
            "scan": scan,
            "pages": [],
        }
        completed = subprocess.run(
            [str(self.workshop)],
            input=json.dumps(request).encode(),
            capture_output=True,
            check=False,
            timeout=60,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
        value = json.loads(completed.stdout)
        self.assertTrue(value["structural_verified"])
        self.assertEqual(value["page_count"], 1)
        self.assertEqual(value["rendered_pages"], [{"page": 1, "renderable": True}])
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before, "source bytes must remain immutable")
        self.assertTrue(output.read_bytes().startswith(b"%PDF-"))
        return value

    def test_synthetic_safe_perspective_and_visual_guards(self) -> None:
        edge = self.run_workshop(self.synthetic / "03-edge-content.png")["pages"][0]
        self.assertEqual(edge["scan_decision"], "preserve_near_full_frame")
        self.assertFalse(edge["perspective_corrected"])
        self.assertFalse(edge["needs_visual_review"])
        edge_metrics = edge["visual_metrics"]
        self.assertTrue(edge_metrics["black_background_guard_pass"])
        self.assertFalse(edge_metrics["white_wedge_introduced"])
        self.assertTrue(edge_metrics["edge_chromatic_retention"])
        for name, ratio in edge_metrics["edge_chromatic_retention"].items():
            self.assertGreaterEqual(ratio, 0.80, f"{name} edge must retain >=80% chromatic coverage")

        perspective = self.run_workshop(self.synthetic / "04-light-perspective.png")["pages"][0]
        self.assertEqual(perspective["scan_decision"], "perspective_corrected")
        self.assertTrue(perspective["perspective_corrected"])
        self.assertTrue(perspective["visual_metrics"]["black_background_guard_pass"])

        shadow = self.run_workshop(self.synthetic / "05-shadow-uneven.png")["pages"][0]
        self.assertEqual(shadow["scan_decision"], "perspective_corrected")
        self.assertTrue(shadow["perspective_corrected"])
        self.assertTrue(shadow["visual_metrics"]["black_background_guard_pass"])

        stamp = self.run_workshop(self.synthetic / "02-color-red-stamp.png")["pages"][0]
        self.assertTrue(stamp["visual_metrics"]["black_background_guard_pass"])
        self.assertIsNotNone(stamp["visual_metrics"]["red_retention_ratio"])
        self.assertGreaterEqual(stamp["visual_metrics"]["red_retention_ratio"], 0.50)

        uncertain = self.run_workshop(self.synthetic / "01-clean-white-black.png")["pages"][0]
        self.assertFalse(uncertain["perspective_corrected"])
        self.assertTrue(uncertain["needs_visual_review"], "insufficient corner confidence must remain explicit")

    def test_small_public_real_camera_corpus_bounds_geometry_rule(self) -> None:
        genuine = [
            REAL_CAMERA / "nislive-perspective.jpeg",
            REAL_CAMERA / "pcaswathiii-perspective.jpg",
        ]
        for path in genuine:
            with self.subTest(path=path.name):
                page = self.run_workshop(path)["pages"][0]
                self.assertEqual(page["scan_decision"], "perspective_corrected")
                self.assertTrue(page["perspective_corrected"])
                self.assertGreaterEqual(page["detection_confidence"], 0.80)
                self.assertTrue(page["visual_metrics"]["black_background_guard_pass"])

        flattened = self.run_workshop(REAL_CAMERA / "pcaswathiii-near-full-frame-reference.jpg")["pages"][0]
        self.assertFalse(flattened["perspective_corrected"], "already-flattened camera-derived reference must not be re-warped")
        self.assertTrue(flattened["visual_metrics"]["black_background_guard_pass"])

        # This fixture is derived only by a rectangular crop from a public MIT
        # real-camera image; no perspective transform is applied. Vision still
        # reports a high-confidence document, so it exercises the actual
        # near-full safety branch rather than the confidence=0 fallback used by
        # the already-corrected reference above.
        source = self.run_workshop(REAL_CAMERA / "joellijo32-fronto-parallel-source.jpg")["pages"][0]
        self.assertEqual(source["scan_decision"], "perspective_corrected")
        self.assertTrue(source["perspective_corrected"])
        self.assertGreater(source["max_corner_inset"], 0.065)

        near_full = self.run_workshop(REAL_CAMERA / "joellijo32-near-full-camera-derived.jpg")["pages"][0]
        self.assertEqual(near_full["scan_decision"], "preserve_near_full_frame")
        self.assertFalse(near_full["perspective_corrected"])
        self.assertGreaterEqual(near_full["detection_confidence"], 0.80)
        self.assertLess(near_full["detected_area"], 0.90, "guard must not depend on the old >=0.90 area cutoff")
        self.assertLessEqual(near_full["max_corner_inset"], 0.065)
        self.assertLessEqual(near_full["opposite_edge_delta"], 0.08)
        self.assertFalse(near_full["needs_visual_review"])
        self.assertTrue(near_full["visual_metrics"]["black_background_guard_pass"])


@unittest.skipUnless(platform.system() == "Darwin", "Vision/PDFKit quality proof requires macOS")
class DocumentQualityRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="document-quality-runtime-")
        self.root = Path(self.temp.name)
        self.synthetic = self.root / "synthetic"
        self.synthetic.mkdir()
        subprocess.run(
            ["/usr/bin/xcrun", "swift", str(FIXTURES / "SyntheticDocumentFixtures.swift"), str(self.synthetic)],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.store = Storage(":memory:")
        self.assets = TaskAssetStore(self.root / "materials", self.store)
        self.registry = CapabilityRegistry()
        self.executors = register_task_material_capabilities(
            self.registry,
            assets=self.assets,
            runtime_dir=self.root / "native",
        )
        self.execution = ExecutionRuntime(self.store, self.registry.execution_adapters())
        self.worker = FunctionExecutionWorker(self.execution, self.registry, self.executors)
        self.task_id = "document-quality-task"
        self.submission_id = "document-quality-submission"
        self.store.create_or_get_task(
            task_id=self.task_id,
            goal="把两页合成扫描 PDF 并识别文字",
            invocation_source="unit",
            policy_snapshot={},
            submission_id=self.submission_id,
            status="active",
        )

        manifest = json.loads((self.synthetic / "manifest.json").read_text())
        self.expected_tokens = {
            row["id"]: list(row["expected_tokens"]) for row in manifest["fixtures"]
        }
        self.input_ids: list[str] = []
        bound_ids: list[str] = []
        for file_id, filename in [
            ("edge", "03-edge-content.png"),
            ("perspective", "04-light-perspective.png"),
            ("clean", "01-clean-white-black.png"),
            ("color_stamp", "02-color-red-stamp.png"),
        ]:
            raw = (self.synthetic / filename).read_bytes()
            item = self.assets.upload(
                file_id=file_id,
                name=filename,
                media_type="image/png",
                data=raw,
                sha256=hashlib.sha256(raw).hexdigest(),
            )
            bound_ids.append(item["id"])
            if file_id in {"edge", "perspective"}:
                self.input_ids.append(item["id"])
        self.clean_id = "clean"
        self.color_id = "color_stamp"
        self.assets.bind(f"submission:{self.submission_id}", bound_ids)
        self.original_hashes = {fid: self.assets.get(fid)["sha256"] for fid in bound_ids}

    def tearDown(self) -> None:
        self.assets.close()
        self.temp.cleanup()

    def execute(self, capability: str, args: dict) -> dict:
        action_id = uuid.uuid4().hex
        self.store.create_action(
            action_id=action_id,
            task_id=self.task_id,
            step_index=len(self.store.work_item_actions(self.task_id)) + len(self.store.verified_observations(self.task_id)) + 1,
            action_type=capability,
            payload=args,
            expected={},
            idempotency_key=action_id,
            on_verified="REPLAN",
        )
        self.worker.run_once(self.task_id)
        attempt = self.store.action_attempts(action_id)[0]
        self.assertEqual(attempt["latest_outcome"], "SUCCESS", attempt)
        return self.store.verified_observations(self.task_id)[-1]["data"]

    def test_scan_quality_metadata_and_image_only_pdf_ocr_continuation(self) -> None:
        scan = self.execute(
            "document.scan_pdf",
            {"file_ids": self.input_ids, "name": "quality-scan.pdf", "scan": True, "item_id": "scan"},
        )
        self.assertTrue(scan["verified"])
        self.assertTrue(scan["structural_verified"])
        self.assertEqual(scan["quality_status"], "verified")
        self.assertTrue(scan["quality_verified"])
        self.assertFalse(scan["needs_visual_review"])
        self.assertTrue(scan["ocr"]["ocr_complete"])
        self.assertEqual(scan["ocr"]["page_count"], 2)
        self.assertEqual([page["page"] for page in scan["ocr"]["pages"]], [1, 2])
        self.assertIn("小卷扫描测试", scan["ocr"]["text"])
        self.assertEqual(scan["ocr"]["text_source"], "vision_pdf_page_ocr")

        output = self.assets.manifest(self.task_id)["outputs"][-1]
        metadata = output["metadata"]
        self.assertEqual(metadata["verification_scope"], "pdf_structure_and_scan_quality")
        self.assertEqual(metadata["quality_status"], "verified")
        self.assertTrue(metadata["quality_verified"])
        self.assertEqual(metadata["page_count"], 2)
        self.assertEqual(len(metadata["rendered_pages"]), 2)
        self.assertEqual(metadata["pages"][0]["scan_decision"], "preserve_near_full_frame")
        self.assertEqual(metadata["pages"][1]["scan_decision"], "perspective_corrected")
        self.assertTrue(metadata["quality_evidence"]["originals_preserved"])
        self.assertEqual(metadata["quality_evidence"]["renderable_page_count"], 2)
        self.assertEqual(
            metadata["quality_evidence"]["page_order"]["output_page_sources"],
            [{"page": 1, "file_id": "edge"}, {"page": 2, "file_id": "perspective"}],
        )
        self.assertEqual(metadata["quality_evidence"]["output_sha256"], output["sha256"])
        self.assertTrue(metadata["quality_evidence"]["ocr"]["ocr_complete"])
        self.assertTrue(metadata["quality_evidence"]["ocr_quality_pass"])
        self.assertTrue(metadata["quality_evidence"]["visual_guards_pass"])
        self.assertEqual(metadata["quality_evidence"]["ocr"]["ocr_pass_count"], 1)
        self.assertFalse(metadata["quality_evidence"]["ocr"]["review_recommended"])
        for page in metadata["quality_evidence"]["ocr"]["pages"]:
            self.assertIsNotNone(page["confidence_mean"])
            self.assertIsNotNone(page["confidence_min"])
            self.assertFalse(page["review_recommended"])

        for file_id, digest in self.original_hashes.items():
            self.assertEqual(self.assets.get(file_id)["sha256"], digest)
            path = self.assets.file_path(self.task_id, file_id)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)

        inspected = self.execute("materials.inspect", {"file_ids": [output["id"]]})
        self.assertTrue(inspected["complete"])
        material = inspected["materials"][0]
        self.assertEqual(material["status"], "read")
        self.assertEqual(material["text_source"], "vision_pdf_page_ocr")
        self.assertTrue(material["ocr_complete"])
        self.assertEqual(material["page_count"], 2)
        self.assertEqual(material["pages_returned"], 2)
        self.assertFalse(material["pages_truncated"])
        self.assertEqual([page["page"] for page in material["pages"]], [1, 2])
        for token in self.expected_tokens["edge"]:
            self.assertIn(token, material["pages"][0]["text"], f"edge critical token lost: {token}")
        for token in self.expected_tokens["perspective"]:
            self.assertIn(token, material["pages"][1]["text"], f"perspective critical token lost: {token}")
        self.assertIn("小卷扫描测试", material["text"])

        # Fresh equivalent execution need not serialize byte-identically, but
        # scan decisions, page order and OCR semantics must repeat.
        repeat_scan = self.execute(
            "document.scan_pdf",
            {"file_ids": self.input_ids, "name": "quality-scan-repeat.pdf", "scan": True},
        )
        self.assertEqual(repeat_scan["quality_status"], "verified")
        repeat_output = self.assets.manifest(self.task_id)["outputs"][-1]
        self.assertEqual(
            [page["scan_decision"] for page in repeat_output["metadata"]["pages"]],
            [page["scan_decision"] for page in metadata["pages"]],
        )
        self.assertEqual(
            repeat_output["metadata"]["quality_evidence"]["page_order"]["output_page_sources"],
            metadata["quality_evidence"]["page_order"]["output_page_sources"],
        )
        repeat_material = self.execute("materials.inspect", {"file_ids": [repeat_output["id"]]})["materials"][0]
        self.assertEqual(
            [page["text"] for page in repeat_material["pages"]],
            [page["text"] for page in material["pages"]],
        )

        selected_result = self.execute(
            "document.pdf_select",
            {"file_id": output["id"], "pages": [2, 1, 2], "name": "selected.pdf"},
        )
        self.assertTrue(selected_result["structural_verified"])
        selected = self.assets.manifest(self.task_id)["outputs"][-1]
        selected_text = self.execute("materials.inspect", {"file_ids": [selected["id"]]})["materials"][0]
        self.assertEqual(selected_text["page_count"], 3)
        self.assertEqual([page["page"] for page in selected_text["pages"]], [1, 2, 3])
        self.assertIn("PERSPECTIVEPAGE", selected_text["pages"][0]["text"])
        self.assertIn("EDGEPAGE", selected_text["pages"][1]["text"])
        self.assertIn("PERSPECTIVEPAGE", selected_text["pages"][2]["text"])

        merged_result = self.execute(
            "document.pdf_merge",
            {"file_ids": [output["id"], selected["id"]], "name": "merged.pdf"},
        )
        self.assertTrue(merged_result["structural_verified"])
        merged = self.assets.manifest(self.task_id)["outputs"][-1]
        merged_text = self.execute("materials.inspect", {"file_ids": [merged["id"]]})["materials"][0]
        self.assertEqual(merged_text["page_count"], 5)
        ordered_tokens = ["EDGEPAGE", "PERSPECTIVEPAGE", "PERSPECTIVEPAGE", "EDGEPAGE", "PERSPECTIVEPAGE"]
        for page, token in zip(merged_text["pages"], ordered_tokens):
            self.assertIn(token, page["text"])

    def test_red_stamp_scan_preserves_critical_ocr_even_when_geometry_needs_review(self) -> None:
        scan = self.execute(
            "document.scan_pdf",
            {"file_ids": [self.color_id], "name": "color-stamp.pdf", "scan": True},
        )
        self.assertEqual(scan["quality_status"], "needs_visual_review")
        output = self.assets.manifest(self.task_id)["outputs"][-1]
        page = output["metadata"]["pages"][0]
        self.assertGreaterEqual(page["visual_metrics"]["red_retention_ratio"], 0.50)
        self.assertTrue(page["visual_metrics"]["black_background_guard_pass"])
        inspected = self.execute("materials.inspect", {"file_ids": [output["id"]]})["materials"][0]
        self.assertTrue(inspected["ocr_complete"])
        self.assertEqual(inspected["page_count"], 1)
        for token in self.expected_tokens["color_stamp"]:
            self.assertIn(token, inspected["pages"][0]["text"], f"color/stamp critical token lost: {token}")
        self.assertIn("小卷扫描测试", inspected["text"])

    def test_uncertain_scan_requires_review_and_does_not_complete_document_item(self) -> None:
        self.execute(
            "deliverables.plan",
            {
                "title": "扫描材料",
                "items": [{
                    "id": "scan-review",
                    "title": "扫描 PDF",
                    "depends_on": [],
                    "completion_rule": "document",
                }],
            },
        )
        scan = self.execute(
            "document.scan_pdf",
            {"file_ids": [self.clean_id], "name": "needs-review.pdf", "scan": True, "item_id": "scan-review"},
        )
        self.assertEqual(scan["quality_status"], "needs_visual_review")
        self.assertFalse(scan["quality_verified"])
        self.assertTrue(scan["needs_visual_review"])
        output = self.assets.manifest(self.task_id)["outputs"][-1]
        self.assertEqual(output["metadata"]["status"], "needs_review")
        self.assertFalse(output["metadata"]["quality_verified"])
        summary = self.assets.manifest(self.task_id)["work_summary"]
        self.assertEqual(summary["completed"], 0)
        self.assertEqual(summary["items"][0]["state"], "needs_review")

    def test_ocr_confidence_is_advisory_and_low_quality_requires_review(self) -> None:
        from floweroll_host.task_material_tools import TaskMaterialTools
        strong = TaskMaterialTools._ocr_page_quality({
            "text": "ALPHA BETA 小卷", "block_count": 2,
            "confidence_mean": 0.94, "confidence_min": 0.88,
            "low_confidence_block_count": 0,
        })
        self.assertFalse(strong["review_recommended"])
        weak = TaskMaterialTools._ocr_page_quality({
            "text": "ALPHA 小", "block_count": 2,
            "confidence_mean": 0.53, "confidence_min": 0.18,
            "low_confidence_block_count": 2,
        })
        self.assertTrue(weak["review_recommended"])
        empty = TaskMaterialTools._ocr_page_quality({"text": "", "block_count": 0})
        self.assertTrue(empty["review_recommended"])

    def test_generic_scan_name_uses_source_name_instead_of_photograph_placeholder(self) -> None:
        result = self.execute(
            "document.scan_pdf",
            {"file_ids": [self.input_ids[0]], "name": "拍摄照片扫描件", "scan": True},
        )
        self.assertEqual(result["file"]["name"], "03-edge-content-扫描.pdf")

    def test_scan_name_falls_back_to_task_semantics_then_material_title(self) -> None:
        from floweroll_host.task_material_tools import TaskMaterialTools
        raw = (self.synthetic / "03-edge-content.png").read_bytes()
        generic = self.assets.upload(
            file_id="generic-name-photo", name="IMG_20260913.png", media_type="image/png",
            data=raw, sha256=hashlib.sha256(raw).hexdigest(),
        )
        self.store.create_or_get_task(
            task_id="semantic-name-task", goal="把候选人简历扫描成 PDF 并 OCR",
            invocation_source="unit", policy_snapshot={}, submission_id="semantic-name-sub",
            status="active",
        )
        self.assets.bind("submission:semantic-name-sub", [generic["id"]])
        tools = TaskMaterialTools(self.assets, self.root / "name-runtime")
        self.assertEqual(
            tools._pdf_output_name(
                "semantic-name-task", [generic["id"]],
                {"name":"拍摄照片扫描件.pdf", "scan":True}, "images_to_pdf",
            ),
            "候选人简历-扫描.pdf",
        )

        self.store.create_or_get_task(
            task_id="material-title-task", goal="扫描",
            invocation_source="unit", policy_snapshot={}, submission_id="material-title-sub",
            status="active",
        )
        self.assets.bind("submission:material-title-sub", [generic["id"]])
        self.assets.save_plan(
            "material-title-task", "材料处理",
            [{"id":"resume", "title":"求职简历", "depends_on":[], "completion_rule":"document"}],
        )
        self.assertEqual(
            tools._pdf_output_name(
                "material-title-task", [generic["id"]],
                {"name":"拍摄照片扫描件.pdf", "scan":True, "item_id":"resume"}, "images_to_pdf",
            ),
            "求职简历-扫描.pdf",
        )

    def test_scan_pdf_is_complete_allowed_and_describes_single_pass_ocr(self) -> None:
        entry = self.registry.get("document.scan_pdf")
        self.assertEqual(entry.spec.post_verify_mode, "COMPLETE_ALLOWED")
        self.assertIn("做一次逐页 Vision OCR", entry.spec.description)
        self.assertIn("不要再调用 pdf.extract_text/image.ocr", entry.spec.description)
        self.assertEqual(entry.adapter.execution_profile.max_attempts, 1)

    def test_pdf_is_visible_while_single_pass_ocr_is_still_processing(self) -> None:
        action_id = uuid.uuid4().hex
        self.store.create_action(
            action_id=action_id,
            task_id=self.task_id,
            step_index=901,
            action_type="document.scan_pdf",
            payload={"file_ids": self.input_ids, "name": "staged.pdf", "scan": True},
            expected={},
            idempotency_key=action_id,
            on_verified="REPLAN",
        )
        started = threading.Event()
        release = threading.Event()
        original = MacPerceptionToolSet.pdf_ocr_file

        def blocked_ocr(tool, path, *, public_path=None, timeout_seconds=120):
            started.set()
            if not release.wait(timeout=15):
                raise TimeoutError("test did not release staged OCR")
            return original(
                tool, path, public_path=public_path, timeout_seconds=timeout_seconds
            )

        with patch.object(MacPerceptionToolSet, "pdf_ocr_file", new=blocked_ocr):
            worker = threading.Thread(target=self.worker.run_once, args=(self.task_id,), daemon=True)
            worker.start()
            self.assertTrue(started.wait(timeout=15), "OCR did not reach staged boundary")
            manifest = self.assets.manifest(self.task_id)
            self.assertEqual(manifest["outputs"], [], "unverified output must not become tool evidence")
            self.assertEqual(len(manifest["progressive_outputs"]), 1)
            staged = manifest["progressive_outputs"][0]
            self.assertEqual(staged["progress"]["status"], "processing")
            self.assertEqual(staged["progress"]["detail"]["pdf_status"], "ready")
            self.assertEqual(staged["progress"]["detail"]["ocr_status"], "processing")
            staged_file_id = staged["id"]
            delivery = self.assets.delivery_file_path(self.task_id, staged["id"])
            self.assertTrue(delivery.read_bytes().startswith(b"%PDF-"))
            with self.assertRaises(KeyError):
                self.assets.file_path(self.task_id, staged["id"])
            release.set()
            worker.join(timeout=90)
            self.assertFalse(worker.is_alive(), "scan worker did not converge after OCR resumed")

        attempt = self.store.action_attempts(action_id)[0]
        self.assertEqual(attempt["latest_outcome"], "SUCCESS", attempt)
        manifest = self.assets.manifest(self.task_id)
        self.assertEqual(manifest["progressive_outputs"], [])
        self.assertEqual(len(manifest["outputs"]), 1)
        self.assertEqual(manifest["outputs"][0]["id"], staged_file_id)

    def test_ocr_timeout_fails_soft_and_inspect_reuses_scan_cache(self) -> None:
        with patch.object(
            MacPerceptionToolSet,
            "pdf_ocr_file",
            side_effect=TimeoutError("simulated bounded OCR timeout"),
        ):
            scan = self.execute(
                "document.scan_pdf",
                {"file_ids": [self.input_ids[0]], "name": "ocr-timeout.pdf", "scan": True},
            )
        self.assertEqual(scan["partial_delivery"]["pdf_status"], "ready")
        self.assertEqual(scan["ocr"]["ocr_status"], "failed")
        self.assertEqual(scan["ocr"]["ocr_pass_count"], 1)
        self.assertTrue(scan["ocr"]["review_recommended"])
        self.assertEqual(scan["quality_status"], "needs_visual_review")

        output = self.assets.manifest(self.task_id)["outputs"][-1]
        metadata = output["metadata"]
        self.assertEqual(metadata["ocr_status"], "failed")
        self.assertEqual(metadata["status"], "needs_review")
        self.assertEqual(metadata["ocr_cache"]["ocr_pass_count"], 1)
        self.assertEqual(
            metadata["ocr_cache"]["critical_field_policy"],
            "verify_names_numbers_dates_times_amounts_addresses_against_original",
        )
        self.assertTrue(self.assets.delivery_file_path(self.task_id, output["id"]).is_file())

        with patch.object(
            MacPerceptionToolSet,
            "pdf_extract_text",
            side_effect=AssertionError("scan output must not call generic pdf.extract_text"),
        ), patch.object(
            MacPerceptionToolSet,
            "pdf_ocr",
            side_effect=AssertionError("scan output must not perform duplicate OCR"),
        ):
            inspected = self.execute("materials.inspect", {"file_ids": [output["id"]]})
        material = inspected["materials"][0]
        self.assertEqual(material["status"], "read")
        self.assertTrue(material["ocr_reused"])
        self.assertEqual(material["ocr_status"], "failed")
        self.assertTrue(material["review_recommended"])

    def test_non_scan_pdf_keeps_structural_verification_separate(self) -> None:
        raw = self.execute(
            "document.scan_pdf",
            {"file_ids": [self.input_ids[0]], "name": "raw.pdf", "scan": False},
        )
        self.assertEqual(raw["quality_status"], "structural_only")
        self.assertFalse(raw["quality_verified"])
        self.assertFalse(raw["needs_visual_review"])
        output = self.assets.manifest(self.task_id)["outputs"][-1]
        self.assertEqual(output["metadata"]["verification_scope"], "pdf_structure_only")
        self.assertEqual(output["metadata"]["quality_status"], "structural_only")
        self.assertFalse(output["metadata"]["quality_verified"])
        self.assertEqual(output["metadata"]["label"], "PDF 已生成 · 已完成结构核验")
        evidence = output["metadata"]["quality_evidence"]
        self.assertEqual(evidence["page_order"]["output_page_sources"], [{"page": 1, "file_id": self.input_ids[0]}])
        self.assertEqual(evidence["output_sha256"], output["sha256"])


if __name__ == "__main__":
    unittest.main()
