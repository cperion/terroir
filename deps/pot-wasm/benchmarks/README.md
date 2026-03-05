# Benchmarks

This directory adds a reproducible cross-runtime harness for `examples/bench.wasm`.

## Build benchmark module

```bash
./benchmarks/build_bench_wasm.sh
```

Notes:
- The build uses `-fno-builtin` to avoid unresolved imports like `env.strlen` in POT.
- You can override compiler with `CLANG=clang-18` (or another clang binary).

## Run cross-runtime benchmarks

```bash
./benchmarks/run.sh
```

Default behavior:
- Warmups: `1`
- Timed runs: `7`
- Runtimes: `pot,wasmtime,wasmer` (missing runtimes are skipped)
- Checks: verifies benchmark names and result checksums match across runs/runtimes

Runtime note:
- The harness resolves the local PO.T launcher first (`./po.t`), then falls back to legacy `./pot`.

Useful flags:

```bash
./benchmarks/run.sh --runs 11 --warmups 2
./benchmarks/run.sh --runtimes pot,wasmtime
./benchmarks/run.sh --raw-dir ./benchmarks/raw
./benchmarks/run.sh --skip-checks
```

Output includes:
- Per-benchmark median time (us) with winner and margin over second-best.
- Runtime-level wall vs in-wasm timing medians (to expose process overhead).
- Geometric-mean relative speed ratio vs baseline runtime (defaults to POT when present).
