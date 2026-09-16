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


FEISHU_PROVIDER_ID = "feishu-cli"


def locate_lark_cli() -> Optional[Path]:
    explicit = os.environ.get("FLOWEROLL_LARK_CLI", "").strip()
    if explicit:
        path = Path(explicit).expanduser()
        return path.resolve() if path.is_file() else None
    found = shutil.which("lark-cli")
    return Path(found).resolve() if found else None


class FeishuCLITools:
    def __init__(self, cli: ManagedJSONCLI) -> None:
        self.cli = cli

    def health(self) -> Dict[str, Any]:
        try:
            result = self.cli.run_json(["whoami"])
        except Exception as exc:
            return {
                "installed": True,
                "authenticated": False,
                "reason": type(exc).__name__,
            }
        data = result.get("data")
        ok = isinstance(data, dict) and data.get("ok") is True
        return {"installed": True, "authenticated": ok, "reason": None if ok else "not_authenticated"}

    def calendar_agenda(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = ["calendar", "+agenda", "--as", "user", "--format", "json"]
        _string_flag(argv, "--start", arguments.get("start"))
        _string_flag(argv, "--end", arguments.get("end"))
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已读取飞书日程。"}

    def contact_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = [
            "contact", "+search-user", "--as", "user", "--format", "json",
            "--query", arguments["query"],
            "--page-size", str(_bounded_int(arguments.get("limit"), 20, 1, 30)),
        ]
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已查询飞书联系人。"}

    def message_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = [
            "im", "+messages-search", "--as", "user", "--format", "json",
            "--query", arguments["query"], "--no-reactions",
            "--page-size", str(_bounded_int(arguments.get("limit"), 20, 1, 50)),
        ]
        _string_flag(argv, "--start", arguments.get("start"))
        _string_flag(argv, "--end", arguments.get("end"))
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已搜索飞书消息。"}

    def docs_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = [
            "docs", "+search", "--as", "user", "--format", "json",
            "--query", arguments["query"],
            "--page-size", str(_bounded_int(arguments.get("limit"), 15, 1, 20)),
        ]
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已搜索飞书文档。"}

    def task_list(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = ["task", "+get-my-tasks", "--as", "user", "--format", "json"]
        _string_flag(argv, "--query", arguments.get("query"))
        if isinstance(arguments.get("completed"), bool):
            argv.extend(["--complete", "true" if arguments["completed"] else "false"])
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已读取飞书任务。"}

    def mail_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        argv = [
            "mail", "+triage", "--as", "user", "--format", "json",
            "--max", str(_bounded_int(arguments.get("limit"), 20, 1, 100)),
        ]
        _string_flag(argv, "--query", arguments.get("query"))
        if arguments.get("unread_only") is True:
            argv.append("--is-unread")
        result = self.cli.run_json(argv)
        return {**result, "_completion_summary": "已读取飞书邮件摘要。"}


def register_feishu_cli_capabilities(
    registry: CapabilityRegistry,
    *,
    executable: Optional[Path] = None,
) -> Tuple[Dict[str, FunctionExecutor], Dict[str, Any]]:
    path = executable or locate_lark_cli()
    if path is None:
        ready = False
        tools = None
        health = {"installed": False, "authenticated": False, "reason": "cli_not_found"}
    else:
        tools = FeishuCLITools(ManagedJSONCLI(path))
        health = tools.health()
        ready = bool(health.get("authenticated"))
        health["executable"] = str(path)

    definitions: List[Tuple[CapabilitySpec, str, Optional[FunctionExecutor], tuple[str, ...]]] = [
        (
            CapabilitySpec(
                name="feishu.calendar.agenda",
                description="读取当前用户的飞书主日历议程，可限定 ISO 8601 起止时间。",
                arguments_schema={
                    "type": "object",
                    "properties": {"start": {"type": "string"}, "end": {"type": "string"}},
                    "required": [],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "calendar.+agenda",
            tools.calendar_agenda if tools else None,
            ("feishu", "calendar", "read"),
        ),
        (
            CapabilitySpec(
                name="feishu.contact.search",
                description="按姓名、邮箱等关键词搜索当前用户可见的飞书联系人。",
                arguments_schema={
                    "type": "object",
                    "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}},
                    "required": ["query"],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "contact.+search-user",
            tools.contact_search if tools else None,
            ("feishu", "contact", "read"),
        ),
        (
            CapabilitySpec(
                name="feishu.message.search",
                description="在当前用户可见的飞书会话中按关键词/时间搜索消息。",
                arguments_schema={
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"}, "start": {"type": "string"},
                        "end": {"type": "string"}, "limit": {"type": "integer"},
                    },
                    "required": ["query"],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "im.+messages-search",
            tools.message_search if tools else None,
            ("feishu", "message", "read"),
        ),
        (
            CapabilitySpec(
                name="feishu.docs.search",
                description="搜索当前用户可访问的飞书文档、Wiki 和表格文件。",
                arguments_schema={
                    "type": "object",
                    "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}},
                    "required": ["query"],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "docs.+search",
            tools.docs_search if tools else None,
            ("feishu", "docs", "read"),
        ),
        (
            CapabilitySpec(
                name="feishu.tasks.list",
                description="读取当前用户被分配的飞书任务，可按标题和完成状态过滤。",
                arguments_schema={
                    "type": "object",
                    "properties": {"query": {"type": "string"}, "completed": {"type": "boolean"}},
                    "required": [],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "task.+get-my-tasks",
            tools.task_list if tools else None,
            ("feishu", "task", "read"),
        ),
        (
            CapabilitySpec(
                name="feishu.mail.search",
                description="读取/搜索当前用户飞书邮箱的邮件摘要，不发送或修改邮件。",
                arguments_schema={
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"}, "unread_only": {"type": "boolean"},
                        "limit": {"type": "integer"},
                    },
                    "required": [],
                    "additionalProperties": False,
                },
                post_verify_mode="REPLAN_REQUIRED",
            ),
            "mail.+triage",
            tools.mail_search if tools else None,
            ("feishu", "mail", "read"),
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
                    server_id=FEISHU_PROVIDER_ID,
                    tool_name=command_name,
                    metadata={"provider": "feishu", "read_only": True},
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
    if value is None:
        return default
    if not isinstance(value, int) or isinstance(value, bool):
        return default
    return max(minimum, min(maximum, value))
