from __future__ import annotations

import hmac
import ipaddress
from typing import Optional


class HostAuthConfigurationError(ValueError):
    pass


def is_loopback_host(host: str) -> bool:
    normalized = host.strip().lower()
    if normalized == "localhost":
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


def validate_host_binding(host: str) -> None:
    """The built-in V1 HTTP server is intentionally loopback-only.

    A real iPhone reaches it through an HTTPS tunnel/reverse proxy. Direct LAN
    serving requires a future TLS-capable transport; a bearer token alone is
    not sufficient protection over plaintext HTTP.
    """

    if not is_loopback_host(host):
        raise HostAuthConfigurationError(
            "the built-in Host server only permits loopback binding; use an HTTPS "
            "tunnel/reverse proxy or a future TLS-capable LAN transport"
        )


def bearer_token_matches(header: Optional[str], expected_token: Optional[str]) -> bool:
    if expected_token is None:
        return True
    if header is None:
        return False
    scheme, separator, supplied = header.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not supplied:
        return False
    return hmac.compare_digest(supplied, expected_token)
