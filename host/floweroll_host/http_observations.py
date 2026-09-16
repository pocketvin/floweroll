"""Observation API routes; scheduling/persistence remain in ObservationService."""
from fastapi import Request

from . import http_schemas as schema
from .http_common import APIProblem, host, router
from .observation_service import ObservationConflict

routes = router(tags=["observations"])
PREFIX = "/v1/observations"
SESSION = PREFIX + "/sessions/{session_id}"


def invoke(function, *args, **kwargs):
    try:
        return function(*args, **kwargs)
    except ObservationConflict as exc:
        raise APIProblem(409, "OBSERVATION_CONFLICT", "Observation conflict", str(exc)) from exc
    except KeyError as exc:
        raise APIProblem(404, "OBSERVATION_NOT_FOUND", "Observation not found", "这段观察记录不存在或已删除。") from exc
    except (ValueError, TypeError) as exc:
        raise APIProblem(400, "INVALID_OBSERVATION", "Invalid observation", "观察数据格式不正确。") from exc


@routes.get(PREFIX + "/health", response_model=schema.ObservationHealth, response_model_exclude_unset=True)
def observation_health(request: Request):
    return {"schema": 1, "ready": host(request).observation_service.ready, "summary_interval_seconds": 120}


@routes.post(PREFIX + "/sessions", response_model=schema.ObservationView, response_model_exclude_unset=True)
def observation_create(body: schema.ObservationCreate, request: Request):
    return invoke(host(request).observation_service.create, body.model_dump(exclude_unset=True))


@routes.get(SESSION, response_model=schema.ObservationView, response_model_exclude_unset=True)
@routes.get(SESSION + "/view", response_model=schema.ObservationView, response_model_exclude_unset=True)
def observation_view(session_id: str, request: Request):
    service = host(request).observation_service
    invoke(service.schedule, session_id)
    return invoke(service.view, session_id)


@routes.get(SESSION + "/evidence", response_model=schema.ObservationEvidence, response_model_exclude_unset=True)
def observation_evidence(session_id: str, request: Request):
    return invoke(host(request).observation_service.evidence, session_id)


@routes.post(SESSION + "/events", response_model=schema.ObservationIngested, response_model_exclude_unset=True)
def observation_events(session_id: str, body: schema.ObservationBatch, request: Request):
    return invoke(host(request).observation_service.ingest, session_id, body.model_dump(exclude_unset=True))


@routes.post(SESSION + "/event-status", response_model=schema.ObservationAcknowledged, response_model_exclude_unset=True)
def observation_event_status(session_id: str, body: schema.ObservationEventStatus, request: Request):
    return invoke(host(request).observation_service.event_status, session_id, body.model_dump(exclude_unset=True))


@routes.post(SESSION + "/finish", status_code=202, response_model=schema.ObservationView, response_model_exclude_unset=True)
def observation_finish(session_id: str, body: schema.ObservationFinish, request: Request):
    return invoke(host(request).observation_service.finish, session_id, body.model_dump(exclude_unset=True))


@routes.post(SESSION + "/questions", status_code=202, response_model=schema.ObservationView, response_model_exclude_unset=True)
def observation_question(session_id: str, body: schema.ObservationQuestion, request: Request):
    return invoke(host(request).observation_service.ask, session_id, body.model_dump(exclude_unset=True))


@routes.post(SESSION + "/delete", response_model=schema.ObservationDeleted, response_model_exclude_unset=True)
def observation_delete(session_id: str, request: Request):
    return invoke(host(request).observation_service.delete, session_id)


@routes.post(SESSION + "/retry", status_code=202, response_model=schema.ObservationView, response_model_exclude_unset=True)
def observation_retry(session_id: str, request: Request):
    service = host(request).observation_service
    invoke(service.schedule, session_id, force=True)
    return invoke(service.view, session_id)
