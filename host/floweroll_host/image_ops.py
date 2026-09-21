from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Tuple

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .execution_contracts import ExecutionProfile, ExecutionVerification
from .function_execution_worker import FunctionToolError, TaskScopedFunction
from .planner_contracts import CapabilitySpec
from .task_assets import TaskAssetStore, safe_name


INSPECT_ID = "image.inspect"
TRANSFORM_ID = "image.transform"

SUPPORTED_INPUT_MEDIA_TYPES = {
    "image/jpeg": "jpeg",
    "image/png": "png",
    "image/tiff": "tiff",
    "image/heic": "heic",
}
FORMAT_MEDIA_TYPES = {
    "jpeg": "image/jpeg",
    "png": "image/png",
    "tiff": "image/tiff",
    "heic": "image/heic",
}
FORMAT_SUFFIXES = {
    "jpeg": ".jpg",
    "png": ".png",
    "tiff": ".tiff",
    "heic": ".heic",
}
FORMAT_ACCEPTED_SUFFIXES = {
    "jpeg": {".jpg", ".jpeg"},
    "png": {".png"},
    "tiff": {".tif", ".tiff"},
    "heic": {".heic", ".heif"},
}

MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_PIXELS = 32_000_000
MAX_DECODE_BYTES = 96 * 1024 * 1024
MAX_SIDE = 32_768
MAX_OUTPUT_SIDE = 8_192
MIN_JPEG_QUALITY = 10
MAX_JPEG_QUALITY = 95

TRANSFORM_OPERATIONS = (
    "convert",
    "resize_fit",
    "resize_exact",
    "crop",
    "compress_jpeg",
    "normalize_orientation",
    "strip_metadata",
)
ALPHA_POLICIES = ("preserve", "flatten_white")
OUTPUT_FORMATS = ("jpeg", "png", "tiff", "heic")
METADATA_SCOPES = ("basic", "privacy_flags", "technical")

INSPECT_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "input_id": {
            "type": "string",
            "description": "当前任务附件/已验证祖先成果中的图片 file id，不是文件路径。",
        },
        "metadata_scope": {
            "type": "string",
            "enum": list(METADATA_SCOPES),
            "description": "basic=格式/尺寸/方向/alpha；privacy_flags=再返回隐私元数据是否存在；technical=再返回有界技术参数。",
        },
    },
    "required": ["input_id"],
    "additionalProperties": False,
}

TRANSFORM_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "operation": {
            "type": "string",
            "enum": list(TRANSFORM_OPERATIONS),
            "description": (
                "convert=转格式；resize_fit=按最长边等比缩小；resize_exact=精确宽高；"
                "crop=按左上角坐标裁出区域；compress_jpeg=JPEG quality 压缩；"
                "normalize_orientation=方向归一化；strip_metadata=去除隐私/身份 metadata。"
            ),
        },
        "input_id": {
            "type": "string",
            "description": "当前任务附件/已验证祖先成果中的图片 file id，不是文件路径。",
        },
        "output_name": {
            "type": "string",
            "description": "给用户看的单个安全文件名；扩展名必须与输出格式一致，如 .jpg/.png/.tiff/.heic。",
        },
        "output_format": {
            "type": "string",
            "enum": list(OUTPUT_FORMATS),
            "description": "输出格式。compress_jpeg 固定为 JPEG，因此该操作不要传此字段。",
        },
        "max_dimension": {
            "type": "integer", "minimum": 1, "maximum": MAX_OUTPUT_SIDE,
            "description": "resize_fit 的最长显示边像素数；不会把较小图片放大。",
        },
        "width": {
            "type": "integer", "minimum": 1, "maximum": MAX_OUTPUT_SIDE,
            "description": "resize_exact/crop 的输出宽度（像素）。",
        },
        "height": {
            "type": "integer", "minimum": 1, "maximum": MAX_OUTPUT_SIDE,
            "description": "resize_exact/crop 的输出高度（像素）。",
        },
        "offset_x": {
            "type": "integer", "minimum": 0, "maximum": MAX_SIDE,
            "description": "crop 左上角横坐标，0 表示图片最左侧。",
        },
        "offset_y": {
            "type": "integer", "minimum": 0, "maximum": MAX_SIDE,
            "description": "crop 左上角纵坐标，0 表示图片最上侧。",
        },
        "jpeg_quality": {
            "type": "integer",
            "minimum": MIN_JPEG_QUALITY,
            "maximum": MAX_JPEG_QUALITY,
            "description": "compress_jpeg 的质量 10..95；这是质量参数，不承诺精确输出字节数。",
        },
        "alpha_policy": {
            "type": "string",
            "enum": list(ALPHA_POLICIES),
            "description": "preserve=保留透明度；flatten_white=先铺白底再编码。透明图转 JPEG/HEIC 必须使用 flatten_white。",
        },
    },
    "required": ["operation", "input_id", "output_name"],
    "additionalProperties": False,
}

_OPERATION_FIELDS = {
    "convert": {"operation", "input_id", "output_name", "output_format", "alpha_policy"},
    "resize_fit": {
        "operation",
        "input_id",
        "output_name",
        "output_format",
        "max_dimension",
        "alpha_policy",
    },
    "resize_exact": {
        "operation",
        "input_id",
        "output_name",
        "output_format",
        "width",
        "height",
        "alpha_policy",
    },
    "crop": {
        "operation",
        "input_id",
        "output_name",
        "output_format",
        "width",
        "height",
        "offset_x",
        "offset_y",
        "alpha_policy",
    },
    "compress_jpeg": {
        "operation",
        "input_id",
        "output_name",
        "jpeg_quality",
        "alpha_policy",
    },
    "normalize_orientation": {
        "operation",
        "input_id",
        "output_name",
        "output_format",
        "alpha_policy",
    },
    "strip_metadata": {
        "operation",
        "input_id",
        "output_name",
        "output_format",
        "alpha_policy",
    },
}

_EXPECTED_NATIVE_CODES = {
    "INVALID_REQUEST",
    "INPUT_NOT_FOUND",
    "INPUT_TOO_LARGE",
    "UNSUPPORTED_MEDIA_TYPE",
    "UNSUPPORTED_OPERATION",
    "UNSUPPORTED_FORMAT",
    "INVALID_DIMENSIONS",
    "CROP_OUT_OF_BOUNDS",
    "INVALID_ALPHA_POLICY",
    "ALPHA_NOT_SUPPORTED_BY_OUTPUT",
    "INVALID_QUALITY",
    "PIXEL_LIMIT_EXCEEDED",
    "DECODE_COST_EXCEEDED",
    "DECODE_FAILED",
    "ENCODE_FAILED",
    "OUTPUT_TOO_LARGE",
}

_HELPER_LOCK = threading.Lock()
_CONTROL_OR_PATH = re.compile(r"[\\/\x00-\x1f\x7f:]")


class ImageOpsError(RuntimeError):
    def __init__(self, code: str, message: str, *, error_kind: str = "model_correctable") -> None:
        super().__init__(message)
        self.code = code
        self.error_kind = error_kind


class ImageOpsAdapter:
    source_kind = "task_material"

    def __init__(self, capability_id: str, tools: "ImageOpsToolSet", *, read_only: bool) -> None:
        self.capability_id = capability_id
        self.tools = tools
        self.read_only = read_only
        self.replay_safe = True
        self.execution_profile = ExecutionProfile(
            timeout_seconds=45,
            idempotency_mode="NATURAL_READ_ONLY" if read_only else "EXACT_INPUT",
            retry_mode="SAFE_WITH_SAME_KEY",
            verification_mode=(
                "IMAGE_SOURCE_READBACK" if read_only else "IMAGE_ARTIFACT_READBACK"
            ),
            reconciliation_mode="SAFE_REREAD" if read_only else "REPLAY_SAME_ATTEMPT",
            max_attempts=1 if read_only else 2,
            retry_backoff_seconds=1,
        )

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "source": {"kind": self.source_kind, "capability": self.capability_id},
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
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
            kind = output.get("error_kind")
            if kind == "model_correctable":
                outcome = "MODEL_CORRECTABLE_FAILURE"
            elif kind == "transient":
                outcome = "TRANSIENT_FAILURE"
            else:
                outcome = "TERMINAL_FAILURE"
            code = output.get("error_code")
            detail = error or "image operation failed"
            if isinstance(code, str) and code:
                detail = f"{code}: {detail}"
            return ExecutionVerification(outcome=outcome, error=detail)

        try:
            if self.capability_id == INSPECT_ID:
                observation = self.tools.verify_inspection_result(action, output)
                summary = None
            elif self.capability_id == TRANSFORM_ID:
                observation = self.tools.verify_transform_result(action, output)
                summary = _transform_completion_summary(observation)
            else:
                return ExecutionVerification(
                    outcome="TERMINAL_FAILURE",
                    error="unknown image capability adapter identity",
                )
        except ImageOpsError as exc:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=f"{exc.code}: {exc}",
            )
        except Exception as exc:
            return ExecutionVerification(
                outcome="TERMINAL_FAILURE",
                error=f"image verifier failed closed: {type(exc).__name__}",
            )

        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=summary,
        )


def _transform_completion_summary(observation: Dict[str, Any]) -> str:
    file_value = observation.get("file") if isinstance(observation.get("file"), dict) else {}
    readback = observation.get("readback") if isinstance(observation.get("readback"), dict) else {}
    verification = observation.get("verification") if isinstance(observation.get("verification"), dict) else {}
    name = file_value.get("name") if isinstance(file_value.get("name"), str) else "处理后的图片"
    fmt = str(readback.get("format") or observation.get("output_format") or "image").upper()
    width = readback.get("display_width")
    height = readback.get("display_height")
    dimensions = f"，{width}×{height} 像素" if isinstance(width, int) and isinstance(height, int) else ""
    operation = observation.get("operation")
    suffix = ""
    if observation.get("alpha_policy") == "flatten_white":
        composite = verification.get("white_composite") if isinstance(verification.get("white_composite"), dict) else {}
        if composite.get("verified") is True:
            suffix = "；透明区域已铺白色并核验"
    if operation == "strip_metadata" and readback.get("privacy_metadata_present") is False:
        suffix = "；隐私元数据已移除并核验"
    elif operation == "normalize_orientation" and readback.get("orientation") == 1:
        suffix = "；图片方向已归一化"
    return f"已生成 {name}（{fmt}{dimensions}{suffix}）。"


def _bounded_text(value: Any, *, field: str, maximum: int = 160) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise ImageOpsError("INVALID_PAYLOAD", f"{field} must be bounded non-empty text")
    return value.strip()


def _integer(value: Any, *, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ImageOpsError(
            "INVALID_PAYLOAD",
            f"{field} must be an integer in {minimum}..{maximum}",
        )
    return value


def _file_id(value: Any) -> str:
    text = _bounded_text(value, field="input_id", maximum=100)
    try:
        return TaskAssetStore.validate_id(text)
    except ValueError as exc:
        raise ImageOpsError("INVALID_PAYLOAD", "input_id is not a valid TaskAsset identifier") from exc


def _output_name(value: Any) -> str:
    text = _bounded_text(value, field="output_name", maximum=160)
    if text in {".", ".."} or _CONTROL_OR_PATH.search(text):
        raise ImageOpsError("INVALID_PAYLOAD", "output_name must be one safe filename, not a path")
    return text


def validate_inspect_arguments(arguments: Any) -> Dict[str, Any]:
    if not isinstance(arguments, dict):
        raise ImageOpsError("INVALID_PAYLOAD", "image.inspect arguments must be an object")
    if set(arguments) - {"input_id", "metadata_scope"}:
        raise ImageOpsError("INVALID_PAYLOAD", "image.inspect received unexpected fields")
    if "input_id" not in arguments:
        raise ImageOpsError("INVALID_PAYLOAD", "image.inspect requires input_id")
    scope = arguments.get("metadata_scope", "basic")
    if not isinstance(scope, str) or scope not in METADATA_SCOPES:
        raise ImageOpsError("INVALID_PAYLOAD", "metadata_scope is outside the supported enum")
    return {"input_id": _file_id(arguments["input_id"]), "metadata_scope": scope}


def validate_transform_arguments(arguments: Any) -> Dict[str, Any]:
    if not isinstance(arguments, dict):
        raise ImageOpsError("INVALID_PAYLOAD", "image.transform arguments must be an object")
    operation = arguments.get("operation")
    if not isinstance(operation, str) or operation not in TRANSFORM_OPERATIONS:
        raise ImageOpsError("INVALID_PAYLOAD", "operation is outside the supported enum")
    expected_fields = _OPERATION_FIELDS[operation]
    actual_fields = set(arguments)
    missing = expected_fields - actual_fields
    extra = actual_fields - expected_fields
    if missing or extra:
        detail = []
        if missing:
            detail.append("missing=" + ",".join(sorted(missing)))
        if extra:
            detail.append("unexpected=" + ",".join(sorted(extra)))
        raise ImageOpsError(
            "INVALID_PAYLOAD",
            f"{operation} fields do not match operation contract ({'; '.join(detail)})",
        )

    normalized: Dict[str, Any] = {
        "operation": operation,
        "input_id": _file_id(arguments["input_id"]),
        "output_name": _output_name(arguments["output_name"]),
    }
    alpha_policy = arguments.get("alpha_policy")
    if not isinstance(alpha_policy, str) or alpha_policy not in ALPHA_POLICIES:
        raise ImageOpsError("INVALID_PAYLOAD", "alpha_policy is outside the supported enum")
    normalized["alpha_policy"] = alpha_policy

    if operation != "compress_jpeg":
        output_format = arguments.get("output_format")
        if not isinstance(output_format, str) or output_format not in OUTPUT_FORMATS:
            raise ImageOpsError("INVALID_PAYLOAD", "output_format is outside the supported enum")
        normalized["output_format"] = output_format
    else:
        normalized["jpeg_quality"] = _integer(
            arguments.get("jpeg_quality"),
            field="jpeg_quality",
            minimum=MIN_JPEG_QUALITY,
            maximum=MAX_JPEG_QUALITY,
        )

    if operation == "resize_fit":
        normalized["max_dimension"] = _integer(
            arguments.get("max_dimension"),
            field="max_dimension",
            minimum=1,
            maximum=MAX_OUTPUT_SIDE,
        )
    elif operation in {"resize_exact", "crop"}:
        width = _integer(arguments.get("width"), field="width", minimum=1, maximum=MAX_OUTPUT_SIDE)
        height = _integer(arguments.get("height"), field="height", minimum=1, maximum=MAX_OUTPUT_SIDE)
        if width * height > MAX_PIXELS:
            raise ImageOpsError("INVALID_PAYLOAD", "requested output pixel count exceeds bounded limit")
        normalized["width"] = width
        normalized["height"] = height
        if operation == "crop":
            normalized["offset_x"] = _integer(
                arguments.get("offset_x"),
                field="offset_x",
                minimum=0,
                maximum=MAX_SIDE,
            )
            normalized["offset_y"] = _integer(
                arguments.get("offset_y"),
                field="offset_y",
                minimum=0,
                maximum=MAX_SIDE,
            )

    # Direct-dispatch validation is complete before TaskAsset/file access.
    # A filename extension that contradicts the declared codec is a malformed
    # payload, not an input lookup failure discovered later in execution.
    normalized["output_name"] = _canonical_output_name(
        normalized["output_name"],
        _format_for(normalized),
    )
    return normalized


def _format_for(arguments: Mapping[str, Any]) -> str:
    return "jpeg" if arguments["operation"] == "compress_jpeg" else str(arguments["output_format"])


def _canonical_output_name(name: str, output_format: str) -> str:
    suffix = Path(name).suffix.lower()
    accepted = FORMAT_ACCEPTED_SUFFIXES[output_format]
    if suffix and suffix not in accepted:
        raise ImageOpsError(
            "INVALID_PAYLOAD",
            f"output_name suffix does not match output_format={output_format}",
        )
    if not suffix:
        name += FORMAT_SUFFIXES[output_format]
    return safe_name(name)


def _stable_output_id(task_id: str, action_id: str, media_type: str) -> str:
    digest = hashlib.sha256(f"{task_id}:{action_id}:{media_type}".encode()).hexdigest()[:32]
    return "out_" + digest


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _compile_helper(helper_source: Path, runtime_dir: Path) -> Path:
    helper_source = helper_source.expanduser().resolve()
    runtime_dir = runtime_dir.expanduser().resolve()
    if not helper_source.is_file():
        raise ImageOpsError("TOOL_UNAVAILABLE", "ImageOps native helper source is missing", error_kind="terminal")
    if not Path("/usr/bin/xcrun").is_file():
        raise ImageOpsError("TOOL_UNAVAILABLE", "xcrun is unavailable", error_kind="terminal")
    runtime_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(helper_source.read_bytes()).hexdigest()[:16]
    binary = runtime_dir / f"ImageOpsHelper-{digest}"
    with _HELPER_LOCK:
        if binary.is_file() and os.access(binary, os.X_OK):
            return binary
        temp = binary.with_name(binary.name + ".building")
        temp.unlink(missing_ok=True)
        try:
            completed = subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "swiftc",
                    "-O",
                    str(helper_source),
                    "-framework",
                    "Foundation",
                    "-framework",
                    "CoreGraphics",
                    "-framework",
                    "ImageIO",
                    "-framework",
                    "UniformTypeIdentifiers",
                    "-o",
                    str(temp),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=90,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise ImageOpsError("TOOL_UNAVAILABLE", "ImageOps native helper compile timed out", error_kind="terminal") from exc
        if completed.returncode != 0:
            raise ImageOpsError("TOOL_UNAVAILABLE", "ImageOps native helper failed to compile", error_kind="terminal")
        temp.replace(binary)
        binary.chmod(0o700)
    return binary


def _parse_native_response(stdout: bytes) -> Dict[str, Any]:
    try:
        value = json.loads(stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ImageOpsError("NATIVE_FAILURE", "native helper returned invalid JSON", error_kind="terminal") from exc
    if not isinstance(value, dict):
        raise ImageOpsError("NATIVE_FAILURE", "native helper returned non-object JSON", error_kind="terminal")
    return value


def _native_call(binary: Path, request: Mapping[str, Any]) -> Dict[str, Any]:
    payload = json.dumps(dict(request), separators=(",", ":")).encode("utf-8")
    try:
        completed = subprocess.run(
            [str(binary)],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=40,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise ImageOpsError("TIMEOUT", "image native helper timed out", error_kind="transient") from exc
    value = _parse_native_response(completed.stdout)
    if completed.returncode == 0 and value.get("ok") is True and isinstance(value.get("result"), dict):
        return dict(value["result"])
    error = value.get("error")
    if isinstance(error, dict):
        code = error.get("code") if isinstance(error.get("code"), str) else "NATIVE_FAILURE"
        message = error.get("message") if isinstance(error.get("message"), str) else "native image operation failed"
    else:
        code = "NATIVE_FAILURE"
        message = "native image operation failed"
    kind = "model_correctable" if code in _EXPECTED_NATIVE_CODES else "terminal"
    raise ImageOpsError(code, message[:400], error_kind=kind)


def _native_request(input_path: Path) -> Dict[str, Any]:
    return {
        "input_path": str(input_path),
        "max_input_bytes": MAX_INPUT_BYTES,
        "max_output_bytes": MAX_OUTPUT_BYTES,
        "max_pixels": MAX_PIXELS,
        "max_decode_bytes": MAX_DECODE_BYTES,
        "max_side": MAX_SIDE,
    }


def _validate_inspection_shape(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "native inspection is not an object", error_kind="terminal")
    required = {
        "format",
        "type_identifier",
        "pixel_width",
        "pixel_height",
        "display_width",
        "display_height",
        "orientation",
        "has_alpha",
        "file_size",
        "pixel_count",
        "decode_cost_bytes",
        "privacy_metadata_present",
        "privacy_metadata_fields",
    }
    if not required.issubset(value):
        raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "native inspection fields are incomplete", error_kind="terminal")
    if value.get("format") not in OUTPUT_FORMATS:
        raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "native inspection format is unsupported", error_kind="terminal")
    for key in (
        "pixel_width",
        "pixel_height",
        "display_width",
        "display_height",
        "orientation",
        "file_size",
        "pixel_count",
        "decode_cost_bytes",
    ):
        if isinstance(value.get(key), bool) or not isinstance(value.get(key), int):
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", f"native inspection {key} is invalid", error_kind="terminal")
    if not isinstance(value.get("has_alpha"), bool) or not isinstance(value.get("privacy_metadata_present"), bool):
        raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "native inspection booleans are invalid", error_kind="terminal")
    privacy = value.get("privacy_metadata_fields")
    if not isinstance(privacy, list) or any(not isinstance(item, str) for item in privacy):
        raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "privacy metadata flags are invalid", error_kind="terminal")
    return dict(value)


def _bounded_readback(value: Mapping[str, Any], *, scope: str = "technical") -> Dict[str, Any]:
    basic_keys = {
        "format",
        "pixel_width",
        "pixel_height",
        "display_width",
        "display_height",
        "orientation",
        "has_alpha",
        "file_size",
        "pixel_count",
        "decode_cost_bytes",
    }
    privacy_keys = {
        "has_exif",
        "has_gps",
        "has_tiff",
        "has_iptc",
        "privacy_metadata_present",
        "privacy_metadata_fields",
    }
    technical_keys = {"type_identifier", "dpi_width", "dpi_height", "depth", "color_model"}
    keys = set(basic_keys)
    if scope in {"privacy_flags", "technical"}:
        keys.update(privacy_keys)
    if scope == "technical":
        keys.update(technical_keys)
    return {key: value[key] for key in sorted(keys) if key in value}


class ImageOpsToolSet:
    def __init__(
        self,
        assets: TaskAssetStore,
        *,
        runtime_dir: Path,
        helper_source: Optional[Path] = None,
        binary: Optional[Path] = None,
    ) -> None:
        self.assets = assets
        self.runtime_dir = runtime_dir.expanduser().resolve()
        self.helper_source = (
            helper_source.expanduser().resolve()
            if helper_source is not None
            else Path(__file__).resolve().parents[1] / "native_helpers" / "ImageOpsHelper.swift"
        )
        self.binary = binary or _compile_helper(self.helper_source, self.runtime_dir)

    def _input(self, dispatch: Mapping[str, Any], input_id: str) -> Tuple[Path, Dict[str, Any], str]:
        task_id = dispatch.get("task_id")
        action_id = dispatch.get("action_id")
        if not isinstance(task_id, str) or not task_id or not isinstance(action_id, str) or not action_id:
            raise ImageOpsError("INVALID_DISPATCH", "Runtime dispatch identity is missing", error_kind="terminal")
        try:
            path = self.assets.file_path(task_id, input_id)
            item = self.assets.get(input_id)
        except (KeyError, ValueError) as exc:
            raise ImageOpsError("INPUT_NOT_FOUND", "input image is not available to this Task") from exc
        media_type = item.get("media_type")
        if media_type not in SUPPORTED_INPUT_MEDIA_TYPES:
            raise ImageOpsError("UNSUPPORTED_MEDIA_TYPE", "input TaskAsset is not a supported image")
        size = path.stat().st_size
        if not 0 < size <= MAX_INPUT_BYTES:
            raise ImageOpsError("INPUT_TOO_LARGE", "input image exceeds the bounded byte limit")
        digest = _sha256(path)
        if digest != item.get("sha256"):
            raise ImageOpsError("INPUT_INTEGRITY_FAILED", "input TaskAsset hash changed", error_kind="terminal")
        return path, item, digest

    def _inspect_native(self, path: Path) -> Dict[str, Any]:
        request = {"command": "inspect", **_native_request(path)}
        native = _native_call(self.binary, request)
        return _validate_inspection_shape(native.get("inspection"))

    def inspect(self, dispatch: Dict[str, Any], arguments: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_inspect_arguments(arguments)
        path, item, before_hash = self._input(dispatch, args["input_id"])
        inspection = self._inspect_native(path)
        after_hash = _sha256(path)
        if after_hash != before_hash:
            raise ImageOpsError("INPUT_INTEGRITY_FAILED", "image inspect modified source bytes", error_kind="terminal")
        if inspection["file_size"] != item["size_bytes"]:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image byte-size readback mismatches TaskAsset", error_kind="terminal")
        expected_format = SUPPORTED_INPUT_MEDIA_TYPES[item["media_type"]]
        if inspection["format"] != expected_format:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image codec readback mismatches TaskAsset media type", error_kind="terminal")
        return {
            "input_id": args["input_id"],
            "sha256": before_hash,
            "size_bytes": item["size_bytes"],
            "metadata_scope": args["metadata_scope"],
            "readback": _bounded_readback(inspection, scope=args["metadata_scope"]),
            "verified": True,
            "engine": "ImageIO/CoreGraphics",
        }

    def _transform_request(
        self,
        *,
        input_path: Path,
        output_path: Path,
        args: Mapping[str, Any],
        command: str,
    ) -> Dict[str, Any]:
        return {
            "command": command,
            **_native_request(input_path),
            "output_path": str(output_path),
            **{key: value for key, value in args.items() if key not in {"input_id", "output_name"}},
        }

    def _native_verify_transform(
        self,
        *,
        input_path: Path,
        output_path: Path,
        args: Mapping[str, Any],
    ) -> Dict[str, Any]:
        value = _native_call(
            self.binary,
            self._transform_request(
                input_path=input_path,
                output_path=output_path,
                args=args,
                command="verify_transform",
            ),
        )
        if value.get("verified") is not True or not isinstance(value.get("checks"), dict):
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image transform failed deterministic readback", error_kind="terminal")
        readback = _validate_inspection_shape(value.get("readback"))
        return {
            "verified": True,
            "checks": {str(key): bool(item) for key, item in value["checks"].items()},
            "readback": _bounded_readback(readback, scope="technical"),
            "white_composite": value.get("white_composite") if isinstance(value.get("white_composite"), dict) else None,
            "method": "imageio_operation_readback",
            "integrity_scope": "source_hash+artifact_hash+codec+dimensions+orientation+alpha+privacy_metadata",
        }

    def _existing_output(
        self,
        *,
        dispatch: Mapping[str, Any],
        fid: str,
        suffix: str,
        args: Mapping[str, Any],
        input_path: Path,
        input_hash: str,
        media_type: str,
    ) -> Optional[Dict[str, Any]]:
        try:
            item = self.assets.get(fid)
        except KeyError:
            return None
        task_id = str(dispatch["task_id"])
        action_id = str(dispatch["action_id"])
        try:
            output_path = self.assets.verify_unit_file(task_id, action_id, fid)
        except (KeyError, ValueError) as exc:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "existing image artifact identity/integrity mismatches Action", error_kind="terminal") from exc
        metadata = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
        if (
            item.get("media_type") != media_type
            or metadata.get("action_id") != action_id
            or metadata.get("input_id") != args["input_id"]
            or metadata.get("input_sha256") != input_hash
            or metadata.get("operation") != args["operation"]
        ):
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "existing image artifact provenance mismatches Action", error_kind="terminal")
        verification = self._native_verify_transform(
            input_path=input_path,
            output_path=output_path,
            args=args,
        )
        output_hash = _sha256(output_path)
        if output_hash != item.get("sha256"):
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "existing image artifact hash mismatches manifest", error_kind="terminal")
        return self._result(
            item=item,
            args=args,
            input_hash=input_hash,
            output_hash=output_hash,
            verification=verification,
            replayed=True,
        )

    def transform(self, dispatch: Dict[str, Any], arguments: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_transform_arguments(arguments)
        input_path, _, input_hash = self._input(dispatch, args["input_id"])
        output_format = _format_for(args)
        media_type = FORMAT_MEDIA_TYPES[output_format]
        suffix = FORMAT_SUFFIXES[output_format]
        name = _canonical_output_name(args["output_name"], output_format)
        task_id = str(dispatch["task_id"])
        action_id = str(dispatch["action_id"])
        fid = _stable_output_id(task_id, action_id, media_type)

        existing = self._existing_output(
            dispatch=dispatch,
            fid=fid,
            suffix=suffix,
            args=args,
            input_path=input_path,
            input_hash=input_hash,
            media_type=media_type,
        )
        if existing is not None:
            return existing

        with tempfile.TemporaryDirectory(prefix="image-ops-", dir=str(self.runtime_dir)) as temp:
            output_path = Path(temp) / ("output" + suffix)
            native = _native_call(
                self.binary,
                self._transform_request(
                    input_path=input_path,
                    output_path=output_path,
                    args=args,
                    command="transform",
                ),
            )
            if native.get("operation") != args["operation"] or native.get("output_format") != output_format:
                raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "native transform provenance mismatch", error_kind="terminal")
            if _sha256(input_path) != input_hash:
                raise ImageOpsError("INPUT_INTEGRITY_FAILED", "image transform modified source bytes", error_kind="terminal")
            verification = self._native_verify_transform(
                input_path=input_path,
                output_path=output_path,
                args=args,
            )
            data = output_path.read_bytes()
            if not data or len(data) > MAX_OUTPUT_BYTES:
                raise ImageOpsError("OUTPUT_TOO_LARGE", "image output exceeds bounded byte limit")
            output_hash = hashlib.sha256(data).hexdigest()
            readback = verification["readback"]
            metadata_status = (
                "privacy_fields_present"
                if readback.get("privacy_metadata_present") is True
                else "privacy_fields_absent"
            )
            item = self.assets._save(
                file_id=fid,
                name=name,
                media_type=media_type,
                data=data,
                suffix=suffix,
                task_id=task_id,
                category="image",
                metadata={
                    "action_id": action_id,
                    "input_id": args["input_id"],
                    "input_sha256": input_hash,
                    "operation": args["operation"],
                    "output_format": output_format,
                    "alpha_policy": args["alpha_policy"],
                    "metadata_status": metadata_status,
                    "verification_scope": "image_structure_and_operation_invariants",
                    "status": "ready",
                    "label": "图片已处理 · 已完成确定性读回核验",
                },
            )

        stored_path = self.assets.verify_unit_file(task_id, action_id, fid)
        if _sha256(stored_path) != output_hash or item.get("sha256") != output_hash:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "stored image artifact hash mismatch", error_kind="terminal")
        return self._result(
            item=item,
            args=args,
            input_hash=input_hash,
            output_hash=output_hash,
            verification=verification,
            replayed=False,
        )

    @staticmethod
    def _result(
        *,
        item: Dict[str, Any],
        args: Mapping[str, Any],
        input_hash: str,
        output_hash: str,
        verification: Dict[str, Any],
        replayed: bool,
    ) -> Dict[str, Any]:
        return {
            "file": item,
            "input_id": args["input_id"],
            "input_sha256": input_hash,
            "output_sha256": output_hash,
            "operation": args["operation"],
            "output_format": _format_for(args),
            "alpha_policy": args["alpha_policy"],
            "readback": verification["readback"],
            "verification": verification,
            "replayed_artifact": replayed,
            "verified": True,
            "engine": "ImageIO/CoreGraphics",
        }

    def verify_inspection_result(self, action: Dict[str, Any], output: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_inspect_arguments(action.get("payload"))
        path, item, digest = self._input(action, args["input_id"])
        fresh = self._inspect_native(path)
        if output.get("input_id") != args["input_id"] or output.get("sha256") != digest:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.inspect result identity/hash mismatch", error_kind="terminal")
        if output.get("size_bytes") != item.get("size_bytes") or _sha256(path) != digest:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.inspect source changed before verification", error_kind="terminal")
        expected = _bounded_readback(fresh, scope=args["metadata_scope"])
        if output.get("readback") != expected:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.inspect readback mismatch", error_kind="terminal")
        return {
            "capability": INSPECT_ID,
            "input_id": args["input_id"],
            "sha256": digest,
            "size_bytes": item["size_bytes"],
            "metadata_scope": args["metadata_scope"],
            "readback": expected,
            "verification": {
                "method": "imageio_source_readback",
                "integrity_scope": "task_asset_hash+codec+dimensions+orientation+alpha+bounded_metadata_flags",
            },
        }

    def verify_transform_result(self, action: Dict[str, Any], output: Dict[str, Any]) -> Dict[str, Any]:
        args = validate_transform_arguments(action.get("payload"))
        input_path, _, input_hash = self._input(action, args["input_id"])
        if output.get("input_sha256") != input_hash or output.get("operation") != args["operation"]:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.transform result provenance mismatch", error_kind="terminal")
        output_format = _format_for(args)
        media_type = FORMAT_MEDIA_TYPES[output_format]
        fid = _stable_output_id(str(action["task_id"]), str(action["action_id"]), media_type)
        file_value = output.get("file")
        if not isinstance(file_value, dict) or file_value.get("id") != fid or file_value.get("media_type") != media_type:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.transform artifact descriptor mismatch", error_kind="terminal")
        try:
            output_path = self.assets.verify_unit_file(str(action["task_id"]), str(action["action_id"]), fid)
        except (KeyError, ValueError) as exc:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.transform artifact is not bound to exact Task/Action", error_kind="terminal") from exc
        output_hash = _sha256(output_path)
        if output.get("output_sha256") != output_hash or file_value.get("sha256") != output_hash:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.transform artifact hash mismatch", error_kind="terminal")
        verification = self._native_verify_transform(
            input_path=input_path,
            output_path=output_path,
            args=args,
        )
        if output.get("readback") != verification["readback"]:
            raise ImageOpsError("OUTPUT_VERIFICATION_FAILED", "image.transform machine readback mismatch", error_kind="terminal")
        return {
            "capability": TRANSFORM_ID,
            "file": file_value,
            "input_id": args["input_id"],
            "input_sha256": input_hash,
            "output_sha256": output_hash,
            "operation": args["operation"],
            "output_format": output_format,
            "alpha_policy": args["alpha_policy"],
            "readback": verification["readback"],
            "verification": verification,
        }


def readiness(
    *,
    runtime_dir: Path,
    helper_source: Optional[Path] = None,
) -> Dict[str, Any]:
    source = (
        helper_source.expanduser().resolve()
        if helper_source is not None
        else Path(__file__).resolve().parents[1] / "native_helpers" / "ImageOpsHelper.swift"
    )
    try:
        binary = _compile_helper(source, runtime_dir)
    except ImageOpsError as exc:
        return {
            "ready": False,
            "reason": exc.code,
            "network": False,
            "credentials": False,
            "new_dependencies": False,
        }
    return {
        "ready": True,
        "binary": str(binary),
        "engine": "ImageIO/CoreGraphics",
        "network": False,
        "credentials": False,
        "new_dependencies": False,
        "limits": {
            "max_input_bytes": MAX_INPUT_BYTES,
            "max_output_bytes": MAX_OUTPUT_BYTES,
            "max_pixels": MAX_PIXELS,
            "max_decode_bytes": MAX_DECODE_BYTES,
            "max_output_side": MAX_OUTPUT_SIDE,
            "jpeg_quality": [MIN_JPEG_QUALITY, MAX_JPEG_QUALITY],
        },
        "unsupported": [
            "semantic_or_generative_edit",
            "raw_development",
            "professional_color_fidelity_guarantee",
            "exact_byte_budget_compression",
        ],
    }


def register_image_ops_capabilities(
    registry: CapabilityRegistry,
    *,
    assets: TaskAssetStore,
    runtime_dir: Path,
    helper_source: Optional[Path] = None,
) -> Tuple[Dict[str, TaskScopedFunction], Dict[str, Any]]:
    health = readiness(runtime_dir=runtime_dir, helper_source=helper_source)
    if health.get("ready") is not True:
        return {}, health
    tools = ImageOpsToolSet(
        assets,
        runtime_dir=runtime_dir,
        helper_source=helper_source,
        binary=Path(str(health["binary"])),
    )

    inspect_spec = CapabilitySpec(
        name=INSPECT_ID,
        description=(
            "查看/告诉用户本任务一张图片的格式、尺寸、宽高、方向/EXIF orientation、是否透明/alpha，"
            "以及有界 metadata 隐私标记；不识别物体或语义内容，不返回 GPS 坐标或身份元数据值。"
        ),
        arguments_schema=INSPECT_SCHEMA,
        post_verify_mode="REPLAN_REQUIRED",
    )
    transform_spec = CapabilitySpec(
        name=TRANSFORM_ID,
        description=(
            "对本任务图片执行确定性处理：转成/转换/导出 JPEG、PNG、TIFF、HEIC；缩小/缩放到指定最长边；"
            "精确改尺寸；从左上角坐标裁剪/裁掉/裁出指定像素区域；JPEG quality 压缩；方向归一化；"
            "去掉/去除 metadata/元数据。只接受声明字段；alpha 必须显式 preserve 或 flatten_white。"
            "不做语义/生成式编辑，不承诺 RAW/专业色彩保真或精确目标字节数。"
        ),
        arguments_schema=TRANSFORM_SCHEMA,
        post_verify_mode="COMPLETE_ALLOWED",
    )

    registry.register(
        RegisteredCapability(
            spec=inspect_spec,
            adapter=ImageOpsAdapter(INSPECT_ID, tools, read_only=True),
            source=CapabilitySourceTarget(
                kind="task_material",
                tool_name=INSPECT_ID,
                metadata={
                    "execution_plane": "host",
                    "foreground_policy": "background_only",
                    "read_only": True,
                    "effect": "read",
                    "operation": "read",
                    "domains": ["media", "files"],
                    "deterministic": True,
                    "network": False,
                    "verification": "imageio_source_readback",
                },
            ),
            tags=("image", "inspect", "metadata", "orientation", "alpha", "read"),
            loading="always_visible",
        )
    )
    registry.register(
        RegisteredCapability(
            spec=transform_spec,
            adapter=ImageOpsAdapter(TRANSFORM_ID, tools, read_only=False),
            source=CapabilitySourceTarget(
                kind="task_material",
                tool_name=TRANSFORM_ID,
                metadata={
                    "execution_plane": "host",
                    "foreground_policy": "background_only",
                    "read_only": False,
                    "effect": "local_file",
                    "operation": "write",
                    "domains": ["media", "files"],
                    "deterministic": True,
                    "network": False,
                    "verification": "imageio_artifact_readback",
                },
            ),
            tags=(
                "image",
                "transform",
                "convert",
                "resize",
                "crop",
                "compress",
                "orientation",
                "metadata",
                "write",
            ),
            loading="always_visible",
        )
    )

    def wrap(function):
        def scoped(dispatch: Dict[str, Any], args: Dict[str, Any]) -> Dict[str, Any]:
            try:
                return function(dispatch, args)
            except ImageOpsError as exc:
                raise FunctionToolError(
                    str(exc),
                    error_kind=exc.error_kind,
                    output={"error_code": exc.code},
                ) from exc
            except (KeyError, ValueError, TypeError) as exc:
                raise FunctionToolError(
                    "image operation rejected malformed direct payload",
                    error_kind="model_correctable",
                    output={"error_code": "INVALID_PAYLOAD"},
                ) from exc
        return TaskScopedFunction(scoped)

    return {
        INSPECT_ID: wrap(tools.inspect),
        TRANSFORM_ID: wrap(tools.transform),
    }, health
