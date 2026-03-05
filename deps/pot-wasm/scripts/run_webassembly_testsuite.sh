#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="$ROOT/third_party/webassembly-testsuite"
RUNNER="$ROOT/tests/spec_runner.t"

TERRA_BIN="$(command -v terra 2>/dev/null || true)"
if [[ -z "$TERRA_BIN" || ! -x "$TERRA_BIN" ]]; then
  echo "terra not found; cannot run testsuite" >&2
  exit 0
fi

if [[ ! -d "$SUITE" ]]; then
  echo "testsuite submodule missing: $SUITE" >&2
  exit 1
fi
WAT2WASM_BIN="$(command -v wat2wasm 2>/dev/null || true)"
if [[ -z "$WAT2WASM_BIN" || ! -x "$WAT2WASM_BIN" ]]; then
  echo "wat2wasm not found; skipping webassembly testsuite run" >&2
  exit 0
fi

# MVP-focused smoke subset.
FILES=(
  "$SUITE/address.wast"
  "$SUITE/block.wast"
  "$SUITE/br.wast"
  "$SUITE/br_if.wast"
  "$SUITE/br_table.wast"
  "$SUITE/call.wast"
  "$SUITE/call_indirect.wast"
  "$SUITE/const.wast"
  "$SUITE/conversions.wast"
  "$SUITE/exports.wast"
  "$SUITE/f32.wast"
  "$SUITE/f64.wast"
  "$SUITE/forward.wast"
  "$SUITE/global.wast"
  "$SUITE/i32.wast"
  "$SUITE/i64.wast"
  "$SUITE/if.wast"
  "$SUITE/imports.wast"
  "$SUITE/load.wast"
  "$SUITE/local_get.wast"
  "$SUITE/local_set.wast"
  "$SUITE/local_tee.wast"
  "$SUITE/loop.wast"
  "$SUITE/memory.wast"
  "$SUITE/memory_grow.wast"
  "$SUITE/memory_size.wast"
  "$SUITE/return.wast"
  "$SUITE/select.wast"
  "$SUITE/start.wast"
  "$SUITE/store.wast"
)

(
  cd "$ROOT"
  overall_rc=0
  for f in "${FILES[@]}"; do
    echo "=== $f ==="
    if ! "$TERRA_BIN" "$RUNNER" "$f"; then
      overall_rc=1
      echo "FAILED: $f"
    fi
  done
  exit "$overall_rc"
)
