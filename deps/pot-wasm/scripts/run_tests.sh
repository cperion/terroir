#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TERRA_BIN="$(command -v terra 2>/dev/null || true)"
if [[ -z "$TERRA_BIN" || ! -x "$TERRA_BIN" ]]; then
  echo "terra not found; skipping terra-based tests" >&2
  exit 0
fi

(
  cd "$ROOT"
  "$TERRA_BIN" tests/smoke.t
)

"$ROOT/scripts/run_webassembly_testsuite.sh"
"$ROOT/scripts/run_wasi_testsuite.sh"
