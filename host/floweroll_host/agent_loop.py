from __future__ import annotations

import threading
import uuid
from typing import Any, Dict, Optional

from .device_probe_adapter import DeviceProbeAdapter
from .execution_runtime import ExecutionRuntime
from .storage import Storage


class AgentLoop:
    """Deterministic compatibility path for hosts started without TaskRuntime.

    Production Planner-enabled hosts use TaskRuntime. This path keeps the small
    device-probe contract available to protocol tests and explicit no-Planner
    deployments without creating a second semantic Planner.
    """

    def __init__(self, storage: Storage):
        self.storage = storage
        self.execution = ExecutionRuntime(storage, [DeviceProbeAdapter()])
        # Compatibility probe creation is synchronous. Keep idempotent intake +
        # initial probe planning in one process-local critical section.
        self._lock = threading.RLock()

    def create_task(
        self,
        goal: str,
        invocation_source: str = "protocol_probe",
        policy_snapshot: Optional[Dict[str, Any]] = None,
        submission_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        if not goal or not goal.strip():
            raise ValueError("goal must not be empty")
        if submission_id is not None and not submission_id.strip():
            raise ValueError("submission_id must not be empty")

        with self._lock:
            task_id = str(uuid.uuid4())
            task, created = self.storage.create_or_get_task(
                task_id=task_id,
                goal=goal.strip(),
                invocation_source=invocation_source,
                policy_snapshot=policy_snapshot or {},
                submission_id=submission_id.strip() if submission_id is not None else None,
            )
            # If a no-Planner Host crashed after durable Task acceptance but
            # before the compatibility probe was planned, replay repairs
            # that boundary instead of stranding or duplicating the Task.
            if int(task["current_step"]) == 0:
                self.plan_initial_action(task)
            current = self.storage.get_task(task["task_id"]) or task
            return {**current, "idempotent_replay": not created}

    def plan_initial_action(self, task: Dict[str, Any]) -> Dict[str, Any]:
        """Plan one harmless device probe action.

        The future iPhone executor will replace this probe with real semantic
        capabilities such as EventKit. The action shape already contains the
        identifiers required for safe retry/reconnect.
        """
        task_id = task["task_id"]
        message = "小卷收到：{}".format(task["goal"])
        action_id = str(uuid.uuid4())
        return self.storage.create_action(
            action_id=action_id,
            task_id=task_id,
            step_index=1,
            action_type="device.probe",
            payload={"message": message},
            expected={"echo": message},
            idempotency_key="{}:1:device.probe".format(task_id),
        )

    def next_action(self, task_id: str) -> Optional[Dict[str, Any]]:
        if self.storage.get_task(task_id) is None:
            raise KeyError(task_id)
        dispatch = self.execution.next_action(task_id)
        if dispatch is None:
            return None
        # Keep the legacy wire value while Runtime state uses `executing`.
        # New clients should use attempt_id/attempt_status as the execution identity.
        return {**dispatch, "runtime_action_status": dispatch["status"], "status": "dispatched"}

    def accept_result(
        self,
        task_id: str,
        action_id: str,
        success: bool,
        output: Optional[Dict[str, Any]] = None,
        error: Optional[str] = None,
        attempt_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        return self.execution.accept_result(
            task_id=task_id,
            action_id=action_id,
            attempt_id=attempt_id,
            success=success,
            output=output,
            error=error,
        )
