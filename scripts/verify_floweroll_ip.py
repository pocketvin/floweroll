#!/usr/bin/env python3
"""Verify current Floweroll identity assets and the retained legacy micro-motion rig."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "assets" / "floweroll"

CURRENT_ICON_SHA = "e0e0579f7bc721cdbf16725715852d89456a21d761d50ebcfd695e7793e5c00c"
# Shipped PNG has equivalent RGBA pixels to the authored reference; metadata differs.
LEGACY_RIG_SHA = "fb17d94caf65ee3d661d45123d633b7241f7eaaa25ddece848de3f83292162e9"
LEGACY_RIG_SIZE = (552, 381)

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit(
        "Pillow is required. Install dev/requirements.txt in the project virtual environment."
    ) from exc


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# Current identity / product asset library.
manifest_path = ASSET_ROOT / "manifest.json"
if not manifest_path.exists():
    fail("current asset manifest is missing")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

icon_source = ASSET_ROOT / manifest["identity"]["primary_anchor"]
if not icon_source.exists():
    fail("current approved App Icon source is missing")
if sha256(icon_source) != CURRENT_ICON_SHA:
    fail("current approved App Icon source SHA changed")

icon_1024 = ASSET_ROOT / manifest["identity"]["runtime_app_icon"]
if not icon_1024.exists():
    fail("1024px runtime App Icon export is missing")
with Image.open(icon_1024) as image:
    if image.size != (1024, 1024):
        fail(f"runtime App Icon must be 1024x1024, got {image.size}")

xcode_icon = (
    ROOT
    / "ios"
    / "Floweroll"
    / "Shared"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "AppIcon.png"
)
if not xcode_icon.exists() or xcode_icon.read_bytes() != icon_1024.read_bytes():
    fail("Xcode AppIcon does not byte-match the approved 1024px runtime export")

canonical = manifest.get("canonical_assets", [])
states = [item for item in canonical if item.get("category") == "state"]
scenes = [item for item in canonical if item.get("category") == "scene"]
if len(canonical) != 20 or len(states) != 6 or len(scenes) != 14:
    fail(
        "expected 20 canonical state/scene assets "
        f"(6 states + 14 scenes), got {len(canonical)} "
        f"({len(states)} states + {len(scenes)} scenes)"
    )
for item in canonical:
    path = ASSET_ROOT / item["path"]
    if not path.exists():
        fail(f"canonical asset missing: {item['path']}")
    if sha256(path) != item["sha256"]:
        fail(f"canonical asset SHA drifted: {item['path']}")
    if item.get("status") != "canonical":
        fail(f"non-canonical entry found in canonical list: {item['path']}")
    with Image.open(path) as image:
        if image.size != (1024, 1024):
            fail(f"canonical asset must be 1024x1024: {item['path']} -> {image.size}")
        if "A" not in image.getbands():
            fail(f"canonical state/scene asset is missing alpha: {item['path']}")
        alpha_min, alpha_max = image.getchannel("A").getextrema()
        if alpha_min == 255:
            fail(f"canonical state/scene asset background is fully opaque: {item['path']}")
        if alpha_max != 255:
            fail(f"canonical asset has no fully opaque foreground pixels: {item['path']}")

# Canonical product assets must be mirrored byte-for-byte into Asset Catalog.
asset_catalog = ROOT / "ios" / "Floweroll" / "Shared" / "Assets.xcassets"
def catalog_image(name: str) -> Path:
    matches = list(asset_catalog.rglob(f"{name}.imageset"))
    if len(matches) != 1:
        fail(f"expected one Asset Catalog entry for {name}, found {len(matches)}")
    contents = json.loads((matches[0] / "Contents.json").read_text())
    filenames = {item["filename"] for item in contents["images"] if item.get("filename")}
    if len(filenames) != 1:
        fail(f"expected one universal source image for {name}")
    return matches[0] / filenames.pop()


asset_catalog_map = {
    "states/idle.png": "FlowerollStateIdle",
    "states/listening.png": "FlowerollStateListening",
    "states/thinking.png": "FlowerollStateThinking",
    "states/working.png": "FlowerollStateWorking",
    "states/waiting.png": "FlowerollStateWaiting",
    "states/done-cheer.png": "FlowerollStateDone",
    "scenes/ride-hailing.png": "FlowerollSceneRideHailing",
    "scenes/food-delivery.png": "FlowerollSceneFoodDelivery",
    "scenes/email.png": "FlowerollSceneEmail",
    "scenes/notes.png": "FlowerollSceneNotes",
    "scenes/calendar.png": "FlowerollSceneCalendar",
    "scenes/search.png": "FlowerollSceneSearch",
    "scenes/map.png": "FlowerollSceneMap",
    "scenes/files.png": "FlowerollSceneFiles",
    "scenes/checklist.png": "FlowerollSceneChecklist",
    "scenes/phone.png": "FlowerollScenePhone",
    "scenes/camera.png": "FlowerollSceneCamera",
    "scenes/translate.png": "FlowerollSceneTranslate",
    "scenes/data.png": "FlowerollSceneData",
    "scenes/alarm.png": "FlowerollSceneAlarm",
}
for rel, name in asset_catalog_map.items():
    src = ASSET_ROOT / rel
    dst = catalog_image(name)
    if not dst.exists() or dst.read_bytes() != src.read_bytes():
        fail(f"Asset Catalog copy drifted: {name} <- {rel}")

# Core Motion V1 layers are derived from the six canonical poses. They must
# recompose pixel-exactly and the Asset Catalog mirrors must stay byte-identical.
motion_root = ASSET_ROOT / "motion" / "core"
motion_manifest_path = motion_root / "manifest.json"
if not motion_manifest_path.exists():
    fail("core motion manifest is missing")
motion_manifest = json.loads(motion_manifest_path.read_text(encoding="utf-8"))
expected_motion_states = {"idle", "listening", "thinking", "working", "waiting", "done"}
if set(motion_manifest.get("states", {})) != expected_motion_states:
    fail("core motion manifest must contain exactly six states")

motion_catalog_names = {
    ("idle", "main"): "FlowerollMotionIdleMain",
    ("listening", "main"): "FlowerollMotionListeningMain",
    ("listening", "signal"): "FlowerollMotionListeningSignal",
    ("thinking", "main"): "FlowerollMotionThinkingMain",
    ("thinking", "question"): "FlowerollMotionThinkingQuestion",
    ("thinking", "tailAccent"): "FlowerollMotionThinkingTailAccent",
    ("working", "main"): "FlowerollMotionWorkingMain",
    ("working", "accent"): "FlowerollMotionWorkingAccent",
    ("waiting", "main"): "FlowerollMotionWaitingMain",
    ("waiting", "bubble"): "FlowerollMotionWaitingBubble",
    ("done", "main"): "FlowerollMotionDoneMain",
    ("done", "sparklesLeft"): "FlowerollMotionDoneSparklesLeft",
    ("done", "sparklesRight"): "FlowerollMotionDoneSparklesRight",
}
for state, item in motion_manifest["states"].items():
    source = ROOT / item["source"]
    base = Image.open(source).convert("RGBA")
    main = Image.open(motion_root / state / item["main"]).convert("RGBA")
    composite = main
    parts = [("main", motion_root / state / item["main"])]
    for accessory in item.get("accessories", []):
        part = motion_root / state / f"{accessory}.png"
        composite = Image.alpha_composite(composite, Image.open(part).convert("RGBA"))
        parts.append((accessory, part))
    if base.tobytes() != composite.tobytes():
        fail(f"core motion layers no longer recompose exactly: {state}")
    for part_name, part_path in parts:
        catalog_name = motion_catalog_names.get((state, part_name))
        if catalog_name is None:
            fail(f"motion layer missing catalog mapping: {state}/{part_name}")
        dst = catalog_image(catalog_name)
        if not dst.exists() or dst.read_bytes() != part_path.read_bytes():
            fail(f"motion Asset Catalog copy drifted: {catalog_name}")

# Validate the retained lab rig from its actual shipped resources. A fresh checkout
# must not depend on the original author's private work/ directory.
# This calibration reference is not used by SwiftUI, so it is kept outside the
# runtime bundle instead of shipping an unused imageset to both App and widget.
legacy_master_path = ASSET_ROOT / "reference" / "rig-master.png"
if not legacy_master_path.exists() or sha256(legacy_master_path) != LEGACY_RIG_SHA:
    fail("retained rig master identity changed")
legacy_master = Image.open(legacy_master_path).convert("RGBA")
if legacy_master.size != LEGACY_RIG_SIZE:
    fail("retained rig dimensions changed")
order = ["FlowerollTailBase", "FlowerollTailAccent", "FlowerollBodyBase",
         "FlowerollCheekLeft", "FlowerollCheekRight", "FlowerollEyeLeft",
         "FlowerollEyeRightWink", "FlowerollMouth"]
composite = Image.new("RGBA", LEGACY_RIG_SIZE, (0, 0, 0, 0))
for name in order:
    path = catalog_image(name)
    layer = Image.open(path).convert("RGBA")
    if layer.size != LEGACY_RIG_SIZE:
        fail("retained rig layer dimensions changed: " + name)
    composite = Image.alpha_composite(composite, layer)
if legacy_master.tobytes() != composite.tobytes():
    fail("retained rig no longer recomposes pixel-exactly")

swift = (ROOT / "ios" / "Floweroll" / "Shared" / "FlowerollMascotView.swift").read_text(
    encoding="utf-8"
)
for forbidden in ("Canvas {", "drawBody(", "drawEars(", "drawCurl(", "drawFace("):
    if forbidden in swift:
        fail(f"mascot runtime reintroduced freehand character drawing: {forbidden}")

print("PASS: current App Icon identity SHA + 1024 runtime export")
print("PASS: 20 canonical state/scene assets (6 states + 14 scenes) + hashes + transparency")
print("PASS: Xcode AppIcon byte-matches current approved runtime export")
print("PASS: 20 canonical state/scene assets byte-match Asset Catalog copies")
print("PASS: Core Motion V1 six-state layers recompose pixel-exactly and match Asset Catalog")
print("PASS: retained legacy Rig v2 remains pixel-exact for current micro-motion prototype")
print("PASS: mascot runtime has not reintroduced freehand Canvas character drawing")
