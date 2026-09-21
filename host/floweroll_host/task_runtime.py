from __future__ import annotations

import re
import threading
import time
import uuid
from contextlib import contextmanager
from dataclasses import asdict, replace
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional, Tuple
from zoneinfo import ZoneInfo

from .capability_registry import CapabilityRegistry
from .context_builder import ContextBuilder
from .planner_contracts import CapabilitySpec, PlannerDecision
from . import planner_capture
from .planner_request import PlannerRequestBuilder
from .planner_graph import PlannerGraph, PlannerGraphServices
from .storage import StalePlannerDecisionError, Storage
from .task_capability_policy import EffectiveTaskCapabilityPolicy, TaskCapabilityDeniedError
from .transition_engine import RuntimeCommand, RuntimeSnapshot, TransitionEngine


DEFAULT_MAX_PLANNER_CALLS = 32


class PlannerAlreadyRunningError(RuntimeError):
    pass


class PlannerWorkSupersededError(RuntimeError):
    """A concurrent durable transition made the in-flight Planner work obsolete."""

    def __init__(self, command: RuntimeCommand) -> None:
        super().__init__(f"Planner work superseded: {command.kind}/{command.reason}")
        self.command = command


class TaskRuntime:
    """Single durable lifecycle owner for semantic planning transitions."""

    _claim_guard = threading.Lock()
    _planner_claims: set[Tuple[str, str]] = set()

    def __init__(
        self,
        storage: Storage,
        planner_adapter: Any,
        capabilities: List[CapabilitySpec],
        *,
        timezone_name: str = "Asia/Shanghai",
        request_builder: Optional[PlannerRequestBuilder] = None,
        context_builder: Optional[ContextBuilder] = None,
        transition_engine: Optional[TransitionEngine] = None,
        max_planner_calls: int = DEFAULT_MAX_PLANNER_CALLS,
        material_context_provider: Optional[Callable[[str], Dict[str, Any]]] = None,
        memory: Optional[Any] = None,
    ) -> None:
        if not capabilities:
            raise ValueError("TaskRuntime requires at least one capability")
        if max_planner_calls < 1:
            raise ValueError("max_planner_calls must be positive")
        self.storage = storage
        self.planner_adapter = planner_adapter
        self.capabilities = list(capabilities)
        self.timezone_name = timezone_name
        self.request_builder = request_builder or PlannerRequestBuilder()
        self.context_builder = context_builder or ContextBuilder()
        self.transition_engine = transition_engine or TransitionEngine()
        self.max_planner_calls = max_planner_calls
        self.material_context_provider = material_context_provider
        self.memory = memory
        self.capability_context_selector = None
        self.capability_registry: Optional[CapabilityRegistry] = None
        self.completion_guard = None
        self.additional_observation_provider = None
        self.predispatch_confirmation_capabilities: set[str] = set()
        self.planner_graph = PlannerGraph()
        self._close_lock = threading.Lock()
        self._closed = False

    def close(self) -> None:
        with self._close_lock:
            if self._closed:
                return
            self._closed = True
            memory = self.memory
        closer = getattr(memory, "close", None)
        if callable(closer):
            closer()

    @property
    def _storage_identity(self) -> str:
        if self.storage.path == ":memory:":
            return f"memory:{id(self.storage)}"
        return str(Path(self.storage.path).expanduser().resolve())

    @contextmanager
    def _planner_claim(self, task_id: str) -> Iterator[None]:
        """Prevent duplicate Planner calls without blocking inbox admission."""

        key = (self._storage_identity, task_id)
        with self._claim_guard:
            if key in self._planner_claims:
                raise PlannerAlreadyRunningError("a Planner call is already running for this Task")
            self._planner_claims.add(key)
        try:
            yield
        finally:
            with self._claim_guard:
                self._planner_claims.discard(key)

    def create_task(
        self,
        goal: str,
        *,
        invocation_source: str = "task_runtime",
        policy_snapshot: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        if not goal or not goal.strip():
            raise ValueError("goal must not be empty")
        return self.storage.create_task(
            task_id=str(uuid.uuid4()),
            goal=goal.strip(),
            invocation_source=invocation_source,
            policy_snapshot=policy_snapshot or {},
            status="active",
        )

    def admit_user_turn(
        self,
        task_id: str,
        *,
        event_id: str,
        text: str,
        source: str = "user",
        reply_clarification_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        if not text or not text.strip():
            raise ValueError("user turn text must not be empty")
        admitted = self.storage.admit_inbox_event(
            task_id=task_id,
            event_id=event_id,
            event_type="USER_TURN",
            source=source,
            target_type="CLARIFICATION" if reply_clarification_id else None,
            target_id=reply_clarification_id,
            payload={
                "content": {"kind": "text", "text": text.strip()},
                "reply_context": {"clarification_id": reply_clarification_id}
                if reply_clarification_id
                else None,
            },
        )
        if self.memory is not None and not admitted.get("duplicate", False):
            self.memory.remember_user_text(
                task_id=task_id,
                event_id=event_id,
                text=text.strip(),
                source_kind="user_turn",
            )
        return admitted

    def next_command(self, task_id: str) -> RuntimeCommand:
        basis = self.storage.planner_basis(task_id)
        return self.transition_engine.next(self._snapshot_from_basis(basis))

    def decide(
        self,
        task_id: str,
        *,
        current_time: Optional[datetime] = None,
        runtime_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        with self._planner_claim(task_id):
            while True:
                basis = self.storage.planner_basis(task_id)
                command = self.transition_engine.next(self._snapshot_from_basis(basis))
                if command.kind != "CALL_PLANNER":
                    raise ValueError(f"TaskRuntime cannot call Planner: {command.reason}")

                task = basis["task"]
                runtime = basis["runtime"]
                working_set_started = time.perf_counter()
                effective_policy = EffectiveTaskCapabilityPolicy.from_task(
                    task, basis.get("policy_user_turns", [])
                )
                capabilities = self._visible_capabilities(
                    task["policy_snapshot"], effective_policy
                )
                if not capabilities:
                    raise TaskCapabilityDeniedError(
                        "*", "TASK_DENIED: no capability remains under the current Task restrictions"
                    )
                initial_working_set_ms = (time.perf_counter() - working_set_started) * 1000.0

                call_number = self.storage.reserve_planner_call(
                    task_id,
                    max_calls=self.max_planner_calls,
                )
                if self.memory is not None and call_number == 1:
                    self.memory.remember_user_text(
                        task_id=task_id,
                        event_id=f"task-goal:{task_id}",
                        text=task["goal"],
                        source_kind="task_goal",
                    )
                planner_call_started = time.perf_counter()
                now = current_time or datetime.now(ZoneInfo(self.timezone_name))
                def assert_current_basis():
                    current = self.storage.planner_basis(task_id)
                    if (int(current["runtime"]["runtime_revision"]) != int(runtime["runtime_revision"])
                            or int(current["basis_inbox_seq"]) != int(basis["basis_inbox_seq"])):
                        raise StalePlannerDecisionError("Planner graph basis changed before model invocation")

                def build_context(memory_result):
                    return self.context_builder.build(
                        task_id=task_id,
                        raw_goal=task["goal"],
                        current_time=now,
                        timezone_name=self.timezone_name,
                        policy_view={**self._policy_view(task["policy_snapshot"], capabilities),
                                     "task_constraints": effective_policy.model_view()},
                        capabilities=capabilities,
                        task_status=task["status"].upper(),
                        phase=runtime["phase"],
                        normalized_goal=runtime["current_task_brief"],
                        plan=runtime["plan"],
                        verified_observations=basis["verified_observations"] + (
                            self.additional_observation_provider(task_id) if self.additional_observation_provider else []),
                        user_turns=self._project_user_turns(basis["accepted_events"]),
                        pending_clarification=self._project_pending_clarification(
                            basis["pending_clarification"]
                        ),
                        last_semantic_failure=basis.get("last_semantic_failure"),
                        runtime_context={
                            "invocation_source": task["invocation_source"],
                            "capability_discovery_state": self._capability_discovery_state(task_id),
                            "predispatch_confirmation_capabilities": sorted(
                                self.predispatch_confirmation_capabilities
                                & {cap.name for cap in capabilities}
                            ),
                            **(self.material_context_provider(task_id) if self.material_context_provider else {}),
                            **dict(runtime_context or {}),
                            "relevant_memories": list(memory_result.get("items") or []),
                        },
                    )

                services = PlannerGraphServices(
                    load_memory=lambda: (
                        self.memory.search(self._memory_query(task, runtime, basis))
                        if self.memory is not None else {"items": [], "error_type": None}
                    ),
                    build_context=build_context,
                    select_context=lambda value: (
                        self.capability_context_selector.apply(value)
                        if self.capability_context_selector is not None else value
                    ),
                    build_request=self.request_builder.build,
                    adapter=self.planner_adapter,
                    assert_current=assert_current_basis,
                    validate_policy=lambda value: self._enforce_task_policy_decision(
                        task_id=task_id, call_number=call_number, decision=value,
                        effective_policy=effective_policy,
                    ),
                    recovery=self.storage.consecutive_planner_failures(task_id) > 0,
                    capture=lambda value: planner_capture.planner_call(
                        task_id=task_id, call_number=call_number,
                        runtime_db=str(self.storage.path),
                        thread_id=task.get('thread_id') or task_id,
                        basis_runtime_revision=runtime['runtime_revision'],
                        basis_inbox_seq=basis['basis_inbox_seq'],
                        visible_capabilities=[cap.name for cap in value.capabilities],
                    ),
                    emit=lambda event: self.storage.record_trace_event(
                        task_id, "planner.graph.node", {"call_number": call_number, **event}
                    ),
                )

                def record_metrics(outcome, error=None):
                    metrics = dict(services.metrics)
                    metrics["working_set_ms"] = round(initial_working_set_ms + metrics.pop("selector_ms", 0), 3)
                    metrics["graph_steps"] = list(services.steps)
                    self.storage.record_trace_event(task_id, "planner.call.metrics", {
                        "call_number": call_number, "outcome": outcome, **metrics,
                        **({"error_type": type(error).__name__} if error is not None else {}),
                    })

                try:
                    decision = self.planner_graph.invoke(services)
                    decision, wait_regrounded = self._ground_wait_decision(
                        task=task,
                        basis=basis,
                        decision=decision,
                    )
                    if wait_regrounded:
                        self.storage.record_trace_event(
                            task_id,
                            "planner.wait.regrounded",
                            {
                                "call_number": call_number,
                                "reason": "until_time_without_user_temporal_basis",
                                "replacement": decision.decision_type,
                            },
                        )
                    decision, clarification_regrounded = self._ground_deferred_destructive_clarification(
                        basis=basis,
                        decision=decision,
                    )
                    if clarification_regrounded:
                        self.storage.record_trace_event(
                            task_id,
                            "planner.pending_clarification.regrounded",
                            {
                                "call_number": call_number,
                                "reason": "user_deferred_destructive_confirmation_until_after_prerequisite",
                                "replacement": "CANCEL",
                            },
                        )
                    record_metrics("success")
                except Exception as exc:
                    record_metrics("error", exc)
                    # A slow Planner failure is just as stale as a slow Planner
                    # success when user/runtime state changed while the call was
                    # in flight. Never let obsolete model work pause the latest
                    # Task state. Re-read durable truth and replan/yield exactly
                    # as the stale-success path does.
                    current_basis = self.storage.planner_basis(task_id)
                    stale_failure = (
                        int(current_basis["runtime"]["runtime_revision"])
                        != int(runtime["runtime_revision"])
                        or int(current_basis["basis_inbox_seq"])
                        != int(basis["basis_inbox_seq"])
                    )
                    if stale_failure:
                        self.storage.record_stale_planner_result(
                            task_id=task_id,
                            call_number=call_number,
                            basis_runtime_revision=runtime["runtime_revision"],
                            basis_inbox_seq=basis["basis_inbox_seq"],
                            error=exc,
                        )
                        current_command = self.transition_engine.next(
                            self._snapshot_from_basis(current_basis)
                        )
                        if current_command.kind != "CALL_PLANNER":
                            raise PlannerWorkSupersededError(current_command)
                        continue

                    self.storage.record_planner_call_failure(
                        task_id=task_id,
                        call_number=call_number,
                        error=exc,
                    )
                    raise

                self._enforce_task_policy_decision(
                    task_id=task_id,
                    call_number=call_number,
                    decision=decision,
                    effective_policy=effective_policy,
                )
                if self.completion_guard is not None:
                    allowed_specs = self._visible_capabilities(
                        task["policy_snapshot"], effective_policy
                    )
                    decision = self.completion_guard(task_id, decision, {spec.name for spec in allowed_specs})
                    self._enforce_task_policy_decision(
                        task_id=task_id,
                        call_number=call_number,
                        decision=decision,
                        effective_policy=effective_policy,
                    )
                    decision.validate(allowed_specs)
                decision_dict = asdict(decision)
                decision_id = str(uuid.uuid4())
                action_id = str(uuid.uuid4()) if decision.decision_type == "EXECUTE" else None
                clarification_id = (
                    str(uuid.uuid4()) if decision.decision_type == "CLARIFY" else None
                )
                wait_id = (
                    str(uuid.uuid4())
                    if decision.decision_type in {"CLARIFY", "WAIT"}
                    else None
                )
                try:
                    commit_started = time.perf_counter()
                    applied = self.storage.apply_planner_decision_atomic(
                        task_id=task_id,
                        expected_runtime_revision=runtime["runtime_revision"],
                        basis_inbox_seq=basis["basis_inbox_seq"],
                        decision_id=decision_id,
                        decision=decision_dict,
                        action_id=action_id,
                        clarification_id=clarification_id,
                        wait_id=wait_id,
                    )
                    commit_ms = (time.perf_counter() - commit_started) * 1000.0
                    self.storage.record_trace_event(
                        task_id,
                        "planner.call.committed",
                        {
                            "call_number": call_number,
                            "decision_type": decision.decision_type,
                            "commit_ms": round(commit_ms, 3),
                            "total_runtime_ms": round(
                                (time.perf_counter() - planner_call_started) * 1000.0, 3
                            ),
                        },
                    )
                except StalePlannerDecisionError:
                    self.storage.record_stale_planner_result(
                        task_id=task_id,
                        call_number=call_number,
                        basis_runtime_revision=runtime["runtime_revision"],
                        basis_inbox_seq=basis["basis_inbox_seq"],
                    )
                    # Re-read durable state before deciding whether to replan.
                    # A UserTurn may require an immediate fresh Planner call, while
                    # cancellation/wait/execution ownership should simply yield.
                    current_basis = self.storage.planner_basis(task_id)
                    current_command = self.transition_engine.next(
                        self._snapshot_from_basis(current_basis)
                    )
                    if current_command.kind != "CALL_PLANNER":
                        raise PlannerWorkSupersededError(current_command)
                    # Replan immediately from the new durable basis. The task-level
                    # Planner-call budget bounds a stream of continuously stale work.
                    continue

                result: Dict[str, Any] = {
                    "task": self.storage.get_task(task_id),
                    "runtime": self.storage.get_runtime_state(task_id),
                    "decision": {
                        "decision_id": decision_id,
                        "task_id": task_id,
                        "sequence": applied["sequence"],
                        "decision_type": decision.decision_type,
                        "decision": decision_dict,
                        "created_at": applied["created_at"],
                    },
                }
                if action_id is not None:
                    result["action"] = self.storage.get_action(action_id)
                if clarification_id is not None:
                    result["clarification"] = self.storage.pending_clarification(task_id)
                if decision.decision_type == "WAIT":
                    result["wait"] = decision.wait
                if decision.decision_type == "COMPLETE":
                    result["completion"] = decision.completion
                if decision.decision_type == "STOP":
                    result["stop_reason"] = decision.stop_reason
                if decision.decision_type == "CANCEL":
                    result["cancellation"] = decision.cancellation
                return result

    def record_verified_observation(
        self,
        task_id: str,
        action_id: str,
        data: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Compatibility path until ExecutionRuntime owns this in Slice 4."""

        action = self.storage.get_action(action_id)
        runtime = self.storage.get_runtime_state(task_id)
        task = self.storage.get_task(task_id)
        if action is None or action["task_id"] != task_id:
            raise KeyError(action_id)
        if runtime is None or task is None:
            raise KeyError(task_id)

        observation = self.storage.record_verified_observation(
            task_id=task_id,
            action_id=action_id,
            capability=action["action_type"],
            data=data,
        )
        pending_clarification = self.storage.pending_clarification(task_id)
        accepted_user_turns = [
            event
            for event in self.storage.inbox_events(task_id)
            if event["event_type"] == "USER_TURN" and event["status"] == "ACCEPTED"
        ]
        if accepted_user_turns:
            self.storage.set_task_runtime(
                task_id=task_id,
                status="active",
                phase="planning",
                plan=runtime["plan"],
                wait_reason=None,
                wait_payload=None,
                pending_clarification_id=(
                    pending_clarification["clarification_id"] if pending_clarification else None
                ),
                interpreted_goal_summary=runtime.get("interpreted_goal_summary"),
            )
        elif pending_clarification is not None:
            self.storage.restore_pending_clarification_wait(
                task_id=task_id,
                clarification_id=pending_clarification["clarification_id"],
            )
        elif action["on_verified"] == "COMPLETE":
            self.storage.set_task_runtime(
                task_id=task_id,
                status="completed",
                phase="verifying",
                plan=runtime["plan"],
                wait_reason=None,
                wait_payload=None,
                pending_clarification_id=None,
                interpreted_goal_summary=runtime.get("interpreted_goal_summary"),
            )
        else:
            self.storage.set_task_runtime(
                task_id=task_id,
                status="active",
                phase="planning",
                plan=runtime["plan"],
                wait_reason=None,
                wait_payload=None,
                pending_clarification_id=None,
                interpreted_goal_summary=runtime.get("interpreted_goal_summary"),
            )
        return observation

    def _capability_discovery_state(self, task_id: str) -> Dict[str, Any]:
        """Keep the base Planner independent from optional discovery storage.

        Progressive capability discovery installs both a selector and its durable
        Storage extension. Plain PlannerRuntime users should not require that
        extension just to build a decision context.
        """
        if self.capability_context_selector is None:
            return {}
        getter = getattr(self.storage, "capability_discovery_state", None)
        if not callable(getter):
            raise RuntimeError(
                "capability_context_selector requires durable capability discovery state"
            )
        value = getter(task_id)
        return dict(value) if isinstance(value, dict) else {}

    @staticmethod
    def _memory_query(
        task: Dict[str, Any],
        runtime: Dict[str, Any],
        basis: Dict[str, Any],
    ) -> str:
        parts: List[str] = []
        current_brief = runtime.get("current_task_brief")
        if isinstance(current_brief, str) and current_brief.strip():
            parts.append(current_brief.strip())
        else:
            goal = task.get("goal")
            if isinstance(goal, str) and goal.strip():
                parts.append(goal.strip())
        for turn in TaskRuntime._project_user_turns(basis.get("accepted_events", []))[-2:]:
            content = turn.get("content") or {}
            text = content.get("text") if isinstance(content, dict) else None
            if isinstance(text, str) and text.strip():
                parts.append(text.strip())
        return "\n".join(parts)[:2000]

    @staticmethod
    def _snapshot_from_basis(basis: Dict[str, Any]) -> RuntimeSnapshot:
        task = basis["task"]
        runtime = basis["runtime"]
        return RuntimeSnapshot(
            task_status=str(task["status"]),
            phase=str(runtime["phase"]),
            runtime_revision=int(runtime["runtime_revision"]),
            has_open_action=basis["open_action"] is not None,
            pending_clarification_id=(
                basis["pending_clarification"]["clarification_id"]
                if basis["pending_clarification"] is not None
                else None
            ),
            wait_kind=runtime.get("wait_kind") or runtime.get("wait_reason"),
            cancel_requested=task.get("cancel_requested_at") is not None,
            accepted_event_types=frozenset(
                str(event["event_type"]) for event in basis["accepted_events"]
            ),
        )

    @staticmethod
    def _project_user_turns(events: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        result = []
        for event in events:
            if event["event_type"] != "USER_TURN":
                continue
            payload = event.get("payload") or {}
            result.append(
                {
                    "event_id": event["event_id"],
                    "content": payload.get("content"),
                    "reply_context": payload.get("reply_context"),
                    "received_at": event["received_at"],
                }
            )
        return result

    @staticmethod
    def _project_pending_clarification(
        value: Optional[Dict[str, Any]],
    ) -> Optional[Dict[str, Any]]:
        if value is None:
            return None
        payload = value.get("payload") or {}
        return {
            "clarification_id": value["clarification_id"],
            "question": value["question"],
            "suggested_options": payload.get("suggested_options", []),
            "accepts_text": bool(payload.get("accepts_text", False)),
            "reason": payload.get("reason"),
        }

    @staticmethod
    def _user_authored_wait_texts(task: Dict[str, Any], basis: Dict[str, Any]) -> List[str]:
        texts: List[str] = []
        goal = task.get("goal")
        if isinstance(goal, str) and goal.strip():
            texts.append(goal.strip())
        for event in basis.get("accepted_events", []):
            if event.get("event_type") != "USER_TURN":
                continue
            payload = event.get("payload") or {}
            content = payload.get("content") or {}
            if isinstance(content, dict):
                text = content.get("text")
                if isinstance(text, str) and text.strip():
                    texts.append(text.strip())
        return texts

    @staticmethod
    def _has_user_temporal_basis(texts: List[str]) -> bool:
        text = "\n".join(texts).lower()
        if not text:
            return False
        patterns = (
            r"\d{1,2}\s*[:：]\s*\d{1,2}",
            r"\d{1,2}\s*点(?:\s*\d{1,2}\s*分|半)?",
            r"(?:零|一|二|两|三|四|五|六|七|八|九|十|十一|十二)\s*点(?:半|(?:零|一|二|两|三|四|五|六|七|八|九|十|十一|十二|\d{1,2})\s*分)?",
            r"(?:今天|明天|后天|今晚|今早|明早|本周|下周|下个月|月底|周[一二三四五六日天]|星期[一二三四五六日天])",
            r"(?:每|每隔|隔)\s*(?:半|一|两|二|\d+)?\s*(?:分钟|小时|天|周|月|年|点)",
            r"(?:直到|持续到|监控到|跟踪到|检查到).{0,16}(?:为止|结束|点|日|号|周|星期|月)",
            r"\d+\s*(?:分钟|小时|天|周|月)\s*(?:后|以后|一次)",
            r"\b(?:today|tonight|tomorrow|next\s+(?:week|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b",
            r"\b(?:at|until|every|after|in)\s+\d",
            r"\bevery\s+(?:hour|day|week|month|\d+)\b",
        )
        return any(re.search(pattern, text, re.IGNORECASE) for pattern in patterns)

    @staticmethod
    def _looks_like_ongoing_monitoring(texts: List[str]) -> bool:
        text = "\n".join(texts).lower()
        return bool(re.search(
            r"(?:持续|一直|不断|反复|定期|周期|监控|跟踪|持续检查|持续整理|"
            r"continuously|continuous|keep\s+(?:checking|monitoring)|monitor|track|periodic)",
            text,
            re.IGNORECASE,
        ))

    def _ground_wait_decision(
        self,
        *,
        task: Dict[str, Any],
        basis: Dict[str, Any],
        decision: PlannerDecision,
    ) -> Tuple[PlannerDecision, bool]:
        """Prevent the model from inventing a polling clock the user never authorized.

        Provider/external/user-input waits may be discovered at runtime. A concrete
        `until_time` wait is different: its clock must come from user-authored intent.
        If an ongoing-monitoring request omits cadence/end conditions, surface that
        missing product decision as a clarification instead of silently creating an
        infinite self-polling loop.
        """
        if decision.decision_type != "WAIT" or not isinstance(decision.wait, dict):
            return decision, False
        if decision.wait.get("kind") != "until_time":
            return decision, False

        texts = self._user_authored_wait_texts(task, basis)
        ongoing = self._looks_like_ongoing_monitoring(texts)
        if ongoing:
            # A broad range such as “today” or “until tonight” may bound the
            # monitoring task, but it still does not authorize an arbitrary
            # polling cadence. until_time needs an explicit next-check schedule.
            schedule_text = "\n".join(texts).lower()
            has_recheck_schedule = bool(re.search(
                r"(?:每|每隔|隔)\s*(?:半|一|两|二|\d+)?\s*(?:分钟|小时|天|周|月)|"
                r"\d+\s*(?:分钟|小时|天|周|月)\s*(?:后|以后|一次)|"
                r"\bevery\s+(?:hour|day|week|month|\d+)\b|"
                r"\b(?:after|in)\s+\d+\s*(?:minutes?|hours?|days?)\b",
                schedule_text,
                re.IGNORECASE,
            ))
            if has_recheck_schedule:
                return decision, False
        elif self._has_user_temporal_basis(texts):
            return decision, False

        question = (
            "你希望多久检查一次，并持续到什么时候？"
            if ongoing
            else "这件事需要等到什么时间再继续？"
        )
        replacement = PlannerDecision(
            decision_type="CLARIFY",
            interpreted_goal_summary=decision.interpreted_goal_summary,
            plan_update=None,
            action=None,
            on_verified=None,
            clarification={
                "question": question,
                "suggested_options": [],
                "accepts_text": True,
                "reason": "missing_wait_schedule",
            },
            wait=None,
            completion=None,
            stop_reason=None,
            cancellation=None,
            state_update=decision.state_update,
        )
        replacement.validate(self.capabilities)
        return replacement, True

    @staticmethod
    def _ground_deferred_destructive_clarification(
        *,
        basis: Dict[str, Any],
        decision: PlannerDecision,
    ) -> Tuple[PlannerDecision, bool]:
        """Cancel an obsolete delete confirmation when the user explicitly defers it.

        A destructive confirmation must bind to the exact target state the user
        saw. If the user replies "query it first; ask me again when you actually
        delete it", keeping the old clarification open across that prerequisite
        read is both stale UX and the wrong authority boundary. Only re-ground a
        Planner KEEP when all of those facts are explicit; ordinary clarifications
        may legitimately remain pending while independent safe work progresses.
        """
        if decision.decision_type != "EXECUTE" or not isinstance(decision.action, dict):
            return decision, False
        state_update = decision.state_update if isinstance(decision.state_update, dict) else {}
        if state_update.get("pending_clarification") != "KEEP":
            return decision, False

        pending = basis.get("pending_clarification")
        if not isinstance(pending, dict):
            return decision, False
        clarification_id = str(pending.get("clarification_id") or "")
        question = str(pending.get("question") or "")
        payload = pending.get("payload") if isinstance(pending.get("payload"), dict) else {}
        reason = str(payload.get("reason") or "")
        destructive_basis = question + "\n" + reason
        if not re.search(r"(?:删除|移除|remove|delete)", destructive_basis, re.IGNORECASE):
            return decision, False
        if not re.search(r"(?:确认|是否|要不要|破坏性|confirm|approve)", destructive_basis, re.IGNORECASE):
            return decision, False

        matching_texts: List[str] = []
        for event in basis.get("accepted_events", []):
            if event.get("event_type") != "USER_TURN":
                continue
            event_payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
            reply = event_payload.get("reply_context") if isinstance(event_payload.get("reply_context"), dict) else {}
            if str(reply.get("clarification_id") or "") != clarification_id:
                continue
            content = event_payload.get("content") if isinstance(event_payload.get("content"), dict) else {}
            text = content.get("text")
            if isinstance(text, str) and text.strip():
                matching_texts.append(text.strip())
        if not matching_texts:
            return decision, False

        def explicitly_defers_confirmation(text: str) -> bool:
            compact = re.sub(r"\s+", "", text)
            if re.search(r"(?:之后|稍后|到时|届时|等.{0,16}后).{0,12}(?:再|重新)?(?:向我)?(?:确认|问我)", compact):
                return True
            if re.search(r"真正.{0,16}(?:删除|移除).{0,12}(?:时|之前|前).{0,12}(?:再|重新).{0,12}(?:向我)?(?:确认|问我)", compact):
                return True
            return "先" in compact and bool(re.search(r"再.{0,20}(?:确认|问我)", compact))

        if not any(explicitly_defers_confirmation(text) for text in matching_texts):
            return decision, False

        replacement_state = dict(decision.state_update or {})
        replacement_state["pending_clarification"] = "CANCEL"
        return replace(decision, state_update=replacement_state), True

    def _enforce_task_policy_decision(
        self,
        *,
        task_id: str,
        call_number: int,
        decision: PlannerDecision,
        effective_policy: EffectiveTaskCapabilityPolicy,
    ) -> None:
        if decision.decision_type != "EXECUTE" or decision.action is None:
            return
        capability_id = str(decision.action["capability"])
        full_spec = next(
            (spec for spec in self.capabilities if spec.name == capability_id),
            None,
        )
        if full_spec is None:
            raise ValueError(f"Planner selected unknown capability: {capability_id}")
        policy_basis = self.storage.task_policy_basis(task_id)
        policy_decision = effective_policy.decide(
            full_spec, self.capability_registry, arguments=decision.action["arguments"],
            prior_created_titles=[item["title"] for item in policy_basis["completed_creations"]
                                  if item["capability"] == capability_id],
        )
        if policy_decision.allowed:
            return
        detail = policy_decision.detail or "TASK_DENIED"
        self.storage.record_planner_task_denied(
            task_id=task_id,
            call_number=call_number,
            capability_id=capability_id,
            detail=detail,
        )
        raise TaskCapabilityDeniedError(capability_id, detail)

    def _visible_capabilities(
        self,
        policy_snapshot: Dict[str, Any],
        effective_policy: Optional[EffectiveTaskCapabilityPolicy] = None,
    ) -> List[CapabilitySpec]:
        allowed = policy_snapshot.get("allowed_capabilities")
        if allowed is None:
            visible = list(self.capabilities)
        else:
            allowed_names = {str(item) for item in allowed if isinstance(item, str)}
            visible = [cap for cap in self.capabilities if cap.name in allowed_names]
        if effective_policy is not None:
            visible = effective_policy.filter_specs(visible, self.capability_registry)
        return visible

    @staticmethod
    def _policy_view(
        policy_snapshot: Dict[str, Any],
        capabilities: List[CapabilitySpec],
    ) -> Dict[str, Any]:
        return {
            "allowed_capabilities": [cap.name for cap in capabilities],
            "constraints": list(policy_snapshot.get("constraints", [])),
            "effective_task_policy_applied": True,
        }
