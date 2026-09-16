"""花卷的持久 Host 软件包。

Read-only helpers can be imported without loading the HTTP server or runtime.
Public convenience exports remain available, but are resolved only on demand.
"""
from __future__ import annotations

from importlib import import_module
from typing import Any

__all__ = ["AgentLoop", "HostApp", "Storage", "create_server"]

_EXPORTS = {
    "AgentLoop": ".agent_loop",
    "HostApp": ".server",
    "Storage": ".storage",
    "create_server": ".server",
}


def __getattr__(name: str) -> Any:
    module = _EXPORTS.get(name)
    if module is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    value = getattr(import_module(module, __name__), name)
    globals()[name] = value
    return value
