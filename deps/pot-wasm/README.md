# pot-wasm (strata migration)

This is a clean-architecture reboot of `pot-wasm`.

- Legacy implementation is preserved in `deps/pot-wasm-old`.
- New implementation keeps a strict split:
  - `compiler/` parser + IR lowering (Strata)
  - `runtime/` instance lifecycle + C ABI surface
  - `tests/` local tests
  - `third_party/` upstream conformance suites

Current phase:
- Frontend/lowering are new and Strata-based.
- Runtime is new-only (no delegation to `pot-wasm-old`).
- Runtime compiles WASM bytes directly to Terra functions and exposes callable pointers.
- No per-module `.so` path is used.
- Compile work is memoized; instantiation remains fresh per call.

## Canonical API

- `instantiate(wasm_bytes, host_functions, opts)`
- `instance_init(instance)` / `instance_deinit(instance)`
- `instance_export_count(instance)`
- `instance_export_name(instance, i)` (zero-based)
- `instance_export_sig(instance, i)`
- `instance_export_ptr(instance, i, ctype?)`
- `instance_memory(instance)`
- `instance_memory_size(instance)`

## Test entrypoint

```bash
./scripts/run_tests.sh
```

Conformance helpers:

```bash
./scripts/run_webassembly_testsuite.sh
./scripts/run_wasi_testsuite.sh
```

Current known red areas:
- `conversions.wast`: bit-exact reinterpret + NaN payload semantics.
- `wat2wasm` parser support gaps in wabt `1.0.34` for newer reference-type syntax used by some suite files.

## Third-party suites

- `third_party/webassembly-testsuite`
- `third_party/wasi-testsuite`
