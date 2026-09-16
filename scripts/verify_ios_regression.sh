#!/bin/zsh
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-}"
PROJECT="$ROOT/ios/Floweroll.xcodeproj"
SCHEME="Floweroll"
WORK_ROOT_OVERRIDE="${FLOWEROLL_REGRESSION_WORK_ROOT:-}"
SIMULATOR_PRIMARY_NAME="${IOS_SIMULATOR_PRIMARY_NAME:-Floweroll-iPhone17Pro-iOS27}"
SIMULATOR_SECONDARY_NAME="${IOS_SIMULATOR_SECONDARY_NAME:-Floweroll-iPhone17Pro-iOS27-B}"
SIMULATOR_LEASE_ROOT="${FLOWEROLL_SIMULATOR_LEASE_ROOT:-${TMPDIR:-/tmp}/floweroll-ios-simulator-leases}"
SIMULATOR_ID=""
SIMULATOR_NAME=""
SIMULATOR_LEASE_DIR=""

if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]]; then
  :
elif [[ -d /Applications/Xcode-27-RC.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-27-RC.app/Contents/Developer
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
else
  printf '%s\n' 'ERROR: no usable Xcode developer directory found.' >&2
  exit 69
fi

usage() {
  cat <<'EOF'
Usage: scripts/verify_ios_regression.sh <runtime|unit|build>

runtime  Run RuntimeInteractionPolicyTests on an available iPhone Simulator.
unit     Run the complete FlowerollTests target on an available iPhone Simulator.
build    Build the app for generic iOS with signing disabled.

By default the script leases one simulator from the Floweroll iPhone 17 Pro / iOS 27 pool:
  Floweroll-iPhone17Pro-iOS27
  Floweroll-iPhone17Pro-iOS27-B
If the primary is leased by another Builder, the secondary is used automatically.
Set IOS_SIMULATOR_ID to force a specific simulator; forced simulators are still lease-protected.
Default DerivedData/result paths are isolated per simulator. The script fails if Swift
source/project files change while the command is running.
EOF
}

snapshot() {
  python3 - <<'PY'
from pathlib import Path
import hashlib
paths = []
for root in (Path("ios/Floweroll"), Path("ios/FlowerollTests")):
    paths.extend(root.glob("**/*.swift"))
for path in (Path("ios/project.yml"), Path("ios/Floweroll.xcodeproj/project.pbxproj")):
    if path.exists():
        paths.append(path)
for path in sorted(set(paths)):
    print(hashlib.sha256(path.read_bytes()).hexdigest(), path)
PY
}

simulator_record_for_id() {
  local requested_id="$1"
  xcrun simctl list devices available -j | python3 -c '
import json, sys
payload=json.load(sys.stdin)
requested=sys.argv[1]
for devices in payload.get("devices", {}).values():
    for d in devices:
        if d.get("isAvailable") and d.get("udid") == requested:
            print("{}\t{}\t{}".format(d["udid"], d.get("name", ""), d.get("state", "Unknown")))
            raise SystemExit(0)
raise SystemExit(1)
' "$requested_id"
}

simulator_pool_records() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
payload=json.load(sys.stdin)
wanted=sys.argv[1:]
by_name={}
for devices in payload.get("devices", {}).values():
    for d in devices:
        if d.get("isAvailable") and d.get("name") in wanted:
            by_name[d["name"]]=d
for name in wanted:
    d=by_name.get(name)
    if d:
        print("{}\t{}\t{}".format(d["udid"], name, d.get("state", "Unknown")))
' "$SIMULATOR_PRIMARY_NAME" "$SIMULATOR_SECONDARY_NAME"
}

try_acquire_simulator_lease() {
  local id="$1"
  local name="$2"
  local lock="$SIMULATOR_LEASE_ROOT/$id"
  local holder=""
  mkdir -p "$SIMULATOR_LEASE_ROOT"

  if ! mkdir "$lock" 2>/dev/null; then
    if [[ -f "$lock/pid" ]]; then
      holder="$(cat "$lock/pid" 2>/dev/null || true)"
      if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$lock"
        mkdir "$lock" 2>/dev/null || return 1
      else
        return 1
      fi
    else
      return 1
    fi
  fi

  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' "$name" > "$lock/name"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$lock/started_at"
  SIMULATOR_ID="$id"
  SIMULATOR_NAME="$name"
  SIMULATOR_LEASE_DIR="$lock"
  return 0
}

select_simulator() {
  local record=""
  local id=""
  local name=""
  local state=""

  if [[ -n "${IOS_SIMULATOR_ID:-}" ]]; then
    record="$(simulator_record_for_id "$IOS_SIMULATOR_ID")" || {
      printf 'ERROR: forced IOS_SIMULATOR_ID is unavailable: %s\n' "$IOS_SIMULATOR_ID" >&2
      return 70
    }
    IFS=$'\t' read -r id name state <<< "$record"
    if ! try_acquire_simulator_lease "$id" "$name"; then
      printf 'ERROR: forced simulator is currently leased by another Builder: %s (%s)\n' "$name" "$id" >&2
      return 71
    fi
  else
    while IFS=$'\t' read -r id name state; do
      [[ -n "$id" ]] || continue
      if try_acquire_simulator_lease "$id" "$name"; then
        break
      fi
    done <<< "$(simulator_pool_records)"
    if [[ -z "$SIMULATOR_ID" ]]; then
      printf 'ERROR: both Floweroll iOS Simulator slots are currently leased or unavailable.\n' >&2
      return 71
    fi
  fi

  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  if ! xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null; then
    printf 'ERROR: selected simulator failed to boot: %s (%s)\n' "$SIMULATOR_NAME" "$SIMULATOR_ID" >&2
    return 72
  fi
  printf 'Using iOS Simulator slot: %s (%s)\n' "$SIMULATOR_NAME" "$SIMULATOR_ID" >&2
}

work_root_for_simulator() {
  if [[ -n "$WORK_ROOT_OVERRIDE" ]]; then
    printf '%s\n' "$WORK_ROOT_OVERRIDE"
  else
    printf '%s\n' "$ROOT/work/ios-regression/$SIMULATOR_NAME"
  fi
}

case "$MODE" in
  runtime|unit|build) ;;
  *) usage >&2; exit 64 ;;
esac

before="$(mktemp -t floweroll-ios-regression-before.XXXXXX)"
after="$(mktemp -t floweroll-ios-regression-after.XXXXXX)"
cleanup() {
  rm -f "$before" "$after"
  if [[ -n "$SIMULATOR_LEASE_DIR" ]]; then
    rm -rf "$SIMULATOR_LEASE_DIR"
  fi
}
trap cleanup EXIT
snapshot > "$before"

case "$MODE" in
  runtime)
    select_simulator || exit $?
    WORK_ROOT="$(work_root_for_simulator)"
    mkdir -p "$WORK_ROOT"
    derived="$WORK_ROOT/DerivedData-Runtime"
    result="$WORK_ROOT/runtime.xcresult"
    rm -rf "$derived" "$result"
    DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild test \
      -parallel-testing-enabled NO \
      -maximum-parallel-testing-workers 1 \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
      -only-testing:FlowerollTests/RuntimeInteractionPolicyTests \
      -derivedDataPath "$derived" \
      -resultBundlePath "$result"
    test_rc=$?
    ;;
  unit)
    select_simulator || exit $?
    WORK_ROOT="$(work_root_for_simulator)"
    mkdir -p "$WORK_ROOT"
    derived="$WORK_ROOT/DerivedData-Unit"
    result="$WORK_ROOT/unit.xcresult"
    rm -rf "$derived" "$result"
    DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild test \
      -parallel-testing-enabled NO \
      -maximum-parallel-testing-workers 1 \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
      -derivedDataPath "$derived" \
      -resultBundlePath "$result"
    test_rc=$?
    ;;
  build)
    if [[ -n "$WORK_ROOT_OVERRIDE" ]]; then
      WORK_ROOT="$WORK_ROOT_OVERRIDE"
    else
      WORK_ROOT="$ROOT/work/ios-regression/generic-build"
    fi
    mkdir -p "$WORK_ROOT"
    derived="$WORK_ROOT/DerivedData-Build"
    rm -rf "$derived"
    DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$derived" \
      CODE_SIGNING_ALLOWED=NO
    test_rc=$?
    ;;
esac

snapshot > "$after"
if ! cmp -s "$before" "$after"; then
  printf '%s\n' 'ERROR: iOS Swift/project files changed while regression was running; result is not a stable-snapshot proof.' >&2
  diff -u "$before" "$after" | sed -n '1,120p' >&2 || true
  exit 86
fi

exit "$test_rc"
