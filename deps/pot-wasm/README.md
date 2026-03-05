# POT-WASM: Polyglot Optimizing Terra WASM Runtime

A high-performance WASM runtime built on Terra/LLVM.

## Quick Start

```lua
local POT = require("pot")

-- Load WASM (lazy by default - 3x faster)
local exports = POT.load_file("module.wasm")
exports.main()  -- First call triggers JIT for that function
```

### Eager Mode

```lua
-- Compile all functions upfront (predictable latency)
local exports = POT.load_file("module.wasm", {}, {eager = true})
```

## Performance

### Load Time

| Runtime | Load Time | Notes |
|---------|-----------|-------|
| **POT (lazy)** | 120 ms | Default, functions JIT on first call |
| **POT (eager)** | 385 ms | All functions compiled upfront |
| **wasmtime** | 3-4 ms | Fast JIT, but slower runtime |

### Runtime Performance

POT is **10-16% faster** than wasmtime on geometric mean across benchmarks:
- Recursion: **36% faster**
- Call chains: **31-165% faster**
- I64 operations: **25-52% faster**
- Float comparisons: **58-59% faster**

### Trade-offs

| Use Case | Recommended |
|----------|-------------|
| Long-running servers | POT (lazy) |
| Compute-heavy workloads | POT |
| CLI tools (< 1s) | wasmtime |
| CLI tools (> 1s) | POT |
| Development/REPL | POT (lazy) |

## API Reference

### JIT Functions

#### `POT.load_file(path, host_functions, opts)`
Load and JIT compile a WASM file.

```lua
-- Default: lazy mode (3x faster)
local exports = POT.load_file("app.wasm", {
    -- Optional host functions
    my_import = function(x) return x * 2 end,
})

-- Eager mode: compile all upfront
local exports = POT.load_file("app.wasm", {}, {eager = true})
```

#### `POT.load_module(wasm_bytes, host_functions, opts)`
Load and JIT compile WASM from bytes.

```lua
local f = io.open("app.wasm", "rb")
local bytes = f:read("*a")
f:close()

-- Default: lazy mode (3x faster)
local exports = POT.load_module(bytes)

-- Eager mode: compile all upfront
local exports = POT.load_module(bytes, {}, {eager = true})
```

#### `POT.compile_module(wasm_bytes, host_functions, opts)`
Compile WASM to Terra functions without initializing.

```lua
local compiled = POT.compile_module(bytes, {}, {
    auto_wasi = true,      -- Auto-provide WASI functions
    auto_c_imports = true, -- Auto-generate C imports
})
compiled.init_fn()  -- Initialize memory/globals
compiled.exports.my_func()
```

#### `POT.run(wasm_bytes, args)`
Run a WASM command-line program.

```lua
local exports = POT.run(bytes, {"arg1", "arg2"})
```

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
- `file_overhead_analysis.md` - Compile latency analysis
- `BENCHMARK_RESULTS.md` - Performance benchmarks
- `benchmarks/` - Benchmark scripts
- `test_*.wasm` - Test WASM files

## License

Same as Terra (MIT).
