-- GeoArrow benchmark: generated Arrow readers vs nanoarrow ArrowArrayView
-- Run: terra lib/arrow/geoarrow_bench.t
--
-- Fairness rules in this benchmark:
-- 1) Same dataset and same math on both sides.
-- 2) Strictly identical loop bounds (no extra points).
-- 3) Full result validation (all bbox fields, all rows for arrays).
-- 4) Separate benchmark modes:
--    - Terra loops: generated accessors vs nanoarrow view accessors.
--    - LuaJIT FFI batch calls: one call per iteration on both sides.

package.terrapath = "lib/?.t;lib/?/init.t;" .. (package.terrapath or "")
package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local arrow = require("arrow")
local ffi = require("ffi")

local ArrowArray = arrow.ArrowArray
local ArrowSchema = arrow.ArrowSchema
local T = arrow.types
local C = terralib.includec("stdlib.h")
local Cmath = terralib.includec("math.h")

io.stdout:setvbuf("no")

-- ============================================================
-- nanoarrow linkage + extern declarations
-- ============================================================

terralib.linklibrary("build/libnanoarrow.so")

local na_schema_init = terralib.externfunction("na_schema_init", {&ArrowSchema, int32} -> int32)
local na_schema_release = terralib.externfunction("na_schema_release", {&ArrowSchema} -> {})
local na_schema_alloc_children = terralib.externfunction("ArrowSchemaAllocateChildren", {&ArrowSchema, int64} -> int32)
local na_schema_set_name = terralib.externfunction("ArrowSchemaSetName", {&ArrowSchema, rawstring} -> int32)

local na_view_sizeof = terralib.externfunction("na_view_sizeof", {} -> int64)
local na_view_init = terralib.externfunction("na_view_init_from_schema", {&opaque, &ArrowSchema} -> int32)
local na_view_set = terralib.externfunction("na_view_set_array", {&opaque, &ArrowArray} -> int32)
local na_view_reset = terralib.externfunction("na_view_reset", {&opaque} -> {})
local na_view_get_double = terralib.externfunction("na_view_get_double", {&opaque, int64} -> double)
local na_view_list_offset = terralib.externfunction("na_view_list_child_offset", {&opaque, int64} -> int64)
local na_view_child = terralib.externfunction("na_view_child", {&opaque, int64} -> &opaque)
local na_view_length = terralib.externfunction("na_view_length", {&opaque} -> int64)

local NA_DOUBLE = 13
local NA_LIST = 26
local NA_STRUCT = 27

-- ============================================================
-- Shared benchmark structs
-- ============================================================

struct BBox { min_x: double; min_y: double; max_x: double; max_y: double }
struct Point { x: double; y: double }

-- Batch nanoarrow C kernels from deps/nanoarrow/dist/nanoarrow_ffi.c
local na_geo_bbox = terralib.externfunction("na_geo_bbox", {&opaque} -> BBox)
local na_geo_area = terralib.externfunction("na_geo_area", {&opaque, &double} -> {})
local na_geo_centroid = terralib.externfunction("na_geo_centroid", {&opaque, &Point} -> {})

-- ============================================================
-- Dataset: List<Struct<x: float64, y: float64>>
-- ============================================================

local N_POLYS = tonumber(os.getenv("N_POLYS")) or 10000
local N_VERTS = tonumber(os.getenv("N_VERTS")) or 64 -- +closing vertex
local N_ITERS = tonumber(os.getenv("N_ITERS")) or 100
local TOTAL_COORDS = N_POLYS * (N_VERTS + 1)

print(string.format("Dataset: %d polygons, %d vertices each (%d total coords)",
  N_POLYS, N_VERTS, TOTAL_COORDS))
print("GeoArrow layout: List<Struct<x: float64, y: float64>>")
print(string.format("Iterations: %d\n", N_ITERS))

local build_dataset = terra() : &ArrowArray
  var list = [&ArrowArray](C.calloc(1, sizeof(ArrowArray)))
  list.length = N_POLYS
  list.null_count = 0
  list.offset = 0
  list.n_buffers = 2
  list.n_children = 1

  var list_bufs = [&&opaque](C.calloc(2, sizeof([&opaque])))
  list_bufs[0] = nil
  var offsets = [&int32](C.calloc(N_POLYS + 1, sizeof(int32)))
  for i = 0, N_POLYS + 1 do
    offsets[i] = i * (N_VERTS + 1)
  end
  list_bufs[1] = offsets
  list.buffers = list_bufs

  var coord = [&ArrowArray](C.calloc(1, sizeof(ArrowArray)))
  coord.length = TOTAL_COORDS
  coord.null_count = 0
  coord.offset = 0
  coord.n_buffers = 1
  coord.n_children = 2

  var coord_bufs = [&&opaque](C.calloc(1, sizeof([&opaque])))
  coord_bufs[0] = nil
  coord.buffers = coord_bufs

  var x_arr = [&ArrowArray](C.calloc(1, sizeof(ArrowArray)))
  x_arr.length = TOTAL_COORDS
  x_arr.null_count = 0
  x_arr.offset = 0
  x_arr.n_buffers = 2
  x_arr.n_children = 0

  var x_bufs = [&&opaque](C.calloc(2, sizeof([&opaque])))
  x_bufs[0] = nil
  var xs = [&double](C.calloc(TOTAL_COORDS, sizeof(double)))
  x_bufs[1] = xs
  x_arr.buffers = x_bufs

  var y_arr = [&ArrowArray](C.calloc(1, sizeof(ArrowArray)))
  y_arr.length = TOTAL_COORDS
  y_arr.null_count = 0
  y_arr.offset = 0
  y_arr.n_buffers = 2
  y_arr.n_children = 0

  var y_bufs = [&&opaque](C.calloc(2, sizeof([&opaque])))
  y_bufs[0] = nil
  var ys = [&double](C.calloc(TOTAL_COORDS, sizeof(double)))
  y_bufs[1] = ys
  y_arr.buffers = y_bufs

  var PI = 3.14159265358979323846
  for p = 0, N_POLYS do
    var cx = [double](p % 100) * 10.0
    var cy = [double](p / 100) * 10.0
    var radius = 5.0
    var base = p * (N_VERTS + 1)

    -- Base ring points
    for v = 0, N_VERTS do
      var angle = 2.0 * PI * [double](v) / [double](N_VERTS)
      xs[base + v] = cx + radius * Cmath.cos(angle)
      ys[base + v] = cy + radius * Cmath.sin(angle)
    end

    -- Explicit closing point at index base + N_VERTS
    xs[base + N_VERTS] = xs[base]
    ys[base + N_VERTS] = ys[base]
  end

  var coord_children = [&&ArrowArray](C.calloc(2, sizeof([&ArrowArray])))
  coord_children[0] = x_arr
  coord_children[1] = y_arr
  coord.children = coord_children

  var list_children = [&&ArrowArray](C.calloc(1, sizeof([&ArrowArray])))
  list_children[0] = coord
  list.children = list_children

  return list
end

local dataset = build_dataset()

local setup_nanoarrow_view = terra(list_arr: &ArrowArray) : &opaque
  var schema: ArrowSchema
  na_schema_init(&schema, NA_LIST)
  na_schema_alloc_children(&schema, 1)
  na_schema_init(schema.children[0], NA_STRUCT)
  na_schema_set_name(schema.children[0], "coord")
  na_schema_alloc_children(schema.children[0], 2)
  na_schema_init(schema.children[0].children[0], NA_DOUBLE)
  na_schema_set_name(schema.children[0].children[0], "x")
  na_schema_init(schema.children[0].children[1], NA_DOUBLE)
  na_schema_set_name(schema.children[0].children[1], "y")

  var view_size = na_view_sizeof()
  var view = [&opaque](C.calloc(1, [uint64](view_size)))

  var rc = na_view_init(view, &schema)
  if rc ~= 0 then
    C.free(view)
    na_schema_release(&schema)
    return nil
  end

  rc = na_view_set(view, list_arr)
  if rc ~= 0 then
    na_view_reset(view)
    C.free(view)
    na_schema_release(&schema)
    return nil
  end

  na_schema_release(&schema)
  return view
end

local view = setup_nanoarrow_view(dataset)
assert(view ~= nil, "failed to initialize ArrowArrayView")
print("Nanoarrow ArrowArrayView initialized.\n")

-- ============================================================
-- Generated reader setup
-- ============================================================

local geom_type = T.list(T["struct"]({
  { name = "x", type = T.float64 },
  { name = "y", type = T.float64 },
}))
local schema = {{ name = "geom", type = geom_type }}
local reader = arrow.gen_reader(schema)

-- ============================================================
-- Benchmark helpers
-- ============================================================

local function bench(fn, ...)
  fn(...) -- warmup
  local t0 = os.clock()
  for i = 1, N_ITERS do
    fn(...)
  end
  local t1 = os.clock()
  local elapsed = t1 - t0
  local us_per_iter = elapsed * 1e6 / N_ITERS
  local m_coords = (N_ITERS * TOTAL_COORDS) / elapsed / 1e6
  return elapsed, us_per_iter, m_coords
end

local results = {}
local function record(op, method, elapsed, us_per_iter, m_coords)
  results[#results + 1] = {
    op = op,
    method = method,
    elapsed = elapsed,
    us_per_iter = us_per_iter,
    m_coords = m_coords,
  }
  print(string.format("  %-14s %9.1f us/iter  %8.0f M coords/sec", method, us_per_iter, m_coords))
end

local function assert_close(label, a, b, eps)
  assert(math.abs(a - b) <= eps, string.format("%s mismatch: %.17g vs %.17g", label, a, b))
end

local function assert_bbox_eq(label, a, b, eps)
  assert_close(label .. ".min_x", a.min_x, b.min_x, eps)
  assert_close(label .. ".min_y", a.min_y, b.min_y, eps)
  assert_close(label .. ".max_x", a.max_x, b.max_x, eps)
  assert_close(label .. ".max_y", a.max_y, b.max_y, eps)
end

-- ============================================================
-- Terra kernels: generated accessors vs ArrowArrayView accessors
-- ============================================================

local bbox_compiled = terra(list_arr: &ArrowArray) : BBox
  var out = BBox { 1e30, 1e30, -1e30, -1e30 }
  var coords = [reader.child.geom.array(`@list_arr)]

  for row: int64 = 0, list_arr.length do
    var slice = [reader.get.geom(`@list_arr, row)]
    for j: int64 = 0, slice.len do
      var idx = slice.start + j
      var x = [reader.child.geom.get.x(`coords, idx)]
      var y = [reader.child.geom.get.y(`coords, idx)]
      if x < out.min_x then out.min_x = x end
      if x > out.max_x then out.max_x = x end
      if y < out.min_y then out.min_y = y end
      if y > out.max_y then out.max_y = y end
    end
  end

  return out
end

local bbox_nanoarrow_terra = terra(list_view: &opaque) : BBox
  var out = BBox { 1e30, 1e30, -1e30, -1e30 }
  var struct_view = na_view_child(list_view, 0)
  var x_view = na_view_child(struct_view, 0)
  var y_view = na_view_child(struct_view, 1)
  var nrows = na_view_length(list_view)

  for row: int64 = 0, nrows do
    var start = na_view_list_offset(list_view, row)
    var stop = na_view_list_offset(list_view, row + 1)
    for idx: int64 = start, stop do
      var x = na_view_get_double(x_view, idx)
      var y = na_view_get_double(y_view, idx)
      if x < out.min_x then out.min_x = x end
      if x > out.max_x then out.max_x = x end
      if y < out.min_y then out.min_y = y end
      if y > out.max_y then out.max_y = y end
    end
  end

  return out
end

local area_compiled = terra(list_arr: &ArrowArray, areas: &double)
  var coords = [reader.child.geom.array(`@list_arr)]

  for row: int64 = 0, list_arr.length do
    var slice = [reader.get.geom(`@list_arr, row)]
    var sum = 0.0
    for j: int64 = 0, slice.len - 1 do
      var i0 = slice.start + j
      var i1 = i0 + 1
      var x0 = [reader.child.geom.get.x(`coords, i0)]
      var y0 = [reader.child.geom.get.y(`coords, i0)]
      var x1 = [reader.child.geom.get.x(`coords, i1)]
      var y1 = [reader.child.geom.get.y(`coords, i1)]
      sum = sum + (x0 * y1 - x1 * y0)
    end
    areas[row] = sum * 0.5
  end
end

local area_nanoarrow_terra = terra(list_view: &opaque, areas: &double)
  var struct_view = na_view_child(list_view, 0)
  var x_view = na_view_child(struct_view, 0)
  var y_view = na_view_child(struct_view, 1)
  var nrows = na_view_length(list_view)

  for row: int64 = 0, nrows do
    var start = na_view_list_offset(list_view, row)
    var stop = na_view_list_offset(list_view, row + 1)
    var sum = 0.0
    for idx: int64 = start, stop - 1 do
      var x0 = na_view_get_double(x_view, idx)
      var y0 = na_view_get_double(y_view, idx)
      var x1 = na_view_get_double(x_view, idx + 1)
      var y1 = na_view_get_double(y_view, idx + 1)
      sum = sum + (x0 * y1 - x1 * y0)
    end
    areas[row] = sum * 0.5
  end
end

local centroid_compiled = terra(list_arr: &ArrowArray, centroids: &Point)
  var coords = [reader.child.geom.array(`@list_arr)]

  for row: int64 = 0, list_arr.length do
    var slice = [reader.get.geom(`@list_arr, row)]
    var n = slice.len - 1 -- exclude duplicated closing point
    var sx = 0.0
    var sy = 0.0

    for j: int64 = 0, n do
      var idx = slice.start + j
      sx = sx + [reader.child.geom.get.x(`coords, idx)]
      sy = sy + [reader.child.geom.get.y(`coords, idx)]
    end

    if n > 0 then
      centroids[row] = Point { sx / [double](n), sy / [double](n) }
    else
      centroids[row] = Point { 0.0, 0.0 }
    end
  end
end

local centroid_nanoarrow_terra = terra(list_view: &opaque, centroids: &Point)
  var struct_view = na_view_child(list_view, 0)
  var x_view = na_view_child(struct_view, 0)
  var y_view = na_view_child(struct_view, 1)
  var nrows = na_view_length(list_view)

  for row: int64 = 0, nrows do
    var start = na_view_list_offset(list_view, row)
    var stop = na_view_list_offset(list_view, row + 1)
    var n = stop - start - 1 -- exclude duplicated closing point
    var sx = 0.0
    var sy = 0.0

    for idx: int64 = start, start + n do
      sx = sx + na_view_get_double(x_view, idx)
      sy = sy + na_view_get_double(y_view, idx)
    end

    if n > 0 then
      centroids[row] = Point { sx / [double](n), sy / [double](n) }
    else
      centroids[row] = Point { 0.0, 0.0 }
    end
  end
end

-- ============================================================
-- Full validation across all methods
-- ============================================================

print("=== Validation ===")

local bbox_cg = bbox_compiled(dataset)
local bbox_na_t = bbox_nanoarrow_terra(view)
assert_bbox_eq("bbox cg vs na-terra", bbox_cg, bbox_na_t, 1e-10)

local areas_cg = terralib.new(double[N_POLYS])
local areas_na_t = terralib.new(double[N_POLYS])
area_compiled(dataset, areas_cg)
area_nanoarrow_terra(view, areas_na_t)
for i = 0, N_POLYS - 1 do
  assert_close("area row " .. i, areas_cg[i], areas_na_t[i], 1e-6)
end

local centroids_cg = terralib.new(Point[N_POLYS])
local centroids_na_t = terralib.new(Point[N_POLYS])
centroid_compiled(dataset, centroids_cg)
centroid_nanoarrow_terra(view, centroids_na_t)
for i = 0, N_POLYS - 1 do
  assert_close("centroid.x row " .. i, centroids_cg[i].x, centroids_na_t[i].x, 1e-10)
  assert_close("centroid.y row " .. i, centroids_cg[i].y, centroids_na_t[i].y, 1e-10)
end

print(string.format("  bbox   = [%.1f, %.1f] - [%.1f, %.1f]",
  bbox_cg.min_x, bbox_cg.min_y, bbox_cg.max_x, bbox_cg.max_y))
print(string.format("  area[0] = %.6f", math.abs(areas_cg[0])))
print(string.format("  centroid[0] = (%.6f, %.6f)", centroids_cg[0].x, centroids_cg[0].y))

local expected_area = math.pi * 25.0
print(string.format("  expected area(circle r=5) ~= %.6f\n", expected_area))

-- ============================================================
-- Bench 1: Terra loops (no Lua in hot loop)
-- ============================================================

print("=== Bench 1: Terra loops ===")
print("  generated reader (direct pointers) vs nanoarrow view accessor calls")

local e, u, m

e, u, m = bench(bbox_compiled, dataset)
record("bbox", "cg-terra", e, u, m)

e, u, m = bench(bbox_nanoarrow_terra, view)
record("bbox", "na-terra", e, u, m)

e, u, m = bench(area_compiled, dataset, areas_cg)
record("area", "cg-terra", e, u, m)

e, u, m = bench(area_nanoarrow_terra, view, areas_na_t)
record("area", "na-terra", e, u, m)

e, u, m = bench(centroid_compiled, dataset, centroids_cg)
record("centroid", "cg-terra", e, u, m)

e, u, m = bench(centroid_nanoarrow_terra, view, centroids_na_t)
record("centroid", "na-terra", e, u, m)

-- ============================================================
-- Bench 2: LuaJIT FFI one-call-per-batch (symmetric)
-- ============================================================

print("\n=== Bench 2: LuaJIT FFI batch calls ===")
print("  one FFI call/iteration on BOTH sides")

terralib.saveobj("build/bench_compiled.so", {
  cg_geo_bbox = bbox_compiled,
  cg_geo_area = area_compiled,
  cg_geo_centroid = centroid_compiled,
})

ffi.cdef[[
  typedef struct { double min_x; double min_y; double max_x; double max_y; } CBox;
  typedef struct { double x; double y; } CPoint;

  CBox na_geo_bbox(const void* list_view);
  void na_geo_area(const void* list_view, double* areas);
  void na_geo_centroid(const void* list_view, CPoint* centroids);

  CBox cg_geo_bbox(void* list_arr);
  void cg_geo_area(void* list_arr, double* areas);
  void cg_geo_centroid(void* list_arr, CPoint* centroids);
]]

local na = ffi.load("build/libnanoarrow.so")
local cg = ffi.load("build/bench_compiled.so")

local view_ptr = ffi.cast("const void*", view)
local dataset_ptr = ffi.cast("void*", dataset)

local ffi_areas_na = ffi.new("double[?]", N_POLYS)
local ffi_areas_cg = ffi.new("double[?]", N_POLYS)
local ffi_centroids_na = ffi.new("CPoint[?]", N_POLYS)
local ffi_centroids_cg = ffi.new("CPoint[?]", N_POLYS)

local function bbox_ffi_na()
  return na.na_geo_bbox(view_ptr)
end

local function bbox_ffi_cg()
  return cg.cg_geo_bbox(dataset_ptr)
end

local function area_ffi_na()
  na.na_geo_area(view_ptr, ffi_areas_na)
end

local function area_ffi_cg()
  cg.cg_geo_area(dataset_ptr, ffi_areas_cg)
end

local function centroid_ffi_na()
  na.na_geo_centroid(view_ptr, ffi_centroids_na)
end

local function centroid_ffi_cg()
  cg.cg_geo_centroid(dataset_ptr, ffi_centroids_cg)
end

-- Validate FFI paths against Terra-generated baseline
local bb_na = bbox_ffi_na()
local bb_cg = bbox_ffi_cg()
assert_bbox_eq("bbox cg ffi vs terra", bb_cg, bbox_cg, 1e-10)
assert_bbox_eq("bbox na ffi vs terra", bb_na, bbox_cg, 1e-10)

area_ffi_na()
area_ffi_cg()
for i = 0, N_POLYS - 1 do
  assert_close("area ffi na row " .. i, ffi_areas_na[i], areas_cg[i], 1e-6)
  assert_close("area ffi cg row " .. i, ffi_areas_cg[i], areas_cg[i], 1e-6)
end

centroid_ffi_na()
centroid_ffi_cg()
for i = 0, N_POLYS - 1 do
  assert_close("centroid ffi na x row " .. i, ffi_centroids_na[i].x, centroids_cg[i].x, 1e-10)
  assert_close("centroid ffi na y row " .. i, ffi_centroids_na[i].y, centroids_cg[i].y, 1e-10)
  assert_close("centroid ffi cg x row " .. i, ffi_centroids_cg[i].x, centroids_cg[i].x, 1e-10)
  assert_close("centroid ffi cg y row " .. i, ffi_centroids_cg[i].y, centroids_cg[i].y, 1e-10)
end

print("  FFI validation passed")

-- Benchmark FFI batch mode

e, u, m = bench(bbox_ffi_na)
record("bbox-ffi", "na-ffi-batch", e, u, m)

e, u, m = bench(bbox_ffi_cg)
record("bbox-ffi", "cg-ffi-batch", e, u, m)

e, u, m = bench(area_ffi_na)
record("area-ffi", "na-ffi-batch", e, u, m)

e, u, m = bench(area_ffi_cg)
record("area-ffi", "cg-ffi-batch", e, u, m)

e, u, m = bench(centroid_ffi_na)
record("cent-ffi", "na-ffi-batch", e, u, m)

e, u, m = bench(centroid_ffi_cg)
record("cent-ffi", "cg-ffi-batch", e, u, m)

-- ============================================================
-- Summary
-- ============================================================

print("\n" .. string.rep("=", 76))
print("SUMMARY")
print(string.rep("=", 76))

local function print_pair(label, op, a, b)
  local ma, mb
  for _, r in ipairs(results) do
    if r.op == op and r.method == a then ma = r.m_coords end
    if r.op == op and r.method == b then mb = r.m_coords end
  end
  if ma and mb then
    print(string.format("  %-18s %11.0f M/s  %11.0f M/s  %7.2fx", label, ma, mb, ma / mb))
  end
end

print("\nTerra loops:")
print("  (generated direct pointers vs nanoarrow accessor calls)")
print_pair("bbox", "bbox", "cg-terra", "na-terra")
print_pair("area", "area", "cg-terra", "na-terra")
print_pair("centroid", "centroid", "cg-terra", "na-terra")

print("\nLuaJIT FFI batch calls:")
print("  (one batch call per iteration on both sides)")
print_pair("bbox", "bbox-ffi", "cg-ffi-batch", "na-ffi-batch")
print_pair("area", "area-ffi", "cg-ffi-batch", "na-ffi-batch")
print_pair("centroid", "cent-ffi", "cg-ffi-batch", "na-ffi-batch")

print("\nNotes:")
print("  - FFI batch mode removes per-element Lua<->C call overhead from the comparison.")
print("  - All methods are validated against the same generated-reader baseline.")
print(string.format("  - %d polygons x %d coords/ring = %d coords total, %d iterations",
  N_POLYS, N_VERTS + 1, TOTAL_COORDS, N_ITERS))
print(string.rep("=", 76))
