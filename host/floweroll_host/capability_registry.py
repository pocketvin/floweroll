from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional

from .execution_contracts import CapabilityAdapter
from .planner_contracts import CapabilitySpec


@dataclass(frozen=True)
class CapabilitySourceTarget:
    kind: str
    server_id: Optional[str] = None
    tool_name: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "kind": self.kind,
            "server_id": self.server_id,
            "tool_name": self.tool_name,
            "metadata": dict(self.metadata),
        }


@dataclass(frozen=True)
class RegisteredCapability:
    spec: CapabilitySpec
    adapter: CapabilityAdapter
    source: CapabilitySourceTarget
    tags: tuple[str, ...] = ()
    loading: str = "always_visible"


class CapabilityRegistry:
    """Unified semantic registry independent from source transport.

    Planner sees CapabilitySpec. Execution sees the Adapter/source target. Raw
    MCP tool names are never required to become global capability identity.
    """

    def __init__(self, entries: Iterable[RegisteredCapability] = ()) -> None:
        self._entries: Dict[str, RegisteredCapability] = {}
        for entry in entries:
            self.register(entry)

    def register(self, entry: RegisteredCapability) -> None:
        capability_id = entry.spec.name
        if not capability_id.strip():
            raise ValueError("capability id must not be empty")
        if entry.adapter.capability_id != capability_id:
            raise ValueError("CapabilitySpec and CapabilityAdapter identities must match")
        if entry.loading not in {"always_visible", "deferred"}:
            raise ValueError("invalid capability loading mode")
        if capability_id in self._entries:
            raise ValueError(f"capability already registered: {capability_id}")
        self._entries[capability_id] = entry

    def get(self, capability_id: str) -> RegisteredCapability:
        try:
            return self._entries[capability_id]
        except KeyError as exc:
            raise KeyError(f"unknown capability: {capability_id}") from exc

    def planner_capabilities(self, *, include_deferred: bool = False) -> List[CapabilitySpec]:
        result = []
        for capability_id in sorted(self._entries):
            entry = self._entries[capability_id]
            if entry.loading == "deferred" and not include_deferred:
                continue
            result.append(entry.spec)
        return result

    def execution_adapters(self) -> List[CapabilityAdapter]:
        return [self._entries[key].adapter for key in sorted(self._entries)]

    def entries(self, *, include_deferred: bool = True) -> List[RegisteredCapability]:
        result: List[RegisteredCapability] = []
        for capability_id in sorted(self._entries):
            entry = self._entries[capability_id]
            if entry.loading == "deferred" and not include_deferred:
                continue
            result.append(entry)
        return result

    def source_entries(self, kind: str) -> List[RegisteredCapability]:
        return [
            self._entries[key]
            for key in sorted(self._entries)
            if self._entries[key].source.kind == kind
        ]

    def __contains__(self, capability_id: object) -> bool:
        return isinstance(capability_id, str) and capability_id in self._entries

    def __len__(self) -> int:
        return len(self._entries)
