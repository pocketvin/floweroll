from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from floweroll_host.capability_discovery import CapabilityContextSelector
from floweroll_host.capability_registry import CapabilityRegistry
from floweroll_host.image_ops import (
    INSPECT_ID,
    TRANSFORM_ID,
    TRANSFORM_SCHEMA,
    _transform_completion_summary,
)
from floweroll_host.planner_contracts import DecisionContext
from floweroll_host.presentation import capability_activity_title, capability_label
from floweroll_host.server import create_server
from floweroll_host.task_runtime import TaskRuntime


class _NoopPlanner:
    pass


class ImageOpsProductTests(unittest.TestCase):
    def _working_set(self, prompt: str) -> list[str]:
        with tempfile.TemporaryDirectory(prefix="image-product-routing-") as td:
            root = Path(td)
            registry = CapabilityRegistry()
            with patch("floweroll_host.runtime_supervisor.RuntimeSupervisor.start"):
                server = create_server(
                    "127.0.0.1",
                    0,
                    str(root / "runtime.sqlite3"),
                    capability_registry=registry,
                    task_asset_root=root / "materials",
                    progressive_discovery=True,
                    task_runtime_factory=lambda store: TaskRuntime(
                        store, _NoopPlanner(), registry.planner_capabilities()
                    ),
                )
            try:
                specs = server.app.task_runtime.capabilities
                context = DecisionContext(
                    task_id="image-product-task",
                    raw_goal=prompt,
                    task_status="ACTIVE",
                    phase="planning",
                    current_time=datetime.now(timezone.utc).isoformat(),
                    timezone="Asia/Shanghai",
                    policy_view={
                        "allowed_capabilities": [spec.name for spec in specs],
                        "effective_task_policy_applied": True,
                    },
                    capabilities=specs,
                    verified_observations=[],
                    user_turns=[],
                    runtime_context={
                        "task_materials": {
                            "inputs": [
                                {
                                    "id": "image-input",
                                    "name": "demo.png",
                                    "media_type": "image/png",
                                    "size_bytes": 123,
                                    "sha256": "fixture",
                                    "category": "input",
                                    "metadata": {},
                                }
                            ],
                            "outputs": [],
                            "plan": None,
                            "work_units": {},
                            "work_summary": None,
                        }
                    },
                )
                selected = CapabilityContextSelector(
                    registry,
                    ready_specs=server.app._ready_discovery_capabilities,
                ).apply(context)
                return [spec.name for spec in selected.capabilities]
            finally:
                server.server_close()
                server.app.task_assets.close()

    def test_natural_image_prompts_put_the_right_specialized_route_first(self) -> None:
        cases = [
            ("告诉我这张图是什么尺寸、格式、方向", INSPECT_ID),
            ("把这张图最长边缩小到 120 像素，导出 PNG", TRANSFORM_ID),
            ("从左上角开始裁出 120×100 像素区域，导出 PNG", TRANSFORM_ID),
            ("把这张透明 PNG 转成 JPEG，透明区域铺白色", TRANSFORM_ID),
            ("去掉这张照片的 metadata，保留为 JPEG", TRANSFORM_ID),
        ]
        for prompt, expected in cases:
            with self.subTest(prompt=prompt):
                selected = self._working_set(prompt)
                self.assertEqual(selected[0], expected)
                self.assertLessEqual(len(selected), 8)
                self.assertNotIn("materials.inspect", selected)

    def test_image_ocr_prompt_keeps_generic_material_reader_first(self) -> None:
        selected = self._working_set("把这张图里的文字识别出来")
        self.assertEqual(selected[0], "materials.inspect")
        self.assertNotIn(TRANSFORM_ID, selected)
        self.assertLessEqual(len(selected), 8)

    def test_transform_schema_explains_operation_specific_product_semantics(self) -> None:
        props = TRANSFORM_SCHEMA["properties"]
        self.assertIn("左上角", props["operation"]["description"])
        self.assertIn("左上角", props["offset_y"]["description"])
        self.assertIn("最长", props["max_dimension"]["description"])
        self.assertIn("flatten_white", props["alpha_policy"]["description"])
        self.assertIn("不要传", props["output_format"]["description"])
        self.assertIn("给用户看的", props["output_name"]["description"])

    def test_transform_completion_summary_is_user_facing_and_effect_specific(self) -> None:
        base = {
            "file": {"name": "结果.jpg"},
            "output_format": "jpeg",
            "readback": {
                "format": "jpeg",
                "display_width": 240,
                "display_height": 160,
                "privacy_metadata_present": False,
            },
            "verification": {},
        }
        resize = _transform_completion_summary({**base, "operation": "resize_fit", "alpha_policy": "preserve"})
        self.assertEqual(resize, "已生成 结果.jpg（JPEG，240×160 像素）。")

        alpha = _transform_completion_summary({
            **base,
            "operation": "convert",
            "alpha_policy": "flatten_white",
            "verification": {"white_composite": {"verified": True}},
        })
        self.assertIn("透明区域已铺白色并核验", alpha)

        stripped = _transform_completion_summary({
            **base,
            "operation": "strip_metadata",
            "alpha_policy": "preserve",
        })
        self.assertIn("隐私元数据已移除并核验", stripped)
        for text in (resize, alpha, stripped):
            self.assertNotIn("image.transform", text)
            self.assertNotIn("readback", text)
            self.assertNotIn("privacy_metadata_present", text)

    def test_existing_public_progress_copy_is_natural(self) -> None:
        self.assertEqual(capability_label(INSPECT_ID), "查看图片信息")
        self.assertEqual(capability_label(TRANSFORM_ID), "处理图片")
        self.assertEqual(capability_activity_title(INSPECT_ID, "complete"), "图片信息已核对")
        self.assertEqual(capability_activity_title(TRANSFORM_ID, "complete"), "图片已处理并核验")
