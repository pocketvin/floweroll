from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor, wait
from dataclasses import dataclass
import threading
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
        self._pool = ThreadPoolExecutor(
            max_workers=max_workers,
            thread_name_prefix="floweroll-function",
        )
        self._futures: Dict[str, Future] = {}
        self._futures_lock = threading.Lock()
        self._completion_callback: Optional[Callable[[], None]] = None
        self._closed = False

    def sweep_once(self) -> List[Dict[str, Any]]:
        """Harvest finished work and admit new independent Tasks without blocking.

        A function can have its own bounded network/process timeout, but Python
        cannot safely preempt an arbitrary in-process callable after it may have
        crossed a side-effect boundary. Keep one Future per Task instead: a
        slow callable occupies only its worker slot and never causes this sweep
        to wait for every other Function Action.
        """
        results: List[Dict[str, Any]] = []
        errors: List[Exception] = []
        failed_task_ids: set[str] = set()
        with self._futures_lock:
            finished = [
                (task_id, future)
                for task_id, future in self._futures.items()
                if future.done()
            ]
            for task_id, _ in finished:
                self._futures.pop(task_id, None)

        for task_id, future in finished:
            try:
                value = future.result()
                if value is not None:
                    results.append(value)
            except Exception as exc:
                failed_task_ids.add(task_id)
                errors.append(exc)

        capability_ids = sorted(self.executors)
        if capability_ids:
            task_ids = self.execution.storage.open_action_task_ids(capability_ids)
            scheduled: List[Future] = []
            with self._futures_lock:
                if not self._closed:
                    capacity = max(0, self.max_workers - len(self._futures))
                    for task_id in task_ids:
                        if capacity == 0:
                            break
                        if task_id in self._futures or task_id in failed_task_ids:
                            continue
                        future = self._pool.submit(self.run_once, task_id)
                        self._futures[task_id] = future
                        scheduled.append(future)
                        capacity -= 1
            for future in scheduled:
                future.add_done_callback(self._did_finish_future)

        if errors:
            raise errors[0]
        return results

    def set_completion_callback(self, callback: Optional[Callable[[], None]]) -> None:
        """Wake an owning scheduler when an asynchronous Function run finishes."""
        with self._futures_lock:
            self._completion_callback = callback

    def close(self, *, timeout_seconds: float = 0.5) -> bool:
        first_close = False
        with self._futures_lock:
            if not self._closed:
                self._closed = True
                first_close = True
            self._completion_callback = None
            futures = tuple(self._futures.values())
        # Queued work never crossed the function boundary and can be cancelled.
        # Running callables are intentionally not force-killed: doing so cannot
        # prove whether a side effect started. Their durable Attempt remains the
        # source of truth until the callable returns or the Host process exits.
        if first_close:
            self._pool.shutdown(wait=False, cancel_futures=True)
        if not futures:
            return True
        _, pending = wait(futures, timeout=max(0.0, float(timeout_seconds)))
        return not pending

    def when_drained(self, callback: Callable[[], None]) -> None:
        """Run callback once every already-admitted Future has settled."""
        with self._futures_lock:
            pending = {future for future in self._futures.values() if not future.done()}
        if not pending:
            callback()
            return

        callback_lock = threading.Lock()
        fired = False

        def settled(future: Future) -> None:
            nonlocal fired
            should_fire = False
            with callback_lock:
                pending.discard(future)
                if not pending and not fired:
                    fired = True
                    should_fire = True
            if should_fire:
                try:
                    callback()
                except Exception:
                    pass

        for future in tuple(pending):
            future.add_done_callback(settled)

    def _did_finish_future(self, _: Future) -> None:
        with self._futures_lock:
            callback = self._completion_callback
        if callback is not None:
            try:
                callback()
            except Exception:
                pass

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
