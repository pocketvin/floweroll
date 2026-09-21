from __future__ import annotations

import queue
import re
import threading
from typing import Any, Dict, List, Optional

import httpx
from mem0 import MemoryClient


DEFAULT_MEM0_USER_ID = "floweroll-owner"
DEFAULT_TOP_K = 5
DEFAULT_TIMEOUT_SECONDS = 8.0
MAX_QUERY_CHARS = 2000
MAX_MEMORY_CHARS = 600
MAX_WRITE_CHARS = 4000

_CREDENTIAL_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", re.IGNORECASE),
    re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{12,}", re.IGNORECASE),
    re.compile(r"\bsk-[A-Za-z0-9_-]{16,}\b"),
    re.compile(
        r"['\"]?(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|passwd|secret|密码|令牌|密钥)['\"]?"
        r"\s*[:=]\s*['\"]?[^\s'\"\n]{8,}",
        re.IGNORECASE,
    ),
)


class Mem0Memory:
    """Thin Mem0 Platform adapter for Floweroll long-term user memory.

    Durable Task/Action/Attempt truth stays in SQLite. Mem0 only stores and
    retrieves cross-task user memory. Writes are serialized off the critical
    path; reads are bounded and fail open so memory availability cannot invent
    or destroy Runtime truth.
    """

    def __init__(
        self,
        *,
        api_key: str,
        user_id: str = DEFAULT_MEM0_USER_ID,
        top_k: int = DEFAULT_TOP_K,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        client: Optional[Any] = None,
    ) -> None:
        if not api_key.strip() and client is None:
            raise ValueError("MEM0_API_KEY must not be empty")
        if not user_id.strip():
            raise ValueError("Mem0 user_id must not be empty")
        if top_k < 1 or top_k > 20:
            raise ValueError("Mem0 top_k must be between 1 and 20")
        if timeout_seconds <= 0:
            raise ValueError("Mem0 timeout_seconds must be positive")

        self.user_id = user_id.strip()
        self.top_k = top_k
        self._owned_http_client: Optional[httpx.Client] = None
        if client is None:
            # The Host has an explicit outbound trust boundary. Do not inherit
            # process/system proxy or certificate environment here: on macOS that
            # can make Mem0 startup depend on unrelated developer-shell settings.
            http_client = httpx.Client(timeout=timeout_seconds, trust_env=False)
            self._owned_http_client = http_client
            self.client = MemoryClient(api_key=api_key.strip(), client=http_client)
        else:
            self.client = client

        self._state_lock = threading.Lock()
        self._closed = False
        self._write_queue: queue.Queue[Optional[Dict[str, str]]] = queue.Queue(maxsize=128)
        self._writer = threading.Thread(
            target=self._writer_loop,
            name="floweroll-mem0-writer",
            daemon=True,
        )
        self._writer.start()

    def remember_user_text(
        self,
        *,
        task_id: str,
        event_id: str,
        text: str,
        source_kind: str,
    ) -> bool:
        """Queue one user-authored text for Mem0 extraction without blocking intake."""

        normalized = self._memory_write_input(text)
        if not normalized:
            return False
        item = {
            "task_id": task_id,
            "event_id": event_id,
            "text": normalized,
            "source_kind": source_kind,
        }
        try:
            with self._state_lock:
                if self._closed:
                    return False
                self._write_queue.put_nowait(item)
            return True
        except queue.Full:
            return False

    def search(self, query: str) -> Dict[str, Any]:
        """Return a bounded Planner-safe projection of relevant Mem0 memories."""

        with self._state_lock:
            if self._closed:
                return {"items": [], "error_type": "MemoryClosed"}
        raw_query = query.strip()
        if not raw_query:
            return {"items": [], "error_type": None}
        if len(raw_query) > MAX_QUERY_CHARS or self._contains_credential(raw_query):
            return {
                "items": [],
                "error_type": None,
                "skipped_reason": "sensitive_or_oversized_query",
            }
        normalized = raw_query
        try:
            response = self.client.search(
                normalized,
                filters={"user_id": self.user_id},
                top_k=self.top_k,
            )
            raw_results = response.get("results", []) if isinstance(response, dict) else []
            items: List[Dict[str, Any]] = []
            for row in raw_results:
                if not isinstance(row, dict):
                    continue
                text = row.get("memory")
                if not isinstance(text, str) or not text.strip():
                    continue
                item: Dict[str, Any] = {
                    "memory": text.strip()[:MAX_MEMORY_CHARS],
                }
                memory_id = row.get("id")
                if isinstance(memory_id, str) and memory_id:
                    item["memory_id"] = memory_id
                score = row.get("score")
                if isinstance(score, (int, float)):
                    item["score"] = float(score)
                categories = row.get("categories")
                if isinstance(categories, list):
                    item["categories"] = [
                        value for value in categories[:5] if isinstance(value, str)
                    ]
                items.append(item)
                if len(items) >= self.top_k:
                    break
            return {"items": items, "error_type": None}
        except Exception as exc:
            return {"items": [], "error_type": type(exc).__name__}

    @staticmethod
    def _memory_write_input(text: str) -> Optional[str]:
        normalized = text.strip()
        if not normalized or len(normalized) > MAX_WRITE_CHARS:
            return None
        if Mem0Memory._contains_credential(normalized):
            return None
        return normalized

    @staticmethod
    def _contains_credential(text: str) -> bool:
        return any(pattern.search(text) for pattern in _CREDENTIAL_PATTERNS)

    def close(self, *, timeout_seconds: float = 0.5) -> bool:
        """Stop accepting new writes without making Host shutdown wait on Mem0."""
        if timeout_seconds < 0:
            raise ValueError("timeout_seconds must not be negative")
        with self._state_lock:
            if not self._closed:
                self._closed = True
                while True:
                    try:
                        self._write_queue.get_nowait()
                    except queue.Empty:
                        break
                    else:
                        self._write_queue.task_done()
                self._write_queue.put_nowait(None)
            writer = self._writer
        if writer is not threading.current_thread() and writer.is_alive():
            writer.join(timeout=timeout_seconds)
        return not writer.is_alive()

    def _writer_loop(self) -> None:
        try:
            while True:
                item = self._write_queue.get()
                if item is None:
                    self._write_queue.task_done()
                    return
                try:
                    self.client.add(
                        [{"role": "user", "content": item["text"]}],
                        user_id=self.user_id,
                        metadata={
                            "source": "floweroll",
                            "source_kind": item["source_kind"],
                            "task_id": item["task_id"],
                            "event_id": item["event_id"],
                        },
                    )
                except Exception:
                    # Long-term personalization must never corrupt or block the
                    # authoritative Task Runtime. Search/write health is observed
                    # separately from Task correctness.
                    pass
                finally:
                    self._write_queue.task_done()
        finally:
            transport = self._owned_http_client
            if transport is not None:
                try:
                    transport.close()
                except Exception:
                    pass
