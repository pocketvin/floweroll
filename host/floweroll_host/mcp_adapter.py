from __future__ import annotations

from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification


class MCPReadToolAdapter:
    """Semantic adapter for a read-only MCP capability.

    Provider/MCP tool annotations are not trusted to define retry safety. This
    class is used only when the application itself has classified the semantic
    capability as read-only.
    """

    source_kind = "mcp"

    def __init__(
        self,
        *,
        capability_id: str,
        server_id: str,
        tool_name: str,
        timeout_seconds: int = 30,
        max_attempts: int = 2,
    ) -> None:
        self.capability_id = capability_id
        self.server_id = server_id
        self.tool_name = tool_name
        self.execution_profile = ExecutionProfile(
            timeout_seconds=timeout_seconds,
            idempotency_mode="NATURAL_READ_ONLY",
            retry_mode="SAFE_WITH_SAME_KEY",
            verification_mode="SOURCE_SCHEMA",
            reconciliation_mode="NONE",
            max_attempts=max_attempts,
            retry_backoff_seconds=1,
        )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "source": {
                "kind": "mcp",
                "server_id": self.server_id,
                "tool_name": self.tool_name,
            },
            "arguments": dict(action["payload"]),
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if success:
            return ExecutionVerification(
                outcome="SUCCESS",
                observation={
                    "source_kind": "mcp",
                    "server_id": self.server_id,
                    "tool_name": self.tool_name,
                    "structured_content": output.get("structured_content"),
                    "content": output.get("content", []),
                    "truncated": bool(output.get("truncated", False)),
                },
            )
        if output.get("mcp_source_status") == "cancelled":
            return ExecutionVerification(outcome="CANCELLED", error=error or "MCP source task cancelled")
        error_kind = output.get("mcp_error_kind")
        if error_kind == "transient_transport":
            return ExecutionVerification(outcome="TRANSIENT_FAILURE", error=error or "MCP transport failure")
        if error_kind == "tool":
            return ExecutionVerification(outcome="MODEL_CORRECTABLE_FAILURE", error=error or "MCP tool rejected request")
        return ExecutionVerification(outcome="TERMINAL_FAILURE", error=error or "MCP protocol failure")
