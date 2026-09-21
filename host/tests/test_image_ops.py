from __future__ import annotations

import copy
import hashlib
import json
import struct
import subprocess
import tempfile
import unittest
import uuid
import zlib
from pathlib import Path

from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.execution_runtime import ExecutionRuntime
from floweroll_host.function_execution_worker import FunctionExecutionWorker
from floweroll_host.image_ops import (
    FORMAT_MEDIA_TYPES,
    INSPECT_ID,
    MAX_INPUT_BYTES,
    TRANSFORM_ID,
    ImageOpsAdapter,
    ImageOpsToolSet,
    _stable_output_id,
    register_image_ops_capabilities,
    validate_inspect_arguments,
    validate_transform_arguments,
)
from floweroll_host.planner_contracts import PlannerDecision
from floweroll_host.server import HostApp
from floweroll_host.storage import Storage
from floweroll_host.task_assets import TaskAssetStore
from floweroll_host.task_capability_policy import EffectiveTaskCapabilityPolicy, capability_semantics


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_SOURCE = ROOT / "host/tests/fixtures/image_ops/SyntheticImageFixtures.swift"
HELPER_SOURCE = ROOT / "host/native_helpers/ImageOpsHelper.swift"


class ImageOpsFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.class_tmp = tempfile.TemporaryDirectory(prefix="image-ops-class-")
        cls.class_root = Path(cls.class_tmp.name)
        cls.fixture_binary = cls.class_root / "SyntheticImageFixtures"
        completed = subprocess.run(
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-O",
                str(FIXTURE_SOURCE),
                "-framework",
                "Foundation",
                "-framework",
                "CoreGraphics",
                "-framework",
                "ImageIO",
                "-framework",
                "UniformTypeIdentifiers",
                "-o",
                str(cls.fixture_binary),
            ],
            capture_output=True,
            timeout=90,
            check=False,
        )
        if completed.returncode:
            raise RuntimeError(completed.stderr.decode(errors="replace"))
        fixture_dir = cls.class_root / "fixtures"
        generated = subprocess.run(
            [str(cls.fixture_binary), str(fixture_dir)],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        )
        cls.fixture_paths = {key: Path(value) for key, value in json.loads(generated.stdout).items()}
        cls.native_runtime = cls.class_root / "native-runtime"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.class_tmp.cleanup()

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="image-ops-test-")
        self.root = Path(self.tmp.name)
        self.store = Storage(str(self.root / "runtime.sqlite3"))
        self.assets = TaskAssetStore(self.root / "materials", self.store)
        self.registry = CapabilityRegistry()
        self.executors, self.health = register_image_ops_capabilities(
            self.registry,
            assets=self.assets,
            runtime_dir=self.native_runtime,
            helper_source=HELPER_SOURCE,
        )
        self.execution = ExecutionRuntime(
            self.store,
            self.registry.execution_adapters(),
            capability_specs=self.registry.planner_capabilities(include_deferred=True),
            capability_registry=self.registry,
        )
        self.worker = FunctionExecutionWorker(self.execution, self.registry, self.executors)
        self.task_counter = 0

    def tearDown(self) -> None:
        self.assets.close()
        self.tmp.cleanup()

    @staticmethod
    def _sha(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest()

    def create_task(self, *, goal: str = "处理图片", inputs: tuple[str, ...] = ("opaque",)) -> str:
        self.task_counter += 1
        task_id = f"image-task-{self.task_counter}"
        submission_id = f"image-submission-{self.task_counter}"
        self.store.create_or_get_task(
            task_id=task_id,
            goal=goal,
            invocation_source="unit",
            policy_snapshot={},
            submission_id=submission_id,
            status="active",
        )
        file_ids: list[str] = []
        for kind in inputs:
            path = self.fixture_paths[kind]
            data = path.read_bytes()
            media_type = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
            file_id = f"{task_id}-{kind}"
            self.assets.upload(
                file_id=file_id,
                name=path.name,
                media_type=media_type,
                data=data,
                sha256=self._sha(data),
            )
            file_ids.append(file_id)
        if file_ids:
            self.assets.bind("submission:" + submission_id, file_ids)
        return task_id

    def input_id(self, task_id: str, kind: str) -> str:
        return f"{task_id}-{kind}"

    def action(
        self,
        task_id: str,
        capability: str,
        payload: dict,
        *,
        action_id: str | None = None,
        on_verified: str = "COMPLETE",
    ) -> str:
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

    def run_action(
        self,
        task_id: str,
        capability: str,
        payload: dict,
        *,
        action_id: str | None = None,
        on_verified: str = "COMPLETE",
    ) -> tuple[str, dict]:
        action_id = self.action(
            task_id,
            capability,
            payload,
            action_id=action_id,
            on_verified=on_verified,
        )
        result = self.worker.run_once(task_id)
        self.assertIsNotNone(result)
        attempts = self.store.action_attempts(action_id)
        self.assertEqual(len(attempts), 1)
        return action_id, attempts[0]

    def transform_payload(self, task_id: str, **updates) -> dict:
        value = {
            "operation": "convert",
            "input_id": self.input_id(task_id, "opaque"),
            "output_name": "converted.jpg",
            "output_format": "jpeg",
            "alpha_policy": "preserve",
        }
        value.update(updates)
        return value

    @staticmethod
    def synthetic_large_png(width: int, height: int) -> bytes:
        def chunk(kind: bytes, payload: bytes) -> bytes:
            return (
                struct.pack(">I", len(payload))
                + kind
                + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
            )

        # Valid 8-bit grayscale PNG. Compress one repeated all-zero scanline at
        # a time so the fixture advertises large geometry without allocating a
        # decoded bitmap in the test process. ImageOpsHelper must reject from
        # ImageIO properties before it reaches CGImage decode/allocation.
        compressor = zlib.compressobj(level=9)
        row = b"\x00" + (b"\x00" * width)
        compressed = bytearray()
        for _ in range(height):
            compressed.extend(compressor.compress(row))
        compressed.extend(compressor.flush())
        ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", bytes(compressed))
            + chunk(b"IEND", b"")
        )


class ImageOpsContractTests(ImageOpsFixture):
    def test_registry_readiness_specs_metadata_and_profiles(self) -> None:
        self.assertTrue(self.health["ready"])
        self.assertEqual(set(self.executors), {INSPECT_ID, TRANSFORM_ID})
        inspect = self.registry.get(INSPECT_ID)
        transform = self.registry.get(TRANSFORM_ID)
        self.assertEqual(inspect.source.kind, "task_material")
        self.assertEqual(transform.source.kind, "task_material")
        self.assertEqual(inspect.source.metadata["operation"], "read")
        self.assertEqual(inspect.source.metadata["effect"], "read")
        self.assertTrue(inspect.source.metadata["read_only"])
        self.assertEqual(transform.source.metadata["operation"], "write")
        self.assertEqual(transform.source.metadata["effect"], "local_file")
        self.assertFalse(transform.source.metadata["read_only"])
        self.assertEqual(inspect.adapter.execution_profile.verification_mode, "IMAGE_SOURCE_READBACK")
        self.assertEqual(transform.adapter.execution_profile.verification_mode, "IMAGE_ARTIFACT_READBACK")
        self.assertEqual(transform.adapter.execution_profile.idempotency_mode, "EXACT_INPUT")
        self.assertEqual(transform.adapter.execution_profile.reconciliation_mode, "REPLAY_SAME_ATTEMPT")
        self.assertTrue(transform.adapter.replay_safe)
        self.assertIn("exact_byte_budget_compression", self.health["unsupported"])
        self.assertIn("raw_development", self.health["unsupported"])

    def test_planner_schema_rejects_wrong_types_and_enums(self) -> None:
        transform_spec = self.registry.get(TRANSFORM_ID).spec
        good = {
            "decision_type": "EXECUTE",
            "interpreted_goal_summary": "转换图片",
            "plan_update": None,
            "action": {
                "capability": TRANSFORM_ID,
                "arguments": {
                    "operation": "convert",
                    "input_id": "asset-one",
                    "output_name": "out.png",
                    "output_format": "png",
                    "alpha_policy": "preserve",
                },
            },
            "on_verified": "COMPLETE",
            "clarification": None,
            "wait": None,
            "completion": None,
            "stop_reason": None,
        }
        decision = PlannerDecision.from_dict(good, [transform_spec])
        self.assertEqual(decision.action["capability"], TRANSFORM_ID)
        for mutate in (
            lambda value: value["action"]["arguments"].__setitem__("operation", []),
            lambda value: value["action"]["arguments"].__setitem__("output_format", "raw"),
            lambda value: value["action"]["arguments"].__setitem__("width", True),
            lambda value: value["action"]["arguments"].__setitem__("extra", "no"),
        ):
            bad = copy.deepcopy(good)
            mutate(bad)
            with self.assertRaises(ValueError):
                PlannerDecision.from_dict(bad, [transform_spec])

    def test_direct_validator_rejects_cross_operation_fields_and_non_objects(self) -> None:
        with self.assertRaisesRegex(Exception, "object"):
            validate_inspect_arguments([])
        with self.assertRaisesRegex(Exception, "unexpected"):
            validate_inspect_arguments({"input_id": "x", "operation": "crop"})
        cases = [
            [],
            {"operation": [], "input_id": "x", "output_name": "x.jpg"},
            {
                "operation": "convert",
                "input_id": "x",
                "output_name": "x.jpg",
                "output_format": "jpeg",
                "alpha_policy": "preserve",
                "width": 10,
            },
            {
                "operation": "crop",
                "input_id": "x",
                "output_name": "x.png",
                "output_format": "png",
                "alpha_policy": "preserve",
                "width": 10,
                "height": 10,
                "offset_x": 0,
            },
            {
                "operation": "resize_exact",
                "input_id": "x",
                "output_name": "x.png",
                "output_format": {},
                "alpha_policy": "preserve",
                "width": 10,
                "height": 10,
            },
        ]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(Exception):
                validate_transform_arguments(value)

    def test_malformed_direct_dispatch_is_model_correctable_never_observed(self) -> None:
        malformed = [
            {"operation": [], "input_id": "x", "output_name": "x.jpg"},
            {
                "operation": "not-an-operation",
                "input_id": "x",
                "output_name": "x.jpg",
            },
            {
                "operation": "convert",
                "input_id": [],
                "output_name": "x.jpg",
                "output_format": "jpeg",
                "alpha_policy": "preserve",
            },
            {
                "operation": "convert",
                "input_id": "x",
                "output_name": "x.jpg",
                "output_format": {},
                "alpha_policy": "preserve",
            },
            {
                "operation": "convert",
                "input_id": "x",
                "output_name": "wrong.png",
                "output_format": "jpeg",
                "alpha_policy": "preserve",
            },
            {
                "operation": "resize_fit",
                "input_id": "x",
                "output_name": "x.png",
                "output_format": "png",
                "alpha_policy": "preserve",
                "max_dimension": True,
            },
            {
                "operation": "resize_fit",
                "input_id": "x",
                "output_name": "x.png",
                "output_format": "png",
                "alpha_policy": "preserve",
                "max_dimension": 50,
                "width": 20,
            },
        ]
        for index, payload in enumerate(malformed):
            with self.subTest(index=index):
                task_id = self.create_task(inputs=("opaque",))
                action_id, attempt = self.run_action(
                    task_id,
                    TRANSFORM_ID,
                    payload,
                    action_id=f"malformed-{index}",
                )
                self.assertEqual(attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
                self.assertEqual(attempt["result"]["error_kind"], "model_correctable")
                self.assertEqual(attempt["result"]["error_code"], "INVALID_PAYLOAD")
                self.assertEqual(self.store.verified_observations(task_id), [])
                self.assertNotEqual(self.store.get_task(task_id)["status"], "completed")

        for index, payload in enumerate((
            {"input_id": [], "metadata_scope": "basic"},
            {"input_id": "x", "metadata_scope": []},
            {"input_id": "x", "metadata_scope": "everything"},
        )):
            with self.subTest(inspect_index=index):
                task_id = self.create_task(inputs=("opaque",))
                _, attempt = self.run_action(
                    task_id,
                    INSPECT_ID,
                    payload,
                    action_id=f"malformed-inspect-{index}",
                    on_verified="REPLAN",
                )
                self.assertEqual(attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
                self.assertEqual(attempt["result"]["error_code"], "INVALID_PAYLOAD")
                self.assertEqual(self.store.verified_observations(task_id), [])

    def test_task_policy_read_only_media_allows_inspect_denies_transform(self) -> None:
        inspect = self.registry.get(INSPECT_ID).spec
        transform = self.registry.get(TRANSFORM_ID).spec
        self.assertEqual(capability_semantics(inspect, self.registry).operation, "read")
        self.assertEqual(capability_semantics(transform, self.registry).operation, "write")
        policy = EffectiveTaskCapabilityPolicy.from_texts(["只读处理图片，不要修改图片"])
        self.assertTrue(policy.allows(inspect, self.registry))
        self.assertFalse(policy.allows(transform, self.registry))

        task_id = self.create_task(goal="只读处理图片，不要修改图片", inputs=("opaque",))
        action_id = self.action(
            task_id,
            TRANSFORM_ID,
            self.transform_payload(task_id),
            action_id="image-policy-denied",
        )
        self.assertIsNone(self.worker.run_once(task_id))
        self.assertEqual(self.store.action_attempts(action_id), [])
        action = self.store.get_action(action_id)
        self.assertEqual(action["status"], "failed")
        self.assertEqual(action["failure_code"], "TASK_DENIED")


class ImageOpsResourceAndInspectTests(ImageOpsFixture):
    def test_inspect_runtime_readback_is_bounded_and_source_unchanged(self) -> None:
        task_id = self.create_task(inputs=("metadata",))
        input_id = self.input_id(task_id, "metadata")
        path = self.assets.file_path(task_id, input_id)
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        _, attempt = self.run_action(
            task_id,
            INSPECT_ID,
            {"input_id": input_id, "metadata_scope": "privacy_flags"},
            on_verified="REPLAN",
        )
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        observation = self.store.verified_observations(task_id)[0]["data"]
        self.assertEqual(observation["sha256"], before)
        readback = observation["readback"]
        self.assertEqual(readback["format"], "jpeg")
        self.assertTrue(readback["privacy_metadata_present"])
        self.assertTrue(readback["has_gps"])
        self.assertNotIn("dpi_width", readback)
        rendered = json.dumps(observation, ensure_ascii=False)
        self.assertNotIn("FlowerollTest", rendered)
        self.assertNotIn("SyntheticCamera", rendered)
        self.assertNotIn("Synthetic Tester", rendered)

    def test_input_byte_limit_rejects_before_decode(self) -> None:
        task_id = self.create_task(inputs=())
        file_id = self.input_id(task_id, "oversized")
        data = b"\x89PNG\r\n\x1a\n" + b"0" * (MAX_INPUT_BYTES + 1)
        self.assets._save(
            file_id=file_id,
            name="oversized.png",
            media_type="image/png",
            data=data,
            suffix=".png",
            task_id=None,
            category="input",
            metadata={"origin": "generated_test"},
        )
        self.assets.bind("submission:image-submission-1", [file_id])
        _, attempt = self.run_action(
            task_id,
            INSPECT_ID,
            {"input_id": file_id},
            on_verified="REPLAN",
        )
        self.assertEqual(attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
        self.assertIn("INPUT_TOO_LARGE", attempt["error"])

    def _run_header_bound(self, width: int, height: int, expected_code: str) -> None:
        task_id = self.create_task(inputs=())
        data = self.synthetic_large_png(width, height)
        file_id = self.input_id(task_id, expected_code.lower())
        self.assets.upload(
            file_id=file_id,
            name="header-bound.png",
            media_type="image/png",
            data=data,
            sha256=self._sha(data),
        )
        self.assets.bind("submission:image-submission-1", [file_id])
        _, attempt = self.run_action(
            task_id,
            INSPECT_ID,
            {"input_id": file_id},
            on_verified="REPLAN",
        )
        self.assertEqual(attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
        self.assertIn(expected_code, attempt["error"])

    def test_pixel_count_limit_fails_before_large_decode(self) -> None:
        self._run_header_bound(9000, 4000, "PIXEL_LIMIT_EXCEEDED")

    def test_decode_cost_limit_fails_before_large_bitmap_allocation(self) -> None:
        self._run_header_bound(6000, 5000, "DECODE_COST_EXCEEDED")


class ImageOpsTransformTests(ImageOpsFixture):
    def test_resize_fit_exact_and_crop_machine_readback(self) -> None:
        cases = [
            (
                "resize_fit",
                {
                    "operation": "resize_fit",
                    "output_name": "fit.png",
                    "output_format": "png",
                    "max_dimension": 120,
                    "alpha_policy": "preserve",
                },
                (120, 68),
            ),
            (
                "resize_exact",
                {
                    "operation": "resize_exact",
                    "output_name": "exact.png",
                    "output_format": "png",
                    "width": 100,
                    "height": 100,
                    "alpha_policy": "preserve",
                },
                (100, 100),
            ),
            (
                "crop",
                {
                    "operation": "crop",
                    "output_name": "crop.png",
                    "output_format": "png",
                    "width": 120,
                    "height": 100,
                    "offset_x": 60,
                    "offset_y": 40,
                    "alpha_policy": "preserve",
                },
                (120, 100),
            ),
        ]
        for name, fields, expected in cases:
            with self.subTest(operation=name):
                task_id = self.create_task(inputs=("opaque",))
                payload = {"input_id": self.input_id(task_id, "opaque"), **fields}
                _, attempt = self.run_action(task_id, TRANSFORM_ID, payload)
                self.assertEqual(attempt["latest_outcome"], "SUCCESS")
                observation = self.store.verified_observations(task_id)[0]["data"]
                self.assertEqual(
                    (observation["readback"]["display_width"], observation["readback"]["display_height"]),
                    expected,
                )
                self.assertEqual(observation["readback"]["orientation"], 1)
                self.assertFalse(observation["readback"]["privacy_metadata_present"])

    def test_format_conversion_supports_png_jpeg_tiff_and_heic(self) -> None:
        for output_format in ("png", "jpeg", "tiff", "heic"):
            with self.subTest(output_format=output_format):
                task_id = self.create_task(inputs=("opaque",))
                _, attempt = self.run_action(
                    task_id,
                    TRANSFORM_ID,
                    {
                        "operation": "convert",
                        "input_id": self.input_id(task_id, "opaque"),
                        "output_name": "converted." + ("jpg" if output_format == "jpeg" else output_format),
                        "output_format": output_format,
                        "alpha_policy": "preserve",
                    },
                )
                self.assertEqual(attempt["latest_outcome"], "SUCCESS", attempt.get("error"))
                observation = self.store.verified_observations(task_id)[0]["data"]
                self.assertEqual(observation["readback"]["format"], output_format)
                self.assertEqual(observation["file"]["media_type"], FORMAT_MEDIA_TYPES[output_format])

    def test_alpha_preserve_and_flatten_white_are_deterministic(self) -> None:
        preserve_task = self.create_task(inputs=("alpha",))
        _, preserve_attempt = self.run_action(
            preserve_task,
            TRANSFORM_ID,
            {
                "operation": "convert",
                "input_id": self.input_id(preserve_task, "alpha"),
                "output_name": "alpha.tiff",
                "output_format": "tiff",
                "alpha_policy": "preserve",
            },
        )
        self.assertEqual(preserve_attempt["latest_outcome"], "SUCCESS")
        preserve_obs = self.store.verified_observations(preserve_task)[0]["data"]
        self.assertTrue(preserve_obs["readback"]["has_alpha"])
        self.assertTrue(preserve_obs["verification"]["checks"]["alpha_preserved"])

        reject_task = self.create_task(inputs=("alpha",))
        _, reject_attempt = self.run_action(
            reject_task,
            TRANSFORM_ID,
            {
                "operation": "convert",
                "input_id": self.input_id(reject_task, "alpha"),
                "output_name": "should-fail.jpg",
                "output_format": "jpeg",
                "alpha_policy": "preserve",
            },
        )
        self.assertEqual(reject_attempt["latest_outcome"], "MODEL_CORRECTABLE_FAILURE")
        self.assertIn("ALPHA_NOT_SUPPORTED_BY_OUTPUT", reject_attempt["error"])
        self.assertEqual(self.store.verified_observations(reject_task), [])

        flatten_task = self.create_task(inputs=("alpha",))
        _, flatten_attempt = self.run_action(
            flatten_task,
            TRANSFORM_ID,
            {
                "operation": "convert",
                "input_id": self.input_id(flatten_task, "alpha"),
                "output_name": "white.jpg",
                "output_format": "jpeg",
                "alpha_policy": "flatten_white",
            },
        )
        self.assertEqual(flatten_attempt["latest_outcome"], "SUCCESS")
        flatten_obs = self.store.verified_observations(flatten_task)[0]["data"]
        self.assertFalse(flatten_obs["readback"]["has_alpha"])
        composite = flatten_obs["verification"]["white_composite"]
        self.assertTrue(composite["verified"])
        self.assertGreater(composite["sample_count"], 0)
        self.assertLess(composite["white_mae"], composite["black_mae"])

    def test_orientation_normalization_and_metadata_stripping(self) -> None:
        orientation_task = self.create_task(inputs=("orientation6",))
        _, orientation_attempt = self.run_action(
            orientation_task,
            TRANSFORM_ID,
            {
                "operation": "normalize_orientation",
                "input_id": self.input_id(orientation_task, "orientation6"),
                "output_name": "normalized.jpg",
                "output_format": "jpeg",
                "alpha_policy": "preserve",
            },
        )
        self.assertEqual(orientation_attempt["latest_outcome"], "SUCCESS")
        orientation_obs = self.store.verified_observations(orientation_task)[0]["data"]
        self.assertEqual(orientation_obs["readback"]["orientation"], 1)
        self.assertEqual(
            (orientation_obs["readback"]["display_width"], orientation_obs["readback"]["display_height"]),
            (320, 180),
        )

        metadata_task = self.create_task(inputs=("metadata",))
        inspect_tool = self.registry.get(INSPECT_ID).adapter.tools
        before = inspect_tool.inspect(
            {"task_id": metadata_task, "action_id": "read-before"},
            {"input_id": self.input_id(metadata_task, "metadata"), "metadata_scope": "privacy_flags"},
        )
        self.assertTrue(before["readback"]["privacy_metadata_present"])
        _, strip_attempt = self.run_action(
            metadata_task,
            TRANSFORM_ID,
            {
                "operation": "strip_metadata",
                "input_id": self.input_id(metadata_task, "metadata"),
                "output_name": "stripped.jpg",
                "output_format": "jpeg",
                "alpha_policy": "preserve",
            },
        )
        self.assertEqual(strip_attempt["latest_outcome"], "SUCCESS")
        strip_obs = self.store.verified_observations(metadata_task)[0]["data"]
        self.assertFalse(strip_obs["readback"]["privacy_metadata_present"])
        self.assertTrue(strip_obs["verification"]["checks"]["strip_metadata_verified"])

    def test_jpeg_quality_is_bounded_control_not_exact_byte_budget(self) -> None:
        sizes = {}
        for quality in (20, 90):
            task_id = self.create_task(inputs=("opaque",))
            _, attempt = self.run_action(
                task_id,
                TRANSFORM_ID,
                {
                    "operation": "compress_jpeg",
                    "input_id": self.input_id(task_id, "opaque"),
                    "output_name": f"q{quality}.jpg",
                    "jpeg_quality": quality,
                    "alpha_policy": "preserve",
                },
            )
            self.assertEqual(attempt["latest_outcome"], "SUCCESS")
            observation = self.store.verified_observations(task_id)[0]["data"]
            sizes[quality] = observation["file"]["size_bytes"]
            self.assertEqual(observation["output_format"], "jpeg")
        self.assertLess(sizes[20], sizes[90])

    def test_output_is_hidden_until_runtime_verification_then_downloadable(self) -> None:
        task_id = self.create_task(inputs=("opaque",))
        payload = self.transform_payload(task_id)
        action_id = self.action(task_id, TRANSFORM_ID, payload, action_id="image-hidden-output")
        dispatch = self.execution.next_action(task_id, source_kind="task_material")
        self.assertIsNotNone(dispatch)
        executor = self.executors[TRANSFORM_ID]
        output = executor.invoke(dict(dispatch), dict(dispatch["payload"]))
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
        outputs = self.assets.manifest(task_id)["outputs"]
        self.assertEqual(len(outputs), 1)
        self.assertEqual(outputs[0]["id"], output["file"]["id"])
        path = self.assets.file_path(task_id, outputs[0]["id"])
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), outputs[0]["sha256"])

    def test_same_action_replay_reuses_exact_artifact_without_reencoding(self) -> None:
        task_id = self.create_task(inputs=("opaque",))
        payload = self.transform_payload(task_id)
        action_id = self.action(task_id, TRANSFORM_ID, payload, action_id="image-replay")
        dispatch = self.execution.next_action(task_id, source_kind="task_material")
        self.assertIsNotNone(dispatch)
        executor = self.executors[TRANSFORM_ID]
        first = executor.invoke(dict(dispatch), dict(dispatch["payload"]))
        second = executor.invoke(dict(dispatch), dict(dispatch["payload"]))
        self.assertFalse(first["replayed_artifact"])
        self.assertTrue(second["replayed_artifact"])
        self.assertEqual(first["file"]["id"], second["file"]["id"])
        self.assertEqual(first["output_sha256"], second["output_sha256"])

    def test_verifier_rejects_tampered_artifact_before_observation(self) -> None:
        task_id = self.create_task(inputs=("opaque",))
        payload = self.transform_payload(task_id)
        action_id = self.action(task_id, TRANSFORM_ID, payload, action_id="image-tamper")
        dispatch = self.execution.next_action(task_id, source_kind="task_material")
        self.assertIsNotNone(dispatch)
        output = self.executors[TRANSFORM_ID].invoke(dict(dispatch), dict(dispatch["payload"]))
        fid = output["file"]["id"]
        path = self.assets.directory / (fid + ".jpg")
        path.write_bytes(path.read_bytes() + b"tamper")
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
        self.assertEqual(attempt["latest_outcome"], "TERMINAL_FAILURE")
        self.assertEqual(self.store.verified_observations(task_id), [])
        self.assertNotEqual(self.store.get_task(task_id)["status"], "completed")

    def test_runtime_transform_chain_produces_verified_task_artifact_and_completion(self) -> None:
        task_id = self.create_task(inputs=("opaque",))
        source_path = self.assets.file_path(task_id, self.input_id(task_id, "opaque"))
        source_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
        action_id, attempt = self.run_action(
            task_id,
            TRANSFORM_ID,
            {
                "operation": "resize_fit",
                "input_id": self.input_id(task_id, "opaque"),
                "output_name": "interview-image.png",
                "output_format": "png",
                "max_dimension": 180,
                "alpha_policy": "preserve",
            },
            action_id="image-runtime-chain",
        )
        self.assertEqual(attempt["latest_outcome"], "SUCCESS")
        task = self.store.get_task(task_id)
        self.assertEqual(task["status"], "completed")
        observation = self.store.verified_observations(task_id)[0]
        self.assertEqual(observation["action_id"], action_id)
        self.assertEqual(observation["capability"], TRANSFORM_ID)
        self.assertTrue(observation["data"]["verification"]["verified"])
        output = observation["data"]["file"]
        self.assertEqual(self.assets.manifest(task_id)["outputs"][0]["id"], output["id"])
        self.assertEqual(hashlib.sha256(source_path.read_bytes()).hexdigest(), source_hash)
        self.assertIn("interview-image.png", task["result"]["summary"])


class ImageOpsServerIntegrationTests(ImageOpsFixture):
    def test_host_app_registers_image_capabilities_when_task_assets_enabled(self) -> None:
        app_registry = CapabilityRegistry()
        app = HostApp(
            ":memory:",
            capability_registry=app_registry,
            task_asset_root=self.root / "server-materials",
        )
        try:
            by_id = {item["capability_id"]: item for item in app.capability_status()["capabilities"]}
            self.assertIn(INSPECT_ID, by_id)
            self.assertIn(TRANSFORM_ID, by_id)
            self.assertTrue(by_id[INSPECT_ID]["ready"])
            self.assertTrue(by_id[TRANSFORM_ID]["ready"])
            self.assertIn(INSPECT_ID, app.function_executors)
            self.assertIn(TRANSFORM_ID, app.function_executors)
        finally:
            app.close()

    def test_run_host_policy_snapshot_declares_image_capabilities(self) -> None:
        source = (ROOT / "host/run_host.py").read_text(encoding="utf-8")
        self.assertIn("IMAGE_INSPECT_ID", source)
        self.assertIn("IMAGE_TRANSFORM_ID", source)
        self.assertIn("[IMAGE_INSPECT_ID, IMAGE_TRANSFORM_ID", source)


if __name__ == "__main__":
    unittest.main()
