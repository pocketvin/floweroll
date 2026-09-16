from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional

from .planner_contracts import CapabilitySpec, DecisionContext
from .observation_projection import project_observations


class ContextBuilder:
    """Build the compact LLM-visible context for one semantic decision.

    Runtime state can be much larger than model-visible context. This builder
    deliberately projects only task-relevant facts, policy and capabilities.
    """

    def build(
        self,
        *,
        task_id: str,
        raw_goal: str,
        current_time: datetime,
        timezone_name: str,
        policy_view: Dict[str, Any],
        capabilities: List[CapabilitySpec],
        task_status: str = "ACTIVE",
        phase: str = "planning",
        normalized_goal: Optional[str] = None,
        plan: Optional[List[str]] = None,
        verified_observations: Optional[List[Dict[str, Any]]] = None,
        user_turns: Optional[List[Dict[str, Any]]] = None,
        pending_clarification: Optional[Dict[str, Any]] = None,
        runtime_context: Optional[Dict[str, Any]] = None,
        last_semantic_failure: Optional[Dict[str, Any]] = None,
    ) -> DecisionContext:
        if not task_id.strip():
            raise ValueError("task_id must not be empty")
        if not raw_goal.strip():
            raise ValueError("raw_goal must not be empty")
        if current_time.tzinfo is None or current_time.utcoffset() is None:
            raise ValueError("current_time must be timezone-aware")
        if not capabilities:
            raise ValueError("at least one capability must be exposed to the Planner")

        return DecisionContext(
            task_id=task_id,
            raw_goal=raw_goal.strip(),
            normalized_goal=normalized_goal,
            task_status=task_status,
            phase=phase,
            current_time=current_time.isoformat(),
            timezone=timezone_name,
            plan=list(plan or []),
            verified_observations=project_observations(list(verified_observations or [])),
            user_turns=list(user_turns or []),
            pending_clarification=dict(pending_clarification) if pending_clarification else None,
            runtime_context=dict(runtime_context or {}),
            policy_view=dict(policy_view),
            capabilities=list(capabilities),
            last_semantic_failure=last_semantic_failure,
        )
