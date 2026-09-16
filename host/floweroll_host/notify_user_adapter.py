from __future__ import annotations

import hashlib
from typing import Any, Dict, Optional

from .execution_contracts import ExecutionProfile, ExecutionVerification


CAPABILITY_ID = "notify.user"
PRESENTATION_STATES = {"delivered", "pending", "accepted_unobserved"}
READBACK_SOURCES = {"delivered", "pending", "acceptance_receipt"}
MODEL_CORRECTABLE_ERRORS = {
    "notify_user_invalid_arguments",
    "notifications_authorization_denied",
    "notifications_authorization_not_determined",
    "notifications_authorization_insufficient",
}


def stable_notification_id(idempotency_key: str) -> str:
    digest = hashlib.sha256(idempotency_key.encode("utf-8")).hexdigest()[:32]
    return f"floweroll.notify.{digest}"


def notify_user_arguments_valid(arguments: Dict[str, Any]) -> bool:
    if set(arguments) != {"title", "body", "attention_level"}:
        return False
    title = arguments.get("title")
    body = arguments.get("body")
    attention = arguments.get("attention_level")
    if not isinstance(title, str) or not title.strip() or title != title.strip() or len(title) > 120:
        return False
    if not isinstance(body, str) or not body.strip() or body != body.strip() or len(body) > 600:
        return False
    return attention in {"IMPORTANT", "USER_REQUIRED"}


class NotifyUserAdapter:
    capability_id = CAPABILITY_ID
    source_kind = "ios"
    execution_profile = ExecutionProfile(
        timeout_seconds=20,
        idempotency_mode="DEVICE_JOURNAL_AND_STABLE_NOTIFICATION_ID",
        retry_mode="NO_BLIND_RETRY",
        verification_mode="DEVICE_NOTIFICATION_ACCEPTANCE",
        reconciliation_mode="DEVICE_NOTIFICATION_READ_BACK",
        max_attempts=1,
    )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
            "notification_id": stable_notification_id(action["idempotency_key"]),
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            code = output.get("error_code")
            outcome = "MODEL_CORRECTABLE_FAILURE" if code in MODEL_CORRECTABLE_ERRORS else "TERMINAL_FAILURE"
            return ExecutionVerification(
                outcome=outcome,
                error=error or (str(code) if code else "iPhone notification executor reported failure"),
            )

        expected_arguments = action.get("payload")
        if not isinstance(expected_arguments, dict) or not notify_user_arguments_valid(expected_arguments):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="notify.user Action arguments were invalid at verification time",
            )

        expected_notification_id = stable_notification_id(action["idempotency_key"])
        required = {
            "notification_id",
            "task_id",
            "action_id",
            "system_accepted",
            "correlation_verified",
            "authorization_status",
            "presentation_state",
            "durable_acceptance_receipt",
            "reconciled",
            "readback_source",
            "duplicate_suppressed",
        }
        if not required.issubset(output):
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="notify.user result is missing required acceptance/readback fields",
            )

        valid = True
        valid = valid and output.get("notification_id") == expected_notification_id
        valid = valid and output.get("task_id") == action.get("task_id")
        valid = valid and output.get("action_id") == action.get("action_id")
        valid = valid and output.get("system_accepted") is True
        valid = valid and output.get("correlation_verified") is True
        valid = valid and output.get("authorization_status") == "authorized"
        valid = valid and output.get("presentation_state") in PRESENTATION_STATES
        valid = valid and output.get("durable_acceptance_receipt") is True
        valid = valid and isinstance(output.get("reconciled"), bool)
        valid = valid and output.get("readback_source") in READBACK_SOURCES
        valid = valid and isinstance(output.get("duplicate_suppressed"), bool)
        if not valid:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error="notify.user acceptance/readback did not match the dispatched Action",
            )

        observation = {key: output[key] for key in sorted(required)}
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=f"通知已提交给系统：「{expected_arguments['title']}」。",
        )
