"""LangGraph owns one bounded Planner invocation, NOT the durable Task lifecycle.

No ToolNode, checkpointer, interrupt or second retry scheduler lives here. The
Runtime supplies a fresh basis for every normal/recovery invocation and commits
only a validated PlannerDecision behind its existing revision fence.
"""
from __future__ import annotations

import json
import time
from contextlib import AbstractContextManager, nullcontext
from dataclasses import dataclass, field
from typing import Any, Callable, TypedDict

from langgraph.graph import END, START, StateGraph
from langgraph.runtime import Runtime
from langsmith import tracing_context

from .planner_compaction import compact_context, json_chars
from .planner_contracts import DecisionContext, PlannerDecision

GRAPH_NAME = "floweroll_planner_v1"
RECOVERY_MODEL_TIMEOUT_SECONDS = 120.0


class PlannerGraphState(TypedDict, total=False):
    memories: dict
    context: DecisionContext
    request: dict
    decision: PlannerDecision
    error: Exception | None


@dataclass
class PlannerGraphServices:
    """Per-invocation dependencies, never serialized into model input or state."""
    load_memory: Callable[[], dict]
    build_context: Callable[[dict], DecisionContext]
    select_context: Callable[[DecisionContext], DecisionContext]
    build_request: Callable[[DecisionContext], dict]
    adapter: Any
    assert_current: Callable[[], None]
    validate_policy: Callable[[PlannerDecision], None] = lambda decision: None
    capture: Callable[[DecisionContext], AbstractContextManager] = lambda context: nullcontext()
    emit: Callable[[dict], None] = lambda event: None
    recovery: bool = False
    metrics: dict = field(default_factory=dict)
    steps: list[dict] = field(default_factory=list)


class PlannerGraph:
    """Reusable compiled graph with isolated state/services for concurrent Tasks."""

    def __init__(self) -> None:
        builder = StateGraph(PlannerGraphState, context_schema=PlannerGraphServices)
        nodes = {
            "memory": self._memory,
            "build_context": self._context,
            "compact_context": self._compact,
            "recovery_context": self._recovery,
            "select_capabilities": self._select,
            "build_request": self._request,
            "call_model": self._model,
            "validate": self._validate,
            "failed": self._failed,
        }
        for name, function in nodes.items():
            builder.add_node(name, self._instrument(name, function))
        builder.add_edge(START, "memory")
        builder.add_edge("memory", "build_context")
        builder.add_edge("build_context", "select_capabilities")
        builder.add_conditional_edges("select_capabilities", self._context_route,
                                      {"normal": "compact_context", "recovery": "recovery_context"})
        builder.add_edge("compact_context", "build_request")
        builder.add_edge("recovery_context", "build_request")
        builder.add_edge("build_request", "call_model")
        builder.add_conditional_edges("call_model", self._model_route,
                                      {"validating": "validate", "error": "failed"})
        builder.add_edge("validate", END)
        builder.add_edge("failed", END)
        self.graph = builder.compile(name=GRAPH_NAME)

    def describe(self) -> dict:
        graph = self.graph.get_graph()
        return {"engine": "langgraph", "name": GRAPH_NAME, "checkpointed": False,
                "retry_owner": "task_runtime", "tool_execution": False,
                "nodes": [name for name in graph.nodes if name not in {START, END}]}

    def invoke(self, services: PlannerGraphServices) -> PlannerDecision:
        services.metrics.update(planner_engine="langgraph", planner_graph=GRAPH_NAME,
                                recovery_context=services.recovery)
        # Explicit privacy boundary: inherited LANGSMITH/LANGCHAIN environment
        # must not export task content or memory to a new service implicitly.
        with tracing_context(enabled=False):
            state = self.graph.invoke({}, context=services,
                                      config={"recursion_limit": 16, "callbacks": []})
        return state["decision"]

    @staticmethod
    def _emit(services: PlannerGraphServices, event: dict) -> None:
        # Diagnostics cannot change Task truth or turn a valid result into failure.
        try:
            services.emit(event)
        except Exception:
            pass

    @classmethod
    def _instrument(cls, name, function):
        def node(state: PlannerGraphState, runtime: Runtime[PlannerGraphServices]) -> dict:
            services = runtime.context
            cls._emit(services, {"node": name, "phase": "started", "recovery": services.recovery})
            started = time.perf_counter()
            error = None
            try:
                result = function(state, services)
                error = result.get("error")
                return result
            except Exception as exc:
                error = exc
                raise
            finally:
                elapsed = round((time.perf_counter() - started) * 1000.0, 3)
                metric = {"memory": "memory_search_ms", "build_context": "context_build_ms",
                          "select_capabilities": "selector_ms", "build_request": "request_build_ms",
                          "call_model": "model_ms"}.get(name, name + "_ms")
                services.metrics[metric] = elapsed
                event = {"node": name, "phase": "finished", "duration_ms": elapsed,
                         "outcome": "error" if error is not None else "success",
                         "recovery": services.recovery}
                if error is not None:
                    event["error_type"] = type(error).__name__
                services.steps.append(event)
                cls._emit(services, event)
        return node

    @staticmethod
    def _context_route(state: PlannerGraphState, runtime: Runtime[PlannerGraphServices]) -> str:
        return "recovery" if runtime.context.recovery else "normal"

    @staticmethod
    def _model_route(state: PlannerGraphState) -> str:
        return "error" if state.get("error") is not None else "validating"

    @staticmethod
    def _memory(state, services):
        services.assert_current()
        result = services.load_memory()
        services.metrics.update(memory_result_count=len(result.get("items") or []),
                                memory_error_type=result.get("error_type"))
        return {"memories": result}

    @staticmethod
    def _context(state, services):
        return {"context": services.build_context(state["memories"])}

    @staticmethod
    def _compact(state, services):
        context, metrics = compact_context(state["context"])
        services.metrics.update(metrics)
        return {"context": context}

    @staticmethod
    def _recovery(state, services):
        services.assert_current()
        context, metrics = compact_context(state["context"], recovery=True)
        services.metrics.update(metrics)
        return {"context": context}

    @staticmethod
    def _select(state, services):
        return {"context": services.select_context(state["context"])}

    @staticmethod
    def _request(state, services):
        context = state["context"]
        request = services.build_request(context)
        services.metrics.update(
            context_chars=json_chars(context.model_view()),
            request_bytes=len(json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode()),
            visible_capability_count=len(context.capabilities),
            verified_observation_count=len(context.verified_observations),
            user_turn_count=len(context.user_turns),
        )
        return {"request": request}

    @staticmethod
    def _model(state, services):
        services.assert_current()
        context = state["context"]
        # Production adapter exposes a single HTTP attempt. Durable Runtime
        # backoff is the only retry owner, so failures cannot multiply 2 x 2.
        single_attempt = getattr(services.adapter, "decide_once", None)
        try:
            with services.capture(context):
                if callable(single_attempt):
                    timeout_seconds = None
                    if services.recovery:
                        configured = getattr(services.adapter, "timeout_seconds", 0.0)
                        try:
                            configured = float(configured)
                        except (TypeError, ValueError):
                            configured = 0.0
                        timeout_seconds = max(configured, RECOVERY_MODEL_TIMEOUT_SECONDS)
                    decision = single_attempt(
                        state["request"],
                        context.capabilities,
                        timeout_seconds=timeout_seconds,
                    )
                else:
                    decision = services.adapter.decide(state["request"], context.capabilities)
            return {"decision": decision, "error": None}
        except Exception as exc:
            return {"error": exc}
        finally:
            consumer = getattr(services.adapter, "consume_last_call_metrics", None)
            if callable(consumer):
                try:
                    metrics = consumer()
                    if isinstance(metrics, dict):
                        allowed = {"provider_model", "provider_attempts", "provider_total_ms",
                                   "prompt_tokens", "completion_tokens", "total_tokens"}
                        services.metrics.update({k: v for k, v in metrics.items() if k in allowed})
                except Exception:
                    pass

    @staticmethod
    def _validate(state, services):
        decision = state["decision"]
        if not isinstance(decision, PlannerDecision):
            raise ValueError("Planner graph requires a PlannerDecision")
        services.validate_policy(decision)
        decision.validate(state["context"].capabilities)
        return {"decision": decision}

    @staticmethod
    def _failed(state, services):
        # Propagate the original typed failure. Runtime will persist a wait or
        # block, and on its next invocation select recovery_context from truth.
        raise state["error"]
