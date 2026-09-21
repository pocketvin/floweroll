"""Task HTTP adapters. Durable admission/execution remain in existing services."""
from __future__ import annotations

import asyncio
import time
from typing import Annotated

from fastapi import Header, Query, Request, Response
from starlette.responses import StreamingResponse

from . import http_schemas as schema
from .http_common import APIProblem, call, host, legacy_error, router, stopped
from .read_models import InvalidCursorError
from .storage import InvalidPlannerTransitionError, SubmissionConflictError

routes = router(tags=["tasks"])


@routes.get("/health", response_model=schema.Health, response_model_exclude_unset=True)
def health():
    return {"ok": True, "service": "floweroll-host"}


@routes.get("/v1/capabilities", response_model=schema.CapabilityStatus, response_model_exclude_unset=True)
def capabilities(request: Request):
    return host(request).capability_status()


@routes.get("/v1/tasks", response_model=schema.TaskIndexPage, response_model_exclude_unset=True)
def task_index(request: Request, query: Annotated[schema.TaskIndexQuery, Query()]):
    try:
        return host(request).storage.list_tasks(**query.model_dump())
    except (ValueError, InvalidCursorError) as exc:
        raise APIProblem(400, "INVALID_TASK_INDEX_QUERY", "Invalid task index query", str(exc)) from exc


@routes.post("/v1/tasks", response_model=schema.Task, response_model_exclude_unset=True, status_code=201,
             responses={200: {"model": schema.Task}})
def create_task(body: schema.TaskCreate, request: Request, response: Response):
    app, data = host(request), body.root
    try:
        if isinstance(data, schema.TaskSubmission):
            task = app.accept_product_task(goal=data.input.text, invocation_source=data.invocation_source,
                submission_id=data.submission_id.strip(),
                parent_task_id=data.parent_task_id.strip() if data.parent_task_id is not None else None,
                attachment_ids=data.input.attachment_ids)
        else:
            task = app.agent.create_task(goal=data.goal, invocation_source=data.invocation_source,
                                         policy_snapshot=data.policy_snapshot, submission_id=None)
    except SubmissionConflictError as exc:
        raise APIProblem(409, "SUBMISSION_ID_CONFLICT", "Submission ID conflict", str(exc)) from exc
    except ValueError as exc:
        raise APIProblem(400, "INVALID_TASK_SUBMISSION", "Invalid task submission", str(exc)) from exc
    response.status_code = 200 if task.get("idempotent_replay") else 201
    return task


@routes.get("/v1/submissions/{submission_id}/task", response_model=schema.Task, response_model_exclude_unset=True)
def submission_task(submission_id: str, request: Request):
    task = host(request).storage.get_task_by_submission_id(submission_id)
    if task is None:
        raise APIProblem(404, "SUBMISSION_NOT_ADMITTED", "Submission not admitted", "该发送尚未在 Host 创建 Task。")
    return task


@routes.get("/v1/tasks/{task_id}", response_model=schema.Task, response_model_exclude_unset=True)
def get_task(task_id: str, request: Request):
    task = host(request).storage.get_task(task_id)
    return legacy_error(404, "task not found") if task is None else task


@routes.get("/v1/tasks/{task_id}/view", response_model=schema.TaskView, response_model_exclude_unset=True)
def task_view(task_id: str, request: Request):
    view = host(request).get_task_view(task_id)
    if view is None:
        raise APIProblem(404, "TASK_NOT_FOUND", "Task not found", "The requested Task does not exist.")
    return view


@routes.get("/v1/tasks/{task_id}/artifacts/{artifact_id}", response_model=schema.Artifact, response_model_exclude_unset=True)
def get_artifact(task_id: str, artifact_id: str, request: Request):
    artifact = host(request).storage.get_artifact(task_id=task_id, artifact_id=artifact_id)
    if artifact is None:
        raise APIProblem(404, "ARTIFACT_NOT_FOUND", "Artifact not found", "The requested Artifact does not exist for this Task.")
    return artifact


@routes.get("/v1/tasks/{task_id}/trace", response_model=schema.Trace, response_model_exclude_unset=True)
def task_trace(task_id: str, request: Request):
    if host(request).storage.get_task(task_id) is None:
        return legacy_error(404, "task not found")
    return {"task_id": task_id, "events": host(request).storage.trace(task_id)}


def _legacy_generic_action_allowed(task: dict, action: dict) -> bool:
    """The generic action HTTP route is compatibility-only.

    Product execution has source-owned workers (iOS, Function, MCP). The old
    generic route remains only for the harmless no-Planner device.probe
    protocol, whose Task has no product submission identity.
    """
    return bool(
        task.get("submission_id") is None
        and action.get("task_id") == task.get("task_id")
        and action.get("action_type") == "device.probe"
    )


def _reject_nonlegacy_generic_action() -> None:
    raise APIProblem(
        409,
        "GENERIC_ACTION_ROUTE_NOT_ALLOWED",
        "Generic action route is compatibility-only",
        "Product Actions must be executed and completed by their source-owned worker.",
    )


@routes.get("/v1/tasks/{task_id}/next-action", response_model=schema.ActionDispatch, response_model_exclude_unset=True,
            responses={204: {"description": "No action available"}})
async def next_action(task_id: str, request: Request):
    return await _next_action(task_id, request, device=False)


@routes.get("/v1/tasks/{task_id}/next-device-action", response_model=schema.ActionDispatch, response_model_exclude_unset=True,
            responses={204: {"description": "No device action available"}})
async def next_device_action(task_id: str, request: Request, query: Annotated[schema.DeviceWait, Query()]):
    return await _next_action(
        task_id,
        request,
        device=True,
        wait=query.wait_seconds,
        supports_reconciliation=query.supports_reconciliation,
    )


async def _next_action(
    task_id: str,
    request: Request,
    *,
    device: bool,
    wait: float = 0,
    supports_reconciliation: bool = False,
):
    app = host(request)
    task = await call(app.storage.get_task, task_id)
    if task is None:
        return legacy_error(404, "task not found")
    if not device:
        open_action = await call(app.storage.get_open_action, task_id)
        if open_action is None:
            # The generic endpoint is not a product worker. Do not wait for a
            # future source-owned Action to appear after this compatibility poll.
            return Response(status_code=204)
        if not _legacy_generic_action_allowed(task, open_action):
            _reject_nonlegacy_generic_action()
    deadline = time.monotonic() + wait
    while True:
        action = await call(app.execution.next_action, task_id,
                            source_kind="ios", supports_reconciliation=supports_reconciliation)
        if action is not None:
            return {**action, "runtime_action_status": action["status"], "status": "dispatched"}
        current = await call(app.storage.get_task, task_id)
        if current is None:
            return legacy_error(404, "task not found")
        remaining = deadline - time.monotonic()
        if str(current["status"]).lower() != "active" or remaining <= 0 or stopped(request) or await request.is_disconnected():
            return Response(status_code=204)
        await asyncio.sleep(min(0.1, remaining))


@routes.post("/v1/tasks/{task_id}/actions/{action_id}/result", response_model=schema.ActionResult, response_model_exclude_unset=True)
def action_result(task_id: str, action_id: str, body: schema.ActionResultRequest, request: Request):
    app = host(request)
    task = app.storage.get_task(task_id)
    action = app.storage.get_action(action_id)
    if task is None or action is None or action.get("task_id") != task_id:
        return legacy_error(404, "task/action not found")
    if not _legacy_generic_action_allowed(task, action):
        if body.attempt_id is None:
            raise APIProblem(
                409,
                "ACTION_RESULT_ATTEMPT_REQUIRED",
                "Action Attempt identity is required",
                "Product Action results must identify the exact source-owned Attempt.",
            )
        attempt = app.storage.get_action_attempt(body.attempt_id)
        if attempt is None or attempt.get("action_id") != action_id:
            return legacy_error(404, "task/action attempt not found")
        if attempt.get("source_kind") != "ios":
            raise APIProblem(
                409,
                "ACTION_RESULT_SOURCE_NOT_ALLOWED",
                "Action result source is not allowed",
                "Only iOS-owned product Attempts may submit results over HTTP; Host Function/MCP workers complete in-process.",
            )
    try:
        result = app.execution.accept_result(task_id=task_id, action_id=action_id,
            attempt_id=body.attempt_id, success=body.success, output=body.output, error=body.error)
    except KeyError:
        return legacy_error(404, "task/action not found")
    app.supervisor.wake()
    return result


@routes.post(
    "/v1/tasks/{task_id}/actions/{action_id}/reconciliations/definitely-not-started",
    response_model=schema.ActionResult,
    response_model_exclude_unset=True,
)
def device_definitely_not_started(
    task_id: str,
    action_id: str,
    body: schema.DeviceDefinitelyNotStartedRequest,
    request: Request,
):
    app = host(request)
    try:
        result = app.execution.reconcile_device_definitely_not_started(
            task_id=task_id,
            action_id=action_id,
            attempt_id=body.attempt_id,
        )
    except KeyError as exc:
        raise APIProblem(
            404, "ACTION_ATTEMPT_NOT_FOUND", "Action Attempt not found",
            "The exact device Attempt does not exist.",
        ) from exc
    except InvalidPlannerTransitionError as exc:
        raise APIProblem(
            409, "RECONCILIATION_STATE_CONFLICT", "Reconciliation state conflict", str(exc)
        ) from exc
    app.supervisor.wake()
    return result


@routes.get("/v1/tasks/{task_id}/stream", response_class=StreamingResponse,
            responses={200: {"content": {"text/event-stream": {"schema": {"type": "string"}}}}})
async def presentation_stream(
    task_id: str,
    request: Request,
    query: Annotated[schema.PresentationCursor, Query()],
    last_event_id: Annotated[int | None, Header(alias="Last-Event-ID", ge=0)] = None,
):
    app = host(request)
    if await call(app.storage.get_task, task_id) is None:
        raise APIProblem(404, "TASK_NOT_FOUND", "Task not found", "The requested Task does not exist.")
    cursor = query.after_seq if query.after_seq is not None else (last_event_id or 0)

    async def events():
        nonlocal cursor
        heartbeat = time.monotonic()
        while not stopped(request):
            for event in await call(app.storage.presentation_events_after, task_id, cursor):
                payload = schema.PresentationEvent.model_validate(event).model_dump_json(exclude_unset=True)
                yield f"id: {event['seq']}\nevent: presentation\ndata: {payload}\n\n".encode()
                cursor = int(event["seq"])
            current = await call(app.storage.get_task, task_id)
            if current is None or str(current["status"]).lower() in {"completed", "failed", "cancelled"}:
                return
            if time.monotonic() - heartbeat >= 15:
                yield b": keepalive\n\n"
                heartbeat = time.monotonic()
            await asyncio.sleep(0.2)

    return StreamingResponse(events(), media_type="text/event-stream; charset=utf-8",
        headers={"Cache-Control": "no-cache", "Connection": "close", "X-Accel-Buffering": "no"})
