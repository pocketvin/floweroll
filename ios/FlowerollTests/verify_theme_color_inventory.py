#!/usr/bin/env python3
"""Static guard for AUD-006 foreground theme ownership.

Run from anywhere inside the repository. The guard intentionally allows the
AlarmKit system presentation to keep its independent `.blue` tint and the
shared non-Rive mascot fallback to keep its existing app/system accent token.
All app-foreground brand accents must otherwise flow through Floweroll Theme.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PRODUCT = REPO / "ios" / "Floweroll"
APP = PRODUCT / "App"
SHARED = PRODUCT / "Shared"
LIVE_ACTIVITY = PRODUCT / "LiveActivity"

BLUE_RE = re.compile(r"(?:Color\.blue|UIColor\.systemBlue|(?<![A-Za-z0-9_])\.blue\b)")
LEGACY_ACCENT_RE = re.compile(
    r"Color\.accentColor|\.tint\(\.accentColor\)|return\s+\.accentColor|\?\s*\.accentColor\b"
)
THEME_KEY_RE = re.compile(r'"floweroll\.theme\.[^"]+"')


def swift_files(root: Path) -> list[Path]:
    return sorted(root.rglob("*.swift"))


def hits(files: list[Path], pattern: re.Pattern[str]) -> list[dict[str, object]]:
    found: list[dict[str, object]] = []
    for path in files:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if pattern.search(line):
                found.append(
                    {
                        "path": str(path.relative_to(REPO)),
                        "line": line_number,
                        "text": line.strip(),
                    }
                )
    return found


def main() -> int:
    product_swift = swift_files(APP) + swift_files(SHARED) + swift_files(LIVE_ACTIVITY)
    explicit_blue = hits(product_swift, BLUE_RE)
    expected_blue = [
        {
            "path": "ios/Floweroll/App/RuntimeClient/AlarmCreateExecutor.swift",
            "text_fragment": "tintColor: .blue",
        }
    ]
    if len(explicit_blue) != 1:
        raise SystemExit(f"expected exactly one explicit blue exception, found {explicit_blue}")
    blue = explicit_blue[0]
    allowed = expected_blue[0]
    if blue["path"] != allowed["path"] or allowed["text_fragment"] not in str(blue["text"]):
        raise SystemExit(f"unexpected foreground/system blue reference: {blue}")

    app_legacy_accent = hits(swift_files(APP), LEGACY_ACCENT_RE)
    if app_legacy_accent:
        raise SystemExit(f"app foreground still contains legacy accentColor references: {app_legacy_accent}")

    shared_legacy_accent = hits(swift_files(SHARED), LEGACY_ACCENT_RE)
    if len(shared_legacy_accent) != 1:
        raise SystemExit(
            "shared mascot accent exception changed; review rather than silently widening the allowlist: "
            + json.dumps(shared_legacy_accent, ensure_ascii=False)
        )
    shared = shared_legacy_accent[0]
    if shared["path"] != "ios/Floweroll/Shared/FlowerollMascotView.swift":
        raise SystemExit(f"unexpected shared accent reference: {shared}")

    theme_keys = hits(swift_files(APP), THEME_KEY_RE)
    key_values = [item["text"] for item in theme_keys]
    if len(theme_keys) != 1 or "floweroll.theme.accent.v1" not in str(key_values[0]):
        raise SystemExit(f"theme persistence key ownership is not singular: {theme_keys}")

    summary = {
        "explicit_blue_exceptions": explicit_blue,
        "app_legacy_accent_references": app_legacy_accent,
        "shared_mascot_accent_exception": shared_legacy_accent,
        "theme_key_references": theme_keys,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
