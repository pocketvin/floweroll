from __future__ import annotations

import unittest

from floweroll_host.mcp_adapter import MCPReadToolAdapter
from floweroll_host.mcp_execution_worker import MCPExecutionWorker


class MCPOutputBoundingTests(unittest.TestCase):
    def test_large_text_and_binary_payload_are_bounded_before_runtime_storage(self) -> None:
        content, truncated = MCPExecutionWorker._bounded_content(
            [
                {"type": "text", "text": "x" * 50_000},
                {"type": "image", "data": "A" * 100_000, "mimeType": "image/png"},
            ]
        )
        self.assertTrue(truncated)
        self.assertEqual(len(content[0]["text"]), 40_000)
        self.assertNotIn("data", content[1])
        self.assertEqual(content[1]["mimeType"], "image/png")

    def test_structured_content_is_depth_and_item_bounded(self) -> None:
        value = {
            "items": [{"text": "z" * 20_000, "nested": {"a": {"b": {"c": {"d": 1}}}}} for _ in range(70)]
        }
        bounded, truncated = MCPExecutionWorker._bounded_value(value)
        self.assertTrue(truncated)
        self.assertEqual(len(bounded["items"]), 50)
        self.assertEqual(len(bounded["items"][0]["text"]), 12_000)

    def test_adapter_preserves_truncation_signal_in_verified_observation(self) -> None:
        adapter = MCPReadToolAdapter(
            capability_id="docs.query",
            server_id="docs",
            tool_name="query-docs",
        )
        verification = adapter.verify_result(
            {"payload": {}},
            success=True,
            output={"content": [], "structured_content": None, "truncated": True},
            error=None,
        )
        self.assertEqual(verification.outcome, "SUCCESS")
        self.assertTrue(verification.observation["truncated"])


if __name__ == "__main__":
    unittest.main()
