# POT Runtime Compile Notes

## Current model

POT is in-memory only:
- instantiate WASM bytes
- Terra compiles exported functions (`fn:compile()`)
- host reads raw function pointers (`fn:getpointer()`)

There is no per-module `.so`/AOT path in the runtime API.

## What affects compile time

- WASM parsing and Terra AST generation
- LLVM optimization/codegen
- number/shape of exported functions

## Practical controls

- `POT_NOOPT=1` reduces compile latency for iteration, at runtime-performance cost.
- `POT_PROFILE_COMPILE=1` prints per-function compile timing.
- `terralib.memoize(...)` is used so identical `(wasm bytes, compile opts, host import set)` does not recompile.

## Canonical host path

Use `POT.instantiate(...)` and runtime instance accessors:
- `POT.instance_export_count`
- `POT.instance_export_name`
- `POT.instance_export_sig`
- `POT.instance_export_ptr`
