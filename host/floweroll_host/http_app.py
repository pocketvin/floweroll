"""FastAPI composition. The Host remains the sole owner of business state."""
from __future__ import annotations

from contextlib import asynccontextmanager
import threading

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError, ResponseValidationError
from fastapi.openapi.utils import get_openapi
from starlette.exceptions import HTTPException

from .auth import bearer_token_matches
from .http_common import APIProblem, JSON_LIMIT, call, legacy_error, problem_response, validation_problem


class APIBoundary:
    """Authenticate canonical API paths before reading request bodies."""
    def __init__(self, app, auth_token):
        self.app, self.auth_token = app, auth_token

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path", "")
        request = Request(scope, receive)
        if (path == "/v1" or path.startswith("/v1/")) and not bearer_token_matches(request.headers.get("authorization"), self.auth_token):
            response = problem_response(request, APIProblem(401, "AUTH_REQUIRED", "Authentication required", "A valid paired Host credential is required."))
            return await response(scope, receive, send)
        try:
            content_length = int(request.headers.get("content-length", "0"))
        except ValueError:
            content_length = 0
        if scope["method"] == "POST" and path == "/v1/files":
            from .task_assets import MAX_UPLOAD_BYTES
            if content_length > MAX_UPLOAD_BYTES:
                response = problem_response(request, APIProblem(
                    413, "FILE_TOO_LARGE", "File size rejected", "每份附件最大 12 MB。",
                    headers={"Connection": "close"},
                ))
                return await response(scope, receive, send)
        elif scope["method"] == "PATCH" and path.startswith("/v1/files/uploads/"):
            from .task_assets import MAX_BACKGROUND_UPLOAD_CHUNK_BYTES, MAX_UPLOAD_CHUNK_BYTES
            background_transfer = (request.headers.get("x-floweroll-background-upload") == "?1"
                and request.headers.get("upload-complete") == "?1")
            limit = MAX_BACKGROUND_UPLOAD_CHUNK_BYTES if background_transfer else MAX_UPLOAD_CHUNK_BYTES
            if content_length > limit:
                response = problem_response(request, APIProblem(
                    400, "INVALID_UPLOAD_CHUNK", "Invalid upload chunk", "上传分段超过大小限制。"
                ))
                return await response(scope, receive, send)
        elif content_length > JSON_LIMIT:
            response = legacy_error(400, "JSON body exceeds 2 MB; upload binary attachments separately")
            return await response(scope, receive, send)
        return await self.app(scope, receive, send)


def create_http_app(host_app, *, auth_token=None, shutdown_event=None) -> FastAPI:
    event = shutdown_event if shutdown_event is not None else threading.Event()
    close_lock = threading.Lock()
    closed = False

    def close_host():
        nonlocal closed
        with close_lock:
            if not closed:
                closed = True
                host_app.close()

    @asynccontextmanager
    async def lifespan(app):
        try:
            yield
        finally:
            event.set()
            await call(close_host)

    app = FastAPI(title="Floweroll Host API", version="1", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None, redirect_slashes=False)
    app.state.host, app.state.shutdown_event = host_app, event
    app.state.close_host = close_host
    app.add_middleware(APIBoundary, auth_token=auth_token)
    app.add_exception_handler(APIProblem, problem_response)
    app.add_exception_handler(RequestValidationError, validation_problem)

    @app.exception_handler(ResponseValidationError)
    async def invalid_response(request: Request, exc: ResponseValidationError):
        return problem_response(request, APIProblem(500, "INVALID_RESPONSE", "Invalid Host response", "The Host could not produce a valid response."))

    @app.exception_handler(HTTPException)
    async def unknown(request: Request, exc: HTTPException):
        path = request.url.path
        parts = [part for part in path.split("/") if part]
        if request.method in {"GET", "POST"} and parts[:3] == ["v1", "developer", "observability"]:
            from .http_developer import guard
            # Exception handlers return responses; raising here bypasses the
            # inner ExceptionMiddleware's registered APIProblem handler.
            try:
                guard(request)
                error = APIProblem(404, "DEVELOPER_OBSERVABILITY_ROUTE_NOT_FOUND", "Developer observability route not found", "The requested developer observability route does not exist.")
            except APIProblem as exc:
                error = exc
            return problem_response(request, error)
        if path == "/v1/observations" or path.startswith("/v1/observations/"):
            return problem_response(request, APIProblem(404, "OBSERVATION_ROUTE_NOT_FOUND", "Observation route unavailable", "观察接口不存在。"))
        return legacy_error(404, "route not found")

    from .http_tasks import routes
    app.include_router(routes)
    from .http_interactions import routes as interactions
    app.include_router(interactions)
    from .http_files import routes as files
    app.include_router(files)
    from .http_observations import routes as observations
    app.include_router(observations)
    from .http_developer import routes as developer
    app.include_router(developer)

    def openapi():
        if app.openapi_schema is None:
            document = get_openapi(title=app.title, version=app.version, routes=app.routes)
            # Runtime validation is intentionally exposed as the existing 400
            # contract, so do not advertise FastAPI's default 422 response.
            for operations in document["paths"].values():
                for operation in operations.values():
                    operation["responses"].pop("422", None)
            app.openapi_schema = document
        return app.openapi_schema

    app.openapi = openapi
    return app
