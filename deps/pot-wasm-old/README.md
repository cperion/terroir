# POT-WASM: Polyglot Optimizing Terra WASM Runtime

A WASM runtime built on Terra/LLVM with a canonical in-memory C ABI.

## Canonical API

```lua
local POT = require("pot")
local f = assert(io.open("module.wasm", "rb"))
local bytes = f:read("*a")
f:close()

local inst = POT.instantiate(bytes, {}, { eager = true })

local ffi = require("ffi")
local n = POT.instance_export_count(inst)
for i = 0, n - 1 do
  local name = POT.instance_export_name(inst, i)
  local sig = POT.instance_export_sig(inst, i)  -- e.g. "int32_t(*)(int32_t, int32_t)"
  local ptr = POT.instance_export_ptr(inst, i)
  local fn = ffi.cast(sig, ptr)
  print(name, fn)
end
```

Terra model:
- Each exported Terra function is compiled via `fn:compile()`.
- Function pointers are retrieved via `fn:getpointer()`.
- POT uses `terralib.memoize(...)` so the same module/options/import-set does not recompile.

Instance lifecycle API:
- `POT.instantiate(wasm_bytes, host_functions, opts)`
- `POT.instance_init(inst)` / `POT.instance_deinit(inst)`
- `POT.instance_export_count(inst)`
- `POT.instance_export_name(inst, i)` (`i` is zero-based, end-exclusive loops)
- `POT.instance_export_sig(inst, i)`
- `POT.instance_export_ptr(inst, i, ctype?)`
- `POT.instance_memory(inst)`
- `POT.instance_memory_size(inst)`

Compatibility wrappers (non-canonical):
- `POT.load_module(...)`
- `POT.load_file(...)`
- `POT.run(...)`

## Environment Variables

- `POT_NOOPT=1` - Disable LLVM optimization for faster JIT (30% faster compile, slower runtime)
- `POT_PROFILE_COMPILE=1` - Print per-function compile timing

## WASI Support

POT automatically provides WASI functions when a module imports from `wasi_snapshot_preview1`:

```lua
local exports = POT.load_file("wasi_app.wasm", {
    _wasi_args = {"--flag", "value"},  -- Command-line args
})
```

Supported WASI functions:
- `fd_write`, `fd_read`, `fd_seek`, `fd_close`
- `path_open`, `path_create_directory`
- `clock_time_get`, `clock_res_get`
- `args_get`, `args_sizes_get`
- `environ_get`, `environ_sizes_get`
- `proc_exit`

## Benchmarking

Run benchmarks comparing POT vs wasmtime vs wasmer:

```bash
cd benchmarks
./run.sh
```

See `BENCHMARK_RESULTS.md` for results.

## Building

POT requires Terra to be installed. No additional build step needed - it's pure Terra/Lua.

```bash
# Run tests
terra test_pot.t

# Run an example
terra examples/basic.t
```

## Files

- `pot.t` - Main POT implementation
- `BENCHMARK_RESULTS.md` - Performance benchmarks
- `benchmarks/` - Benchmark scripts
- `test_*.wasm` - Test WASM files

## License

Same as Terra (MIT).
