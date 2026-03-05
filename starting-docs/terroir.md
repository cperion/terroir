# Terroir

### Compiled GIS Pipelines on a Dynamic Runtime

*Internal Technical Proposal — v0.5*

---

## Overview

Terroir is a GIS platform built on three layers.

The **runtime layer** is Luvit (LuaJIT on libuv). It handles I/O, HTTP, service orchestration, the effect system, and supervision. Fully dynamic — services load, swap, rewire, and introspect at runtime.

The **data layer** is DataFusion through its C API. It handles SQL parsing, query planning, predicate pushdown, joins, aggregation, and vectorized execution. It produces Apache Arrow record batches — columnar, typed, zero-copy.

The **compute layer** is compiled WASM modules instantiated directly in-memory by the Terra runtime. Data filtering beyond SQL, geometry transforms, coordinate reprojection, tile encoding, style evaluation, and template rendering. Called from Luvit through LuaJIT FFI using exported function pointers. Pure computation — no I/O, no allocation outside linear memory.

The critical design: **Arrow is the data format between all three layers.** DataFusion produces Arrow batches. Compiled modules consume Arrow batches. No serialization, no deserialization, no row-to-column conversion. The data is allocated once by DataFusion and read in place through the entire pipeline. Terra generates Arrow-native accessor code from compile-time schemas — direct pointer arithmetic into Arrow's columnar buffers with no Arrow library at runtime.

Each WASM module is **self-describing**. It carries a custom section embedding its schema, requirements, provides, error channels, and ABI details. The module is the single source of truth for its own capabilities. The effect system verifies the full service graph at build time and re-validates on live hot-swap.

```
Luvit (LuaJIT + libuv)
├── HTTP, routing, config, caching, supervision
├── Effect system (wiring, error routing, lifecycle)
│
├── ffi.C.datafusion_*
│   SQL queries → Arrow record batches (zero-copy)
│
└── pot-wasm runtime via LuaJIT FFI
    load wasm bytes -> Terra JIT -> export function pointers
    Arrow batches → GIS output (MVT, PNG, HTML, GeoJSON)
    reads Arrow columns via generated pointer arithmetic
```

---

## Part I: The Data Layer

### 1. DataFusion via C API

DataFusion is a Rust-native query engine with a published C API (datafusion-c). It provides SQL parsing, logical and physical query planning, predicate pushdown, join execution, aggregation, and vectorized columnar processing. It operates natively on Apache Arrow record batches.

Luvit interacts with DataFusion through LuaJIT FFI:

```lua
local ffi = require("ffi")

ffi.cdef[[
  typedef struct DFSessionContext DFSessionContext;
  typedef struct DFDataFrame DFDataFrame;
  typedef struct ArrowSchema ArrowSchema;
  typedef struct ArrowArray ArrowArray;

  DFSessionContext* df_session_context_new();
  int df_register_parquet(DFSessionContext* ctx, const char* name, const char* path);
  int df_register_csv(DFSessionContext* ctx, const char* name, const char* path);
  DFDataFrame* df_sql(DFSessionContext* ctx, const char* query);
  int df_collect(DFDataFrame* df, ArrowArray*** batches, ArrowSchema** schema, int* n_batches);
  void df_free_batches(ArrowArray** batches, int n_batches);
  void df_free_schema(ArrowSchema* schema);
]]

local df = ffi.load("datafusion_c")
```

A query execution in Luvit:

```lua
local ctx = df.df_session_context_new()
df.df_register_parquet(ctx, "roads", "/data/roads.parquet")

local dataframe = df.df_sql(ctx,
  "SELECT geom, name, highway_type, lanes FROM roads WHERE bbox && make_bbox($1,$2,$3,$4)"
)

local batches = ffi.new("ArrowArray**[1]")
local schema = ffi.new("ArrowSchema*[1]")
local n_batches = ffi.new("int[1]")
df.df_collect(dataframe, batches, schema, n_batches)

-- batches[0] through batches[n_batches-1] are Arrow record batches
-- pass directly to a compiled runtime export pointer — zero copy
local rc = tile_roads_handle(
  z, x, y,
  batches[0], n_batches[0],  -- Arrow data, no conversion
  out_buf, out_len
)

df.df_free_batches(batches[0], n_batches[0])
```

DataFusion handles everything up to producing columnar data: parsing the SQL, optimizing the query plan, pushing predicates down to the data source, executing joins and aggregations, producing Arrow batches. Terroir's compiled modules handle everything after: reading the columns, applying GIS-specific transforms, encoding the output.

### 2. Data Sources

DataFusion supports multiple source types natively. Registration happens in Luvit at service boot:

```lua
function register_sources(ctx, config)
  for _, source in ipairs(config.sources) do
    if source.type == "parquet" then
      df.df_register_parquet(ctx, source.name, source.path)

    elseif source.type == "csv" then
      df.df_register_csv(ctx, source.name, source.path)

    elseif source.type == "postgres" then
      -- custom table provider: DataFusion queries are pushed down to PG
      register_postgres_provider(ctx, source.name, source.connection)

    elseif source.type == "geopackage" then
      -- custom provider: SQLite reads through DataFusion
      register_gpkg_provider(ctx, source.name, source.path)

    elseif source.type == "flatgeobuf" then
      -- custom provider: FGB with spatial index support
      register_fgb_provider(ctx, source.name, source.path)
    end
  end
end
```

Custom table providers for spatial formats (PostGIS, GeoPackage, FlatGeobuf) implement DataFusion's `TableProvider` trait in Rust, exposed through the C API. They handle spatial index lookups and predicate pushdown specific to each format. DataFusion treats them as regular tables — they participate in joins, aggregations, and query optimization like any other source.

### 3. Arrow as the Universal Data Format

Apache Arrow defines a columnar memory layout. The specification is simple:

**Fixed-width types** (int32, int64, float64, bool): a contiguous buffer of values. Element `i` is at `base_ptr + i * sizeof(type)`.

**Variable-width types** (utf8, binary): an offset buffer (int32 or int64 array) plus a data buffer. String `i` starts at `data[offsets[i]]` with length `offsets[i+1] - offsets[i]`.

**Null bitmaps**: one bit per value, LSB-first within each byte. Bit `i` is `(bitmap[i >> 3] >> (i & 7)) & 1`. A 1 bit means the value is valid (non-null).

**Nested types** (structs, lists): child arrays following the same layout, referenced from parent.

The C Data Interface defines two structs for zero-copy interchange:

```c
struct ArrowSchema {
  const char* format;       // "i" = int32, "u" = utf8, "Z" = binary, etc
  const char* name;
  int64_t n_children;
  struct ArrowSchema** children;
  void (*release)(struct ArrowSchema*);
  // ...
};

struct ArrowArray {
  int64_t length;           // number of elements
  int64_t null_count;
  int64_t offset;           // starting offset within buffers
  int64_t n_buffers;
  const void** buffers;     // [null_bitmap, (offsets)?, data]
  int64_t n_children;
  struct ArrowArray** children;
  void (*release)(struct ArrowArray*);
  // ...
};
```

This is not an abstraction layer. It's a memory layout contract. DataFusion allocates buffers in this layout. Compiled modules read from these buffers directly. No Arrow library is loaded, invoked, or linked. The layout is the interface.

---

## Part II: Compiled Arrow Access

### 4. Terra-Generated Arrow Readers

When a pipeline declares its source schema, the compiler generates typed accessor functions that read Arrow columns through direct pointer arithmetic. The schema is known at compile time; the generated code has no dispatch, no type switches, no schema lookups.

```lua
local function gen_arrow_reader(schema)
  local accessors = {}
  local null_checks = {}

  for i, col in ipairs(schema) do
    local col_idx = i - 1  -- zero-based in Arrow

    -- null check: same for all types
    null_checks[col.name] = function(batch_sym, row_sym)
      return quote
        var bitmap = [&uint8](batch_sym.columns[col_idx].buffers[0])
        var is_valid = (bitmap ~= nil) and
          ((bitmap[row_sym >> 3] and (1 << (row_sym and 7))) ~= 0)
      in
        is_valid
      end
    end

    if col.type == "int32" then
      accessors[col.name] = function(batch_sym, row_sym)
        return `[&int32](batch_sym.columns[col_idx].buffers[1])[row_sym]
      end

    elseif col.type == "int64" then
      accessors[col.name] = function(batch_sym, row_sym)
        return `[&int64](batch_sym.columns[col_idx].buffers[1])[row_sym]
      end

    elseif col.type == "float32" then
      accessors[col.name] = function(batch_sym, row_sym)
        return `[&float](batch_sym.columns[col_idx].buffers[1])[row_sym]
      end

    elseif col.type == "float64" then
      accessors[col.name] = function(batch_sym, row_sym)
        return `[&double](batch_sym.columns[col_idx].buffers[1])[row_sym]
      end

    elseif col.type == "bool" then
      accessors[col.name] = function(batch_sym, row_sym)
        return quote
          var bools = [&uint8](batch_sym.columns[col_idx].buffers[1])
          var val = (bools[row_sym >> 3] and (1 << (row_sym and 7))) ~= 0
        in
          val
        end
      end

    elseif col.type == "utf8" then
      accessors[col.name] = function(batch_sym, row_sym)
        return quote
          var offsets = [&int32](batch_sym.columns[col_idx].buffers[1])
          var data = [&uint8](batch_sym.columns[col_idx].buffers[2])
          var start = offsets[row_sym]
          var len = offsets[row_sym + 1] - start
        in
          { data = data + start, len = len }
        end
      end

    elseif col.type == "large_utf8" then
      accessors[col.name] = function(batch_sym, row_sym)
        return quote
          var offsets = [&int64](batch_sym.columns[col_idx].buffers[1])
          var data = [&uint8](batch_sym.columns[col_idx].buffers[2])
          var start = offsets[row_sym]
          var len = offsets[row_sym + 1] - start
        in
          { data = data + start, len = len }
        end
      end

    elseif col.type == "binary" then
      -- identical layout to utf8: offsets + data
      accessors[col.name] = function(batch_sym, row_sym)
        return quote
          var offsets = [&int32](batch_sym.columns[col_idx].buffers[1])
          var data = [&uint8](batch_sym.columns[col_idx].buffers[2])
          var start = offsets[row_sym]
          var len = offsets[row_sym + 1] - start
        in
          { data = data + start, len = len }
        end
      end

    elseif col.type == "fixed_binary" then
      local width = col.byte_width
      accessors[col.name] = function(batch_sym, row_sym)
        return quote
          var data = [&uint8](batch_sym.columns[col_idx].buffers[1])
        in
          { data = data + row_sym * [width], len = [width] }
        end
      end
    end
  end

  return { get = accessors, is_valid = null_checks }
end
```

For a schema `{highway_type: utf8, lanes: int32, geom: binary}`, the generated code for reading row `i` compiles to:

```terra
-- highway_type (utf8, column 0)
var ht_offsets = [&int32](batch.columns[0].buffers[1])
var ht_data = [&uint8](batch.columns[0].buffers[2])
var ht_start = ht_offsets[i]
var ht_len = ht_offsets[i + 1] - ht_start
var highway_type = { data = ht_data + ht_start, len = ht_len }

-- lanes (int32, column 1)
var lanes = [&int32](batch.columns[1].buffers[1])[i]

-- geom (binary, column 2)
var g_offsets = [&int32](batch.columns[2].buffers[1])
var g_data = [&uint8](batch.columns[2].buffers[2])
var g_start = g_offsets[i]
var g_len = g_offsets[i + 1] - g_start
var geom = { data = g_data + g_start, len = g_len }
```

This is pointer arithmetic. No Arrow library, no virtual dispatch, no type switch. The column index, the buffer index, and the element type are all compile-time constants. LLVM sees through the pointer casts and optimizes the access patterns.

### 5. Geometry Access from Arrow

Geometries in Arrow are stored as WKB (Well-Known Binary) in binary columns, or as coordinate arrays in GeoArrow's native layout. The compiler generates specialized decoders for each.

#### 5.1 WKB Geometry (standard layout)

```lua
local function gen_wkb_reader(geom_type)
  if geom_type == "linestring" then
    return function(data_ptr, data_len)
      return quote
        -- WKB linestring layout:
        -- byte 0: endianness (1 = little endian)
        -- bytes 1-4: geometry type (2 = linestring)
        -- bytes 5-8: point count (uint32)
        -- bytes 9+: coordinate pairs (double, double) × count
        var p = [&uint8](data_ptr)
        var n_points = @[&uint32](p + 5)
        var coords = [&double](p + 9)
        -- coords[i*2] = x, coords[i*2+1] = y
      in
        { coords = coords, n_points = n_points }
      end
    end

  elseif geom_type == "polygon" then
    return function(data_ptr, data_len)
      return quote
        var p = [&uint8](data_ptr)
        var n_rings = @[&uint32](p + 5)
        var cursor = p + 9
        -- first ring is exterior, rest are holes
        var rings: RingArray
        for r = 0, n_rings do
          var n_points = @[&uint32](cursor)
          cursor = cursor + 4
          rings[r] = { coords = [&double](cursor), n_points = n_points }
          cursor = cursor + n_points * 16  -- 2 doubles × 8 bytes
        end
      in
        { rings = rings, n_rings = n_rings }
      end
    end
  end
end
```

#### 5.2 GeoArrow Native (coordinate arrays)

GeoArrow encodes geometries as nested Arrow arrays — a point column is two float64 columns (x, y), a linestring column adds an offsets array, a polygon adds two levels of offsets. The generated reader follows the Arrow nesting:

```lua
local function gen_geoarrow_linestring_reader(col_idx)
  return function(batch_sym, row_sym)
    return quote
      -- linestring column: offsets into coordinate array
      var ls_offsets = [&int32](batch_sym.columns[col_idx].buffers[1])
      var start = ls_offsets[row_sym]
      var n_points = ls_offsets[row_sym + 1] - start

      -- child 0: x coordinates, child 1: y coordinates
      var xs = [&double](batch_sym.columns[col_idx].children[0].buffers[1])
      var ys = [&double](batch_sym.columns[col_idx].children[1].buffers[1])
    in
      { xs = xs + start, ys = ys + start, n_points = n_points }
    end
  end
end
```

GeoArrow's struct-of-arrays layout is inherently SIMD-friendly — x coordinates are contiguous, y coordinates are contiguous. The compiled transform code can process them with vector instructions directly.

### 6. Vectorized Filtering on Arrow Columns

Because Arrow data is columnar, filters can operate on entire columns at once instead of row-by-row. The compiler generates vectorized filter code that produces bitmasks — 64 rows evaluated per loop iteration, auto-vectorized by LLVM.

```lua
local function gen_vectorized_filter(expr, schema)
  local col_idx = schema_index(schema, expr.field_name)

  if expr.op == ">" and is_fixed_width(schema[col_idx]) then
    local T = terra_type_for(schema[col_idx].type)
    local threshold = expr.literal_value
    return function(batch_sym, mask_sym)
      return quote
        var col = [&T](batch_sym.columns[col_idx].buffers[1])
        var n = batch_sym.length
        var n_blocks = (n + 63) / 64

        for block = 0, n_blocks do
          var bits: uint64 = 0
          var base = block * 64
          -- inner loop: LLVM auto-vectorizes this
          for j = 0, 64 do
            var idx = base + j
            if idx < n and col[idx] > [threshold] then
              bits = bits or (1ULL << j)
            end
          end
          mask_sym[block] = bits
        end
      end
    end

  elseif expr.op == "in" and schema[col_idx].type == "utf8" then
    -- string IN (...): build a hash set at compile time
    local hash = build_perfect_hash(expr.values)
    return function(batch_sym, mask_sym)
      return quote
        var offsets = [&int32](batch_sym.columns[col_idx].buffers[1])
        var data = [&uint8](batch_sym.columns[col_idx].buffers[2])
        var n = batch_sym.length
        var n_blocks = (n + 63) / 64

        for block = 0, n_blocks do
          var bits: uint64 = 0
          var base = block * 64
          for j = 0, 64 do
            var idx = base + j
            if idx < n then
              var start = offsets[idx]
              var len = offsets[idx + 1] - start
              if [hash]:lookup(data + start, len) then
                bits = bits or (1ULL << j)
              end
            end
          end
          mask_sym[block] = bits
        end
      end
    end

  elseif expr.op == "and" then
    local left_gen = gen_vectorized_filter(expr.left, schema)
    local right_gen = gen_vectorized_filter(expr.right, schema)
    return function(batch_sym, mask_sym)
      return quote
        -- two bitmask arrays, then AND them
        var left_mask: uint64[MAX_BLOCKS]
        var right_mask: uint64[MAX_BLOCKS]
        [left_gen(batch_sym, left_mask)]
        [right_gen(batch_sym, right_mask)]
        var n_blocks = (batch_sym.length + 63) / 64
        for block = 0, n_blocks do
          mask_sym[block] = left_mask[block] and right_mask[block]
        end
      end
    end
  end
end
```

For `highway_type IN ('motorway','trunk','primary') AND lanes > 1`, the generated code:

1. Scans the `highway_type` utf8 column, producing a 64-bit mask per block using a perfect hash lookup
2. Scans the `lanes` int32 column, producing a 64-bit mask per block using a vectorized comparison
3. ANDs the two masks

The result is a bitmask where set bits indicate rows that pass the filter. Downstream stages (geometry transforms, encoding) iterate only the set bits. LLVM vectorizes the integer comparison loop with SIMD — processing 4 or 8 int32 values per instruction.

This operates at the same level as DataFusion's own vectorized execution, but for GIS-specific predicates (spatial intersections, distance filters) that DataFusion doesn't know about natively.

### 7. Combining DataFusion and Compiled Filters

The query pipeline naturally splits: DataFusion handles SQL-expressible filters (attribute predicates, joins, aggregations), and compiled modules handle GIS-specific filters (spatial predicates, geometry-dependent conditions) on the result.

```lua
local tile_roads = pipeline {
  name = "tile_roads";
  input = { z = int, x = int, y = int };

  -- DataFusion handles: attribute filter, column selection, sort
  source = datafusion {
    sql = [[
      SELECT geom, name, highway_type, lanes
      FROM roads
      WHERE highway_type IN ('motorway','trunk','primary','secondary')
      ORDER BY highway_type
    ]];
    -- spatial filter pushed to the table provider
    spatial = bbox_filter("geom", tile_bbox(input.z, input.x, input.y));
  };

  -- compiled module handles: GIS-specific post-processing
  transform = {
    -- additional filter: compiled, vectorized, on Arrow columns
    filter(field "lanes" > zoom_threshold(input.z)),

    -- geometry: compiled, specialized to linestring
    clip_to_bbox(),
    simplify(zoom_tolerance(input.z)),
  };

  output = mvt { layer = "roads", extent = 4096 };
}
```

DataFusion's query optimizer can push the spatial predicate down to the table provider (PostGIS does the spatial index lookup, FlatGeobuf uses its built-in R-tree). The attribute filter (`highway_type IN (...)`) is handled by DataFusion's vectorized execution. The result arrives as Arrow batches.

The compiled module then applies additional filters that are zoom-dependent or geometry-dependent — things DataFusion can't express. These run as vectorized bitmask operations on the Arrow columns. The geometry transforms (clip, simplify) operate on the WKB/GeoArrow geometry column, reading directly from Arrow buffers.

The full flow for a tile request:

```
1. Luvit receives request: GET /tiles/roads/12/1024/2048.mvt
2. Luvit computes bbox from z/x/y
3. Luvit calls DataFusion via FFI:
   - DataFusion plans query (pushes spatial filter to provider)
   - DataFusion executes: table scan → filter → project → sort
   - DataFusion returns ArrowArray** (columnar, zero-copy)
4. Luvit passes Arrow batches to compiled module via FFI:
   - module reads Arrow columns (generated pointer arithmetic)
   - module applies compiled GIS filter (vectorized bitmask)
   - module clips geometries (compiled Sutherland-Hodgman)
   - module simplifies (compiled Douglas-Peucker, inlined tolerance)
   - module encodes MVT (compiled, schema-specific protobuf)
   - module writes output bytes to buffer
5. Luvit sends response, frees Arrow batches
```

Zero-copy from DataFusion through the compiled pipeline. The Arrow buffers allocated by DataFusion are the same buffers read by the geometry clipper and the MVT encoder. No intermediate representation, no serialization, no object construction.

---

## Part III: Self-Describing Modules

### 8. The Module as the Unit of Truth

A Terroir WASM module is a standard WASM binary with a custom section named `terroir`. Generated by the pipeline compiler from the same AST as the executable code, it describes the module's full capabilities, requirements, and data contracts.

```
tile_roads.wasm
│
├── WASM standard sections
│   ├── code     (compiled pipeline)
│   ├── memory   (linear memory for scratch buffers)
│   └── export   (entry: tile_roads_handle)
│
└── WASM custom section: "terroir"
    ├── version: 1
    ├── identity
    │   ├── name: "tile_roads"
    │   ├── kind: "tile_pipeline"
    │   └── content_type: "application/vnd.mapbox-vector-tile"
    │
    ├── requires
    │   ├── { name: "datafusion", type: "query_engine" }
    │   └── { name: "cache", type: "tile_cache", config: { ttl: 3600 } }
    │
    ├── provides
    │   ├── { name: "endpoint", type: "http",
    │   │     method: "GET", pattern: "/tiles/roads/{z}/{x}/{y}.mvt" }
    │   └── { name: "tile_data", type: "stream",
    │         schema_ref: "output.schema" }
    │
    ├── errors
    │   ├── { code: 1, name: "empty_result", disposition: "expected" }
    │   ├── { code: 2, name: "geometry_invalid", disposition: "log_warn_skip" }
    │   └── { code: 3, name: "output_overflow", disposition: "fatal" }
    │
    ├── input
    │   ├── params: { z: int32, x: int32, y: int32 }
    │   └── arrow_schema:
    │       ├── { name: "geom", type: "binary" }
    │       ├── { name: "name", type: "utf8", nullable: true }
    │       ├── { name: "highway_type", type: "utf8" }
    │       └── { name: "lanes", type: "int32" }
    │
    ├── output
    │   └── schema:
    │       ├── format: "mvt"
    │       ├── layer: "roads"
    │       └── extent: 4096
    │
    ├── source
    │   ├── type: "datafusion"
    │   ├── sql: "SELECT geom, name, highway_type, lanes FROM roads ..."
    │   └── spatial_filter: "bbox_filter(geom, tile_bbox(z, x, y))"
    │
    └── abi
        ├── entry: "tile_roads_handle"
        ├── signature: "(i32, i32, i32, ptr, i32, ptr, ptr) -> i32"
        ├── params: [z, x, y, arrow_batches, n_batches, out_buf, out_len]
        ├── return: "error_code"
        └── max_output_size: 524288
```

The `arrow_schema` in the `input` section describes exactly which Arrow columns the compiled module expects and in what order. The host uses this to validate that DataFusion's output matches the module's expectations — at build time by inspecting the registered table schemas, and at runtime by comparing against the `ArrowSchema` returned by DataFusion.

### 9. Schema Compatibility

When the host wires a DataFusion query to a compiled module, it verifies that the Arrow schema produced by the query matches the schema the module expects:

```lua
function validate_arrow_compat(df_schema, module_schema)
  for _, expected in ipairs(module_schema) do
    local found = false
    for j = 0, df_schema.n_children - 1 do
      local child = df_schema.children[j]
      local name = ffi.string(child.name)
      if name == expected.name then
        local format = ffi.string(child.format)
        if not arrow_format_matches(format, expected.type) then
          return false, string.format(
            "column '%s': DataFusion produces %s, module expects %s",
            name, format, expected.type
          )
        end
        found = true
        break
      end
    end
    if not found then
      return false, string.format("column '%s' not in DataFusion output", expected.name)
    end
  end
  return true
end
```

This runs once at service boot and again during hot-swap. If a pipeline is recompiled with a different schema, the host catches the mismatch before the module is swapped in.

---

## Part IV: The Effect System

### 10. Build-Time Verification

At build time, Terra's Lua reads the `terroir` section from every `.wasm` file and verifies the service graph:

```lua
local function verify_graph(wasm_dir)
  local modules = {}
  for _, path in ipairs(list_wasm_files(wasm_dir)) do
    local meta = read_terroir_section(path)
    modules[meta.identity.name] = { meta = meta, path = path }
  end

  local errors = {}

  -- 1. all requirements satisfiable
  for name, mod in pairs(modules) do
    for _, req in ipairs(mod.meta.requires) do
      if not find_provider(req, modules) then
        table.insert(errors, string.format(
          "service '%s' requires '%s' (type: %s) — no provider\n  defined in: %s",
          name, req.name, req.type, mod.path
        ))
      end
    end
  end

  -- 2. no dependency cycles
  local cycle = find_cycle(build_dep_graph(modules))
  if cycle then
    table.insert(errors, "circular dependency: " .. table.concat(cycle, " → "))
  end

  -- 3. all error channels handled or declared
  for name, mod in pairs(modules) do
    for _, err in ipairs(mod.meta.errors) do
      if err.disposition == "propagate" then
        for _, consumer in ipairs(find_consumers(name, modules)) do
          if not handles_error(consumer, name, err.name) then
            table.insert(errors, string.format(
              "'%s' propagates '%s' but consumer '%s' doesn't handle it",
              name, err.name, consumer.meta.identity.name
            ))
          end
        end
      end
    end
  end

  -- 4. no route conflicts
  check_route_conflicts(modules, errors)

  -- 5. service-to-service schema compatibility
  check_schema_compat(modules, errors)

  -- 6. arrow schema compatibility with declared DataFusion queries
  check_arrow_compat(modules, errors)

  if #errors > 0 then
    for _, e in ipairs(errors) do io.stderr:write("error: " .. e .. "\n\n") end
    os.exit(1)
  end

  emit_verified_graph(modules)
end
```

The output is `verified_graph.lua` — topological boot order, wiring plan, error routing table, supervision tree. The runtime loads it and follows the plan.

### 11. Runtime Execution

The Luvit effect runtime boots services in verified order, resolves per-request requirements, routes errors by disposition, and manages supervision trees.

**Boot:**

```lua
local graph = dofile("verified_graph.lua")

function effects.boot()
  -- create shared DataFusion context
  local df_ctx = df.df_session_context_new()
  register_sources(df_ctx, graph.data_sources)

  for _, entry in ipairs(graph.boot_order) do
    local wasm = assert(read_file(entry.wasm_path))
    local inst = pot.instantiate(wasm, {
      _wasi_args = entry.wasi_args or {},
    }, { eager = true })
    local ptr = pot.instance_export_ptr(inst, entry.meta.abi.entry_index)
    local fn = ffi.cast(entry.meta.abi.entry_ffi, ptr)
    services[entry.name] = {
      inst = inst,
      fn = fn,
      meta = entry.meta,
      ctx = provision_requirements(entry, df_ctx),
    }
    register_routes(entry.meta.provides)
  end
end
```

**Per-request:**

```lua
function handle_request(req, res)
  local route = router:match(req.method, req.path)
  if not route then return res:send(404) end

  local svc = services[route.service]
  local ctx = effects.resolve(svc, req)
  if not ctx then return res:send(503) end

  -- run DataFusion query if this service has a source
  local batches, n_batches = nil, 0
  if svc.meta.source then
    batches, n_batches = execute_query(ctx.datafusion, svc.meta.source, route.params)
  end

  -- call compiled pipeline
  local buf = output_buffer_pool:acquire(svc.meta.abi.max_output_size)
  local out_len = ffi.new("int32_t[1]")

  local rc = svc.fn(
    route.params.z or 0, route.params.x or 0, route.params.y or 0,
    batches, n_batches,
    buf, out_len
  )

  if rc == 0 then
    res:set_header("Content-Type", svc.meta.identity.content_type)
    res:send(200, ffi.string(buf, out_len[0]))
  else
    effects.handle_error(svc, rc, req, res)
  end

  output_buffer_pool:release(buf)
  if batches then df.df_free_batches(batches, n_batches) end
  effects.release(ctx)
end
```

### 12. Live Hot-Swap

When a module recompiles, the host reads the new module's `terroir` section, validates against the live graph (requirements satisfiable, schemas compatible, routes clean), instantiates it in-memory, and atomically swaps:

```lua
function effects.hot_swap(wasm_path)
  local new_meta = read_terroir_section(wasm_path)
  local name = new_meta.identity.name

  -- validate against live graph
  local issues = validate_live(new_meta, services)
  if #issues > 0 then
    log.error("hot-swap rejected for '%s':", name)
    for _, issue in ipairs(issues) do log.error("  %s", issue) end
    return false
  end

  -- validate arrow schema against DataFusion
  local df_schema = get_query_schema(new_meta.source)
  local ok, reason = validate_arrow_compat(df_schema, new_meta.input.arrow_schema)
  if not ok then
    log.error("hot-swap rejected: arrow schema mismatch: %s", reason)
    return false
  end

  -- instantiate and swap
  local wasm = assert(read_file(wasm_path))
  local new_inst = pot.instantiate(wasm, {
    _wasi_args = new_meta.wasi_args or {},
  }, { eager = true })
  local new_ptr = pot.instance_export_ptr(new_inst, new_meta.abi.entry_index)
  local new_fn = ffi.cast(new_meta.abi.entry_ffi, new_ptr)

  local old = services[name]
  services[name] = {
    inst = new_inst,
    fn = new_fn,
    meta = new_meta,
    ctx = reconcile_requirements(old and old.ctx, new_meta.requires),
  }
  if old and old.inst then
    pot.instance_deinit(old.inst)
  end
  update_routes(old and old.meta.provides, new_meta.provides, name)

  log.info("hot-swapped '%s'", name)
  return true
end
```

~150ms from source edit to live service. Validation catches breaking changes before swap. Rejection keeps the old version running.

### 13. Supervision

Erlang-style supervision trees in Luvit. Strategies: `one_for_one` (restart only failed child), `one_for_all` (restart all children if one fails), `rest_for_one` (restart failed child and all after it). Max restart rate limiting with escalation.

```lua
function supervisor:handle_failure(service_name, error_info)
  local child = self:find(service_name)
  if exceeds_restart_rate(child) then
    log.error("'%s' exceeded restart rate, escalating", service_name)
    return self:escalate(child)
  end

  log.info("restarting '%s'", service_name)

  if child.strategy == "one_for_one" then
    reload_service(service_name)
  elseif child.strategy == "one_for_all" then
    for _, sibling in ipairs(child.group) do
      reload_service(sibling)
    end
  end
end
```

---

## Part V: The Compute Layer

### 14. Pipeline Stage Codegen

Each pipeline stage has a code generator: a Lua function that takes AST nodes and emits Terra quotes operating on Arrow data.

#### 14.1 Filters (Row-Based, on Arrow)

For predicates that must check per-row (e.g., involving geometry), the generated filter reads Arrow columns directly:

```lua
local function gen_row_filter(expr, arrow_reader, batch_sym, row_sym)
  if expr.op == "field" then
    return arrow_reader.get[expr.name](batch_sym, row_sym)
  elseif expr.op == "literal" then
    return `[expr.value]
  elseif expr.op == ">" then
    local l = gen_row_filter(expr.left, arrow_reader, batch_sym, row_sym)
    local r = gen_row_filter(expr.right, arrow_reader, batch_sym, row_sym)
    return `l > r
  elseif expr.op == "and" then
    local l = gen_row_filter(expr.left, arrow_reader, batch_sym, row_sym)
    local r = gen_row_filter(expr.right, arrow_reader, batch_sym, row_sym)
    return `l and r
  end
end
```

#### 14.2 Coordinate Reprojection

EPSG codes known at compile time. Math generated directly, constants inlined:

```lua
local function gen_reproject(from_srid, to_srid)
  if from_srid == 4326 and to_srid == 3857 then
    return terra(lon: double, lat: double): {double, double}
      var x = lon * 20037508.34 / 180.0
      var lat_rad = lat * 3.14159265358979 / 180.0
      var y = C.log(C.tan(0.7853981633974483 + lat_rad * 0.5))
            * 20037508.34 / 3.14159265358979
      return {x, y}
    end
  else
    local chain = proj_chain(from_srid, to_srid)
    return gen_transform_chain(chain)
  end
end
```

#### 14.3 Geometry Operations

Specialized to the known geometry type from the Arrow schema. Polygon clipping: unrolled Sutherland-Hodgman. Linestring clipping: Cohen-Sutherland. Simplification: Douglas-Peucker with inlined tolerance.

The generated clipper reads coordinates directly from the Arrow binary/GeoArrow column — no geometry object construction, no intermediate representation.

#### 14.4 Style Compilation

Style rules compile to decision trees. Match conditions are branches. Zoom interpolation is lerp with constant breakpoints. No style interpreter, no cascade resolver.

#### 14.5 MVT Encoding

Schema-specific protobuf encoding. Tags are constants. Key table is a constant byte array. Varint encoding is inlined. Feature encoding iterates fields in known order. Geometry encoding reads from the Arrow buffers.

#### 14.6 HTML Templates (Ignis)

For UI endpoints: flat buffer writes for SSR, mount/patch functions for client WASM. The template compiler reads data from Arrow batches using the generated accessors — the same data flows from DataFusion through the template without conversion.

### 15. The WASM Runtime Compiler

Already built. Takes `.wasm`, walks bytecode at Terra compile time, emits specialized Terra code per-opcode, compiles with Terra/LLVM, and exposes C-ABI function pointers. The runtime memoizes compilation by module/options/import identity. Performance is at or above hand-written C.

---

## Part VI: Client Modules and Raster

### 16. Browser Deployment

Same `.wasm` files serve as browser modules. Client-side use: local filtering on cached Arrow batches (DataFusion-compiled queries can run in the browser via WASM builds of DataFusion), style preview, DOM rendering via Ignis.

### 17. Raster Pipelines

```lua
local ndvi = pipeline {
  name = "ndvi";
  input = { z = int, x = int, y = int };

  source = datafusion {
    sql = "SELECT nir, red FROM sentinel2 WHERE tile_id = make_tile_id($1,$2,$3)";
  };

  compute = raster_expr(function(nir, red)
    return (nir - red) / (nir + red)
  end);

  output = png {
    colormap = gradient {
      [-1.0] = rgb(0xA0, 0x40, 0x00);
      [ 0.0] = rgb(0xF0, 0xF0, 0xF0);
      [ 1.0] = rgb(0x00, 0x80, 0x00);
    };
    width = 256; height = 256;
  };
}
```

The `raster_expr` compiles to a per-pixel Terra function. Raster bands come from DataFusion as Arrow fixed-width columns — the pixel loop reads directly from the Arrow buffers. LLVM auto-vectorizes, processing 4-8 pixels per SIMD instruction.

### 18. User-Defined Pipelines

Users write DSL expressions in the UI. These compile at request time through the same pipeline compiler to sandboxed `.wasm` modules. Filter expressions compile in single-digit milliseconds. The output module is instantiated directly by pot-wasm and reads Arrow data through generated accessors like any other module.

---

## Part VII: Build, Deploy, Tooling

### 19. Project Structure

```
project/
├── pipelines/
│   ├── tiles/
│   │   ├── roads.lua
│   │   ├── buildings.lua
│   │   └── terrain.lua
│   ├── queries/
│   │   ├── parcels.lua
│   │   └── layers.lua
│   ├── views/
│   │   ├── dashboard.lua
│   │   └── layer_manager.lua
│   └── styles/
│       ├── topo.lua
│       └── satellite.lua
├── host/
│   ├── effects.lua
│   ├── supervisor.lua
│   ├── router.lua
│   └── server.lua
├── lib/
│   ├── strata.lua              # ~300 lines
│   ├── ignis.lua               # template compiler
│   └── arrow.lua               # Arrow accessor generator
├── terroir.lua                 # pipeline compiler
└── build/
```

### 20. Build and Deploy

```bash
$ terroir build

[compile] tiles/roads.lua        → build/tile_roads.wasm        (14 KB)
[compile] tiles/buildings.lua    → build/tile_buildings.wasm     (10 KB)
[compile] tiles/terrain.lua      → build/tile_terrain.wasm       (24 KB)
[compile] queries/parcels.lua    → build/query_parcels.wasm      (5 KB)
[compile] queries/layers.lua     → build/query_layers.wasm       (4 KB)
[compile] views/dashboard.lua    → build/view_dashboard.wasm     (16 KB)
[compile] views/layer_manager.lua→ build/view_layers.wasm        (7 KB)
[verify]  arrow schemas: all consistent with DataFusion sources
[verify]  effect graph: all requirements satisfied, no cycles
[verify]  error channels: all handled
[verify]  routes: no conflicts
7 pipelines, 80 KB total

$ terroir deploy --target x86_64-linux

[instantiate] 7 modules loaded via pot-wasm runtime
[boot] DataFusion context: 3 sources registered
[boot] services loaded in dependency order
[listen] :8080

$ terroir dev --watch

[watch] pipelines/ — sub-100ms reload, runtime re-instantiation
```

### 21. Tooling

All tooling reads the `terroir` custom section from `.wasm` files:

```bash
terroir inspect tile_roads.wasm     # module capabilities
terroir graph                       # live service graph
terroir diff old.wasm new.wasm      # schema/abi changes, compatibility
terroir validate build/             # full graph verification
```

---

## Part VIII: Component Summary

```
Terroir
│
├── Strata                           ~300 lines Lua
│   AST nodes, traversal, pattern matching, diagnostics
│
├── Ignis                            template compiler (Lua/Terra)
│   HTML → buffer writes (SSR) or DOM mutations (WASM)
│
├── Arrow Accessor Generator         Lua/Terra
│   compile-time schema → typed pointer arithmetic into Arrow buffers
│   fixed-width, variable-width, binary, GeoArrow, null bitmaps
│   vectorized column filters with bitmask output
│
├── Pipeline Compiler                Lua/Terra, uses Strata
│   pipeline definitions → .wasm with embedded terroir section
│   ├── filter codegen        (row + vectorized, on Arrow columns)
│   ├── transform codegen     (clip, simplify, reproject)
│   ├── style codegen         (rules → decision trees)
│   ├── output codegen        (MVT, PNG, GeoJSON, HTML)
│   ├── raster codegen        (per-pixel expressions, SIMD)
│   └── terroir section       (self-description from same AST)
│
├── pot-wasm Runtime                 Terra/Lua (already built)
│   .wasm -> Terra compile -> C-ABI function pointers
│
├── DataFusion                       Rust, via C API (datafusion-c)
│   SQL → Arrow record batches
│   ├── query planning + optimization
│   ├── predicate pushdown
│   ├── spatial table providers (PostGIS, GeoPackage, FGB)
│   └── vectorized columnar execution
│
├── Effect System
│   ├── build-time verifier          Lua (Terra compile-time)
│   │   reads terroir sections from .wasm files
│   │   dependency, cycle, error, route, schema checks
│   │   Arrow schema compatibility with DataFusion sources
│   │   emits verified_graph.lua
│   │
│   └── runtime executor             LuaJIT (Luvit)
│       boot, resolve, error routing, supervision, hot-swap
│       re-validates on hot-swap against live graph + Arrow schemas
│
├── Host                             Luvit (LuaJIT + libuv)
│   HTTP, routing, DataFusion FFI, pot-wasm FFI, caching, pools
│
└── Client Modules                   .wasm served to browser
    Ignis DOM, client-side filter/style, optional DataFusion-WASM
```

---

### Data Flow Summary

```
DataFusion (Rust)
    produces Arrow record batches (columnar, zero-copy)
        │
        │ ArrowArray* passed via FFI (pointer, no copy)
        ▼
Compiled Pipeline (WASM -> pot-wasm -> Terra native pointers)
    reads Arrow columns via generated pointer arithmetic
    filters, clips, simplifies, reprojects, styles, encodes
    writes output bytes to caller-provided buffer
        │
        │ ffi.string(buf, len)
        ▼
Luvit (LuaJIT)
    sends HTTP response
```

Three zero-copies. Data allocated once by DataFusion. Read in place through the entire pipeline. Output encoded directly into the response buffer.

---

*Terroir: DataFusion queries it. Terra compiles it. Arrow carries it. The module describes itself. The work is all that's left.*
