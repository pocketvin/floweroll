from __future__ import annotations

import logging
import threading
import traceback
import uuid
from concurrent.futures import Future, ThreadPoolExecutor, as_completed, wait
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, List, Optional

from .control_interrupt import ControlInterruptClassifier
from .openai_compatible_chat_adapter import OpenAICompatibleChatPlannerTransientError
from .recovery import RecoveryCoordinator
from .task_capability_policy import TaskCapabilityDeniedError
from .task_runtime import PlannerAlreadyRunningError, PlannerWorkSupersededError, TaskRuntime
from .storage import PlannerBudgetExceededError, Storage


logger = logging.getLogger(__name__)


class RuntimeSupervisor:
    """Small Mac-V1 background scheduler for durable Runtime work.

    Planner progression and urgent control-intent classification use separate
    wake threads. Neither thread owns Task truth; every effect is fenced and
    committed through Storage/TaskRuntime.
    """

    def __init__(
        self,
        storage: Storage,
        task_runtime: Optional[TaskRuntime],
        *,
        control_interrupt_classifier: Optional[ControlInterruptClassifier] = None,
        execution_workers: Iterable[Any] = (),
        poll_interval_seconds: float = 0.5,
        control_max_workers: int = 4,
        planner_max_workers: int = 3,
        planner_transient_auto_retries: int = 1,
        planner_retry_base_seconds: float = 3.0,
    ) -> None:
        if poll_interval_seconds <= 0:
            raise ValueError("poll_interval_seconds must be positive")
        if control_max_workers < 1:
            raise ValueError("control_max_workers must be positive")
        if planner_max_workers < 1:
            raise ValueError("planner_max_workers must be positive")
        if planner_transient_auto_retries < 0:
            raise ValueError("planner_transient_auto_retries must not be negative")
        if planner_retry_base_seconds <= 0:
            raise ValueError("planner_retry_base_seconds must be positive")
        self.storage = storage
        self.task_runtime = task_runtime
        self.recovery = RecoveryCoordinator(storage)
        self.control_interrupt_classifier = control_interrupt_classifier
        self.execution_workers = list(execution_workers)
        self.poll_interval_seconds = poll_interval_seconds
        self.control_max_workers = control_max_workers
        self.planner_max_workers = planner_max_workers
        self.planner_transient_auto_retries = planner_transient_auto_retries
        self.planner_retry_base_seconds = planner_retry_base_seconds
        self._stop = threading.Event()
        self._planner_wake = threading.Event()
        self._control_wake = threading.Event()
        self._execution_wake = threading.Event()
        self._planner_thread: Optional[threading.Thread] = None
        self._planner_pool: Optional[ThreadPoolExecutor] = None
        self._planner_futures: Dict[str, Future] = {}
        self._planner_futures_lock = threading.Lock()
        self._control_thread: Optional[threading.Thread] = None
        self._execution_thread: Optional[threading.Thread] = None
        for worker in self.execution_workers:
            setter = getattr(worker, "set_completion_callback", None)
            if callable(setter):
                setter(self._execution_wake.set)

    @property
    def configured(self) -> bool:
        return (
            self.task_runtime is not None
            or self.control_interrupt_classifier is not None
            or bool(self.execution_workers)
        )

    def start(self) -> None:
        if self.task_runtime is not None and (
            self._planner_thread is None or not self._planner_thread.is_alive()
        ):
            self._stop.clear()
            if self._planner_pool is None:
                self._planner_pool = ThreadPoolExecutor(
                    max_workers=self.planner_max_workers,
                    thread_name_prefix="floweroll-planner",
                )
            self._planner_thread = threading.Thread(
                target=self._run_planner,
                name="floweroll-runtime-supervisor",
                daemon=True,
            )
            self._planner_thread.start()
            self._planner_wake.set()
        if self.control_interrupt_classifier is not None and (
            self._control_thread is None or not self._control_thread.is_alive()
        ):
            self._stop.clear()
            self._control_thread = threading.Thread(
                target=self._run_control,
                name="floweroll-control-interrupt-supervisor",
                daemon=True,
            )
            self._control_thread.start()
            self._control_wake.set()
        if self.execution_workers and (
            self._execution_thread is None or not self._execution_thread.is_alive()
        ):
            self._stop.clear()
            self._execution_thread = threading.Thread(
                target=self._run_execution,
                name="floweroll-execution-supervisor",
                daemon=True,
            )
            self._execution_thread.start()
            self._execution_wake.set()

    def stop(self, timeout_seconds: float = 3.0, planner_drain_seconds: float = 0.5) -> bool:
        self._stop.set()
        self._planner_wake.set()
        self._control_wake.set()
        self._execution_wake.set()
        for thread in (self._planner_thread, self._control_thread, self._execution_thread):
            if thread is not None and thread.is_alive():
                thread.join(timeout=timeout_seconds)

        with self._planner_futures_lock:
            planner_futures = tuple(self._planner_futures.values())
        planner_pool = self._planner_pool
        self._planner_pool = None
        if planner_pool is not None:
            planner_pool.shutdown(wait=False, cancel_futures=True)

        pending = set()
        if planner_futures:
            _, pending = wait(
                planner_futures,
                timeout=max(0.0, float(planner_drain_seconds)),
            )
        with self._planner_futures_lock:
            for task_id, future in list(self._planner_futures.items()):
                if future.done():
                    self._planner_futures.pop(task_id, None)
        self._planner_thread = None
        self._control_thread = None
        self._execution_thread = None
        return not pending

    def when_planner_drained(self, callback: Callable[[], None]) -> None:
        """Run callback once every already-admitted Planner future settles."""
        with self._planner_futures_lock:
            pending = {
                future
                for future in self._planner_futures.values()
                if not future.done()
            }
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

    def wake(self) -> None:
        if self.task_runtime is not None:
            self._planner_wake.set()
        if self.control_interrupt_classifier is not None:
            self._control_wake.set()
        if self.execution_workers:
            self._execution_wake.set()

    def execution_sweep_once(self) -> List[Dict[str, Any]]:
        results: List[Dict[str, Any]] = []
        for worker in self.execution_workers:
            values = worker.sweep_once()
            if values:
                results.extend(values)
        return results

    def sweep_once(self) -> List[Dict[str, Any]]:
        if self.task_runtime is None:
            return []
        now = datetime.now(timezone.utc).isoformat()
        candidates = self.storage.recovery_candidates(now=now)["active_planning"]
        results: List[Dict[str, Any]] = []
        for candidate in candidates:
            task_id = str(candidate["task_id"])
            result = self.advance_task(task_id)
            if result is not None:
                results.append(result)
        return results

    def planner_schedule_once(self) -> List[str]:
        """Schedule independent Tasks without serializing slow model calls."""
        if self.task_runtime is None or self._planner_pool is None:
            return []
        recovered = self.recovery.recover_due()
        if any(
            item.get("owner") in {"EXECUTION_RETRY", "SOURCE_OPERATION"}
            for item in recovered
        ):
            self._execution_wake.set()
        now = datetime.now(timezone.utc).isoformat()
        candidates = self.storage.recovery_candidates(now=now)["active_planning"]
        with self._planner_futures_lock:
            finished = [
                task_id
                for task_id, future in self._planner_futures.items()
                if future.done()
            ]
            for task_id in finished:
                self._planner_futures.pop(task_id, None)
            capacity = max(0, self.planner_max_workers - len(self._planner_futures))
            if capacity == 0:
                return []
            scheduled: List[str] = []
            for candidate in candidates:
                task_id = str(candidate["task_id"])
                if task_id in self._planner_futures:
                    continue
                self.storage.record_trace_event(
                    task_id,
                    "runtime.planner.scheduled",
                    {
                        "active_planner_workers": len(self._planner_futures),
                        "planner_max_workers": self.planner_max_workers,
                    },
                )
                future = self._planner_pool.submit(
                    self._advance_task_background, task_id
                )
                self._planner_futures[task_id] = future
                scheduled.append(task_id)
                capacity -= 1
                if capacity == 0:
                    break
            return scheduled

    def _advance_task_background(self, task_id: str) -> Optional[Dict[str, Any]]:
        try:
            self.storage.record_trace_event(
                task_id,
                "runtime.planner.worker_started",
                {},
            )
            return self.advance_task(task_id)
        finally:
            # Wake the scheduler promptly so the next semantic step or another
            # Task does not wait for the periodic recovery sweep.
            self._planner_wake.set()

    def control_sweep_once(self) -> List[Dict[str, Any]]:
        classifier = self.control_interrupt_classifier
        if classifier is None:
            return []
        bases = []
        for task_id in self.storage.control_interrupt_candidate_task_ids():
            basis = self.storage.control_interrupt_basis(task_id)
            if basis is not None:
                bases.append(basis)
        if not bases:
            return []

        results: List[Dict[str, Any]] = []
        workers = min(self.control_max_workers, len(bases))
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="floweroll-control") as pool:
            future_map = {pool.submit(self._classify_control_basis, basis): basis for basis in bases}
            for future in as_completed(future_map):
                basis = future_map[future]
                try:
                    results.append(future.result())
                except Exception as exc:  # fail closed: preserve UserTurn for normal Planner
                    fallback = self.storage.apply_control_interrupt_decision(
                        decision_id=str(uuid.uuid4()),
                        task_id=str(basis["task_id"]),
                        action_id=str(basis["action"]["action_id"]),
                        attempt_id=str(basis["attempt"]["attempt_id"]),
                        expected_runtime_revision=int(basis["runtime_revision"]),
                        basis_inbox_seq=int(basis["basis_inbox_seq"]),
                        user_event_ids=[str(turn["event_id"]) for turn in basis["user_turns"]],
                        intent="NONE",
                        confidence="LOW",
                        reason="control classifier unavailable: {}".format(type(exc).__name__),
                    )
                    results.append(
                        {
                            "task_id": basis["task_id"],
                            "status": fallback["status"],
                            "intent": "NONE",
                            "confidence": "LOW",
                            "classifier_error_type": type(exc).__name__,
                        }
                    )
        return results

    def _classify_control_basis(self, basis: Dict[str, Any]) -> Dict[str, Any]:
        classifier = self.control_interrupt_classifier
        assert classifier is not None
        decision = classifier.classify(basis)
        applied = self.storage.apply_control_interrupt_decision(
            decision_id=str(uuid.uuid4()),
            task_id=str(basis["task_id"]),
            action_id=str(basis["action"]["action_id"]),
            attempt_id=str(basis["attempt"]["attempt_id"]),
            expected_runtime_revision=int(basis["runtime_revision"]),
            basis_inbox_seq=int(basis["basis_inbox_seq"]),
            user_event_ids=[str(turn["event_id"]) for turn in basis["user_turns"]],
            intent=decision.intent,
            confidence=decision.confidence,
            reason=decision.reason,
        )
        return {
            "task_id": basis["task_id"],
            "status": applied["status"],
            "intent": decision.intent,
            "confidence": decision.confidence,
            "effective_intent": decision.intent if decision.confidence == "HIGH" else "NONE",
        }

    def advance_task(self, task_id: str) -> Optional[Dict[str, Any]]:
        if self.task_runtime is None:
            return None
        try:
            command = self.task_runtime.next_command(task_id)
            if command.kind != "CALL_PLANNER":
                return {
                    "task_id": task_id,
                    "status": "YIELDED",
                    "command": command.kind,
                    "reason": command.reason,
                }
            result = self.task_runtime.decide(task_id)
            if self.execution_workers:
                self._execution_wake.set()
            return {
                "task_id": task_id,
                "status": "ADVANCED",
                "decision_type": result["decision"]["decision_type"],
            }
        except PlannerAlreadyRunningError:
            return {
                "task_id": task_id,
                "status": "BUSY",
                "reason": "planner_already_running",
            }
        except PlannerWorkSupersededError as exc:
            return {
                "task_id": task_id,
                "status": "YIELDED",
                "command": exc.command.kind,
                "reason": exc.command.reason,
            }
        except OpenAICompatibleChatPlannerTransientError as exc:
            consecutive_failures = self.storage.consecutive_planner_failures(task_id)
            if consecutive_failures <= self.planner_transient_auto_retries:
                runtime_state = self.storage.get_runtime_state(task_id)
                call_number = (
                    int(runtime_state["planner_calls"])
                    if runtime_state is not None
                    else consecutive_failures
                )
                retry_delay = min(
                    30.0,
                    self.planner_retry_base_seconds
                    * (2 ** max(0, consecutive_failures - 1)),
                )
                wake_at = (
                    datetime.now(timezone.utc) + timedelta(seconds=retry_delay)
                ).isoformat()
                scheduled = self.storage.schedule_planner_retry_wait(
                    task_id=task_id,
                    call_number=call_number,
                    retry_index=consecutive_failures,
                    max_auto_retries=self.planner_transient_auto_retries,
                    wait_id=str(uuid.uuid4()),
                    wake_at=wake_at,
                    error_type=type(exc).__name__,
                )
                return {
                    "task_id": task_id,
                    "status": "WAITING" if scheduled.get("scheduled") else "YIELDED",
                    "reason": "planner_transient_retry_backoff",
                    "retry_index": consecutive_failures,
                    "wake_at": scheduled.get("wake_at"),
                }
            self.storage.block_task(
                task_id=task_id,
                reason="planner_runtime_error",
                payload={
                    "error_type": type(exc).__name__,
                    "consecutive_failures": consecutive_failures,
                    "auto_retries_exhausted": True,
                },
                public_summary="后台规划连续多次不可用，当前进度已保留，任务已暂停。",
            )
            return {
                "task_id": task_id,
                "status": "BLOCKED",
                "reason": "planner_runtime_error",
                "error_type": type(exc).__name__,
            }
        except PlannerBudgetExceededError:
            return {
                "task_id": task_id,
                "status": "BLOCKED",
                "reason": "planner_budget_exhausted",
            }
        except TaskCapabilityDeniedError as exc:
            self.storage.block_task(
                task_id=task_id,
                reason="task_capability_denied",
                payload={
                    "reason_code": exc.reason_code,
                    "capability": exc.capability_id,
                    "detail": exc.detail,
                },
                public_summary="当前任务的明确限制阻止了这项操作，任务已安全暂停。",
            )
            return {
                "task_id": task_id,
                "status": "BLOCKED",
                "reason": "task_capability_denied",
                "reason_code": exc.reason_code,
                "capability": exc.capability_id,
            }
        except Exception as exc:
            self.storage.block_task(
                task_id=task_id,
                reason="planner_runtime_error",
                payload={"error_type": type(exc).__name__},
                public_summary="后台规划暂时不可用，任务已安全暂停。",
            )
            return {
                "task_id": task_id,
                "status": "BLOCKED",
                "reason": "planner_runtime_error",
                "error_type": type(exc).__name__,
            }

    def _run_planner(self) -> None:
        while not self._stop.is_set():
            # Clear before scheduling. A worker finishing after this point sets
            # the event and cannot have its wake erased before wait().
            self._planner_wake.clear()
            try:
                self.planner_schedule_once()
            except Exception as exc:
                self._log_background_loop_error("planner", exc)
            if self._stop.is_set():
                break
            self._planner_wake.wait(self.poll_interval_seconds)

    def _run_execution(self) -> None:
        while not self._stop.is_set():
            try:
                values = self.execution_sweep_once()
                if values and self.task_runtime is not None:
                    self._planner_wake.set()
            except Exception as exc:
                self._log_background_loop_error("execution", exc)
            self._execution_wake.wait(self.poll_interval_seconds)
            self._execution_wake.clear()

    def _run_control(self) -> None:
        while not self._stop.is_set():
            try:
                self.control_sweep_once()
            except Exception as exc:
                self._log_background_loop_error("control", exc)
            self._control_wake.wait(self.poll_interval_seconds)
            self._control_wake.clear()

    @staticmethod
    def _log_background_loop_error(lane: str, exc: Exception) -> None:
        """Surface scheduler failures without mutating durable Task truth.

        Expected task-scoped Planner failures are handled by ``advance_task``
        and execution/reconciliation failures stay owned by their workers. This
        guard is only for an unexpected failure of the long-lived scheduler
        loop itself. Logging the error type (rather than arbitrary exception
        text) keeps diagnostics useful without leaking provider/user payloads.
        Do not attach ``exc_info`` here: Python's formatted traceback includes
        ``str(exc)``, which can contain provider responses or user data.
        """
        frames = traceback.extract_tb(exc.__traceback__)
        if frames:
            frame = frames[-1]
            filename = frame.filename.rsplit("/", 1)[-1]
            origin = f"{filename}:{frame.lineno}:{frame.name}"
        else:
            origin = "unknown"
        logger.error(
            "runtime supervisor %s loop failed; error_type=%s; origin=%s",
            lane,
            type(exc).__name__,
            origin,
        )
