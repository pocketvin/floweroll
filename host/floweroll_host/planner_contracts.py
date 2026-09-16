from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


DECISION_TYPES = {"EXECUTE", "CLARIFY", "WAIT", "COMPLETE", "STOP", "CANCEL"}
WAIT_KINDS = {"until_time", "provider_event", "external_condition", "user_input"}
ON_VERIFIED_VALUES = {"COMPLETE", "REPLAN"}


POST_VERIFY_MODES = {"COMPLETE_ALLOWED", "REPLAN_REQUIRED"}


@dataclass(frozen=True)
class CapabilitySpec:
    name: str
    description: str
    arguments_schema: Dict[str, Any]
    post_verify_mode: str = "COMPLETE_ALLOWED"

    def __post_init__(self) -> None:
        if self.post_verify_mode not in POST_VERIFY_MODES:
            raise ValueError("invalid capability post_verify_mode")

    def context_view(self) -> Dict[str, Any]:
        # The full argument JSON Schema is already carried once in the strict
        # response_format. Repeating it inside DecisionContext made simple
        # Planner calls pay for the same often-nested schema twice. Keep only
        # the semantic routing hints here; validation remains unchanged.
        properties = self.arguments_schema.get("properties", {})
        return {
            "name": self.name,
            "description": self.description,
            "argument_names": list(properties) if isinstance(properties, dict) else [],
            "required_arguments": list(self.arguments_schema.get("required", [])),
            "post_verify_mode": self.post_verify_mode,
        }


@dataclass
class DecisionContext:
    task_id: str
    raw_goal: str
    task_status: str
    phase: str
    current_time: str
    timezone: str
    policy_view: Dict[str, Any]
    capabilities: List[CapabilitySpec]
    normalized_goal: Optional[str] = None
    plan: List[str] = field(default_factory=list)
    verified_observations: List[Dict[str, Any]] = field(default_factory=list)
    user_turns: List[Dict[str, Any]] = field(default_factory=list)
    pending_clarification: Optional[Dict[str, Any]] = None
    runtime_context: Dict[str, Any] = field(default_factory=dict)
    last_semantic_failure: Optional[Dict[str, Any]] = None

    def model_view(self) -> Dict[str, Any]:
        """Return only LLM-visible context.

        Secrets, DB handles, provider credentials and raw transport traces never
        belong here. ContextBuilder is responsible for producing this curated
        projection before a model call.
        """
        return {
            "task": {
                "task_id": self.task_id,
                "raw_goal": self.raw_goal,
                "normalized_goal": self.normalized_goal,
                "status": self.task_status,
                "phase": self.phase,
            },
            "time": {
                "current_time": self.current_time,
                "timezone": self.timezone,
            },
            "plan": self.plan,
            "verified_observations": self.verified_observations,
            "user_turns": self.user_turns,
            "pending_clarification": self.pending_clarification,
            "runtime_context": self.runtime_context,
            "policy": self.policy_view,
            "available_capabilities": [cap.context_view() for cap in self.capabilities],
            "last_semantic_failure": self.last_semantic_failure,
        }


@dataclass
class PlannerDecision:
    decision_type: str
    interpreted_goal_summary: str
    plan_update: Optional[List[str]]
    action: Optional[Dict[str, Any]]
    on_verified: Optional[str]
    clarification: Optional[Dict[str, Any]]
    wait: Optional[Dict[str, Any]]
    completion: Optional[Dict[str, Any]]
    stop_reason: Optional[str]
    cancellation: Optional[Dict[str, Any]] = None
    state_update: Optional[Dict[str, Any]] = None

    @classmethod
    def from_dict(
        cls,
        data: Dict[str, Any],
        capabilities: List[CapabilitySpec],
    ) -> "PlannerDecision":
        required = {
            "decision_type",
            "interpreted_goal_summary",
            "plan_update",
            "action",
            "on_verified",
            "clarification",
            "wait",
            "completion",
            "stop_reason",
        }
        allowed = required | {"cancellation", "state_update"}
        if not required.issubset(data) or not set(data).issubset(allowed):
            raise ValueError("PlannerDecision fields do not match runtime contract")

        normalized = dict(data)
        normalized.setdefault("cancellation", None)
        normalized.setdefault("state_update", None)
        decision = cls(**normalized)
        decision.validate(capabilities)
        return decision

    def validate(self, capabilities: List[CapabilitySpec]) -> None:
        if self.decision_type not in DECISION_TYPES:
            raise ValueError("invalid decision_type")
        if not isinstance(self.interpreted_goal_summary, str) or not self.interpreted_goal_summary.strip():
            raise ValueError("interpreted_goal_summary must be non-empty")
        if self.plan_update is not None:
            if not isinstance(self.plan_update, list) or not all(
                isinstance(item, str) and item.strip() for item in self.plan_update
            ):
                raise ValueError("plan_update must be null or a list of non-empty strings")

        populated = {
            "EXECUTE": self.action is not None,
            "CLARIFY": self.clarification is not None,
            "WAIT": self.wait is not None,
            "COMPLETE": self.completion is not None,
            "STOP": self.stop_reason is not None,
            "CANCEL": self.cancellation is not None,
        }
        if not populated[self.decision_type]:
            raise ValueError("decision payload missing for {}".format(self.decision_type))

        incompatible = {
            "EXECUTE": [self.clarification, self.wait, self.completion, self.stop_reason, self.cancellation],
            "CLARIFY": [self.action, self.wait, self.completion, self.stop_reason, self.cancellation],
            "WAIT": [self.action, self.clarification, self.completion, self.stop_reason, self.cancellation],
            "COMPLETE": [self.action, self.clarification, self.wait, self.stop_reason, self.cancellation],
            "STOP": [self.action, self.clarification, self.wait, self.completion, self.cancellation],
            "CANCEL": [self.action, self.clarification, self.wait, self.completion, self.stop_reason],
        }
        if any(value is not None for value in incompatible[self.decision_type]):
            raise ValueError("decision contains incompatible payloads")

        if self.action is not None:
            self._validate_action(self.action, capabilities)
        if self.decision_type == "EXECUTE":
            if self.on_verified not in ON_VERIFIED_VALUES:
                raise ValueError("EXECUTE requires on_verified COMPLETE or REPLAN")
            assert self.action is not None
            capability_map = {cap.name: cap for cap in capabilities}
            selected_capability = capability_map[self.action["capability"]]
            if (
                selected_capability.post_verify_mode == "REPLAN_REQUIRED"
                and self.on_verified != "REPLAN"
            ):
                raise ValueError(
                    "capability {} requires REPLAN after verification".format(
                        selected_capability.name
                    )
                )
        elif self.on_verified is not None:
            raise ValueError("on_verified is only valid for EXECUTE")
        if self.clarification is not None:
            self._validate_clarification(self.clarification)
        if self.wait is not None:
            self._validate_wait(self.wait)
        if self.completion is not None:
            if set(self.completion) != {"summary"} or not isinstance(self.completion["summary"], str):
                raise ValueError("invalid completion payload")
        if self.stop_reason is not None and not isinstance(self.stop_reason, str):
            raise ValueError("stop_reason must be string or null")
        if self.cancellation is not None:
            if set(self.cancellation) != {"reason"}:
                raise ValueError("invalid cancellation payload")
            reason = self.cancellation.get("reason")
            if not isinstance(reason, str) or not reason.strip():
                raise ValueError("cancellation.reason must be non-empty")
        if self.state_update is not None:
            if not isinstance(self.state_update, dict):
                raise ValueError("state_update must be object or null")
            allowed_state_fields = {"pending_clarification", "current_task_brief"}
            if not set(self.state_update).issubset(allowed_state_fields):
                raise ValueError("state_update contains unsupported fields")
            pending_update = self.state_update.get("pending_clarification")
            if pending_update is not None and pending_update not in {"RESOLVED", "KEEP", "CANCEL"}:
                raise ValueError("invalid pending_clarification state update")
            brief = self.state_update.get("current_task_brief")
            if brief is not None and (not isinstance(brief, str) or not brief.strip()):
                raise ValueError("current_task_brief must be a non-empty string")

    @staticmethod
    def _validate_action(action: Dict[str, Any], capabilities: List[CapabilitySpec]) -> None:
        if set(action) != {"capability", "arguments"}:
            raise ValueError("invalid action shape")
        capability_map = {cap.name: cap for cap in capabilities}
        name = action.get("capability")
        if name not in capability_map:
            raise ValueError("model selected unavailable capability: {}".format(name))
        arguments = action.get("arguments")
        if not isinstance(arguments, dict):
            raise ValueError("action.arguments must be an object")
        _validate_simple_object_schema(arguments, capability_map[name].arguments_schema)

    @staticmethod
    def _validate_clarification(clarification: Dict[str, Any]) -> None:
        required = {"question", "suggested_options", "accepts_text", "reason"}
        if set(clarification) != required:
            raise ValueError("invalid clarification shape")
        if not isinstance(clarification["question"], str) or not clarification["question"].strip():
            raise ValueError("clarification.question must be non-empty")
        if not isinstance(clarification["reason"], str) or not clarification["reason"].strip():
            raise ValueError("clarification.reason must be non-empty")
        if not isinstance(clarification["accepts_text"], bool):
            raise ValueError("clarification.accepts_text must be boolean")
        options = clarification["suggested_options"]
        if not isinstance(options, list):
            raise ValueError("clarification.suggested_options must be an array")
        for option in options:
            if set(option) != {"id", "label"}:
                raise ValueError("invalid clarification option")
            if not all(isinstance(option[key], str) and option[key].strip() for key in ("id", "label")):
                raise ValueError("clarification option values must be non-empty strings")
        if not options and not clarification["accepts_text"]:
            raise ValueError("clarification must offer at least one response path")

    @staticmethod
    def _validate_wait(wait: Dict[str, Any]) -> None:
        if set(wait) != {"kind", "resume_at", "condition"}:
            raise ValueError("invalid wait shape")
        if wait["kind"] not in WAIT_KINDS:
            raise ValueError("invalid wait kind")
        if wait["resume_at"] is not None and not isinstance(wait["resume_at"], str):
            raise ValueError("wait.resume_at must be string or null")
        if wait["condition"] is not None and not isinstance(wait["condition"], str):
            raise ValueError("wait.condition must be string or null")


def _validate_simple_object_schema(value: Dict[str, Any], schema: Dict[str, Any]) -> None:
    """Validate the small JSON-Schema subset used by V0 capability arguments.

    We intentionally avoid introducing a dependency before the contract proves
    it needs one. V0 supports object/string/number/integer/boolean, enum and
    required/additionalProperties=false.
    """
    if schema.get("type") != "object":
        raise ValueError("V0 capability schema root must be object")
    properties = schema.get("properties", {})
    required = set(schema.get("required", []))
    if not required.issubset(value):
        missing = sorted(required - set(value))
        raise ValueError("missing action arguments: {}".format(", ".join(missing)))
    if schema.get("additionalProperties") is False:
        extra = set(value) - set(properties)
        if extra:
            raise ValueError("unexpected action arguments: {}".format(", ".join(sorted(extra))))

    for key, item in value.items():
        spec = properties.get(key)
        if spec is None:
            continue
        expected = spec.get("type")
        if expected == "string" and not isinstance(item, str):
            raise ValueError("{}.{} must be string".format("arguments", key))
        if expected == "boolean" and not isinstance(item, bool):
            raise ValueError("{}.{} must be boolean".format("arguments", key))
        if expected == "integer" and (not isinstance(item, int) or isinstance(item, bool)):
            raise ValueError("{}.{} must be integer".format("arguments", key))
        if expected == "number" and (not isinstance(item, (int, float)) or isinstance(item, bool)):
            raise ValueError("{}.{} must be number".format("arguments", key))
        if expected in {"integer", "number"} and isinstance(item, (int, float)) and not isinstance(item, bool):
            minimum = spec.get("minimum")
            maximum = spec.get("maximum")
            if isinstance(minimum, (int, float)) and item < minimum:
                raise ValueError("{}.{} is below minimum".format("arguments", key))
            if isinstance(maximum, (int, float)) and item > maximum:
                raise ValueError("{}.{} is above maximum".format("arguments", key))
        if expected == "array":
            if not isinstance(item, list):
                raise ValueError(f"arguments.{key} must be array")
            if len(item) < spec.get('minItems', 0) or len(item) > spec.get('maxItems', float('inf')):
                raise ValueError(f"arguments.{key} array length outside allowed range")
            for child in item:
                child_spec = spec.get('items', {})
                if child_spec.get('type') == 'object':
                    if not isinstance(child, dict):
                        raise ValueError(f"arguments.{key} item must be object")
                    _validate_simple_object_schema(child, child_spec)
                elif 'enum' in child_spec and child not in child_spec['enum']:
                    raise ValueError(f"arguments.{key} item outside enum")
        if expected == "object":
            if not isinstance(item, dict):
                raise ValueError(f"arguments.{key} must be object")
            _validate_simple_object_schema(item, spec)
        if "enum" in spec and item not in spec["enum"]:
            raise ValueError("{}.{} is outside enum".format("arguments", key))


def planner_decision_schema(capabilities: List[CapabilitySpec]) -> Dict[str, Any]:
    action_variants: List[Dict[str, Any]] = [{"type": "null"}]
    for cap in capabilities:
        arguments_schema = json.loads(json.dumps(cap.arguments_schema))
        arguments_schema.setdefault("additionalProperties", False)
        action_variants.append(
            {
                "type": "object",
                "properties": {
                    "capability": {"type": "string", "enum": [cap.name]},
                    "arguments": arguments_schema,
                },
                "required": ["capability", "arguments"],
                "additionalProperties": False,
            }
        )

    clarification_schema = {
        "type": "object",
        "properties": {
            "question": {"type": "string"},
            "suggested_options": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "label": {"type": "string"},
                    },
                    "required": ["id", "label"],
                    "additionalProperties": False,
                },
            },
            "accepts_text": {"type": "boolean"},
            "reason": {"type": "string"},
        },
        "required": ["question", "suggested_options", "accepts_text", "reason"],
        "additionalProperties": False,
    }

    wait_schema = {
        "type": "object",
        "properties": {
            "kind": {
                "type": "string",
                "enum": ["until_time", "provider_event", "external_condition", "user_input"],
            },
            "resume_at": {"anyOf": [{"type": "string"}, {"type": "null"}]},
            "condition": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        },
        "required": ["kind", "resume_at", "condition"],
        "additionalProperties": False,
    }

    return {
        "type": "object",
        "properties": {
            "decision_type": {
                "type": "string",
                "enum": ["EXECUTE", "CLARIFY", "WAIT", "COMPLETE", "STOP", "CANCEL"],
            },
            "interpreted_goal_summary": {"type": "string"},
            "plan_update": {
                "anyOf": [
                    {"type": "array", "items": {"type": "string"}},
                    {"type": "null"},
                ]
            },
            "action": {"anyOf": action_variants},
            "on_verified": {
                "anyOf": [
                    {"type": "string", "enum": ["COMPLETE", "REPLAN"]},
                    {"type": "null"},
                ]
            },
            "clarification": {"anyOf": [clarification_schema, {"type": "null"}]},
            "wait": {"anyOf": [wait_schema, {"type": "null"}]},
            "completion": {
                "anyOf": [
                    {
                        "type": "object",
                        "properties": {"summary": {"type": "string"}},
                        "required": ["summary"],
                        "additionalProperties": False,
                    },
                    {"type": "null"},
                ]
            },
            "stop_reason": {"anyOf": [{"type": "string"}, {"type": "null"}]},
            "cancellation": {
                "anyOf": [
                    {
                        "type": "object",
                        "properties": {"reason": {"type": "string"}},
                        "required": ["reason"],
                        "additionalProperties": False,
                    },
                    {"type": "null"},
                ]
            },
            "state_update": {
                "anyOf": [
                    {
                        "type": "object",
                        "properties": {
                            "pending_clarification": {
                                "anyOf": [
                                    {"type": "string", "enum": ["RESOLVED", "KEEP", "CANCEL"]},
                                    {"type": "null"},
                                ]
                            },
                            "current_task_brief": {
                                "anyOf": [{"type": "string"}, {"type": "null"}]
                            },
                        },
                        "required": ["pending_clarification", "current_task_brief"],
                        "additionalProperties": False,
                    },
                    {"type": "null"},
                ]
            },
        },
        "required": [
            "decision_type",
            "interpreted_goal_summary",
            "plan_update",
            "action",
            "on_verified",
            "clarification",
            "wait",
            "completion",
            "stop_reason",
            "cancellation",
            "state_update",
        ],
        "additionalProperties": False,
    }
