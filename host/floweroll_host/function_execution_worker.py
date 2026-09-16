from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import time
from typing import Any, Callable, Dict, List, Mapping, Optional, Union

from .capability_registry import CapabilityRegistry
from .execution_runtime import ExecutionRuntime


@dataclass(frozen=True)
class TaskScopedFunction:
    """Only Runtime supplies identity; the Planner cannot pass a task/path scope."""
    invoke: Callable[[Dict[str, Any], Dict[str, Any]], Dict[str, Any]]


FunctionExecutor = Union[Callable[[Dict[str, Any]], Dict[str, Any]], TaskScopedFunction]


class FunctionExecutionWorker:
    """Execute bounded Host/API functions through the durable Runtime.

    Concrete functions never mutate Task state directly. They receive only the
    committed Action arguments and return a bounded result that is verified by
    the capability adapter before it can become an Observation.
    """

    def __init__(
        self,
        execution: ExecutionRuntime,
        registry: CapabilityRegistry,
        executors: Mapping[str, FunctionExecutor],
        *,
        max_workers: int = 4,
    ) -> None:
        if max_workers < 1:
            raise ValueError("max_workers must be positive")
        self.execution = execution
        self.registry = registry
        self.executors = dict(executors)
        self.max_workers = max_workers

    def sweep_once(self) -> List[Dict[str, Any]]:
        capability_ids = sorted(self.executors)
        if not capability_ids:
            return []
        task_ids = self.execution.storage.open_action_task_ids(capability_ids)
        if not task_ids:
            return []
        results: List[Dict[str, Any]] = []
        with ThreadPoolExecutor(
            max_workers=min(self.max_workers, len(task_ids)),
            thread_name_prefix="floweroll-function",
        ) as pool:
            futures = {pool.submit(self.run_once, task_id): task_id for task_id in task_ids}
            for future in as_completed(futures):
                value = future.result()
                if value is not None:
                    results.append(value)
        return results

    def run_once(self, task_id: str) -> Optional[Dict[str, Any]]:
        action = self.execution.storage.get_open_action(task_id)
        if action is None:
            return None
        capability_id = str(action["action_type"])
        executor = self.executors.get(capability_id)
        if executor is None:
            return None
        try:
            entry = self.registry.get(capability_id)
        except KeyError:
            return None
        dispatch = self.execution.next_action(task_id, source_kind=entry.source.kind)
        if dispatch is None:
            return None

        execution_started = time.perf_counter()
        try:
            if isinstance(executor, TaskScopedFunction):
                output = executor.invoke(dict(dispatch), dict(dispatch["payload"]))
            else:
                output = executor(dict(dispatch["payload"]))
            if not isinstance(output, dict):
                raise TypeError("function executor must return an object")
            success = True
            error = None
        except FunctionToolError as exc:
            output = {"error_kind": exc.error_kind, **exc.output}
            success = False
            error = str(exc)
        except TimeoutError as exc:
            output = {"error_kind": "transient"}
            success = False
            error = str(exc) or "Host function timed out"
        except Exception as exc:
            output = {"error_kind": "terminal", "error_type": type(exc).__name__}
            success = False
            error = str(exc) or type(exc).__name__

        self.execution.storage.record_trace_event(
            dispatch["task_id"],
            "action.tool.execution",
            {
                "action_id": dispatch["action_id"],
                "attempt_id": dispatch["attempt_id"],
                "capability": capability_id,
                "source_kind": entry.source.kind,
                "execution_ms": round(
                    (time.perf_counter() - execution_started) * 1000.0, 3
                ),
                "success": success,
            },
        )
        return self.execution.accept_result(
            task_id=dispatch["task_id"],
            action_id=dispatch["action_id"],
            attempt_id=dispatch["attempt_id"],
            success=success,
            output=output,
            error=error,
        )


class FunctionToolError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        error_kind: str = "terminal",
        output: Optional[Dict[str, Any]] = None,
    ) -> None:
        if error_kind not in {"terminal", "transient", "model_correctable"}:
            raise ValueError("invalid function tool error kind")
        super().__init__(message)
        self.error_kind = error_kind
        self.output = dict(output or {})
