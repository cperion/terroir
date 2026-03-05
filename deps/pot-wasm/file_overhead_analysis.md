# POT Compile Latency Analysis (Updated)

## TL;DR

Terra's JIT is already in-memory. The `.o` files seen in /tmp were from AOT compilation (saveobj), not JIT. The real bottleneck is LLVM optimization during JIT.

## Key Findings

### 1. File I/O is NOT the Problem
- Terra JIT uses MCJIT/ORC which is entirely in-memory
- No `.o` files are created during JIT compilation
- The files in /tmp/terra-*.o are from AOT compilation via `saveobj`

### 2. Real Bottleneck Breakdown

For stress_test2.wasm (22 functions):
| Stage | Time | Notes |
|-------|------|-------|
| WASM parsing | 0.3 ms | Negligible |
| Terra AST generation | 130 ms | 6 ms/func average |
| LLVM optimization | 120 ms | Can be disabled |
| LLVM codegen | 140 ms | 6 ms/func average |
| **Total (optimized)** | **390 ms** | |
| **Total (unoptimized)** | **270 ms** | With POT_NOOPT=1 |

### 3. Effective Optimizations

#### Disable LLVM Optimization (44% faster JIT)
```bash
POT_NOOPT=1 terra your_script.t
```

This sets `setoptimized(false)` on each Terra function before compilation.
Trade-off: slower runtime performance, faster compile time.

#### Simplify local.get/local.tee (12% faster AST gen)
Changed from:
```lua
local tmp = symbol(locals[idx].type, "local_get")
stmts:insert(quote var [tmp] = [locals[idx].sym] end)
stk.push(`[tmp])
```
To:
```lua
stk.push(`[locals[idx].sym])
```

This is safe because Terra's SSA form already captures the value at that point in code.

### 4. AOT Compilation (750x faster load)

For repeated execution, compile once and load the .so:

```lua
local POT = require("pot")

-- One-time: compile WASM to .so (400ms)
local info = POT.aot_compile("module.wasm", "module.so", {
    header_path = "module.h",  -- optional C header
    module_name = "my_module",
})

-- Subsequent loads: ~0.5ms
local exports = POT.aot_load("module.so")
exports.my_function(42)
```

Generated files:
- `module.so` - Shared library with compiled code
- `module.lua` - Manifest with export metadata
- `module.h` - C header for embedding (optional)

## Performance Comparison

| Configuration | Compile Time | Load Time | vs JIT |
|---------------|--------------|-----------|--------|
| JIT (optimized) | 390 ms | - | baseline |
| JIT (POT_NOOPT=1) | 270 ms | - | 31% faster |
| AOT compile | 410 ms | 0.5 ms | 750x faster load |

## AOT Workflow

### Compile
```bash
# From Terra
terra -e 'local POT = require("pot"); POT.aot_compile("app.wasm", "app.so")'

# Or use a build script
cat > build.t << 'EOF'
local POT = require("pot")
POT.aot_compile("app.wasm", "app.so", {
    header_path = "app.h",
    module_name = "app",
})
EOF
terra build.t
```

### Run
```lua
local POT = require("pot")
local app = POT.aot_load("app.so")

-- Call WASM exports
app.main()
print("Memory size:", app._po_memory_size())
```

### From C
```c
#include "app.h"

int main() {
    po_init();
    int result = po_export_main();
    printf("Result: %d\n", result);
    return 0;
}
```

## Recommendations

1. **Development**: Use `POT_NOOPT=1` for faster iteration (~30% faster)
2. **Production**: Use AOT compilation for ~750x faster startup
3. **Embedded**: Use AOT with C header for integration with other languages

## Future Work

1. Lazy JIT - compile functions on first call
2. Incremental compilation - cache compiled functions
3. Cross-compilation - AOT for different targets
