#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="$ROOT/third_party/wasi-testsuite"
ADAPTER="$ROOT/scripts/wasi_adapter_pot.py"
RUNNER="$ROOT/scripts/pot_wasi_runner.t"
TERRA_BIN="$(command -v terra 2>/dev/null || true)"

if [[ ! -d "$SUITE" ]]; then
  echo "wasi-testsuite submodule missing: $SUITE" >&2
  exit 1
fi

if [[ ! -x "$SUITE/run-tests" ]]; then
  echo "wasi-testsuite runner not found: $SUITE/run-tests" >&2
  exit 1
fi

if [[ -z "$TERRA_BIN" || ! -x "$TERRA_BIN" ]]; then
  echo "terra not found; cannot run wasi-testsuite" >&2
  exit 0
fi

if [[ ! -f "$ADAPTER" ]]; then
  echo "missing POT wasi adapter: $ADAPTER" >&2
  exit 1
fi
if [[ ! -f "$RUNNER" ]]; then
  echo "missing POT wasi runner: $RUNNER" >&2
  exit 1
fi

(
  cd "$ROOT"
  POT_TERRA="$TERRA_BIN" \
  POT_WASI_RUNNER="$RUNNER" \
  WASI_TEST_TIMEOUT_S="${WASI_TEST_TIMEOUT_S:-20}" \
  "$SUITE/run-tests" --runtime-adapter "$ADAPTER" "$@"
)
