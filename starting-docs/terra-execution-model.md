# Terra's Execution Model

### How Lua and Terra interleave — and why it matters for Terroir

---

## The Two Phases

Terra is not a language with an FFI. It is a **staged metaprogramming system**. There are two phases of execution, and they happen in the same process:

| Phase | Language | What runs | When |
|-------|----------|-----------|------|
| **Stage 1** | Lua | Code generation logic, schema parsing, type resolution | Before and during compilation |
| **Stage 2** | Terra (compiled to native) | The generated code — pointer arithmetic, loops, math | After compilation, on real data |

The critical thing: **Stage 1 is not "build time" and Stage 2 is not "runtime".** Both happen in the same running process. Lua can generate and compile Terra code at any point, including after the program has started, in response to data it received over the network.

## A Simple Example

```lua
-- Stage 1: Lua runs
local offset = 42

-- This defines a Terra function. Lua runs NOW, Terra compiles LATER.
local add_offset = terra(x: int32) : int32
  -- The [offset] escape drops back to Lua, evaluates the variable,
  -- and splices the value 42 into the Terra code as a constant.
  return x + [offset]
end

-- Stage 1→2 boundary: Lua triggers compilation
add_offset:compile()

-- Stage 2: native machine code runs. No Lua involved.
add_offset(10)  -- returns 52
```

After `compile()`, `add_offset` is a raw function pointer. LLVM compiled it. The `+ 42` is baked into the instruction stream as an immediate operand. There is no table lookup, no variable reference, no Lua involvement. It's a single `add` instruction.

## The Escape Operator: `[ ]`

Square brackets inside Terra code are **escapes back to Lua**. They execute Lua at compilation time and splice the result into the Terra AST.

```lua
local function make_adder(n)
  -- Lua function that RETURNS a Terra quote
  return terra(x: int32) : int32
    return x + [n]      -- [n] evaluates in Lua, becomes a constant
  end
end

local add5 = make_adder(5)   -- Lua runs, generates Terra, compiles
local add10 = make_adder(10) -- different constant baked in

add5(3)   -- 8  (native code, no dispatch)
add10(3)  -- 13 (native code, no dispatch)
```

`make_adder` is a **code generator**. It's a Lua function that returns a Terra function. Each call produces different machine code with a different constant inlined.

## How This Works in the Arrow Accessor Generator

The arrow module (`lib/arrow/init.t`) uses this pattern everywhere. Here's the int32 type's accessor:

```lua
-- Stage 1: Lua defines a code generator
T.int32 = {
  gen_get = function(batch_sym, row_sym)
    -- This Lua function runs at compilation time.
    -- It returns a Terra QUOTE — a code fragment, not a value.
    return quote
      var col = [&int32]([batch_sym].buffers[1])
    in
      col[ [row_sym] ]
    end
  end,
}
```

`gen_get` is a Lua function. It takes Terra symbols (compile-time representations of variables) and returns a Terra quote (a code fragment). It never runs on real data. It runs once, during compilation, to produce the code that will run on real data.

When you write:

```lua
local reader = arrow.gen_reader(schema)  -- Lua runs: builds accessor tables

local read_val = terra(batch: &ArrowArray, row: int64) : int32
  -- [reader.get.val(...)] escapes to Lua, calls gen_get,
  -- which returns a quote, which gets spliced in here
  return [reader.get.val(`@batch, row)]
end
```

After compilation, `read_val` is machine code equivalent to:

```c
int32_t read_val(ArrowArray* batch, int64_t row) {
    return ((int32_t*)batch->buffers[1])[row];
}
```

One pointer cast. One array index. No dispatch, no switch, no function call. LLVM sees through the entire thing.

## The Runtime JIT Trick

Here's where it gets interesting. Because Lua and Terra live in the same process, and Terra's compiler is always available, you can do this **after the program starts**:

```lua
-- 1. Data arrives at runtime (e.g., from DataFusion)
--    It carries an ArrowSchema with format strings: "i", "g", "+l", "+s"
local schema_cdata = receive_schema_from_datafusion()

-- 2. Lua parses the schema (reads C struct via FFI)
local schema_table = parse_record_batch_schema(schema_cdata)
-- Result: {{ name="id", type=T.int32 }, { name="score", type=T.float64 }}

-- 3. Lua generates Terra code (gen_batch_reader builds accessor quotes)
local reader = arrow.gen_batch_reader(schema_table)

-- 4. Terra compiles to native code (LLVM JIT, ~milliseconds)
local process_fn = terra(batch: &ArrowArray)
  for row: int64 = 0, batch.length do
    var id = [reader.get.id(`@batch, row)]
    var score = [reader.get.score(`@batch, row)]
    -- ... process ...
  end
end
process_fn:compile()

-- 5. Native code runs on every batch (zero overhead per element)
for batch in batches do
  process_fn(batch)  -- pure machine code, no Lua
end
```

The schema was not known at build time. It arrived over FFI from DataFusion. But the compiled function has **zero per-element dispatch** — the types are baked into the instruction stream by LLVM, just as if you had written specialized C code by hand.

The cost is a few milliseconds of JIT compilation per unique schema. Schemas change rarely (once per query, once per layer). Batches flow through thousands of times. Compile once, run on every batch.

## What Terra Does NOT Do

Terra does **not** call Lua from inside a running Terra function. Once `process_fn(batch)` executes, it's pure machine code. If you need Lua logic at runtime, you'd call it explicitly through a function pointer — but that defeats the purpose.

The mental model:

```
Lua is the architect. It designs the building (generates code).
Terra is the building. It stands on its own (runs as native code).
The architect is not inside the building when people walk through it.
```

Escape brackets `[ ]` are the architect's pencil — they operate at design time, not at occupancy time.

## Comparison: Nanoarrow vs. Our Codegen

Nanoarrow is a generic Arrow library. It reads any column type at runtime via a switch:

```c
// Nanoarrow: runs this switch on EVERY element access
switch (array_view->storage_type) {
  case NANOARROW_TYPE_INT32: return data.as_int32[i];
  case NANOARROW_TYPE_INT64: return data.as_int64[i];
  case NANOARROW_TYPE_DOUBLE: return data.as_double[i];
  // ... 12 more cases ...
}
```

Our codegen resolves the type once (at Lua/compilation time) and emits only the one case that applies:

```c
// Our generated code: no switch, no dispatch
return ((int32_t*)batch->children[0]->buffers[1])[row];
```

For nested types like GeoArrow `List<Struct<x: float64, y: float64>>`, the difference compounds. Nanoarrow would need multiple `ArrowArrayView` objects and repeated dispatch. Our codegen flattens the entire child navigation chain at compile time:

```c
// Generated: batch → list child → struct child → x buffer
double* xs = (double*)batch->children[0]  // list
                           ->children[0]  // struct
                           ->children[0]  // x column
                           ->buffers[1];  // data buffer
return xs[idx];
```

LLVM can hoist the pointer chain out of the inner loop — it's all constant offsets from the batch pointer. The inner loop becomes a straight load from a register + scaled index.

## C ABI: JIT Through FFI

Terra functions compile to C ABI. A compiled Terra function is not a Lua closure or a wrapped object — it's a raw function pointer with the same calling convention as `gcc -O2` output. This means the JIT-compiled code is callable from **any language that can call C**.

This opens up a powerful pattern: **JIT-as-a-service**.

```
  Caller (any language)          Terra JIT (Lua + LLVM)
  ─────────────────────          ──────────────────────
  1. Send ArrowSchema ──────────→ 2. Lua parses format strings
                                  3. Lua generates Terra code
                                  4. LLVM compiles to native
  5. Receive function ptr ◄────── 4. Return C function pointer
  6. Call it on every batch
     (pure native, no FFI
      overhead per element)
```

### Concrete example: Luvit calling JIT-compiled accessors

In Terroir, the Luvit runtime (LuaJIT on libuv) receives Arrow batches from DataFusion. It could call into a Terra JIT service to get specialized processors:

```lua
-- Luvit side (LuaJIT FFI)
-- Receive schema from DataFusion
local schema = datafusion_query_schema(query)

-- Ask the Terra JIT to compile a processor for this schema
-- (Terra lives in the same process — it's all LuaJIT)
local process_batch = terra_jit.compile_processor(schema)

-- process_batch is now a C function pointer: void (*)(ArrowArray*)
-- Call it on every batch — no Lua involved in the hot path
for batch in datafusion_stream(query) do
  process_batch(batch)  -- native call, C ABI
end
```

### Why this matters

The traditional choices are:

1. **Interpret at runtime** (nanoarrow, generic C) — switch-dispatch per element, works for any schema
2. **Compile ahead of time** (codegen to .so) — zero dispatch, but schema must be known at build time
3. **JIT compile** (our approach) — zero dispatch AND schema discovered at runtime

Option 3 was historically the domain of complex JIT compilers (V8, LLVM ORC, GraalVM). Terra gives it to you in ~10 lines of Lua because the compiler is just a library call.

### Exporting to shared libraries

Terra can also save compiled functions to `.o` files or shared libraries:

```lua
-- Compile and save to a .so — now callable from C, Rust, Python, anything
terralib.saveobj("build/process_points.so", { process = process_fn })
```

This means you can:
- JIT-compile at deploy time (schema known from config) → save as `.so` → load from any language
- JIT-compile at query time (schema from DataFusion) → use the function pointer directly
- JIT-compile at startup (schema from first batch) → cache for the session

The function pointer is the universal interface. Terra's C ABI guarantee means there's no wrapper, no marshalling, no bridge. The pointer you get from `fn:compile()` is the same kind of pointer you'd get from `dlsym()`.

## Summary

| Concept | What it is |
|---------|-----------|
| `terra(x: int32) ... end` | Defines a function. Lua runs the body's escapes at compile time. |
| `[expr]` inside Terra | Escape to Lua. Evaluates `expr` in Lua, splices result into Terra. |
| `quote ... end` | A Terra code fragment. Not yet compiled — just a data structure. |
| `` `expr `` | A Terra expression quote (shorthand for single expressions). |
| `fn:compile()` | Triggers LLVM compilation. After this, `fn` is a native function pointer. |
| `gen_get(batch_sym, row_sym)` | A Lua function that returns a Terra quote. The code generator. |
| `gen_reader(schema)` | Lua function that builds a table of code generators from a schema. |
| `gen_batch_reader(schema)` | Same, but accessors navigate from record batch to column children. |

The pattern: **Lua decides what code to generate. Terra compiles it. LLVM optimizes it. Native code runs it.** All in one process, triggered whenever you need it.
