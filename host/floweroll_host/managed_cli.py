from __future__ import annotations

import json
import os
import re
from .bounded_process import run_bounded, ProcessOutputLimitError
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional

from .function_execution_worker import FunctionToolError


class ManagedJSONCLI:
    """Bounded JSON CLI runner for provider-owned agent CLIs.

    The Planner never receives a shell. Callers pass a fixed argv prefix plus
    whitelisted values. `shell=False`, timeout/output bounds, JSON-only result
    parsing and a minimal environment keep this source narrow and auditable.
    """

    def __init__(
        self,
        executable: Path,
        *,
        timeout_seconds: float = 20.0,
        max_output_bytes: int = 512_000,
        extra_env: Optional[Mapping[str, str]] = None,
        cwd: Optional[Path] = None,
    ) -> None:
        path = executable.expanduser().resolve()
        if not path.is_file():
            raise FileNotFoundError(path)
        self.executable = path
        self.timeout_seconds = float(timeout_seconds)
        self.max_output_bytes = int(max_output_bytes)
        self.extra_env = dict(extra_env or {})
        if self.timeout_seconds <= 0 or self.max_output_bytes < 1:
            raise ValueError("CLI resource limits must be positive")
        self.cwd = (cwd or Path(__file__).resolve().parents[2] / "work" / "provider-cli").resolve()
        self.cwd.mkdir(parents=True, exist_ok=True)

    def run_json(self, argv: Iterable[str]) -> Any:
        command = [str(self.executable), *[str(item) for item in argv]]
        allowed = {"HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM"}
        env = {key: value for key,value in os.environ.items() if key in allowed}
        env.update(self.extra_env)
        try:
            returncode, stdout, stderr = run_bounded(command, cwd=self.cwd, env=env,
                timeout=self.timeout_seconds, stdout_limit=self.max_output_bytes,
                stderr_limit=min(self.max_output_bytes,32_000))
        except TimeoutError as exc:
            raise FunctionToolError("provider CLI timed out", error_kind="transient") from exc
        except ProcessOutputLimitError as exc:
            raise FunctionToolError("provider CLI output exceeds the safe limit; narrow the query",
                                    error_kind="model_correctable") from exc
        payload = self._parse_json(stdout)
        business_failed = isinstance(payload,dict) and (
            payload.get("ok") is False or payload.get("success") is False)
        if returncode != 0 or business_failed:
            message = self._error_message(payload, stderr)
            # Never persist accidentally echoed provider credentials in failure traces.
            for key,value in self.extra_env.items():
                if value and any(word in key.upper() for word in ("KEY","TOKEN","SECRET","PASSWORD")):
                    message=message.replace(value,"[REDACTED]")
            message=re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+",r"\1[REDACTED]",message)
            kind = self._error_kind(payload, message)
            raise FunctionToolError(message[:1000], error_kind=kind,
                                    output={"cli_exit_code":returncode,"business_error":business_failed})
        if payload is None:
            raise FunctionToolError("provider CLI returned non-JSON output")
        bounded, value_truncated = _bounded_json(payload)
        return {"data": bounded, "truncated": value_truncated}

    @staticmethod
    def _parse_json(raw: bytes) -> Any:
        if not raw.strip():
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None

    @staticmethod
    def _error_message(payload: Any, stderr: bytes) -> str:
        if isinstance(payload, dict):
            error = payload.get("error")
            if isinstance(error, dict):
                message = error.get("message")
                subtype = error.get("subtype")
                if isinstance(message, str) and message.strip():
                    return f"{subtype}: {message}" if isinstance(subtype, str) else message
            message = payload.get("message")
            if isinstance(message, str) and message.strip():
                return message
        safe = stderr.decode("utf-8", errors="replace").strip()
        return safe[:1000] or "provider CLI failed"

    @staticmethod
    def _error_kind(payload: Any, message: str) -> str:
        lowered = message.lower()
        if isinstance(payload, dict):
            error = payload.get("error")
            subtype = error.get("subtype") if isinstance(error, dict) else None
            if subtype in {"not_configured", "not_authenticated", "token_expired", "insufficient_scope"}:
                return "terminal"
        if any(token in lowered for token in ("timeout", "temporar", "rate limit", "429", "503", "502")):
            return "transient"
        if any(token in lowered for token in ("invalid", "missing", "required", "not found", "bad request")):
            return "model_correctable"
        return "terminal"


def _bounded_json(value: Any, *, depth: int = 0) -> tuple[Any, bool]:
    if value is None or isinstance(value, (bool, int, float)):
        return value, False
    if isinstance(value, str):
        return (value[:20_000], len(value) > 20_000)
    if depth >= 6:
        return "[bounded]", True
    if isinstance(value, list):
        truncated = len(value) > 100
        result: List[Any] = []
        for item in value[:100]:
            bounded, item_truncated = _bounded_json(item, depth=depth + 1)
            result.append(bounded)
            truncated = truncated or item_truncated
        return result, truncated
    if isinstance(value, dict):
        items = list(value.items())
        truncated = len(items) > 100
        result: Dict[str, Any] = {}
        for key, item in items[:100]:
            bounded, item_truncated = _bounded_json(item, depth=depth + 1)
            result[str(key)[:200]] = bounded
            truncated = truncated or item_truncated
        return result, truncated
    text = str(value)
    return text[:4000], len(text) > 4000
