#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  source "$ROOT/.env"
  set +a
fi
PYTHON="${PYTHON_BIN:-$ROOT/.venv/bin/python}"
if [[ ! -x "$PYTHON" ]]; then
  print -u2 "Create .venv and install host/requirements.lock first."
  exit 69
fi
export PYTHONPATH="$ROOT/host:$ROOT${PYTHONPATH:+:$PYTHONPATH}"
exec "$PYTHON" "$ROOT/host/run_host.py" --db "${FLOWEROLL_DB_PATH:-$ROOT/work/floweroll-v1.sqlite3}" "$@"
