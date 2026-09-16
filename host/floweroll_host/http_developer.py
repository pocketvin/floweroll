"""FastAPI adapter for the concurrently added read-only developer service."""
from typing import Annotated, Any

from fastapi import Depends, Header, Path, Query, Request
from pydantic import Field

from .http_common import APIProblem, host, router
from .http_schemas import JSONObject, RequestModel, ResponseModel

routes = router(tags=["developer"])
PREFIX = "/v1/developer/observability"


class DeveloperStatus(ResponseModel):
    enabled: bool
    capture_mode: str
    full_capture_available: bool
    configuration_note: str | None
    read_only: bool
    limitations: list[str]
    planner: JSONObject | None = None


class DeveloperTasks(ResponseModel):
    tasks: list[JSONObject]
    limit: int
    status: DeveloperStatus


class DeveloperTask(ResponseModel):
    task: JSONObject
    summary: JSONObject
    planner_calls: list[JSONObject]
    actions: list[JSONObject]
    evidence: list[JSONObject]
    observability: DeveloperStatus


class DeveloperCall(ResponseModel):
    task_id: str
    call_number: int
    available: bool
    capture_mode: str
    metadata: JSONObject
    metrics: list[JSONObject]
    note: str


class DeveloperListQuery(RequestModel):
    validation_error = (
        "INVALID_DEVELOPER_OBSERVABILITY_REQUEST",
        "Invalid developer observability request",
        "limit must be between 1 and 50.",
    )
    limit: Annotated[int, Field(ge=1, le=50)] = 40


def guard(request: Request, developer_mode: str | None = None):
    service = getattr(host(request), "developer_observability", None)
    if service is None or not service.enabled:
        raise APIProblem(404, "DEVELOPER_OBSERVABILITY_DISABLED", "Developer observability disabled", "Developer observability is not enabled on this Host.")
    if (developer_mode if developer_mode is not None else request.headers.get("x-floweroll-developer-mode")) != "1":
        raise APIProblem(403, "DEVELOPER_MODE_REQUIRED", "Developer mode required", "This read-only diagnostic endpoint requires an explicit developer-mode request.")
    if request.method != "GET":
        raise APIProblem(405, "DEVELOPER_OBSERVABILITY_READ_ONLY", "Developer observability is read-only", "Only GET is supported for developer observability.")
    return service


def developer_service(
    request: Request,
    developer_mode: Annotated[str | None, Header(alias="X-Floweroll-Developer-Mode")] = None,
):
    return guard(request, developer_mode)


def invoke(function):
    try:
        return function()
    except KeyError as exc:
        raise APIProblem(404, "DEVELOPER_TASK_NOT_FOUND", "Developer task not found", "The requested Task does not exist.") from exc
    except (TypeError, ValueError) as exc:
        raise APIProblem(400, "INVALID_DEVELOPER_OBSERVABILITY_REQUEST", "Invalid developer observability request", str(exc)) from exc
    except Exception as exc:
        raise APIProblem(503, "DEVELOPER_OBSERVABILITY_UNAVAILABLE", "Developer observability unavailable", "Read-only developer evidence is temporarily unavailable.", extensions={"error_type": type(exc).__name__}) from exc


@routes.get(PREFIX + "/status", response_model=DeveloperStatus, response_model_exclude_unset=True)
def developer_status(service: Annotated[Any, Depends(developer_service)]):
    return invoke(service.status)


@routes.get(PREFIX + "/tasks", response_model=DeveloperTasks, response_model_exclude_unset=True)
def developer_tasks(
    query: Annotated[DeveloperListQuery, Query()],
    service: Annotated[Any, Depends(developer_service)],
):
    return invoke(lambda: service.list_tasks(limit=query.limit))


@routes.get(PREFIX + "/tasks/{task_id}", response_model=DeveloperTask, response_model_exclude_unset=True)
def developer_task(task_id: str, service: Annotated[Any, Depends(developer_service)]):
    return invoke(lambda: service.task_overview(task_id))


@routes.get(PREFIX + "/tasks/{task_id}/planner-calls/{call_number}", response_model=DeveloperCall, response_model_exclude_unset=True)
def developer_call(
    task_id: str,
    call_number: Annotated[int, Path(ge=1)],
    service: Annotated[Any, Depends(developer_service)],
):
    return invoke(lambda: service.planner_call(task_id, call_number))
