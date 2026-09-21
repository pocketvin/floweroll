from __future__ import annotations

import ipaddress
import json
import socket
import urllib.parse
from typing import Any, Dict, Tuple

import urllib3

from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .function_execution_worker import FunctionExecutor, FunctionToolError
from .function_tool_adapter import FunctionToolAdapter
from .planner_contracts import CapabilitySpec


_MAX_BYTES = 512_000
_MAX_CHARS = 40_000


class _PinnedHTTPSClient:
    """Connect to an already-validated IP while preserving TLS hostname checks."""

    def request(
        self,
        *,
        address: str,
        hostname: str,
        port: int,
        target: str,
        host_header: str,
        timeout: float,
    ) -> tuple[int, str, bytes]:
        pool = urllib3.HTTPSConnectionPool(
            address,
            port=port,
            timeout=timeout,
            maxsize=1,
            block=True,
            retries=False,
            cert_reqs="CERT_REQUIRED",
            assert_hostname=hostname,
            server_hostname=hostname,
        )
        try:
            response = pool.urlopen(
                "GET",
                target,
                headers={
                    "Accept": "application/json, text/plain, text/html;q=0.9, */*;q=0.5",
                    "User-Agent": "floweroll-host/0.1",
                    "Host": host_header,
                },
                redirect=False,
                retries=False,
                assert_same_host=False,
                preload_content=False,
            )
            try:
                status = int(response.status)
                content_type = str(
                    response.headers.get("Content-Type", "application/octet-stream")
                )
                raw = response.read(_MAX_BYTES + 1)
                return status, content_type, raw
            finally:
                response.release_conn()
        finally:
            pool.close()


class PublicHTTPToolSet:
    """Small read-only direct HTTP/API surface with SSRF guards."""

    def __init__(self, *, resolver=None, transport=None) -> None:
        self._resolver = resolver or socket.getaddrinfo
        self._transport = transport or _PinnedHTTPSClient()

    def fetch(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        url = arguments.get("url")
        if not isinstance(url, str) or not url.strip():
            raise FunctionToolError(
                "url must be a non-empty string",
                error_kind="model_correctable",
            )
        (
            normalized,
            hostname,
            port,
            addresses,
            target,
            host_header,
        ) = self._validate_public_https(url.strip())
        status, content_type, raw = self._request_validated_addresses(
            addresses=addresses,
            hostname=hostname,
            port=port,
            target=target,
            host_header=host_header,
        )
        if status in {301, 302, 303, 307, 308}:
            raise FunctionToolError(
                "web.fetch does not follow redirects; provide the final HTTPS URL",
                error_kind="model_correctable",
                output={"status": status},
            )
        if status == 429 or 500 <= status <= 599:
            raise FunctionToolError(
                f"HTTP {status}",
                error_kind="transient",
                output={"status": status},
            )
        if status < 200 or status >= 400:
            raise FunctionToolError(
                f"HTTP {status}",
                error_kind="model_correctable",
                output={"status": status},
            )

        truncated_bytes = len(raw) > _MAX_BYTES
        raw = raw[:_MAX_BYTES]
        charset = _charset_from_content_type(content_type) or "utf-8"
        text = raw.decode(charset, errors="replace")
        truncated_chars = len(text) > _MAX_CHARS
        text = text[:_MAX_CHARS]
        result: Dict[str, Any] = {
            "url": normalized,
            "status": status,
            "content_type": content_type,
            "text": text,
            "truncated": truncated_bytes or truncated_chars,
            "_completion_summary": f"已读取公网 HTTPS 资源（HTTP {status}）。",
        }
        if "json" in content_type.lower():
            try:
                result["json"] = _bounded_json(json.loads(text))
            except json.JSONDecodeError:
                pass
        return result

    def _request_validated_addresses(
        self,
        *,
        addresses: tuple[str, ...],
        hostname: str,
        port: int,
        target: str,
        host_header: str,
    ) -> tuple[int, str, bytes]:
        last_error: Exception | None = None
        for address in addresses:
            try:
                return self._transport.request(
                    address=address,
                    hostname=hostname,
                    port=port,
                    target=target,
                    host_header=host_header,
                    timeout=15,
                )
            except (urllib3.exceptions.HTTPError, OSError, TimeoutError) as exc:
                last_error = exc
        error_type = type(last_error).__name__ if last_error is not None else "NetworkError"
        raise FunctionToolError(
            f"network error: {error_type}",
            error_kind="transient",
        ) from last_error

    def _validate_public_https(
        self,
        url: str,
    ) -> tuple[str, str, int, tuple[str, ...], str, str]:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme.lower() != "https" or not parsed.hostname:
            raise FunctionToolError(
                "web.fetch only accepts absolute public HTTPS URLs",
                error_kind="model_correctable",
            )
        if parsed.username is not None or parsed.password is not None:
            raise FunctionToolError(
                "credentials in URLs are not allowed",
                error_kind="model_correctable",
            )
        try:
            port = parsed.port or 443
        except ValueError as exc:
            raise FunctionToolError(
                "URL contains an invalid port",
                error_kind="model_correctable",
            ) from exc
        try:
            answers = self._resolver(parsed.hostname, port, type=socket.SOCK_STREAM)
        except OSError as exc:
            raise FunctionToolError(
                "could not resolve URL host",
                error_kind="transient",
            ) from exc
        addresses = {answer[4][0] for answer in answers if answer and len(answer) >= 5}
        if not addresses:
            raise FunctionToolError(
                "URL host resolved to no address",
                error_kind="transient",
            )
        for raw_ip in addresses:
            try:
                ip = ipaddress.ip_address(raw_ip)
            except ValueError as exc:
                raise FunctionToolError("URL host resolved to an invalid address") from exc
            if not ip.is_global:
                raise FunctionToolError(
                    "private, loopback, link-local, multicast, or reserved network targets are not allowed",
                    error_kind="model_correctable",
                )

        normalized = urllib.parse.urlunsplit(
            ("https", parsed.netloc, parsed.path or "/", parsed.query, "")
        )
        target = urllib.parse.urlunsplit(
            ("", "", parsed.path or "/", parsed.query, "")
        )
        hostname = parsed.hostname
        host_header = hostname
        if ":" in hostname and not hostname.startswith("["):
            host_header = f"[{hostname}]"
        if port != 443:
            host_header = f"{host_header}:{port}"
        return (
            normalized,
            hostname,
            port,
            tuple(sorted(addresses)),
            target,
            host_header,
        )


def register_public_http_capabilities(
    registry: CapabilityRegistry,
) -> Tuple[Dict[str, FunctionExecutor], PublicHTTPToolSet]:
    tools = PublicHTTPToolSet()
    spec = CapabilitySpec(
        name="web.fetch",
        description="读取一个公网 HTTPS URL/API 的受限响应。禁止 localhost/内网/凭据 URL，不跟随重定向。",
        arguments_schema={
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
            "additionalProperties": False,
        },
        post_verify_mode="REPLAN_REQUIRED",
    )
    adapter = FunctionToolAdapter(
        capability_id=spec.name,
        source_kind="http_api",
        read_only=True,
    )
    registry.register(
        RegisteredCapability(
            spec=spec,
            adapter=adapter,
            source=CapabilitySourceTarget(
                kind="http_api",
                tool_name="GET",
                metadata={"public_https_only": True, "max_bytes": _MAX_BYTES},
            ),
            tags=("web", "http", "api", "read"),
            loading="always_visible",
        )
    )
    return {spec.name: tools.fetch}, tools


def _charset_from_content_type(content_type: str) -> str | None:
    for part in content_type.split(";")[1:]:
        key, sep, value = part.strip().partition("=")
        if sep and key.lower() == "charset" and value.strip():
            return value.strip().strip('"')
    return None


def _bounded_json(value: Any, *, depth: int = 0) -> Any:
    if depth >= 4:
        return "[bounded]"
    if isinstance(value, dict):
        return {
            str(k): _bounded_json(v, depth=depth + 1)
            for k, v in list(value.items())[:50]
        }
    if isinstance(value, list):
        return [_bounded_json(item, depth=depth + 1) for item in value[:50]]
    if isinstance(value, str):
        return value[:4000]
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return str(value)[:1000]
