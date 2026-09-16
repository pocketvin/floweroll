from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional

from .context_builder import ContextBuilder
from .planner_contracts import CapabilitySpec
from .planner_request import PlannerRequestBuilder
from .storage import Storage
from .task_runtime import TaskRuntime


class PlannerRuntime:
    """Compatibility façade for the older PlannerRuntime API.

    TaskRuntime is now the lifecycle owner. This class intentionally delegates
    creation, planning and the temporary post-verification compatibility path
    so existing callers/tests do not need a big-bang rewrite.
    """

    def __init__(
        self,
        storage: Storage,
        planner_adapter: Any,
        capabilities: List[CapabilitySpec],
        *,
        timezone_name: str = "Asia/Shanghai",
        request_builder: Optional[PlannerRequestBuilder] = None,
        context_builder: Optional[ContextBuilder] = None,
        max_planner_calls: int = 32,
    ) -> None:
        self.task_runtime = TaskRuntime(
            storage,
            planner_adapter,
            capabilities,
            timezone_name=timezone_name,
            request_builder=request_builder,
            context_builder=context_builder,
            max_planner_calls=max_planner_calls,
        )
        self.storage = storage
        self.planner_adapter = planner_adapter
        self.capabilities = list(capabilities)
        self.timezone_name = timezone_name
        self.request_builder = self.task_runtime.request_builder
        self.context_builder = self.task_runtime.context_builder

    def create_task(
        self,
        goal: str,
        *,
        invocation_source: str = "planner_runtime",
        policy_snapshot: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        return self.task_runtime.create_task(
            goal,
            invocation_source=invocation_source,
            policy_snapshot=policy_snapshot,
        )

    def decide(
        self,
        task_id: str,
        *,
        current_time: Optional[datetime] = None,
        runtime_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        return self.task_runtime.decide(
            task_id,
            current_time=current_time,
            runtime_context=runtime_context,
        )

    def record_verified_observation(
        self,
        task_id: str,
        action_id: str,
        data: Dict[str, Any],
    ) -> Dict[str, Any]:
        return self.task_runtime.record_verified_observation(task_id, action_id, data)
