#!/bin/zsh
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# A fresh source export has no tracked scratch directory.
mkdir -p "$ROOT/work"

MODE="${1:-}"
if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON_BIN="$PYTHON_BIN"
elif [[ -x "$ROOT/.venv/bin/python" ]]; then
  PYTHON_BIN="$ROOT/.venv/bin/python"
else
  PYTHON_BIN="python3"
fi
export PYTHONPATH="$ROOT:$ROOT/host${PYTHONPATH:+:$PYTHONPATH}"

usage() {
  cat <<'EOF'
Usage: scripts/verify_host_regression.sh <core|presentation|capabilities|materials|full>

Runs one bounded Host regression group and fails if Host source/test Python files
change while the suite is running. `full` is an integration/release gate and
should only run after builders stop writing the Host tree.
EOF
}

snapshot() {
  "$PYTHON_BIN" - <<'PY'
from pathlib import Path
import hashlib
for root, suffix in ((Path("host/floweroll_host"), "*.py"), (Path("host/tests"), "*.py"),
                     (Path("host/prompts"), "*.txt"), (Path("host/native_helpers"), "*.swift")):
    for path in sorted(root.glob("**/" + suffix)):
        print(hashlib.sha256(path.read_bytes()).hexdigest(), path)
PY
}

run_modules() {
  "$PYTHON_BIN" -m unittest -v "$@"
}

case "$MODE" in
  core)
    TEST_ARGS=(
      host.tests.test_migrations
      host.tests.test_task_runtime
      host.tests.test_execution_runtime
      host.tests.test_recovery
      host.tests.test_runtime_supervisor
      host.tests.test_control_interrupt
      host.tests.test_planner_runtime
      host.tests.test_planner_graph
      host.tests.test_planner_v0
      host.tests.test_planner_transport_recovery
      host.tests.test_openai_compatible_chat_adapter
      host.tests.test_mem0_memory
      host.tests.test_mem0_runtime
    )
    ;;
  presentation)
    TEST_ARGS=(
      host.tests.test_auth
      host.tests.test_host
      host.tests.test_task_read_side
      host.tests.test_presentation_copy
      host.tests.test_presentation_stream
      host.tests.test_interaction_api
      host.tests.test_interaction_artifact_cancel
      host.tests.test_device_action_wait
      host.tests.test_ios_work_progress_contract
      host.tests.test_r1_structural_regressions
      host.tests.test_r1_ux_regressions
    )
    ;;
  capabilities)
    TEST_ARGS=(
      host.tests.test_alarm_adapter
      host.tests.test_alarm_cancel_adapter
      host.tests.test_calendar_adapter
      host.tests.test_calendar_create_adapter
      host.tests.test_capability_discovery
      host.tests.test_discovery_convergence
      host.tests.test_capability_status
      host.tests.test_deterministic_calc
      host.tests.test_deterministic_calc_product
      host.tests.test_dingtalk_cli
      host.tests.test_feishu_cli
      host.tests.test_flyai_cli
      host.tests.test_host_local_tools
      host.tests.test_image_ops
      host.tests.test_image_ops_product
      host.tests.test_managed_cli_guardrails
      host.tests.test_mcp_compatibility
      host.tests.test_mcp_output_bounds
      host.tests.test_mcp_runtime
      host.tests.test_notify_user
      host.tests.test_public_http_tools
      host.tests.test_reminder_adapter
    )
    ;;
  materials)
    TEST_ARGS=(
      host.tests.test_material_delivery_e2e
      host.tests.test_observation_projection
      host.tests.test_task_materials
      host.tests.test_work_item_projection
      host.tests.test_work_units
      host.tests.test_pdf_report
      host.tests.test_docx_semantic
    )
    ;;
  full)
    TEST_ARGS=()
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

before="$(mktemp -t floweroll-host-regression-before.XXXXXX)"
after="$(mktemp -t floweroll-host-regression-after.XXXXXX)"
trap 'rm -f "$before" "$after"' EXIT
snapshot > "$before"

printf '== Host regression: %s ==\n' "$MODE"
if [[ "$MODE" == "full" ]]; then
  "$PYTHON_BIN" -m unittest discover -s "$ROOT/host/tests" -p 'test_*.py' -v
  test_rc=$?
else
  run_modules "${TEST_ARGS[@]}"
  test_rc=$?
fi

snapshot > "$after"
if ! cmp -s "$before" "$after"; then
  printf '%s\n' 'ERROR: Host source/tests changed while regression was running; result is not a stable-snapshot proof.' >&2
  diff -u "$before" "$after" | sed -n '1,120p' >&2 || true
  exit 86
fi

exit "$test_rc"
