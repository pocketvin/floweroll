from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Optional

from .agent_loop import AgentLoop
from .alarm_adapter import (
    AlarmCreateAdapter, AlarmPauseAdapter, AlarmQueryAdapter, AlarmResumeAdapter, AlarmUpdateAdapter,
)
from .alarm_cancel_adapter import AlarmCancelAdapter
from .auth import validate_host_binding
from .capability_registry import CapabilityRegistry
from .capabilities_v0 import product_native_capabilities
from .calendar_adapter import CalendarFreeBusyAdapter, CalendarQueryAdapter, CalendarRemoveAdapter, CalendarUpdateAdapter
from .calendar_create_adapter import CalendarCreateAdapter
from .contacts_adapter import ContactsCreateAdapter, ContactsQueryAdapter, ContactsUpdateAdapter
from .control_interrupt import ControlInterruptClassifier
from .device_probe_adapter import DeviceProbeAdapter
from .developer_observability import DeveloperObservabilityService
from .docx_semantic import register_docx_semantic_capabilities
from .execution_runtime import ExecutionRuntime
from .function_execution_worker import FunctionExecutionWorker, FunctionExecutor
from .observation_service import ObservationService
from .image_ops import register_image_ops_capabilities
from .mcp_driver import MCPDriver
from .mcp_execution_worker import MCPExecutionWorker
from .location_current_adapter import LocationCurrentAdapter
from .notify_user_adapter import NotifyUserAdapter
from .recovery import RecoveryCoordinator
from .reminder_adapter import ReminderCreateAdapter
from .reminder_management_adapter import ReminderQueryAdapter, ReminderRemoveAdapter, ReminderSetCompletionAdapter, ReminderUpdateAdapter
from .runtime_supervisor import RuntimeSupervisor
from .task_runtime import TaskRuntime
from .task_assets import TaskAssetStore
from .task_material_tools import register_task_material_capabilities
from .storage import Storage
from .http_transport import FlowerollHTTPServer


class HostApp:
    def __init__(
        self,
        db_path: str,
        *,
        task_runtime_factory: Optional[Callable[[Storage], TaskRuntime]] = None,
        product_policy_snapshot: Optional[Dict[str, Any]] = None,
        control_interrupt_classifier: Optional[ControlInterruptClassifier] = None,
        capability_registry: Optional[CapabilityRegistry] = None,
        mcp_drivers: Optional[Mapping[str, MCPDriver]] = None,
        function_executors: Optional[Mapping[str, FunctionExecutor]] = None,
        task_asset_root: Optional[Path] = None,
        progressive_discovery: bool = False,
    ):
        self.storage = Storage(db_path)
        self.developer_observability = DeveloperObservabilityService.from_environment(db_path)
        self.recovery = RecoveryCoordinator(self.storage)
        self.startup_recovery_report = self.recovery.recover_startup()
        self.agent = AgentLoop(self.storage)  # no-Planner compatibility path
        self.capability_registry = capability_registry if capability_registry is not None else CapabilityRegistry()
        self.task_assets = TaskAssetStore(task_asset_root, self.storage) if task_asset_root is not None else None
        extra_executors = {}
        self.image_ops_health: Dict[str, Any] = {"ready": False, "reason": "task_assets_disabled"}
        self.docx_semantic_health: Dict[str, Any] = {"ready": False, "reason": "task_assets_disabled"}
        if self.task_assets is not None:
            extra_executors = register_task_material_capabilities(
                self.capability_registry, assets=self.task_assets,
                helpers=Path(__file__).resolve().parents[1] / "native_helpers",
                runtime_dir=task_asset_root / "native-runtime")
            image_executors, self.image_ops_health = register_image_ops_capabilities(
                self.capability_registry,
                assets=self.task_assets,
                runtime_dir=Path(__file__).resolve().parents[2] / "work" / "host-native-tools" / "image-ops",
                helper_source=Path(__file__).resolve().parents[1] / "native_helpers" / "ImageOpsHelper.swift",
            )
            extra_executors.update(image_executors)
            docx_executors, self.docx_semantic_health = register_docx_semantic_capabilities(
                self.capability_registry,
                assets=self.task_assets,
            )
            extra_executors.update(docx_executors)
        if progressive_discovery:
            from .capability_discovery import register_capability_discovery
            extra_executors.update(register_capability_discovery(
                self.capability_registry, self.storage, self._ready_discovery_capabilities))
        if self.task_assets is not None:
            from .work_units import register_work_units
            extra_executors.update(register_work_units(
                self.capability_registry, self.task_assets,
                {**dict(function_executors or {}), **extra_executors},
                mcp_drivers=dict(mcp_drivers or {})))
        execution_adapters = [
            DeviceProbeAdapter(),
            LocationCurrentAdapter(),
            ReminderCreateAdapter(),
            ReminderQueryAdapter(),
            ReminderSetCompletionAdapter(),
            ContactsQueryAdapter(),
            ContactsCreateAdapter(),
            ContactsUpdateAdapter(),
            ReminderUpdateAdapter(),
            ReminderRemoveAdapter(),
            AlarmQueryAdapter(),
            AlarmCreateAdapter(),
            AlarmUpdateAdapter(),
            AlarmPauseAdapter(),
            AlarmResumeAdapter(),
            AlarmCancelAdapter(),
            CalendarFreeBusyAdapter(),
            CalendarQueryAdapter(),
            CalendarUpdateAdapter(),
            CalendarRemoveAdapter(),
            CalendarCreateAdapter(),
            NotifyUserAdapter(),
        ]
        execution_adapters.extend(self.capability_registry.execution_adapters())
        policy_specs = (
            product_native_capabilities()
            + self.capability_registry.planner_capabilities(include_deferred=True)
        )
        self.execution = ExecutionRuntime(
            self.storage,
            execution_adapters,
            capability_specs=policy_specs,
            capability_registry=self.capability_registry,
        )
        self.mcp_drivers = dict(mcp_drivers or {})
        self.mcp_worker = (
            MCPExecutionWorker(
                self.execution,
                self.capability_registry,
                self.mcp_drivers,
            )
            if self.capability_registry.source_entries("mcp") and self.mcp_drivers
            else None
        )
        self.function_executors = {**dict(function_executors or {}), **extra_executors}
        self.function_worker = (
            FunctionExecutionWorker(
                self.execution,
                self.capability_registry,
                self.function_executors,
            )
            if self.function_executors
            else None
        )
        self.product_policy_snapshot = dict(product_policy_snapshot or {})
        if progressive_discovery and "allowed_capabilities" in self.product_policy_snapshot:
            self.product_policy_snapshot["allowed_capabilities"] = list(dict.fromkeys(
                [*self.product_policy_snapshot["allowed_capabilities"], "capability.search"]))
        self.task_runtime = (
            task_runtime_factory(self.storage) if task_runtime_factory is not None else None
        )
        if self.task_runtime is not None:
            self.task_runtime.capability_registry = self.capability_registry
            self.developer_observability.planner_description = self.task_runtime.planner_graph.describe()
        if self.task_runtime is not None and self.task_assets is not None:
            self.task_runtime.material_context_provider = self.task_assets.context
            self.task_runtime.completion_guard = self.task_assets.guard_completion
            self.task_runtime.additional_observation_provider = self.task_assets.work_units.model_evidence
        if progressive_discovery and self.task_runtime is not None:
            from .capability_discovery import CapabilityContextSelector, SEARCH_ID
            if not any(spec.name == SEARCH_ID for spec in self.task_runtime.capabilities):
                self.task_runtime.capabilities.append(self.capability_registry.get(SEARCH_ID).spec)
            self.task_runtime.capability_context_selector = CapabilityContextSelector(
                self.capability_registry, ready_specs=self._ready_discovery_capabilities)
        execution_workers = [
            worker for worker in (self.mcp_worker, self.function_worker) if worker is not None
        ]
        self.observation_service = ObservationService(db_path)
        self.supervisor = RuntimeSupervisor(
            self.storage,
            self.task_runtime,
            control_interrupt_classifier=control_interrupt_classifier,
            execution_workers=execution_workers,
        )
        self.supervisor.start()

    def get_task_view(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Join verified work progress onto the normal resumable product view.

        Asset and Runtime stores have separate locks. Use a bounded revision
        fence instead of nesting their locks in opposite order. During sustained
        churn, omit progress rather than pairing it with a different lifecycle.
        """
        view = self.storage.get_task_view(task_id)
        if view is None or self.task_assets is None:
            return view
        for _ in range(3):
            summary = self.task_assets.manifest(task_id)["work_summary"]
            current = self.storage.get_task_view(task_id)
            if current is None:
                return None
            if (view["task"] == current["task"] and view["runtime"] == current["runtime"]
                    and view["presentation_cursor"] == current["presentation_cursor"]):
                return {**current, "work_summary": summary}
            view = current
        return {**view, "work_summary": None}

    def _ready_discovery_capabilities(self):
        native = {spec.name for spec in product_native_capabilities()}
        specs = self.task_runtime.capabilities if self.task_runtime is not None else []
        result = []
        for spec in specs:
            if spec.name in native:
                if spec.name in self.execution.adapters:
                    result.append(spec)
                continue
            if spec.name not in self.capability_registry:
                continue
            entry = self.capability_registry.get(spec.name)
            if entry.loading == "deferred":
                continue
            ready = (entry.source.server_id in self.mcp_drivers
                     if entry.source.kind == "mcp" else spec.name in self.function_executors)
            if ready:
                result.append(spec)
        return result

    def capability_status(self) -> Dict[str, Any]:
        capabilities = []
        registry_names = {
            entry.spec.name for entry in self.capability_registry.entries(include_deferred=True)
        }
        for spec in product_native_capabilities():
            if spec.name in registry_names:
                continue
            capabilities.append(
                {
                    "capability_id": spec.name,
                    "description": spec.description,
                    "post_verify_mode": spec.post_verify_mode,
                    "loading": "always_visible",
                    "tags": ["device", "ios", "native"],
                    "source": {
                        "kind": "ios",
                        "server_id": None,
                        "tool_name": spec.name,
                        "readiness_scope": "host_adapter_present",
                    },
                    "ready": spec.name in self.execution.adapters,
                }
            )
        for entry in self.capability_registry.entries(include_deferred=True):
            source = entry.source
            ready = False
            source_status: Dict[str, Any] = {
                "kind": source.kind,
                "server_id": source.server_id,
                "tool_name": source.tool_name,
            }
            if source.kind == "mcp":
                driver = self.mcp_drivers.get(source.server_id or "")
                ready = driver is not None
                if driver is not None:
                    source_status["protocol_era"] = driver.protocol_era
                    source_status["protocol_version"] = driver.protocol_version
            else:
                ready = entry.spec.name in self.function_executors
            capabilities.append(
                {
                    "capability_id": entry.spec.name,
                    "description": entry.spec.description,
                    "post_verify_mode": entry.spec.post_verify_mode,
                    "loading": entry.loading,
                    "tags": list(entry.tags),
                    "source": source_status,
                    "ready": ready,
                }
            )
        return {
            "capabilities": sorted(capabilities, key=lambda item: item["capability_id"]),
            "mcp_servers": {
                server_id: {
                    "protocol_era": driver.protocol_era,
                    "protocol_version": driver.protocol_version,
                }
                for server_id, driver in sorted(self.mcp_drivers.items())
            },
        }

    def accept_product_task(
        self,
        *,
        goal: str,
        invocation_source: str,
        submission_id: str,
        parent_task_id: str | None = None,
        attachment_ids: Optional[list[str]] = None,
    ) -> Dict[str, Any]:
        import uuid

        if self.task_assets is not None:
            self.task_assets.bind("submission:" + submission_id, attachment_ids or [])
        elif attachment_ids:
            raise ValueError("附件服务未启用。")

        task, created = self.storage.create_or_get_task(
            task_id=str(uuid.uuid4()),
            goal=goal,
            invocation_source=invocation_source,
            policy_snapshot=self.product_policy_snapshot,
            submission_id=submission_id,
            status="active",
            parent_task_id=parent_task_id,
        )
        self.supervisor.wake()
        current = self.storage.get_task(task["task_id"]) or task
        return {**current, "idempotent_replay": not created}

    def close(self) -> None:
        self.supervisor.stop()
        self.observation_service.close()
        if self.task_assets is not None:
            self.task_assets.close()



def create_server(
    host: str,
    port: int,
    db_path: str,
    *,
    auth_token: str | None = None,
    task_runtime_factory: Optional[Callable[[Storage], TaskRuntime]] = None,
    product_policy_snapshot: Optional[Dict[str, Any]] = None,
    control_interrupt_classifier: Optional[ControlInterruptClassifier] = None,
    capability_registry: Optional[CapabilityRegistry] = None,
    mcp_drivers: Optional[Mapping[str, MCPDriver]] = None,
    function_executors: Optional[Mapping[str, FunctionExecutor]] = None,
    task_asset_root: Optional[Path] = None,
    progressive_discovery: bool = False,
) -> FlowerollHTTPServer:
    validate_host_binding(host)
    token = auth_token.strip() if isinstance(auth_token, str) and auth_token.strip() else None
    app = HostApp(
        db_path,
        task_runtime_factory=task_runtime_factory,
        product_policy_snapshot=product_policy_snapshot,
        control_interrupt_classifier=control_interrupt_classifier,
        capability_registry=capability_registry,
        mcp_drivers=mcp_drivers,
        function_executors=function_executors,
        task_asset_root=task_asset_root,
        progressive_discovery=progressive_discovery,
    )
    return FlowerollHTTPServer((host, port), app, auth_token=token)
