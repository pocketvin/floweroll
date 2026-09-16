from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .function_execution_worker import FunctionExecutor
from .function_tool_adapter import FunctionToolAdapter
from .managed_cli import ManagedJSONCLI
from .planner_contracts import CapabilitySpec


DINGTALK_PROVIDER_ID = "dingtalk-dws"


def locate_dws() -> Optional[Path]:
    explicit = os.environ.get("FLOWEROLL_DWS_CLI", "").strip()
    if explicit:
        path = Path(explicit).expanduser()
        return path.resolve() if path.is_file() else None
    found = shutil.which("dws")
    if found:
        return Path(found).resolve()
    fallback = Path.home() / ".local" / "bin" / "dws"
    return fallback.resolve() if fallback.is_file() else None


class DingTalkCLITools:
    def __init__(self, cli: ManagedJSONCLI) -> None:
        self.cli = cli

    def health(self) -> Dict[str, Any]:
        try:
            result = self.cli.run_json(["auth", "status", "-f", "json"])
        except Exception as exc:
            return {"installed": True, "authenticated": False, "reason": type(exc).__name__}
        data = result.get("data")
        authenticated = isinstance(data, dict) and data.get("authenticated") is True
        return {
            "installed": True,
            "authenticated": authenticated,
            "reason": None if authenticated else "not_authenticated",
        }

    def calendar_agenda(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = ["calendar", "+agenda", "-f", "json", "--limit", str(_bounded_int(arguments.get("limit"), 50, 1, 100))]
        _string_flag(argv, "--start", arguments.get("start"))
        _string_flag(argv, "--end", arguments.get("end"))
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已读取钉钉日程。"}

    def contact_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        result = self.cli.run_json(["contact", "+search-user", "-f", "json", "--query", arguments["query"]])
        return {**result, "_completion_summary": "已查询钉钉联系人。"}

    def message_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = [
            "chat", "+search-msg", "-f", "json",
            "--query", arguments["query"],
            "--limit", str(_bounded_int(arguments.get("limit"), 50, 1, 100)),
            "--no-reactions", "--no-enrich",
        ]
        _string_flag(argv, "--start", arguments.get("start"))
        _string_flag(argv, "--end", arguments.get("end"))
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已搜索钉钉消息。"}

    def docs_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        result = self.cli.run_json([
            "doc", "+search", "-f", "json",
            "--query", arguments["query"],
            "--limit", str(_bounded_int(arguments.get("limit"), 10, 1, 30)),
        ])
        return {**result, "_completion_summary": "已搜索钉钉文档。"}

    def task_list(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = ["todo", "+get-my-tasks", "-f", "json", "--size", str(_bounded_int(arguments.get("limit"), 20, 1, 100))]
        if isinstance(arguments.get("completed"), bool):
            argv.extend(["--status", "true" if arguments["completed"] else "false"])
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已读取钉钉待办。"}

    def mail_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = ["mail", "+triage", "-f", "json", "--limit", str(_bounded_int(arguments.get("limit"), 20, 1, 100))]
        _string_flag(argv, "--query", arguments.get("query"))
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已读取钉钉邮件摘要。"}


def register_dingtalk_cli_capabilities(
    registry: CapabilityRegistry,
    *,
    executable: Optional[Path] = None,
) -> Tuple[Dict[str, FunctionExecutor], Dict[str, Any]]:
    path = executable or locate_dws()
    if path is None:
        ready = False
        tools = None
        health = {"installed": False, "authenticated": False, "reason": "cli_not_found"}
    else:
        tools = DingTalkCLITools(ManagedJSONCLI(path, timeout_seconds=30))
        health = tools.health()
        ready = bool(health.get("authenticated"))
        health["executable"] = str(path)

    definitions: List[Tuple[CapabilitySpec, str, Optional[FunctionExecutor], tuple[str, ...]]] = [
        (
            CapabilitySpec(
                name="dingtalk.calendar.agenda",
                description="读取当前用户的钉钉日程，可限定 ISO 8601 时间范围。",
                arguments_schema={
                    "type": "object",
                    "properties": {"start": {"type": "string"}, "end": {"type": "string"}, "limit": {"type": "integer"}},
                    "required": [], "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "calendar.+agenda", tools.calendar_agenda if tools else None, ("dingtalk", "calendar", "read"),
        ),
        (
            CapabilitySpec(
                name="dingtalk.contact.search",
                description="按姓名或关键词搜索当前用户可见的钉钉通讯录人员。",
                arguments_schema={
                    "type": "object", "properties": {"query": {"type": "string"}},
                    "required": ["query"], "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "contact.+search-user", tools.contact_search if tools else None, ("dingtalk", "contact", "read"),
        ),
        (
            CapabilitySpec(
                name="dingtalk.message.search",
                description="按关键词和可选时间范围搜索当前用户可见的钉钉消息。",
                arguments_schema={
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"}, "start": {"type": "string"},
                        "end": {"type": "string"}, "limit": {"type": "integer"},
                    },
                    "required": ["query"], "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "chat.+search-msg", tools.message_search if tools else None, ("dingtalk", "message", "read"),
        ),
        (
            CapabilitySpec(
                name="dingtalk.docs.search",
                description="按关键词搜索当前用户有权限的钉钉文档。",
                arguments_schema={
                    "type": "object",
                    "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}},
                    "required": ["query"], "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "doc.+search", tools.docs_search if tools else None, ("dingtalk", "docs", "read"),
        ),
        (
            CapabilitySpec(
                name="dingtalk.tasks.list",
                description="读取当前组织中分配给当前用户的钉钉待办，可按完成状态过滤。",
                arguments_schema={
                    "type": "object",
                    "properties": {"completed": {"type": "boolean"}, "limit": {"type": "integer"}},
                    "required": [], "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "todo.+get-my-tasks", tools.task_list if tools else None, ("dingtalk", "todo", "read"),
        ),
        (
            CapabilitySpec(
                name="dingtalk.mail.search",
                description="读取或按 KQL 搜索当前用户钉钉企业邮箱摘要，不发送/修改邮件。",
                arguments_schema={
                    "type": "object",
                    "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}},
                    "required": [], "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "mail.+triage", tools.mail_search if tools else None, ("dingtalk", "mail", "read"),
        ),
    ]

    executors: Dict[str, FunctionExecutor] = {}
    for spec, command_name, executor, tags in definitions:
        adapter = FunctionToolAdapter(capability_id=spec.name, source_kind="managed_cli", read_only=True)
        registry.register(
            RegisteredCapability(
                spec=spec,
                adapter=adapter,
                source=CapabilitySourceTarget(
                    kind="managed_cli",
                    server_id=DINGTALK_PROVIDER_ID,
                    tool_name=command_name,
                    metadata={"provider": "dingtalk", "read_only": True},
                ),
                tags=tags,
                loading="always_visible" if ready else "deferred",
            )
        )
        if ready and executor is not None:
            executors[spec.name] = executor
    health["ready_capability_count"] = len(executors)
    health["declared_capability_count"] = len(definitions)
    return executors, health


def _string_flag(argv: List[str], flag: str, value: Any) -> None:
    if isinstance(value, str) and value.strip():
        argv.extend([flag, value.strip()])


def _bounded_int(value: Any, default: int, minimum: int, maximum: int) -> int:
    if value is None or not isinstance(value, int) or isinstance(value, bool):
        return default
    return max(minimum, min(maximum, value))
