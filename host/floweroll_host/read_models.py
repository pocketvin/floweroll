from __future__ import annotations

import base64
import json
from typing import Optional, Tuple


class InvalidCursorError(ValueError):
    pass


def encode_task_cursor(updated_at: str, task_id: str) -> str:
    payload = json.dumps(
        {"updated_at": updated_at, "task_id": task_id},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")


def decode_task_cursor(cursor: Optional[str]) -> Optional[Tuple[str, str]]:
    if not cursor:
        return None
    try:
        padded = cursor + "=" * ((4 - len(cursor) % 4) % 4)
        value = json.loads(base64.urlsafe_b64decode(padded.encode("ascii")).decode("utf-8"))
        if set(value) != {"updated_at", "task_id"}:
            raise ValueError("unexpected cursor fields")
        updated_at = value["updated_at"]
        task_id = value["task_id"]
        if not isinstance(updated_at, str) or not updated_at:
            raise ValueError("invalid updated_at")
        if not isinstance(task_id, str) or not task_id:
            raise ValueError("invalid task_id")
        return updated_at, task_id
    except Exception as exc:
        raise InvalidCursorError("invalid task cursor") from exc
