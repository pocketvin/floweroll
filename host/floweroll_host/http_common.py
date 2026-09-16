"""Shared HTTP transport helpers; Runtime ownership stays outside this module."""
from __future__ import annotations

import inspect
import json
from typing import Annotated, Any, get_args, get_origin, get_type_hints

from fastapi import APIRouter, Request
from fastapi.exceptions import RequestValidationError
from starlette.concurrency import run_in_threadpool
from starlette.responses import JSONResponse

from .http_schemas import LegacyError, Problem, RequestContract

JSON_LIMIT = 2 * 1024 * 1024


class WireJSONResponse(JSONResponse):
    media_type = "application/json; charset=utf-8"

    def render(self, content: Any) -> bytes:
        return json.dumps(content, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class APIProblem(Exception):
    def __init__(self, status: int, code: str, title: str, detail: str, *, extensions=None, headers=None):
        self.status, self.code, self.title, self.detail = status, code, title, detail
        self.extensions, self.headers = extensions or {}, headers


def problem_response(request: Request, error: APIProblem):
    value = Problem(
        type="urn:floweroll:problem:" + error.code.lower().replace("_", "-"),
        title=error.title,
        status=error.status,
        detail=error.detail,
        instance=request.url.path,
        code=error.code,
        **error.extensions,
    )
    return WireJSONResponse(
        value.model_dump(exclude_unset=True),
        status_code=error.status,
        media_type="application/problem+json; charset=utf-8",
        headers=error.headers,
    )


def legacy_error(status: int, message: str):
    return WireJSONResponse(LegacyError(error=message).model_dump(), status_code=status)


def host(request: Request):
    return request.app.state.host


def stopped(request: Request) -> bool:
    return request.app.state.shutdown_event.is_set()


async def call(function, *args, **kwargs):
    return await run_in_threadpool(function, *args, **kwargs)


def _request_contract(annotation: Any) -> type[RequestContract] | None:
    if get_origin(annotation) is Annotated:
        annotation = get_args(annotation)[0]
    if inspect.isclass(annotation) and issubclass(annotation, RequestContract):
        return annotation
    return None


def validation_problem(request: Request, exc: RequestValidationError):
    route = request.scope.get("route")
    try:
        hints = get_type_hints(route.endpoint, include_extras=True)
    except (AttributeError, NameError, TypeError):
        hints = {}
    contracts = [contract for annotation in hints.values() if (contract := _request_contract(annotation))]
    contract = contracts[0] if len(contracts) == 1 else None
    if contract is None and contracts:
        error_fields = {str(item) for error in exc.errors() for item in error.get("loc", ())}
        contract = next(
            (candidate for candidate in contracts if error_fields & set(getattr(candidate, "model_fields", {}))),
            contracts[0],
        )
    code, title, detail = (
        contract.validation_problem(exc.errors())
        if contract is not None
        else ("INVALID_REQUEST", "Invalid request", "Invalid request body.")
    )
    return problem_response(request, APIProblem(400, code, title, detail))


def _schema(model):
    return model.model_json_schema()


ERROR_RESPONSES = {
    status: {
        "description": "Host API error",
        "content": {
            "application/problem+json": {"schema": _schema(Problem)},
            "application/json": {"schema": _schema(LegacyError)},
        },
    }
    for status in (400, 401, 403, 404, 405, 409, 413, 500, 503)
}


def router(*, tags: list[str]) -> APIRouter:
    return APIRouter(tags=tags, default_response_class=WireJSONResponse, responses=ERROR_RESPONSES)
