-- Experiment: runtime schema → JIT-compiled Arrow accessors
-- Terra's compiler is available at runtime via LuaJIT.
-- Flow: receive ArrowSchema → parse format strings → gen_reader → JIT compile → call
--
-- Run: terra lib/arrow/jit_test.t

package.terrapath = "lib/?.t;lib/?/init.t;" .. (package.terrapath or "")
package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local ffi = require("ffi")
local arrow = require("arrow")

local ArrowArray = arrow.ArrowArray
local ArrowSchema = arrow.ArrowSchema
local Slice = arrow.Slice
local ListSlice = arrow.ListSlice
local T = arrow.types

local function clone_type(typ)
  local out = {}
  for k, v in pairs(typ) do out[k] = v end
  return out
end

local function parse_metadata_kv(meta_ptr)
  local kv = {}
  if meta_ptr == nil then return kv end

  local p = ffi.cast("const uint8_t*", meta_ptr)
  local function read_i32()
    local v = ffi.cast("const int32_t*", p)[0]
    p = p + 4
    return tonumber(v)
  end

  local n = read_i32()
  if n == nil or n < 0 or n > 100000 then
    return kv
  end

  for _ = 1, n do
    local klen = read_i32()
    if not klen or klen < 0 then break end
    local key = ffi.string(ffi.cast("const char*", p), klen)
    p = p + klen

    local vlen = read_i32()
    if not vlen or vlen < 0 then break end
    local val = ffi.string(ffi.cast("const char*", p), vlen)
    p = p + vlen

    kv[key] = val
  end

  return kv
end

local function apply_schema_attrs(typ, schema_cdata)
  local out = typ
  local md = parse_metadata_kv(schema_cdata.metadata)
  local ext_name = md["ARROW:extension:name"]
  local ext_meta = md["ARROW:extension:metadata"] or ""
  if ext_name and out.id ~= "extension" then
    out = T.extension(out, ext_name, ext_meta)
  end

  -- Preserve ArrowSchema flags on the parsed type object.
  local flags = tonumber(schema_cdata.flags) or 0
  out = clone_type(out)
  out.schema_flags = flags
  out.dictionary_ordered = (flags % 2) == 1
  out.nullable = (math.floor(flags / 2) % 2) == 1
  out.map_keys_sorted = (math.floor(flags / 4) % 2) == 1
  return out
end

-- ============================================================
-- Nanoarrow FFI (same as test.t)
-- ============================================================

ffi.cdef[[
  struct ArrowArray {
    int64_t length;
    int64_t null_count;
    int64_t offset;
    int64_t n_buffers;
    int64_t n_children;
    const void** buffers;
    struct ArrowArray** children;
    struct ArrowArray* dictionary;
    void (*release)(struct ArrowArray*);
    void* private_data;
  };

  struct ArrowSchema {
    const char* format;
    const char* name;
    const char* metadata;
    int64_t flags;
    int64_t n_children;
    struct ArrowSchema** children;
    struct ArrowSchema* dictionary;
    void (*release)(struct ArrowSchema*);
    void* private_data;
  };

  int na_array_init(struct ArrowArray* array, int type);
  int na_array_start(struct ArrowArray* array);
  int na_array_append_int(struct ArrowArray* array, int64_t value);
  int na_array_append_uint(struct ArrowArray* array, uint64_t value);
  int na_array_append_double(struct ArrowArray* array, double value);
  int na_array_append_string(struct ArrowArray* array, const char* value);
  int na_array_append_null(struct ArrowArray* array);
  int na_array_finish(struct ArrowArray* array);
  void na_array_release(struct ArrowArray* array);
  int na_array_allocate_children(struct ArrowArray* array, int64_t n_children);
  int na_array_finish_element(struct ArrowArray* array);
  int na_schema_init(struct ArrowSchema* schema, int type);
  int na_schema_set_fixed_size(struct ArrowSchema* schema, int type, int32_t byte_width);
  void na_schema_release(struct ArrowSchema* schema);
]]

local na = ffi.load("build/libnanoarrow.so")

local NA_INT32  = 8
local NA_INT64  = 10
local NA_DOUBLE = 13
local NA_STRING = 14
local NA_LIST   = 26
local NA_STRUCT = 27

-- ============================================================
-- Test helpers
-- ============================================================

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL: " .. name .. "\n") end
end

-- ============================================================
-- Runtime schema parser: Arrow format strings → type objects
-- ============================================================

-- Arrow C Data Interface format string spec:
--   "c" → int8, "s" → int16, "i" → int32, "l" → int64
--   "C" → uint8, "S" → uint16, "I" → uint32, "L" → uint64
--   "e" → half_float, "f" → float32, "g" → float64, "b" → bool
--   "u" → utf8, "U" → large_utf8, "z" → binary, "Z" → large_binary
--   "vu" → string_view, "vz" → binary_view
--   "tdD" → date32, "tdm" → date64
--   "tiM"/"tiD"/"tin" → interval_{months,day_time,month_day_nano}
--   "tts"/"ttm" → time32[s/ms], "ttu"/"ttn" → time64[us/ns]
--   "tsX:tz" → timestamp(unit X in s/m/u/n, timezone tz)
--   "tDX" → duration(unit X in s/m/u/n)
--   "d:p,s[,bits]" → decimal32/64/128/256
--   "w:N" → fixed_binary(N)
--   "+l"/"+L" → list/large_list, "+vl"/"+vL" → list_view/large_list_view
--   "+m" → map, "+w:N" → fixed_list(N), "+s" → struct
--   "+us:ids"/"+ud:ids" → sparse/dense union
--   "+r" → run_end_encoded

local format_to_type = {
  n = T.na,
  c = T.int8,    s = T.int16,   i = T.int32,   l = T.int64,
  C = T.uint8,   S = T.uint16,  I = T.uint32,  L = T.uint64,
  e = T.half_float, f = T.float32, g = T.float64, b = T.bool,
  u = T.utf8,    U = T.large_utf8,
  z = T.binary,  Z = T.large_binary,
  vu = T.string_view, vz = T.binary_view,
  tdD = T.date32, tdm = T.date64,
  tiM = T.interval_months, tiD = T.interval_day_time, tin = T.interval_month_day_nano,
}

-- Forward declaration for recursion
local parse_schema_type

-- Parse a single ArrowSchema node into a type object
-- schema_cdata: FFI pointer to struct ArrowSchema
function parse_schema_type(schema_cdata)
  local fmt = ffi.string(schema_cdata.format)

  local typ

  -- Simple flat types
  if format_to_type[fmt] then
    typ = format_to_type[fmt]
  end

  -- Time32/Time64
  if not typ then
    local tunit = fmt:match("^tt([smun])$")
    if tunit then
      if tunit == "s" or tunit == "m" then
        typ = T.time32(tunit)
      else
        typ = T.time64(tunit)
      end
    end
  end

  -- Timestamp: "ts<unit>:<timezone>"
  if not typ then
    local ts_unit, ts_tz = fmt:match("^ts([smun]):(.*)$")
    if ts_unit then
      typ = T.timestamp(ts_unit, ts_tz)
    end
  end

  -- Duration: "tD<unit>"
  if not typ then
    local dunit = fmt:match("^tD([smun])$")
    if dunit then
      typ = T.duration(dunit)
    end
  end

  -- Decimal: "d:precision,scale[,bits]" (bits omitted => 128)
  if not typ then
    local p, s, bits = fmt:match("^d:(%-?%d+),(%-?%d+),?(%d*)$")
    if p then
      p = tonumber(p)
      s = tonumber(s)
      local bw = bits ~= "" and tonumber(bits) or 128
      if bw == 32 then
        typ = T.decimal32(p, s)
      elseif bw == 64 then
        typ = T.decimal64(p, s)
      elseif bw == 128 then
        typ = T.decimal128(p, s)
      elseif bw == 256 then
        typ = T.decimal256(p, s)
      else
        error("unsupported decimal bit width: " .. tostring(bw))
      end
    end
  end

  -- Fixed-size binary: "w:N"
  if not typ then
    local fbw = fmt:match("^w:(%d+)$")
    if fbw then
      typ = T.fixed_binary(tonumber(fbw))
    end
  end

  -- Struct: "+s"
  if not typ and fmt == "+s" then
    local fields = {}
    for j = 0, tonumber(schema_cdata.n_children) - 1 do
      local child = schema_cdata.children[j]
      fields[#fields + 1] = {
        name = ffi.string(child.name),
        type = parse_schema_type(child),
      }
    end
    typ = T["struct"](fields)
  end

  -- List: "+l"
  if not typ and fmt == "+l" then
    assert(schema_cdata.n_children == 1)
    typ = T.list(parse_schema_type(schema_cdata.children[0]))
  end

  -- Large list: "+L"
  if not typ and fmt == "+L" then
    assert(schema_cdata.n_children == 1)
    typ = T.large_list(parse_schema_type(schema_cdata.children[0]))
  end

  -- List view: "+vl"
  if not typ and fmt == "+vl" then
    assert(schema_cdata.n_children == 1)
    typ = T.list_view(parse_schema_type(schema_cdata.children[0]))
  end

  -- Large list view: "+vL"
  if not typ and fmt == "+vL" then
    assert(schema_cdata.n_children == 1)
    typ = T.large_list_view(parse_schema_type(schema_cdata.children[0]))
  end

  -- Map: "+m" (child is Struct<key, value>)
  if not typ and fmt == "+m" then
    assert(schema_cdata.n_children == 1)
    local entries = parse_schema_type(schema_cdata.children[0])
    assert(entries.id == "struct" and #entries.fields == 2,
      "map child must be struct<key, value>")
    typ = T.map(entries.fields[1].type, entries.fields[2].type)
  end

  -- Sparse union: "+us:id0,id1,..."
  if not typ then
    local ids = fmt:match("^%+us:(.*)$")
    if ids ~= nil then
      local fields = {}
      for j = 0, tonumber(schema_cdata.n_children) - 1 do
        local child = schema_cdata.children[j]
        fields[#fields + 1] = {
          name = ffi.string(child.name),
          type = parse_schema_type(child),
        }
      end
      local type_ids = {}
      if ids ~= "" then
        for id in ids:gmatch("[^,]+") do
          type_ids[#type_ids + 1] = tonumber(id)
        end
      end
      typ = T.sparse_union(fields, (#type_ids > 0) and type_ids or nil)
    end
  end

  -- Dense union: "+ud:id0,id1,..."
  if not typ then
    local ids = fmt:match("^%+ud:(.*)$")
    if ids ~= nil then
      local fields = {}
      for j = 0, tonumber(schema_cdata.n_children) - 1 do
        local child = schema_cdata.children[j]
        fields[#fields + 1] = {
          name = ffi.string(child.name),
          type = parse_schema_type(child),
        }
      end
      local type_ids = {}
      if ids ~= "" then
        for id in ids:gmatch("[^,]+") do
          type_ids[#type_ids + 1] = tonumber(id)
        end
      end
      typ = T.dense_union(fields, (#type_ids > 0) and type_ids or nil)
    end
  end

  -- Run-end encoded: "+r"
  if not typ and fmt == "+r" then
    assert(schema_cdata.n_children == 2)
    local run_ends = parse_schema_type(schema_cdata.children[0])
    local values = parse_schema_type(schema_cdata.children[1])
    typ = T.run_end_encoded(run_ends, values)
  end

  -- Fixed-size list: "+w:N"
  if not typ then
    local flsz = fmt:match("^%+w:(%d+)$")
    if flsz then
      assert(schema_cdata.n_children == 1)
      typ = T.fixed_list(parse_schema_type(schema_cdata.children[0]), tonumber(flsz))
    end
  end

  if not typ then
    error("unsupported Arrow format: " .. fmt)
  end

  typ = apply_schema_attrs(typ, schema_cdata)

  -- Dictionary-encoded arrays have index storage in this schema node and
  -- the dictionary value schema in schema_cdata.dictionary.
  if schema_cdata.dictionary ~= nil then
    typ = T.dictionary(typ, parse_schema_type(schema_cdata.dictionary))
    typ = apply_schema_attrs(typ, schema_cdata)
  end

  return typ
end

-- Parse a top-level record-batch schema (struct of columns) into
-- the schema table that gen_reader expects
local function parse_record_batch_schema(schema_cdata)
  assert(ffi.string(schema_cdata.format) == "+s",
    "record batch schema must be struct, got: " .. ffi.string(schema_cdata.format))
  local columns = {}
  for j = 0, tonumber(schema_cdata.n_children) - 1 do
    local child = schema_cdata.children[j]
    columns[#columns + 1] = {
      name = ffi.string(child.name),
      type = parse_schema_type(child),
    }
  end
  return columns
end

-- ============================================================
-- JIT compiler: schema → native function
-- ============================================================

-- Compile a scanner: takes a record batch (struct ArrowArray),
-- calls body_fn(reader, batch_sym, row_sym) for each row.
-- Returns a callable Terra function.
local function jit_compile_scan(schema_table, body_fn)
  local reader = arrow.gen_batch_reader(schema_table)
  local batch_sym = symbol(&ArrowArray, "batch")
  local row_sym = symbol(int64, "row")

  local body = body_fn(reader, batch_sym, row_sym)

  local fn = terra([batch_sym])
    for [row_sym] = 0, [batch_sym].length do
      [body]
    end
  end

  -- Force compilation now (Terra JITs on first call anyway,
  -- but this makes timing cleaner)
  fn:compile()
  return fn
end

-- ============================================================
-- Test 1: Flat columns — runtime schema discovery
-- ============================================================

io.stdout:setvbuf("no")
print("=== JIT test 1: flat columns from runtime schema ===")

do
  -- Simulate receiving data from DataFusion:
  -- Build the data array (struct with 2 children: id:int32, score:double)
  local batch = ffi.new("struct ArrowArray")
  assert(na.na_array_init(batch, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(batch, 2) == 0)
  assert(na.na_array_init(batch.children[0], NA_INT32) == 0)
  assert(na.na_array_init(batch.children[1], NA_DOUBLE) == 0)
  assert(na.na_array_start(batch) == 0)

  local data = {
    {1, 10.5}, {2, 20.3}, {3, 30.7}, {4, 40.1}, {5, 50.9},
  }
  for _, row in ipairs(data) do
    assert(na.na_array_append_int(batch.children[0], row[1]) == 0)
    assert(na.na_array_append_double(batch.children[1], row[2]) == 0)
    assert(na.na_array_finish_element(batch) == 0)
  end
  assert(na.na_array_finish(batch) == 0)

  -- Build a mock ArrowSchema (simulating what DataFusion exports via FFI).
  -- Anchor all string buffers to prevent GC.
  local _keep = {}
  local function cstr(s)
    local buf = ffi.new("char[?]", #s + 1, s)
    _keep[#_keep + 1] = buf
    return buf
  end

  local id_schema = ffi.new("struct ArrowSchema")
  id_schema.format = cstr("i"); id_schema.name = cstr("id")
  id_schema.n_children = 0; id_schema.release = nil

  local score_schema = ffi.new("struct ArrowSchema")
  score_schema.format = cstr("g"); score_schema.name = cstr("score")
  score_schema.n_children = 0; score_schema.release = nil

  local child_ptrs = ffi.new("struct ArrowSchema*[2]")
  child_ptrs[0] = id_schema; child_ptrs[1] = score_schema

  local root_schema = ffi.new("struct ArrowSchema")
  root_schema.format = cstr("+s"); root_schema.name = cstr("")
  root_schema.n_children = 2; root_schema.children = child_ptrs
  root_schema.release = nil

  -- === THE KEY PART: runtime schema → JIT-compiled reader ===

  -- Step 1: Parse the schema at runtime (Lua reads the C struct)
  local schema_table = parse_record_batch_schema(root_schema)

  -- Verify parse
  check("jit1: parsed 2 columns", #schema_table == 2)
  check("jit1: col 0 name", schema_table[1].name == "id")
  check("jit1: col 0 type", schema_table[1].type.id == "int32")
  check("jit1: col 1 name", schema_table[2].name == "score")
  check("jit1: col 1 type", schema_table[2].type.id == "float64")

  -- Step 2: JIT-compile a specialized sum function
  local sum_id = global(int64, 0)
  local sum_score = global(double, 0.0)

  local scan_fn = jit_compile_scan(schema_table, function(reader, batch_sym, row_sym)
    -- reader was generated from the runtime-discovered schema
    -- this code compiles to direct pointer arithmetic, no dispatch
    return quote
      sum_id = sum_id + [reader.get.id(batch_sym, row_sym)]
      sum_score = sum_score + [reader.get.score(batch_sym, row_sym)]
    end
  end)

  -- Step 3: Run it
  sum_id:set(0)
  sum_score:set(0.0)
  local ptr = ffi.cast("void*", batch)
  scan_fn(ptr)

  check("jit1: sum_id = 15", sum_id:get() == 15)
  check("jit1: sum_score ~ 152.5", math.abs(sum_score:get() - 152.5) < 0.01)

  na.na_array_release(batch)
end

-- ============================================================
-- Test 2: Nested — List<Struct<x,y>> from runtime schema
-- ============================================================

print("=== JIT test 2: GeoArrow from runtime schema ===")

do
  -- Build List<Struct<x: float64, y: float64>>
  -- 2 geometries: geom0 = [(1,2), (3,4), (5,6)], geom1 = [(7,8)]
  local batch = ffi.new("struct ArrowArray")
  assert(na.na_array_init(batch, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(batch, 1) == 0)

  -- child 0: List
  local list_arr = batch.children[0]
  assert(na.na_array_init(list_arr, NA_LIST) == 0)
  assert(na.na_array_allocate_children(list_arr, 1) == 0)

  -- list child: Struct<x, y>
  local coord_struct = list_arr.children[0]
  assert(na.na_array_init(coord_struct, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(coord_struct, 2) == 0)
  assert(na.na_array_init(coord_struct.children[0], NA_DOUBLE) == 0)
  assert(na.na_array_init(coord_struct.children[1], NA_DOUBLE) == 0)

  assert(na.na_array_start(batch) == 0)

  -- geom0: [(1,2), (3,4), (5,6)]
  local coords0 = {{1,2}, {3,4}, {5,6}}
  for _, c in ipairs(coords0) do
    assert(na.na_array_append_double(coord_struct.children[0], c[1]) == 0)
    assert(na.na_array_append_double(coord_struct.children[1], c[2]) == 0)
    assert(na.na_array_finish_element(coord_struct) == 0)
  end
  assert(na.na_array_finish_element(list_arr) == 0)
  assert(na.na_array_finish_element(batch) == 0)

  -- geom1: [(7,8)]
  assert(na.na_array_append_double(coord_struct.children[0], 7) == 0)
  assert(na.na_array_append_double(coord_struct.children[1], 8) == 0)
  assert(na.na_array_finish_element(coord_struct) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)
  assert(na.na_array_finish_element(batch) == 0)

  assert(na.na_array_finish(batch) == 0)

  -- Build schema (simulating DataFusion export)
  local _keep = {}
  local function cstr(s)
    local buf = ffi.new("char[?]", #s + 1, s)
    _keep[#_keep + 1] = buf
    return buf
  end

  local x_schema = ffi.new("struct ArrowSchema")
  x_schema.format = cstr("g"); x_schema.name = cstr("x")
  x_schema.n_children = 0; x_schema.release = nil

  local y_schema = ffi.new("struct ArrowSchema")
  y_schema.format = cstr("g"); y_schema.name = cstr("y")
  y_schema.n_children = 0; y_schema.release = nil

  local coord_children = ffi.new("struct ArrowSchema*[2]")
  coord_children[0] = x_schema; coord_children[1] = y_schema

  local coord_schema = ffi.new("struct ArrowSchema")
  coord_schema.format = cstr("+s"); coord_schema.name = cstr("item")
  coord_schema.n_children = 2; coord_schema.children = coord_children
  coord_schema.release = nil

  local list_children = ffi.new("struct ArrowSchema*[1]")
  list_children[0] = coord_schema

  local geom_schema = ffi.new("struct ArrowSchema")
  geom_schema.format = cstr("+l"); geom_schema.name = cstr("geom")
  geom_schema.n_children = 1; geom_schema.children = list_children
  geom_schema.release = nil

  local root_children = ffi.new("struct ArrowSchema*[1]")
  root_children[0] = geom_schema

  local root_schema = ffi.new("struct ArrowSchema")
  root_schema.format = cstr("+s"); root_schema.name = cstr("")
  root_schema.n_children = 1; root_schema.children = root_children
  root_schema.release = nil

  -- === Runtime schema → JIT-compiled GeoArrow traversal ===

  local schema_table = parse_record_batch_schema(root_schema)

  check("jit2: 1 column", #schema_table == 1)
  check("jit2: col name", schema_table[1].name == "geom")
  check("jit2: col type", schema_table[1].type.id == "list")

  -- JIT-compile a bounding box calculator
  local min_x = global(double, 1e30)
  local max_x = global(double, -1e30)
  local min_y = global(double, 1e30)
  local max_y = global(double, -1e30)
  local total_coords = global(int64, 0)

  local reader = arrow.gen_batch_reader(schema_table)

  local bbox_fn = terra(batch: &ArrowArray)
    for row: int64 = 0, batch.length do
      var slice = [reader.get.geom(`@batch, row)]
      var coords = [reader.child.geom.array(`@batch)]
      for j: int64 = 0, slice.len do
        var idx = slice.start + j
        var x = [reader.child.geom.get.x(`coords, idx)]
        var y = [reader.child.geom.get.y(`coords, idx)]
        if x < min_x then min_x = x end
        if x > max_x then max_x = x end
        if y < min_y then min_y = y end
        if y > max_y then max_y = y end
        total_coords = total_coords + 1
      end
    end
  end
  bbox_fn:compile()

  min_x:set(1e30); max_x:set(-1e30)
  min_y:set(1e30); max_y:set(-1e30)
  total_coords:set(0)

  local ptr = ffi.cast("void*", batch)
  bbox_fn(ptr)

  check("jit2: total coords = 4", total_coords:get() == 4)
  check("jit2: min_x = 1", math.abs(min_x:get() - 1.0) < 1e-9)
  check("jit2: max_x = 7", math.abs(max_x:get() - 7.0) < 1e-9)
  check("jit2: min_y = 2", math.abs(min_y:get() - 2.0) < 1e-9)
  check("jit2: max_y = 8", math.abs(max_y:get() - 8.0) < 1e-9)

  na.na_array_release(batch)
end

-- ============================================================
-- Test 3: Compilation caching — same schema, different data
-- ============================================================

print("=== JIT test 3: reuse compiled function on new data ===")

do
  -- Compile once, run on multiple batches with the same schema
  local schema_table = {
    { name = "val", type = T.int32 },
  }

  -- Use gen_reader directly (column-level, not batch-level)
  local reader = arrow.gen_reader(schema_table)
  local accum = global(int64, 0)
  local batch_sym = symbol(&ArrowArray, "batch")
  local row_sym = symbol(int64, "row")

  local scan_fn = terra([batch_sym])
    for [row_sym] = 0, [batch_sym].length do
      accum = accum + [reader.get.val(batch_sym, row_sym)]
    end
  end
  scan_fn:compile()

  -- Run on batch 1
  local arr1 = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr1, NA_INT32) == 0)
  assert(na.na_array_start(arr1) == 0)
  for _, v in ipairs({10, 20, 30}) do
    assert(na.na_array_append_int(arr1, v) == 0)
  end
  assert(na.na_array_finish(arr1) == 0)

  accum:set(0)
  scan_fn(ffi.cast("void*", arr1))
  check("jit3: batch1 sum = 60", accum:get() == 60)

  -- Run same compiled function on batch 2 (different data, same schema)
  local arr2 = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr2, NA_INT32) == 0)
  assert(na.na_array_start(arr2) == 0)
  for _, v in ipairs({100, 200}) do
    assert(na.na_array_append_int(arr2, v) == 0)
  end
  assert(na.na_array_finish(arr2) == 0)

  accum:set(0)
  scan_fn(ffi.cast("void*", arr2))
  check("jit3: batch2 sum = 300", accum:get() == 300)

  na.na_array_release(arr1)
  na.na_array_release(arr2)
end

-- ============================================================
-- Test 4: Runtime format parsing coverage
-- ============================================================

print("=== JIT test 4: parse temporal + dictionary formats ===")

do
  local _keep = {}
  local function cstr(s)
    local buf = ffi.new("char[?]", #s + 1, s)
    _keep[#_keep + 1] = buf
    return buf
  end

  -- Temporal formats
  local ts_schema = ffi.new("struct ArrowSchema")
  ts_schema.format = cstr("tsu:")
  ts_schema.n_children = 0
  ts_schema.dictionary = nil

  local dur_schema = ffi.new("struct ArrowSchema")
  dur_schema.format = cstr("tDm")
  dur_schema.n_children = 0
  dur_schema.dictionary = nil

  local t_ts = parse_schema_type(ts_schema)
  local t_dur = parse_schema_type(dur_schema)
  check("jit4: timestamp parsed", t_ts.id == "timestamp" and t_ts.format == "tsu:")
  check("jit4: duration parsed", t_dur.id == "duration" and t_dur.format == "tDm")

  -- Dictionary format: indices int32 + utf8 dictionary values
  local dict_value_schema = ffi.new("struct ArrowSchema")
  dict_value_schema.format = cstr("u")
  dict_value_schema.n_children = 0
  dict_value_schema.dictionary = nil

  local dict_idx_schema = ffi.new("struct ArrowSchema")
  dict_idx_schema.format = cstr("i")
  dict_idx_schema.n_children = 0
  dict_idx_schema.dictionary = dict_value_schema

  local t_dict = parse_schema_type(dict_idx_schema)
  check("jit4: dictionary parsed", t_dict.id == "dictionary")
  check("jit4: dictionary index=int32", t_dict.index_type.id == "int32")
  check("jit4: dictionary value=utf8", t_dict.value_type.id == "utf8")
end

-- ============================================================
-- Test 5: Extended runtime format parsing coverage
-- ============================================================

print("=== JIT test 5: parse extended formats ===")

do
  local _keep = {}
  local function cstr(s)
    local buf = ffi.new("char[?]", #s + 1, s)
    _keep[#_keep + 1] = buf
    return buf
  end

  local function mk_schema(fmt, name)
    local s = ffi.new("struct ArrowSchema")
    s.format = cstr(fmt)
    s.name = name and cstr(name) or nil
    s.metadata = nil
    s.flags = 0
    s.n_children = 0
    s.children = nil
    s.dictionary = nil
    s.release = nil
    s.private_data = nil
    return s
  end

  local function mk_metadata(tbl)
    local n = 0
    local items = {}
    for k, v in pairs(tbl) do
      n = n + 1
      items[#items + 1] = { k, v }
    end

    local total = 4
    for i = 1, #items do
      local k = items[i][1]
      local v = items[i][2]
      total = total + 4 + #k + 4 + #v
    end

    local buf = ffi.new("uint8_t[?]", total + 1)
    local p = ffi.cast("uint8_t*", buf)

    local function write_i32(x)
      ffi.cast("int32_t*", p)[0] = x
      p = p + 4
    end

    write_i32(n)
    for i = 1, #items do
      local k = items[i][1]
      local v = items[i][2]
      write_i32(#k)
      ffi.copy(p, k, #k)
      p = p + #k
      write_i32(#v)
      ffi.copy(p, v, #v)
      p = p + #v
    end
    p[0] = 0

    _keep[#_keep + 1] = buf
    return ffi.cast("char*", buf)
  end

  local function set_children(parent, children)
    local child_ptrs = ffi.new("struct ArrowSchema*[?]", #children)
    for i = 1, #children do child_ptrs[i - 1] = children[i] end
    _keep[#_keep + 1] = child_ptrs
    parent.n_children = #children
    parent.children = child_ptrs
  end

  local t_na = parse_schema_type(mk_schema("n"))
  check("jit5: na parsed", t_na.id == "na")

  local t_vu = parse_schema_type(mk_schema("vu"))
  local t_vz = parse_schema_type(mk_schema("vz"))
  check("jit5: string_view parsed", t_vu.id == "string_view")
  check("jit5: binary_view parsed", t_vz.id == "binary_view")

  local t_tiM = parse_schema_type(mk_schema("tiM"))
  local t_tiD = parse_schema_type(mk_schema("tiD"))
  local t_tin = parse_schema_type(mk_schema("tin"))
  check("jit5: interval_months parsed", t_tiM.id == "interval_months")
  check("jit5: interval_day_time parsed", t_tiD.id == "interval_day_time")
  check("jit5: interval_month_day_nano parsed", t_tin.id == "interval_month_day_nano")

  local t_d32 = parse_schema_type(mk_schema("d:7,2,32"))
  local t_d64 = parse_schema_type(mk_schema("d:18,3,64"))
  local t_d128 = parse_schema_type(mk_schema("d:38,6"))
  local t_d256 = parse_schema_type(mk_schema("d:76,9,256"))
  check("jit5: decimal32 parsed", t_d32.id == "decimal32" and t_d32.precision == 7)
  check("jit5: decimal64 parsed", t_d64.id == "decimal64" and t_d64.scale == 3)
  check("jit5: decimal128 parsed", t_d128.id == "decimal128")
  check("jit5: decimal256 parsed", t_d256.id == "decimal256")

  local lv_item = mk_schema("i", "item")
  local lv_schema = mk_schema("+vl")
  set_children(lv_schema, {lv_item})
  local t_lv = parse_schema_type(lv_schema)
  check("jit5: list_view parsed", t_lv.id == "list_view" and t_lv.child.id == "int32")

  local llv_item = mk_schema("l", "item")
  local llv_schema = mk_schema("+vL")
  set_children(llv_schema, {llv_item})
  local t_llv = parse_schema_type(llv_schema)
  check("jit5: large_list_view parsed", t_llv.id == "large_list_view" and t_llv.child.id == "int64")

  local map_key = mk_schema("i", "key")
  local map_val = mk_schema("u", "value")
  local map_entries = mk_schema("+s", "entries")
  set_children(map_entries, {map_key, map_val})
  local map_schema = mk_schema("+m")
  set_children(map_schema, {map_entries})
  local t_map = parse_schema_type(map_schema)
  check("jit5: map parsed", t_map.id == "map")
  check("jit5: map key=int32", t_map.child.fields[1].type.id == "int32")
  check("jit5: map value=utf8", t_map.child.fields[2].type.id == "utf8")

  local us_a = mk_schema("i", "a")
  local us_b = mk_schema("u", "b")
  local us_schema = mk_schema("+us:3,7")
  set_children(us_schema, {us_a, us_b})
  local t_us = parse_schema_type(us_schema)
  check("jit5: sparse_union parsed", t_us.id == "sparse_union")
  check("jit5: sparse_union ids parsed", t_us.type_ids[1] == 3 and t_us.type_ids[2] == 7)

  local ud_a = mk_schema("i", "a")
  local ud_b = mk_schema("u", "b")
  local ud_schema = mk_schema("+ud:5,9")
  set_children(ud_schema, {ud_a, ud_b})
  local t_ud = parse_schema_type(ud_schema)
  check("jit5: dense_union parsed", t_ud.id == "dense_union")
  check("jit5: dense_union ids parsed", t_ud.type_ids[1] == 5 and t_ud.type_ids[2] == 9)

  local re_run_ends = mk_schema("i", "run_ends")
  local re_values = mk_schema("u", "values")
  local re_schema = mk_schema("+r")
  set_children(re_schema, {re_run_ends, re_values})
  local t_re = parse_schema_type(re_schema)
  check("jit5: run_end_encoded parsed", t_re.id == "run_end_encoded")
  check("jit5: run_end type=int32", t_re.run_end_type.id == "int32")
  check("jit5: run_end value=utf8", t_re.value_type.id == "utf8")

  local ext_schema = mk_schema("i")
  ext_schema.metadata = mk_metadata({
    ["ARROW:extension:name"] = "my.ext",
    ["ARROW:extension:metadata"] = "abc123",
  })
  ext_schema.flags = 7 -- dictionary ordered + nullable + map_keys_sorted
  local t_ext = parse_schema_type(ext_schema)
  check("jit5: extension parsed from metadata", t_ext.id == "extension")
  check("jit5: extension storage=int32", t_ext.storage_type.id == "int32")
  check("jit5: extension name", t_ext.extension_name == "my.ext")
  check("jit5: extension metadata", t_ext.extension_metadata == "abc123")
  check("jit5: flags preserved", t_ext.schema_flags == 7)
  check("jit5: flag nullable", t_ext.nullable == true)
  check("jit5: flag dictionary_ordered", t_ext.dictionary_ordered == true)
  check("jit5: flag map_keys_sorted", t_ext.map_keys_sorted == true)
end

-- ============================================================
-- Summary
-- ============================================================

print(string.format("\njit_test: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
