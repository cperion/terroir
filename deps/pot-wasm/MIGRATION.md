# pot-wasm migration plan

## Goal

Migrate from monolithic runtime/compiler (`pot-wasm-old`) to a clean Strata-driven architecture in `pot-wasm`.

## Current state

- `pot-wasm-old` is archived for reference only.
- New `pot-wasm` owns API shape, compiler pipeline boundaries, and runtime instance facade.
- Third-party conformance suites are vendored as submodules.
- Runtime path is direct: `wasm bytes -> Terra compile -> in-memory instance -> FFI pointers`.
- `.so` per-module output is removed from the new path.

## Target architecture

- `compiler/frontend.t`: binary decode + validation input
- `compiler/ast.t`: Strata schema for canonical IR
- `compiler/lower.t`: parsed wasm -> IR lowering
- `compiler/passes/*.t`: structured transforms and checks
- `compiler/emitter.t`: Terra quote/code emission
- `runtime/instance.t`: canonical C ABI surface for hosts
- `runtime/cache.t`: memoized compile cache policy

## Active work items

1. Finish bit-exact reinterpret/NaN payload behavior (`conversions.wast`).
2. Keep expanding multi-memory/reference-type coverage in runtime and runner.
3. Upgrade/replace WAT toolchain path for newer testsuite syntax currently rejected by wabt `1.0.34`.

## Conformance suites

- WebAssembly testsuite: `third_party/webassembly-testsuite`
- WASI testsuite: `third_party/wasi-testsuite`

Conformance runner wiring is pending in `tests/spec_runner.t` and must target new runtime only.
