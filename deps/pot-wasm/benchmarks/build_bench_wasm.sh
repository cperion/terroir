#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/examples/bench_wasi.c"
OUT="${1:-$ROOT/examples/bench.wasm}"
CLANG_BIN="${CLANG:-clang}"

[[ -f "$SRC" ]] || { echo "error: source not found: $SRC" >&2; exit 1; }
command -v "$CLANG_BIN" >/dev/null 2>&1 || { echo "error: clang not found: $CLANG_BIN" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

"$CLANG_BIN" \
  --target=wasm32 \
  -O3 \
  -fno-builtin \
  -nostdlib \
  -Wl,--no-entry \
  -Wl,--export=_start \
  -Wl,--allow-undefined \
  -o "$OUT" \
  "$SRC"

echo "built: $OUT"
