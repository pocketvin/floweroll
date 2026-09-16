"""Typed HTTP admission for the existing inbox, cancellation and artifact APIs."""
from fastapi import Request, Response

from . import http_schemas as schema
from .http_common import APIProblem, host, router
from .presentation import stable_id
from .storage import (
    InboxEventConflictError, InvalidPlannerTransitionError,
    StaleActionInputError, StaleArtifactRevisionError,
)

routes = router(tags=["interactions"])


@routes.post("/v1/tasks/{task_id}/turns", status_code=202, response_model=schema.Accepted, response_model_exclude_unset=True)
def user_turn(task_id: str, body: schema.UserTurn, request: Request):
    app = host(request)
    context = body.reply_context.model_dump(exclude_unset=True)
    clarification_id = context.get("clarification_id")
    try:
        attachments = body.content.attachment_ids
        if app.task_assets is not None:
            app.task_assets.bind("turn:" + task_id + ":" + body.event_id.strip(), attachments)
        elif attachments:
            raise ValueError("附件服务未启用。")
        admitted = app.storage.admit_inbox_event(task_id=task_id, event_id=body.event_id.strip(),
            event_type="USER_TURN", source="user",
            target_type="CLARIFICATION" if clarification_id else None, target_id=clarification_id,
            payload={"content": {"kind": "text", "text": body.content.text.strip()},
                     "attachment_ids": attachments, "reply_context": context or None})
    except KeyError as exc:
        raise APIProblem(404, "TASK_NOT_FOUND", "Task not found", "The requested Task or reply target does not exist.") from exc
    except InboxEventConflictError as exc:
        raise APIProblem(409, "EVENT_ID_CONFLICT", "Event ID conflict", str(exc)) from exc
    except InvalidPlannerTransitionError as exc:
        raise APIProblem(409, "TASK_STATE_CONFLICT", "Task state conflict", str(exc)) from exc
    except ValueError as exc:
        raise APIProblem(400, "INVALID_ATTACHMENT_BINDING", "Invalid attachment", str(exc)) from exc
    app.supervisor.wake()
    return {"accepted": admitted}


@routes.post("/v1/tasks/{task_id}/clarifications/{clarification_id}/responses", status_code=202,
             response_model=schema.Accepted, response_model_exclude_unset=True)
def clarification_response(task_id: str, clarification_id: str, body: schema.ClarificationResponse, request: Request):
    app = host(request)
    try:
        admitted = app.storage.admit_clarification_response(task_id=task_id, clarification_id=clarification_id,
            event_id=body.event_id.strip(), response=body.response)
    except KeyError as exc:
        raise APIProblem(404, "CLARIFICATION_NOT_FOUND", "Clarification not found", "The requested Clarification does not belong to this Task.") from exc
    except InboxEventConflictError as exc:
        raise APIProblem(409, "EVENT_ID_CONFLICT", "Event ID conflict", str(exc)) from exc
    except InvalidPlannerTransitionError as exc:
        raise APIProblem(409, "STALE_CLARIFICATION", "Clarification is stale", str(exc)) from exc
    except ValueError as exc:
        raise APIProblem(400, "INVALID_CLARIFICATION_RESPONSE", "Invalid clarification response", str(exc)) from exc
    app.supervisor.wake()
    return {"accepted": admitted}


@routes.post("/v1/tasks/{task_id}/action-inputs/{input_request_id}/responses", status_code=202,
             response_model=schema.AcceptedActionInput, response_model_exclude_unset=True)
def action_input_response(task_id: str, input_request_id: str, body: schema.ActionInputResponse, request: Request):
    app = host(request)
    try:
        admitted = app.storage.admit_action_input_response(task_id=task_id, input_request_id=input_request_id,
            event_id=body.event_id.strip(), binding_digest=body.binding_digest, response=body.response)
        resolved = app.storage.consume_action_input_response(event_id=body.event_id.strip())
    except KeyError as exc:
        raise APIProblem(404, "ACTION_INPUT_NOT_FOUND", "Action input not found", "The requested ActionInputRequest does not belong to this Task.") from exc
    except InboxEventConflictError as exc:
        raise APIProblem(409, "EVENT_ID_CONFLICT", "Event ID conflict", str(exc)) from exc
    except StaleActionInputError as exc:
        raise APIProblem(409, "STALE_ACTION_INPUT", "Action input is stale", str(exc)) from exc
    except (InvalidPlannerTransitionError, ValueError) as exc:
        raise APIProblem(409, "ACTION_INPUT_STATE_CONFLICT", "Action input state conflict", str(exc)) from exc
    app.supervisor.wake()
    return {"accepted": admitted, "request": resolved}


@routes.post("/v1/tasks/{task_id}/cancel", status_code=202,
             response_model=schema.Cancelled, response_model_exclude_unset=True)
def cancel_task(task_id: str, body: schema.CancelRequest, request: Request):
    app = host(request)
    try:
        admitted = app.storage.admit_cancel_request(task_id=task_id, event_id=body.event_id.strip(), reason=body.reason)
        task = app.storage.consume_cancel_request(event_id=body.event_id.strip())
    except KeyError as exc:
        raise APIProblem(404, "TASK_NOT_FOUND", "Task not found", "The requested Task does not exist.") from exc
    except InboxEventConflictError as exc:
        raise APIProblem(409, "EVENT_ID_CONFLICT", "Event ID conflict", str(exc)) from exc
    except InvalidPlannerTransitionError as exc:
        raise APIProblem(409, "TASK_STATE_CONFLICT", "Task state conflict", str(exc)) from exc
    app.supervisor.wake()
    return {"accepted": admitted, "task": task}


@routes.post("/v1/tasks/{task_id}/retry", status_code=202,
             response_model=schema.TaskRetry, response_model_exclude_unset=True)
def retry_task(task_id: str, request: Request):
    app = host(request)
    try:
        result = app.storage.retry_blocked_planner_task(task_id=task_id)
    except KeyError as exc:
        raise APIProblem(404, "TASK_NOT_FOUND", "Task not found", "The requested Task does not exist.") from exc
    except InvalidPlannerTransitionError as exc:
        raise APIProblem(409, "TASK_RETRY_NOT_ALLOWED", "Task retry not allowed", str(exc)) from exc
    app.supervisor.wake()
    return result


@routes.post("/v1/tasks/{task_id}/artifacts/{artifact_id}/revisions", status_code=201,
             response_model=schema.Artifact, response_model_exclude_unset=True,
             responses={200: {"model": schema.Artifact}})
def edit_artifact(task_id: str, artifact_id: str, body: schema.ArtifactEdit, request: Request, response: Response):
    app = host(request)
    revision_id = stable_id("rev", task_id, artifact_id, body.event_id.strip())
    try:
        artifact = app.storage.create_artifact_revision(task_id=task_id, artifact_id=artifact_id,
            revision_id=revision_id, expected_revision_id=body.expected_revision_id, content=body.content,
            created_by="user", event_id=body.event_id.strip())
    except KeyError as exc:
        raise APIProblem(404, "ARTIFACT_NOT_FOUND", "Artifact not found", "The requested Artifact or base revision does not exist.") from exc
    except StaleArtifactRevisionError as exc:
        current = app.storage.get_artifact(task_id=task_id, artifact_id=artifact_id)
        raise APIProblem(409, "STALE_ARTIFACT_REVISION", "Artifact revision is stale", str(exc),
            extensions={"current_revision_id": current["current_revision_id"] if current else None}) from exc
    app.supervisor.wake()
    response.status_code = 200 if artifact.get("idempotent_replay") else 201
    return artifact
