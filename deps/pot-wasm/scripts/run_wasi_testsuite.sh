#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="$ROOT/third_party/wasi-testsuite"

if [[ ! -d "$SUITE" ]]; then
  echo "wasi-testsuite submodule missing: $SUITE" >&2
  exit 1
fi

if [[ ! -x "$SUITE/run-tests" ]]; then
  echo "wasi-testsuite runner not found: $SUITE/run-tests" >&2
  exit 1
fi

echo "wasi-testsuite is vendored."
echo "Runtime adapter wiring is pending; integrate POT runner with:"
echo "  $SUITE/run-tests --help"
