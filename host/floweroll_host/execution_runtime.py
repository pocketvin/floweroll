from __future__ import annotations

import hashlib
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, Optional

from .capability_registry import CapabilityRegistry
from .execution_contracts import CapabilityAdapter
from .planner_contracts import CapabilitySpec
from .presentation import canonical_json
from .storage import ActionAdmissionSupersededError, InvalidPlannerTransitionError, Storage
from .task_capability_policy import EffectiveTaskCapabilityPolicy


class ExecutionRuntime:
    """Deterministic mechanics for one committed semantic Action.

    Planner semantics stay outside this class. ExecutionRuntime persists the
    concrete Attempt before dispatch, delegates capability-specific validation
    to the Adapter, and advances only from normalized/verified outcomes.
    """

    def __init__(
        self,
        storage: Storage,
        adapters: Iterable[CapabilityAdapter],
        *,
        capability_specs: Iterable[CapabilitySpec] = (),
        capability_registry: Optional[CapabilityRegistry] = None,
    ) -> None:
        self.storage = storage
        self.capability_registry = capability_registry
        self.policy_specs = {spec.name: spec for spec in capability_specs}
        self._confirmation_lock = threading.RLock()
        materialized = list(adapters)
        self.adapters = {}
        for adapter in materialized:
            if adapter.capability_id in self.adapters:
                raise ValueError(f"duplicate CapabilityAdapter: {adapter.capability_id}")
            self.adapters[adapter.capability_id] = adapter
        if not self.adapters:
            raise ValueError("ExecutionRuntime requires at least one CapabilityAdapter")

    def next_action(
        self,
        task_id: str,
        *,
        source_kind: Optional[str] = None,
        supports_reconciliation: bool = False,
    ) -> Optional[Dict[str, Any]]:
        try:
            if source_kind == "ios" and supports_reconciliation:
                recovered = self._device_reconciliation_dispatch(task_id)
                if recovered is not None:
                    return recovered
            return self._next_action(task_id, source_kind=source_kind)
        except ActionAdmissionSupersededError:
            # Storage checks admission inside the write transaction. A stop or
            # another input arriving after our reads is a normal empty poll.
            return None

    def _device_reconciliation_dispatch(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Read-only continuation of an existing native Attempt, never admission.

        Old clients must opt in before receiving this envelope: they would
        otherwise interpret a missing journal entry as permission to execute.
        """
        task = self.storage.get_task(task_id)
        if task is None or str(task["status"]).lower() in {"completed", "failed", "cancelled"}:
            return None
        action = self.storage.get_open_action(task_id)
        if action is None or self._adapter(action["action_type"]).source_kind != "ios":
            return None
        if not (task.get("cancel_requested_at") or action.get("interrupt_requested_at")
                or str(action["status"]).lower() == "reconciling"):
            return None
        attempt = self.storage.current_action_attempt(action["action_id"])
        if attempt is None or not (attempt["status"] == "IN_FLIGHT"
                or (attempt["status"] == "FINISHED" and attempt["latest_outcome"] == "UNKNOWN")):
            return None
        return {**action, "attempt_id": attempt["attempt_id"],
                "attempt_number": attempt["attempt_number"], "attempt_status": attempt["status"],
                "dispatch_digest": attempt["dispatch_digest"], "reconciliation_only": True}

    def _next_action(
        self, task_id: str, *, source_kind: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        task = self.storage.get_task(task_id)
        if task is None:
            raise KeyError(task_id)
        if task.get("cancel_requested_at") is not None or str(task["status"]).lower() in {"completed", "failed", "cancelled"}:
            return None
        action = self.storage.get_open_action(task_id)
        if action is None:
            return None
        if self.storage.pending_action_input_for_action(action["action_id"]) is not None:
            return None
        if action.get("interrupt_requested_at") is not None:
            # A durable control interrupt means the original invocation must
            # not be (re)dispatched. The current Driver may instead observe
            # current_interrupt_request() and attempt provider-native cancel.
            return None
        adapter = self._adapter(action["action_type"])
        if source_kind is not None and adapter.source_kind != source_kind:
            return None
        status = str(action["status"]).lower()
        if status in {"reconciling", "retry_wait", "verifying"}:
            return None

        attempt = self.storage.current_action_attempt(action["action_id"])
        prospective_new_attempt = (
            status in {"pending", "planned", "dispatched"}
            and (attempt is None or attempt["status"] == "FINISHED")
        )
        policy_revision: Optional[int] = None
        if prospective_new_attempt:
            policy_basis = self.storage.task_policy_basis(task_id)
            effective_policy = EffectiveTaskCapabilityPolicy.from_task(
                policy_basis["task"], policy_basis["user_turns"]
            )
            spec = self._policy_spec(action["action_type"])
            policy_decision = effective_policy.decide(
                spec, self.capability_registry, arguments=action["payload"],
                prior_created_titles=[item["title"] for item in policy_basis["completed_creations"]
                                      if item["capability"] == action["action_type"]],
            )
            policy_revision = int(policy_basis["runtime_revision"])
            if not policy_decision.allowed:
                self.storage.fail_action_task_denied(
                    task_id=task_id,
                    action_id=action["action_id"],
                    expected_policy_revision=policy_revision,
                    detail={
                        "capability": action["action_type"],
                        "operation": policy_decision.operation,
                        "domains": list(policy_decision.domains),
                        "policy_detail": policy_decision.detail,
                    },
                )
                return None

        # Adapters can require the existing, exact-dispatch ActionInput before
        # admitting an Attempt. Repeated polls must not create repeated prompts.
        confirmation = getattr(adapter, "predispatch_confirmation", None)
        if status in {"pending", "planned"} and confirmation is not None:
            with self._confirmation_lock:
                if self.storage.pending_action_input_for_action(action["action_id"]) is not None:
                    return None
                if self.storage.latest_approved_predispatch_input(action["action_id"]) is None:
                    request = confirmation(action)
                    if request is not None:
                        self.request_predispatch_input(
                            task_id=task_id, action_id=action["action_id"],
                            input_request_id=str(uuid.uuid4()), **request,
                        )
                        return None

        if status in {"pending", "planned", "dispatched"}:
            if attempt is None or attempt["status"] == "FINISHED":
                previous_count = len(self.storage.action_attempts(action["action_id"]))
                if previous_count >= adapter.execution_profile.max_attempts:
                    raise RuntimeError(
                        f"Action {action['action_id']} exhausted max attempts "
                        f"({adapter.execution_profile.max_attempts})"
                    )
                dispatch_snapshot = adapter.build_dispatch_snapshot(action)
                dispatch_digest = hashlib.sha256(
                    canonical_json(dispatch_snapshot).encode("utf-8")
                ).hexdigest()
                approval = self.storage.latest_approved_predispatch_input(action["action_id"])
                attempt = self.storage.start_action_attempt(
                    attempt_id=str(uuid.uuid4()),
                    task_id=task_id,
                    action_id=action["action_id"],
                    source_kind=adapter.source_kind,
                    execution_profile=adapter.execution_profile.as_dict(),
                    dispatch_snapshot=dispatch_snapshot,
                    dispatch_digest=dispatch_digest,
                    approved_input_request_id=approval["input_request_id"] if approval else None,
                    expected_policy_revision=policy_revision,
                )
            elif attempt["status"] == "WAITING_INPUT":
                return None
        elif status == "executing":
            if attempt is None:
                raise RuntimeError(
                    f"Action {action['action_id']} is executing without a durable Attempt"
                )
            if attempt["status"] == "WAITING_INPUT":
                return None
            if attempt["status"] != "IN_FLIGHT":
                raise RuntimeError(
                    f"Action {action['action_id']} is executing but latest Attempt is {attempt['status']}"
                )
        else:
            return None

        assert attempt is not None
        # Once the source returned a durable operation handle, the original
        # invocation must never be replayed as a fresh dispatch. Poll/update
        # that source operation through its dedicated continuation path.
        if attempt.get("source_operation_ref") is not None:
            return None
        approved_input_request_id = attempt.get("approved_input_request_id")
        if approved_input_request_id is not None:
            request = self.storage.get_action_input_request(str(approved_input_request_id))
            if request is not None and request.get("attempt_id") == attempt["attempt_id"]:
                # Mid-tool input has a dedicated source continuation. Replaying
                # the original Action dispatch here would duplicate work.
                return None
        current_action = self.storage.get_action(action["action_id"])
        assert current_action is not None
        return {
            **current_action,
            "attempt_id": attempt["attempt_id"],
            "attempt_number": attempt["attempt_number"],
            "attempt_status": attempt["status"],
            "dispatch_digest": attempt["dispatch_digest"],
        }

    def accept_result(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: Optional[str] = None,
        success: bool,
        output: Optional[Dict[str, Any]] = None,
        error: Optional[str] = None,
    ) -> Dict[str, Any]:
        action = self.storage.get_action(action_id)
        if action is None or action["task_id"] != task_id:
            raise KeyError(action_id)

        attempts = self.storage.action_attempts(action_id)
        if not attempts:
            raise RuntimeError("Action result arrived before an ActionAttempt was admitted")
        if attempt_id is None:
            if len(attempts) != 1:
                raise RuntimeError("attempt_id is required once an Action has multiple Attempts")
            attempt = attempts[0]
        else:
            attempt = self.storage.get_action_attempt(attempt_id)
            if attempt is None or attempt["action_id"] != action_id:
                raise KeyError(attempt_id)

        current = attempts[-1]
        if attempt["attempt_id"] != current["attempt_id"]:
            raise RuntimeError(
                "late result belongs to a non-current Attempt and requires reconciliation"
            )

        if attempt["status"] == "FINISHED" and attempt["latest_outcome"] != "UNKNOWN":
            return {
                "task": self.storage.get_task(task_id),
                "action": action,
                "attempt": attempt,
                "duplicate": True,
            }

        self.storage.record_trace_event(
            task_id,
            "action.result.received",
            {
                "action_id": action_id,
                "attempt_id": attempt["attempt_id"],
                "capability": action["action_type"],
                "source_kind": attempt["source_kind"],
            },
        )
        adapter = self._adapter(action["action_type"])
        verifier_started = time.perf_counter()
        verification = adapter.verify_result(
            action,
            success=success,
            output=output or {},
            error=error,
        )
        verifier_ms = (time.perf_counter() - verifier_started) * 1000.0
        commit_started = time.perf_counter()
        if verification.outcome == "SUCCESS":
            assert verification.observation is not None
            completed = self.storage.finish_action_attempt_verified(
                task_id=task_id,
                action_id=action_id,
                attempt_id=attempt["attempt_id"],
                capability=action["action_type"],
                result=output or {},
                observation=verification.observation,
                verification_mode=adapter.execution_profile.verification_mode,
                direct_completion_summary=verification.direct_completion_summary,
            )
        elif verification.outcome == "MODEL_CORRECTABLE_FAILURE":
            completed = self.storage.finish_action_attempt_model_correctable(
                task_id=task_id,
                action_id=action_id,
                attempt_id=attempt["attempt_id"],
                result=output or {},
                error=verification.error,
            )
        elif verification.outcome == "TRANSIENT_FAILURE":
            profile = adapter.execution_profile
            if profile.retry_mode != "SAFE_WITH_SAME_KEY":
                completed = self.storage.finish_action_attempt_failure(
                    task_id=task_id,
                    action_id=action_id,
                    attempt_id=attempt["attempt_id"],
                    outcome="TERMINAL_FAILURE",
                    result=output or {},
                    error=(verification.error or "transient failure") + "; automatic retry is not safe",
                )
            elif int(attempt["attempt_number"]) >= profile.max_attempts:
                reason = (verification.error or "transient failure") + "; retry budget exhausted"
                if (action["action_type"] in {"web.fetch", "web.search", "docs.query"}
                        and profile.idempotency_mode == "NATURAL_READ_ONLY"
                        and action.get("on_verified") == "REPLAN"):
                    # Failure of one research source is not failure of the
                    # user's entire composite goal. Preserve the failed Attempt
                    # and let Planner use existing evidence / another source.
                    # TLS verification and bounded source retries stay enabled.
                    completed = self.storage.finish_action_attempt_model_correctable(
                        task_id=task_id, action_id=action_id, attempt_id=attempt["attempt_id"],
                        result={**(output or {}), "error_kind": "model_correctable",
                                "recovery_hint": "此来源重试已耗尽；保留已有证据，换来源或推进其他工作，不重试同一URL，也不伪称已读取。"},
                        error=reason,
                    )
                else:
                    completed = self.storage.finish_action_attempt_failure(
                        task_id=task_id, action_id=action_id, attempt_id=attempt["attempt_id"],
                        outcome="TERMINAL_FAILURE", result=output or {}, error=reason,
                    )
            else:
                wake_at = (
                    datetime.now(timezone.utc)
                    + timedelta(seconds=max(0, int(profile.retry_backoff_seconds)))
                ).isoformat()
                completed = self.storage.finish_action_attempt_transient_retry(
                    task_id=task_id,
                    action_id=action_id,
                    attempt_id=attempt["attempt_id"],
                    result=output or {},
                    error=verification.error,
                    wait_id=str(uuid.uuid4()),
                    wake_at=wake_at,
                )
        elif verification.outcome in {"TERMINAL_FAILURE", "CANCELLED"}:
            completed = self.storage.finish_action_attempt_failure(
                task_id=task_id,
                action_id=action_id,
                attempt_id=attempt["attempt_id"],
                outcome=verification.outcome,
                result=output or {},
                error=verification.error,
            )
        else:
            raise RuntimeError(
                f"CapabilityAdapter returned unsupported synchronous outcome {verification.outcome}"
            )
        commit_ms = (time.perf_counter() - commit_started) * 1000.0
        self.storage.record_trace_event(
            task_id,
            "action.verification.metrics",
            {
                "action_id": action_id,
                "attempt_id": attempt["attempt_id"],
                "capability": action["action_type"],
                "source_kind": attempt["source_kind"],
                "outcome": verification.outcome,
                "verifier_ms": round(verifier_ms, 3),
                "terminal_commit_ms": round(commit_ms, 3),
            },
        )
        return {**completed, "duplicate": False}

    def current_interrupt_request(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Return the durable Action interrupt signal for a source Driver."""

        action = self.storage.get_open_action(task_id)
        if action is None or action.get("interrupt_requested_at") is None:
            return None
        attempt = self.storage.current_action_attempt(action["action_id"])
        return {
            "task_id": task_id,
            "action_id": action["action_id"],
            "attempt_id": attempt["attempt_id"] if attempt is not None else None,
            "reason": action.get("interrupt_reason"),
            "requested_at": action.get("interrupt_requested_at"),
        }

    def mark_current_attempt_unknown(
        self,
        *,
        task_id: str,
        action_id: str,
        reason: str,
    ) -> Dict[str, Any]:
        action = self.storage.get_action(action_id)
        if action is None or action["task_id"] != task_id:
            raise KeyError(action_id)
        attempt = self.storage.current_action_attempt(action_id)
        if attempt is None:
            raise RuntimeError("cannot mark UNKNOWN before an ActionAttempt exists")
        return self.storage.mark_action_attempt_unknown(
            task_id=task_id,
            action_id=action_id,
            attempt_id=attempt["attempt_id"],
            reason=reason,
        )

    def reconcile_device_definitely_not_started(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
    ) -> Dict[str, Any]:
        """Finalize a stopped iPhone Action after read-back proves no effect."""
        action = self.storage.get_action(action_id)
        if action is None or action["task_id"] != task_id:
            raise KeyError(action_id)
        adapter = self._adapter(action["action_type"])
        if adapter.source_kind != "ios":
            raise InvalidPlannerTransitionError(
                "definitely-not-started reconciliation is device-only"
            )

        task = self.storage.get_task(task_id)
        attempt = self.storage.current_action_attempt(action_id)
        if task is None or attempt is None or attempt["attempt_id"] != attempt_id:
            raise KeyError(attempt_id)

        cancel_requested = task.get("cancel_requested_at") is not None
        interrupt_requested = action.get("interrupt_requested_at") is not None
        action_status = str(action["status"]).lower()
        task_status = str(task["status"]).lower()

        # An identical POST may be replayed after the first response is lost.
        if action_status == "cancelled":
            if cancel_requested and task_status == "cancelled":
                return {
                    "task": task, "action": action, "attempt": attempt, "duplicate": True
                }
            if interrupt_requested and task_status not in {"completed", "failed", "cancelled"}:
                return {
                    "task": task, "action": action, "attempt": attempt, "duplicate": True
                }

        if not cancel_requested and not interrupt_requested:
            raise InvalidPlannerTransitionError(
                "Action is not stopped; definitely-not-started proof cannot finalize it"
            )

        attempt_status = str(attempt["status"]).upper()
        if attempt_status == "IN_FLIGHT":
            self.storage.mark_action_attempt_unknown(
                task_id=task_id,
                action_id=action_id,
                attempt_id=attempt_id,
                reason="device read-back proved the stopped native operation did not start",
            )
        elif not (
            attempt_status == "FINISHED"
            and attempt.get("latest_outcome") == "UNKNOWN"
            and action_status == "reconciling"
        ):
            raise InvalidPlannerTransitionError(
                "Attempt is not eligible for definitely-not-started reconciliation"
            )

        if cancel_requested:
            finalized = self.storage.finalize_cancel_after_reconciliation(
                task_id=task_id, action_id=action_id
            )
        else:
            finalized = self.storage.finalize_action_interrupt_after_reconciliation(
                task_id=task_id, action_id=action_id
            )
        return {
            "task": finalized,
            "action": self.storage.get_action(action_id),
            "attempt": self.storage.get_action_attempt(attempt_id),
            "duplicate": False,
        }

    def reconcile_definitely_absent_retry_safe(
        self,
        *,
        task_id: str,
        action_id: str,
        wake_at: Optional[str] = None,
    ) -> Dict[str, Any]:
        action = self.storage.get_action(action_id)
        if action is None or action["task_id"] != task_id:
            raise KeyError(action_id)
        adapter = self._adapter(action["action_type"])
        if adapter.execution_profile.retry_mode != "SAFE_WITH_SAME_KEY":
            raise RuntimeError("Adapter does not allow deterministic retry after reconciliation")
        task = self.storage.get_task(task_id)
        if task is not None and task.get("cancel_requested_at") is not None:
            return self.storage.finalize_cancel_after_reconciliation(
                task_id=task_id,
                action_id=action_id,
            )
        if action.get("interrupt_requested_at") is not None:
            return self.storage.finalize_action_interrupt_after_reconciliation(
                task_id=task_id,
                action_id=action_id,
            )
        if wake_at is None:
            return self.storage.mark_action_retry_ready(
                task_id=task_id,
                action_id=action_id,
            )
        return self.storage.mark_action_retry_wait(
            task_id=task_id,
            action_id=action_id,
            wait_id=str(uuid.uuid4()),
            wake_at=wake_at,
        )

    def resume_retry_wait(
        self,
        *,
        task_id: str,
        action_id: str,
        wait_id: str,
        event_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        return self.storage.resume_action_retry_wait(
            task_id=task_id,
            action_id=action_id,
            wait_id=wait_id,
            event_id=event_id,
        )

    def request_predispatch_input(
        self,
        *,
        task_id: str,
        action_id: str,
        input_request_id: str,
        prompt: str,
        suggested_options: list[Dict[str, Any]],
        accepts_text: bool,
        reason: str,
        artifact_revision_ids: Optional[list[str]] = None,
        execution_fields: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        action = self.storage.get_action(action_id)
        if action is None or action["task_id"] != task_id:
            raise KeyError(action_id)
        adapter = self._adapter(action["action_type"])
        dispatch_snapshot = adapter.build_dispatch_snapshot(action)
        dispatch_digest = hashlib.sha256(
            canonical_json(dispatch_snapshot).encode("utf-8")
        ).hexdigest()
        binding = {
            "action_id": action_id,
            "capability_id": action["action_type"],
            "artifact_revisions": list(artifact_revision_ids or []),
            "execution_fields": dict(execution_fields or {}),
            "dispatch_digest": dispatch_digest,
        }
        return self.storage.create_action_input_request(
            input_request_id=input_request_id,
            task_id=task_id,
            action_id=action_id,
            attempt_id=None,
            prompt=prompt,
            suggested_options=suggested_options,
            accepts_text=accepts_text,
            reason=reason,
            binding=binding,
        )

    def action_input_continuation(self, *, attempt_id: str) -> Dict[str, Any]:
        attempt = self.storage.get_action_attempt(attempt_id)
        if attempt is None:
            raise KeyError(attempt_id)
        request_id = attempt.get("approved_input_request_id")
        if request_id is None:
            raise RuntimeError("Attempt has no answered ActionInput continuation")
        request = self.storage.get_action_input_request(str(request_id))
        if request is None or request.get("attempt_id") != attempt_id:
            raise RuntimeError("ActionInput continuation does not belong to this Attempt")
        if request["status"] != "ANSWERED":
            raise RuntimeError("ActionInput continuation has not been answered")
        return {
            "attempt_id": attempt_id,
            "source_round": attempt["source_round"],
            "source_continuation_ref": request["source_continuation_ref"],
            "input_request_id": request["input_request_id"],
            "response": request["response"],
            "binding_digest": request["binding_digest"],
        }

    def defer_to_source_operation(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        source_operation_ref: str,
        source_status: str,
        poll_after: Optional[str],
        ttl_at: Optional[str] = None,
    ) -> Dict[str, Any]:
        attempt = self.storage.get_action_attempt(attempt_id)
        if attempt is None or attempt["action_id"] != action_id:
            raise KeyError(attempt_id)
        return self.storage.set_source_operation_wait(
            task_id=task_id,
            action_id=action_id,
            attempt_id=attempt_id,
            wait_id=str(uuid.uuid4()),
            source_operation_ref=source_operation_ref,
            source_status=source_status,
            poll_after=poll_after,
            ttl_at=ttl_at,
        )

    def resume_source_operation_poll(
        self,
        *,
        task_id: str,
        action_id: str,
        attempt_id: str,
        wait_id: str,
        event_id: str,
    ) -> Dict[str, Any]:
        return self.storage.resume_source_operation_from_timer(
            task_id=task_id,
            action_id=action_id,
            attempt_id=attempt_id,
            wait_id=wait_id,
            event_id=event_id,
        )

    def _policy_spec(self, capability_id: str) -> CapabilitySpec:
        spec = self.policy_specs.get(capability_id)
        if spec is not None:
            return spec
        if self.capability_registry is not None and capability_id in self.capability_registry:
            return self.capability_registry.get(capability_id).spec
        return CapabilitySpec(
            name=capability_id,
            description="",
            arguments_schema={
                "type": "object",
                "properties": {},
                "required": [],
                "additionalProperties": True,
            },
        )

    def _adapter(self, capability_id: str) -> CapabilityAdapter:
        adapter = self.adapters.get(capability_id)
        if adapter is None:
            raise ValueError(f"no CapabilityAdapter registered for {capability_id}")
        return adapter
