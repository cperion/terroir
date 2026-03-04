# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Terroir is a compiled GIS pipeline platform with three layers:

- **Runtime layer**: Luvit (LuaJIT on libuv) — HTTP, service orchestration, effect system, supervision
- **Data layer**: DataFusion (Rust) via C API — SQL parsing, query planning, vectorized execution, produces Apache Arrow record batches
- **Compute layer**: Terra-compiled WASM modules specialized to native `.so` — geometry transforms, tile encoding, style evaluation, template rendering

The critical invariant: **Arrow is the data format between all layers.** DataFusion produces Arrow batches. Compiled modules consume them via generated pointer arithmetic. No serialization boundaries, no Arrow library at runtime.

## Architecture

### Core Libraries

- **Strata** (`lib/strata/init.lua`) — ~300-line compiler construction library. Schema-driven AST nodes (plain Lua tables), traversal (`S.walk`, `S.map`, `S.collect`, `S.fold`), structural pattern matching (`S.match`), and source-mapped diagnostics (`S.diag`). Used by all compilers in the project.

- **Ignis** (`lib/ignis.lua`) — Compiled HTML template engine. Takes Lua DSL template definitions, generates either byte-buffer writes (SSR) or DOM mutation functions (client WASM). Type-safe escaping resolved at compile time. Uses Strata for AST/diagnostics.

- **Arrow accessor generator** (`lib/arrow.lua`) — Compile-time schema → typed pointer arithmetic into Arrow columnar buffers. Handles fixed-width, variable-width, binary, GeoArrow, null bitmaps, and vectorized column filters with bitmask output.

- **Pipeline compiler** (`terroir.lua`) — Transforms pipeline definitions into self-describing WASM modules with embedded `terroir` custom sections. Uses Strata. Codegen stages: filter, transform (clip/simplify/reproject), style, output (MVT/PNG/GeoJSON/HTML), raster.

### Key Design Patterns

- **Terra metaprogramming**: Lua code runs at compile time to generate Terra code. Lua functions return Terra quotes (`quote ... end` and backtick expressions). Schema-driven code generation eliminates runtime dispatch.

- **Self-describing WASM modules**: Each `.wasm` carries a `terroir` custom section with its schema, requirements, provides, error channels, and ABI. The module is the single source of truth. The effect system reads these sections for build-time graph verification and runtime hot-swap validation.

- **Effect system**: Build-time verifier reads `terroir` sections from all `.wasm` files, checks dependency satisfaction, cycles, error channel handling, route conflicts, and Arrow schema compatibility. Emits `verified_graph.lua`. Runtime executor boots services in verified order, routes errors by disposition, manages Erlang-style supervision trees.

- **Zero-copy Arrow pipeline**: DataFusion allocates Arrow buffers → passed as pointers via FFI → compiled module reads columns via generated pointer arithmetic → output encoded directly into response buffer. Three zero-copies end to end.

### Data Flow (per request)

```
HTTP request → Luvit → DataFusion FFI (SQL → Arrow batches)
  → Compiled pipeline FFI (Arrow → filter/clip/simplify/encode)
  → Response buffer → HTTP response
```

## Testing

```bash
luajit lib/strata/test.lua
```

Tests use a simple pass/fail counter pattern — no external test framework. Each test file is self-contained and exits with code 1 on failure.

## Dependencies

- `deps/terra/` — Terra language compiler (git submodule, built with CMake + LLVM)

## Building Terra

```bash
cd deps/terra
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=../../terra-install
make -j$(nproc)
make install
```

Terra requires LLVM and Clang development libraries. See `deps/terra/README.md` for platform-specific prerequisites.

## Project Layout

```
starting-docs/     Design documents (terroir.md, strata.md, ignis.md)
deps/terra/        Terra language submodule
lib/               Core libraries (strata, ignis, arrow accessor gen)
pipelines/         Pipeline definitions (tiles/, queries/, views/, styles/)
host/              Luvit runtime (effects, supervisor, router, server)
terroir.lua        Pipeline compiler entry point
build/             Compiled output (.wasm, .so)
```

## Conventions

- AST nodes are plain Lua tables with a `kind` field. No metatables, no wrappers.
- Compiler passes are plain Lua functions. Pass ordering = calling order. Data flow = arguments and return values.
- Terra quotes are the codegen target. Lua functions that return Terra quotes are the code generators.
- Arrow column access is always generated pointer arithmetic — never use an Arrow library at runtime.
- Filter expressions compile to vectorized bitmask operations (64 rows per loop iteration, LLVM auto-vectorizes).
- Geometry is stored as WKB in binary columns or as coordinate arrays in GeoArrow layout.
- WASM modules carry their own metadata. Tooling reads the `terroir` custom section, never external config files.
