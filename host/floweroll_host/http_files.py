"""Raw and resumable file HTTP adapters, backed by the existing TaskAssetStore."""
from urllib.parse import quote, unquote
from typing import Annotated

from fastapi import Body, Header, Request, Response
from starlette.responses import FileResponse
from starlette.requests import ClientDisconnect

from . import http_schemas as schema
from .http_common import APIProblem, WireJSONResponse, call, host, legacy_error, router
from .task_assets import MAX_BACKGROUND_UPLOAD_CHUNK_BYTES, MAX_UPLOAD_BYTES, MAX_UPLOAD_CHUNK_BYTES

routes = router(tags=["files"])


def assets_for(request):
    assets = host(request).task_assets
    if assets is None:
        raise APIProblem(503, "FILES_DISABLED", "Files disabled", "附件服务未启用。")
    return assets


def validation_detail(exc):
    return str(exc)


@routes.post("/v1/files/uploads", status_code=201, response_model=schema.UploadState, response_model_exclude_unset=True)
def begin_upload(request: Request, headers: Annotated[schema.UploadHeaders, Header()]):
    assets = assets_for(request)
    try:
        return assets.begin_resumable_upload(file_id=headers.file_id, name=unquote(headers.name),
            media_type=headers.media_type.split(";")[0], expected_size=headers.expected_size, sha256=headers.sha256)
    except (ValueError, OSError) as exc:
        raise APIProblem(400, "INVALID_UPLOAD", "Invalid upload", validation_detail(exc)) from exc


@routes.post("/v1/files", status_code=201, response_model=schema.FileMetadata, response_model_exclude_unset=True)
async def upload(
    request: Request,
    headers: Annotated[schema.BinaryUploadHeaders, Header()],
    data: Annotated[bytes, Body(media_type="application/octet-stream")],
):
    assets = assets_for(request)
    try:
        length = headers.length
        if not 1 <= length <= MAX_UPLOAD_BYTES:
            raise APIProblem(413, "FILE_TOO_LARGE", "File size rejected", "每份附件最大 12 MB。", headers={"Connection": "close"})
        if len(data) != length:
            raise ValueError("附件上传不完整。")
        return await call(assets.upload, file_id=headers.file_id, name=unquote(headers.name),
            media_type=headers.media_type.split(";")[0], data=data, sha256=headers.sha256)
    except (ValueError, OSError) as exc:
        raise APIProblem(400, "INVALID_ATTACHMENT", "Invalid attachment", validation_detail(exc)) from exc


@routes.get("/v1/files/{file_id}", response_model=schema.FileMetadata, response_model_exclude_unset=True)
def file_metadata(file_id: str, request: Request):
    assets = assets_for(request)
    try:
        item = assets.get(file_id)
        if item.get("category") != "input":
            raise KeyError("File not found")
        return item
    except (KeyError, ValueError) as exc:
        raise APIProblem(404, "FILE_NOT_FOUND", "File unavailable", "该附件尚未上传或已被清理。") from exc


@routes.head("/v1/files/uploads/{file_id}", status_code=204)
def upload_state(file_id: str, request: Request):
    assets = assets_for(request)
    try:
        state = assets.resumable_upload_state(file_id)
        if state is None:
            raise KeyError("Upload resource not found")
        schema.UploadState.model_validate(state)
        headers = {"Upload-Offset": str(state["offset"]), "Upload-Complete": "?1" if state["complete"] else "?0", "Cache-Control": "no-store"}
        if state.get("expected_size") is not None:
            headers["Upload-Length"] = str(state["expected_size"])
        elif state.get("file") is not None:
            headers["Upload-Length"] = str(state["file"]["size_bytes"])
        return Response(status_code=204, headers=headers)
    except (KeyError, ValueError) as exc:
        raise APIProblem(404, "UPLOAD_NOT_FOUND", "Upload unavailable", "该附件没有可恢复的上传状态。") from exc


async def receive_upload_range(request, assets, file_id, chunk, *, background_transfer):
    """Stream system-owned ranges into the existing durable offset store.

    A request is not an atomic upload: an interrupted network stream must keep
    its received prefix. File publication still requires exact length + SHA.
    Ordinary small PATCH requests retain their existing atomic-chunk contract.
    """
    limit = MAX_BACKGROUND_UPLOAD_CHUNK_BYTES if background_transfer else MAX_UPLOAD_CHUNK_BYTES
    if not 0 < chunk.length <= limit:
        raise ValueError("上传分段不完整或超过大小限制。")
    state = await call(assets.resumable_upload_state, file_id)
    if state is None:
        raise KeyError("Upload resource not found")
    if chunk.offset != state["offset"]:
        raise RuntimeError(f'UPLOAD_OFFSET_MISMATCH:{state["offset"]}')
    if state["complete"]:
        raise ValueError("附件已经上传完成。")
    if background_transfer and chunk.offset + chunk.length != state["expected_size"]:
        raise ValueError("后台上传必须覆盖完整的剩余区间。")

    offset, received, pending = chunk.offset, 0, bytearray()

    async def commit(complete=False):
        nonlocal offset
        result = await call(assets.append_resumable_upload, file_id=file_id,
            offset=offset, data=bytes(pending), complete=complete)
        pending.clear()
        offset = result["offset"]
        return result

    try:
        async for packet in request.stream():
            if received + len(packet) > chunk.length:
                raise ValueError("上传内容超过声明的分段大小。")
            received += len(packet)
            if not background_transfer:
                pending.extend(packet)
                continue
            # Bound staging memory and fsync committed prefixes without waiting
            # for the rest of a multi-megabyte HTTP request.
            view = memoryview(packet)
            while view:
                count = min(MAX_UPLOAD_CHUNK_BYTES - len(pending), len(view))
                pending.extend(view[:count])
                view = view[count:]
                if len(pending) == MAX_UPLOAD_CHUNK_BYTES:
                    await commit()
    except ClientDisconnect as exc:
        if background_transfer and pending:
            await commit()
        raise APIProblem(408, "UPLOAD_INTERRUPTED", "Upload interrupted",
            "上传连接中断，已保存收到的部分，可继续上传。",
            headers={"Upload-Offset": str(offset), "Cache-Control": "no-store"}) from exc
    if received != chunk.length:
        raise ValueError("上传分段不完整。")
    return await commit(complete=chunk.complete.strip() == "?1")


@routes.patch("/v1/files/uploads/{file_id}", status_code=204, openapi_extra={
    "requestBody": {"required": True, "content": {
        "application/offset+octet-stream": {"schema": {"type": "string", "format": "binary"}}
    }}
})
async def append_upload(
    file_id: str,
    request: Request,
    chunk: Annotated[schema.UploadChunkHeaders, Header()],
):
    assets = assets_for(request)
    try:
        media_type = chunk.media_type.split(";")[0].strip().lower()
        if media_type != "application/offset+octet-stream":
            raise ValueError("PATCH Content-Type 必须为 application/offset+octet-stream。")
        if chunk.length <= 0:
            raise ValueError("上传分段不能为空。")
        background_transfer = (request.headers.get("x-floweroll-background-upload") == "?1"
                and request.headers.get("upload-complete") == "?1")
        state = await receive_upload_range(request, assets, file_id, chunk,
                                           background_transfer=background_transfer)
        schema.UploadState.model_validate(state)
        return Response(status_code=204, headers={"Upload-Offset": str(state["offset"]),
            "Upload-Complete": "?1" if state["complete"] else "?0", "Cache-Control": "no-store"})
    except RuntimeError as exc:
        if str(exc).startswith("UPLOAD_OFFSET_MISMATCH:"):
            body = schema.Problem(type="about:blank", title="Upload offset mismatch", status=409,
                code="UPLOAD_OFFSET_MISMATCH", detail="客户端上传位置与服务器已确认位置不一致。")
            return WireJSONResponse(body.model_dump(exclude_unset=True), status_code=409,
                media_type="application/problem+json; charset=utf-8", headers={"Upload-Offset": str(exc).split(":", 1)[1]})
        raise APIProblem(409, "UPLOAD_CONFLICT", "Upload conflict", str(exc)) from exc
    except KeyError as exc:
        raise APIProblem(404, "UPLOAD_NOT_FOUND", "Upload unavailable", "该附件没有可恢复的上传状态。") from exc
    except (ValueError, OSError) as exc:
        raise APIProblem(400, "INVALID_UPLOAD_CHUNK", "Invalid upload chunk", validation_detail(exc)) from exc


def disabled_task_route(task_id, request):
    message = "task not found" if host(request).storage.get_task(task_id) is None else "route not found"
    return legacy_error(404, message)


@routes.get("/v1/tasks/{task_id}/materials", response_model=schema.Materials, response_model_exclude_unset=True)
def materials(task_id: str, request: Request):
    assets = host(request).task_assets
    if assets is None:
        return disabled_task_route(task_id, request)
    try:
        return assets.manifest(task_id)
    except (KeyError, ValueError) as exc:
        raise APIProblem(404, "FILE_NOT_FOUND", "File unavailable", "该文件不属于当前任务或尚未生成。") from exc


class FullFileResponse(FileResponse):
    """Keep the old full-file download contract, without adding Range semantics."""
    async def __call__(self, scope, receive, send):
        scope = {**scope, "headers": [(k, v) for k, v in scope["headers"] if k not in {b"range", b"if-range"}]}
        await super().__call__(scope, receive, send)


@routes.get("/v1/tasks/{task_id}/files/{file_id}", response_class=FullFileResponse)
def download(task_id: str, file_id: str, request: Request):
    assets = host(request).task_assets
    if assets is None:
        return disabled_task_route(task_id, request)
    try:
        path = assets.delivery_file_path(task_id, file_id)
        item = schema.FileMetadata.model_validate(assets.get(file_id))
        response = FullFileResponse(path, headers={"Content-Type": item.media_type,
            "Content-Length": str(item.size_bytes), "Content-Disposition": "attachment; filename*=UTF-8''" + quote(item.name),
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Content-SHA256": item.sha256})
        del response.headers["accept-ranges"]
        return response
    except (KeyError, ValueError) as exc:
        raise APIProblem(404, "FILE_NOT_FOUND", "File unavailable", "该文件不属于当前任务或尚未生成。") from exc
