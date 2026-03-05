#!/usr/bin/env bash
# Run all POT-WASM benchmarks
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export PATH="$HOME/.wasmtime/bin:$HOME/.wasmer/bin:$PATH"

TESTS=(
    "examples/bench.wasm"
    "stress_test2.wasm"
    "test_memory_patterns.wasm"
    "test_float_ops.wasm"
    "test_control_flow.wasm"
    "test_i64_ops.wasm"
    "test_locals_globals.wasm"
    "test_recursion.wasm"
    "test_call_indirect.wasm"
)

RUNS=${RUNS:-5}
WARMUPS=${WARMUPS:-1}

echo "========================================"
echo "POT-WASM Comprehensive Benchmark Suite"
echo "========================================"
echo "Runs: $RUNS  Warmups: $WARMUPS"
echo ""

for wasm in "${TESTS[@]}"; do
    if [[ -f "$wasm" ]]; then
        echo ""
        echo "=== $wasm ==="
        ./benchmarks/run.sh --wasm "$wasm" --runs "$RUNS" --warmups "$WARMUPS" --skip-checks 2>&1 | grep -E "^(benchmark|---|Median|Runtime|Relative)" | head -20
    fi
done

echo ""
echo "========================================"
echo "All benchmarks complete!"
echo "========================================"
