-- Arrow accessor generator test suite
-- Run: terra lib/arrow/test.t
-- Uses nanoarrow (via LuaJIT FFI) to build real Arrow arrays

package.terrapath = "lib/?.t;lib/?/init.t;" .. (package.terrapath or "")
package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local ffi = require("ffi")
local arrow = require("arrow")

local ArrowArray = arrow.ArrowArray
local Slice = arrow.Slice
local T = arrow.types

-- ============================================================
-- Nanoarrow FFI setup
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
  int na_array_append_bytes(struct ArrowArray* array, const uint8_t* data, int64_t len);
  int na_array_append_null(struct ArrowArray* array);
  int na_array_finish(struct ArrowArray* array);
  void na_array_release(struct ArrowArray* array);
  int na_schema_init(struct ArrowSchema* schema, int type);
  int na_schema_set_fixed_size(struct ArrowSchema* schema, int type, int32_t byte_width);
  void na_schema_release(struct ArrowSchema* schema);
  int na_array_allocate_children(struct ArrowArray* array, int64_t n_children);
  int na_array_finish_element(struct ArrowArray* array);

  struct ArrowBinaryView {
    int32_t size;
    uint8_t prefix0;
    uint8_t prefix1;
    uint8_t prefix2;
    uint8_t prefix3;
    int32_t buffer_index;
    int32_t offset;
  };

  struct ArrowIntervalMonthDayNano {
    int32_t months;
    int32_t days;
    int64_t ns;
  };
]]

local na = ffi.load("build/libnanoarrow.so")
local nano = require("arrow.nano")

-- Nanoarrow type constants
local NA_BOOL           = 2
local NA_UINT8          = 3
local NA_INT8           = 4
local NA_UINT16         = 5
local NA_INT16          = 6
local NA_UINT32         = 7
local NA_INT32          = 8
local NA_UINT64         = 9
local NA_INT64          = 10
local NA_FLOAT          = 12
local NA_DOUBLE         = 13
local NA_STRING         = 14
local NA_BINARY         = 15
local NA_FIXED_BINARY   = 16
local NA_LIST           = 26
local NA_STRUCT         = 27
local NA_LARGE_STRING   = 35
local NA_LARGE_BINARY   = 36

-- ============================================================
-- Test helpers
-- ============================================================

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL: " .. name .. "\n") end
end

local function check_error(name, fn)
  local ok = pcall(fn)
  if not ok then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL (expected error): " .. name .. "\n") end
end

-- Build a nanoarrow array, return the cdata pointer
-- Caller must call na.na_array_release(arr) when done
local function build_int32_array(values, nulls)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_INT32) == 0)
  assert(na.na_array_start(arr) == 0)
  for i, v in ipairs(values) do
    if nulls and nulls[i] then
      assert(na.na_array_append_null(arr) == 0)
    else
      assert(na.na_array_append_int(arr, v) == 0)
    end
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_int64_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_INT64) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_int(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_float32_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_FLOAT) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_double(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_float64_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_DOUBLE) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_double(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_bool_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_BOOL) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_int(arr, v and 1 or 0) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_string_array(values, nulls)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_STRING) == 0)
  assert(na.na_array_start(arr) == 0)
  for i, v in ipairs(values) do
    if nulls and nulls[i] then
      assert(na.na_array_append_null(arr) == 0)
    else
      assert(na.na_array_append_string(arr, v) == 0)
    end
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_binary_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_BINARY) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_bytes(arr, v, #v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_large_string_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_LARGE_STRING) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_string(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_large_binary_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_LARGE_BINARY) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_bytes(arr, v, #v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_int8_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_INT8) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_int(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_int16_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_INT16) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_int(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_uint8_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_UINT8) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_uint(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_uint16_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_UINT16) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_uint(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_uint32_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_UINT32) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_uint(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_uint64_array(values)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_UINT64) == 0)
  assert(na.na_array_start(arr) == 0)
  for _, v in ipairs(values) do
    assert(na.na_array_append_uint(arr, v) == 0)
  end
  assert(na.na_array_finish(arr) == 0)
  return arr
end

local function build_fixed_binary_array(values, width)
  local arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(arr, NA_FIXED_BINARY) == 0)
  -- Need to set the fixed size through schema
  -- For fixed_binary, nanoarrow needs schema with byte_width
  -- Use ArrowArrayInitFromSchema approach instead
  na.na_array_release(arr)

  local schema = ffi.new("struct ArrowSchema")
  assert(na.na_schema_set_fixed_size(schema, NA_FIXED_BINARY, width) == 0)

  -- Re-init with typed schema - but nanoarrow's init from type for fixed binary
  -- is tricky. Let's just manually build the buffer.
  na.na_schema_release(schema)

  -- Manual approach: build ArrowArray with correct buffers
  -- fixed_binary: buffer[0] = null bitmap, buffer[1] = data (contiguous, stride=width)
  local n = #values
  local C = terralib.includec("stdlib.h")
  local Cstr = terralib.includec("string.h")

  local build = terra() : &ArrowArray
    var arr = [&ArrowArray](C.calloc(1, sizeof(ArrowArray)))
    arr.length = n
    arr.null_count = 0
    arr.offset = 0
    arr.n_buffers = 2
    arr.n_children = 0

    var bufs = [&&opaque](C.calloc(2, sizeof([&opaque])))
    bufs[0] = nil  -- no nulls

    var data = [&uint8](C.calloc(n * [width], 1))
    escape
      for i, v in ipairs(values) do
        for j = 1, width do
          local byte = v:byte(j) or 0
          emit quote data[([i-1]) * [width] + [j-1]] = [byte] end
        end
      end
    end
    bufs[1] = data

    arr.buffers = bufs
    return arr
  end

  return build()
end

-- Cast a nanoarrow cdata ArrowArray to a Terra-compatible pointer
-- Nanoarrow's struct layout matches Arrow C Data Interface exactly,
-- so we can just reinterpret the pointer
local function to_terra_ptr(cdata_arr)
  return ffi.cast("void*", cdata_arr)
end

-- ============================================================
-- Tests: int32
-- ============================================================

print("=== int32 ===")

do
  local arr = build_int32_array({10, 20, 30, 40, 50})
  local schema = {{ name = "val", type = "int32" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("int32: read [0]", read_val(ptr, 0) == 10)
  check("int32: read [2]", read_val(ptr, 2) == 30)
  check("int32: read [4]", read_val(ptr, 4) == 50)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: int64
-- ============================================================

print("=== int64 ===")

do
  local arr = build_int64_array({100, 200, 300})
  local schema = {{ name = "val", type = "int64" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : int64
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("int64: read [0]", read_val(ptr, 0) == 100)
  check("int64: read [1]", read_val(ptr, 1) == 200)
  check("int64: read [2]", read_val(ptr, 2) == 300)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: float32
-- ============================================================

print("=== float32 ===")

do
  local arr = build_float32_array({1.5, 2.5, 3.5})
  local schema = {{ name = "val", type = "float32" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : float
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  local v0 = read_val(ptr, 0)
  local v1 = read_val(ptr, 1)
  check("float32: read [0]", math.abs(v0 - 1.5) < 0.01)
  check("float32: read [1]", math.abs(v1 - 2.5) < 0.01)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: float64
-- ============================================================

print("=== float64 ===")

do
  local arr = build_float64_array({3.14159, 2.71828, 1.41421})
  local schema = {{ name = "val", type = "float64" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : double
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("float64: read [0]", math.abs(read_val(ptr, 0) - 3.14159) < 1e-4)
  check("float64: read [2]", math.abs(read_val(ptr, 2) - 1.41421) < 1e-4)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: bool
-- ============================================================

print("=== bool ===")

do
  local arr = build_bool_array({true, false, true, true, false})
  local schema = {{ name = "val", type = "bool" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("bool: read [0] = true", read_val(ptr, 0) == true)
  check("bool: read [1] = false", read_val(ptr, 1) == false)
  check("bool: read [2] = true", read_val(ptr, 2) == true)
  check("bool: read [3] = true", read_val(ptr, 3) == true)
  check("bool: read [4] = false", read_val(ptr, 4) == false)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: utf8 (string)
-- ============================================================

print("=== utf8 ===")

do
  local arr = build_string_array({"hello", "world", "foo"})
  local schema = {{ name = "val", type = "utf8" }}
  local reader = arrow.gen_reader(schema)

  local Cstr = terralib.includec("string.h")

  local check_str = terra(batch: &ArrowArray, row: int64, expected: rawstring, expected_len: int32) : bool
    var s = [reader.get.val(`@batch, row)]
    if s.len ~= expected_len then return false end
    return Cstr.memcmp(s.data, expected, s.len) == 0
  end

  local ptr = ffi.cast("void*", arr)
  check("utf8: read 'hello'", check_str(ptr, 0, "hello", 5))
  check("utf8: read 'world'", check_str(ptr, 1, "world", 5))
  check("utf8: read 'foo'", check_str(ptr, 2, "foo", 3))
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: binary
-- ============================================================

print("=== binary ===")

do
  local arr = build_binary_array({"\x01\x02\x03", "\xAA\xBB", "\xFF"})
  local schema = {{ name = "val", type = "binary" }}
  local reader = arrow.gen_reader(schema)

  local read_len = terra(batch: &ArrowArray, row: int64) : int64
    var s = [reader.get.val(`@batch, row)]
    return s.len
  end

  local read_byte = terra(batch: &ArrowArray, row: int64, idx: int32) : uint8
    var s = [reader.get.val(`@batch, row)]
    return s.data[idx]
  end

  local ptr = ffi.cast("void*", arr)
  check("binary: len [0] = 3", read_len(ptr, 0) == 3)
  check("binary: len [1] = 2", read_len(ptr, 1) == 2)
  check("binary: len [2] = 1", read_len(ptr, 2) == 1)
  check("binary: byte [0][0] = 0x01", read_byte(ptr, 0, 0) == 0x01)
  check("binary: byte [0][2] = 0x03", read_byte(ptr, 0, 2) == 0x03)
  check("binary: byte [1][0] = 0xAA", read_byte(ptr, 1, 0) == 0xAA)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: large_utf8
-- ============================================================

print("=== large_utf8 ===")

do
  local arr = build_large_string_array({"alpha", "beta", "gamma"})
  local schema = {{ name = "val", type = "large_utf8" }}
  local reader = arrow.gen_reader(schema)

  local Cstr = terralib.includec("string.h")

  local check_str = terra(batch: &ArrowArray, row: int64, expected: rawstring, expected_len: int32) : bool
    var s = [reader.get.val(`@batch, row)]
    if s.len ~= expected_len then return false end
    return Cstr.memcmp(s.data, expected, s.len) == 0
  end

  local ptr = ffi.cast("void*", arr)
  check("large_utf8: read 'alpha'", check_str(ptr, 0, "alpha", 5))
  check("large_utf8: read 'beta'", check_str(ptr, 1, "beta", 4))
  check("large_utf8: read 'gamma'", check_str(ptr, 2, "gamma", 5))
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: fixed_binary
-- ============================================================

print("=== fixed_binary ===")

do
  local arr_ptr = build_fixed_binary_array({"ABCD", "EFGH", "IJKL"}, 4)
  local schema = {{ name = "val", type = "fixed_binary", byte_width = 4 }}
  local reader = arrow.gen_reader(schema)

  local Cstr = terralib.includec("string.h")

  local check_fixed = terra(batch: &ArrowArray, row: int64, expected: rawstring) : bool
    var s = [reader.get.val(`@batch, row)]
    if s.len ~= 4 then return false end
    return Cstr.memcmp(s.data, expected, 4) == 0
  end

  check("fixed_binary: read 'ABCD'", check_fixed(arr_ptr, 0, "ABCD"))
  check("fixed_binary: read 'EFGH'", check_fixed(arr_ptr, 1, "EFGH"))
  check("fixed_binary: read 'IJKL'", check_fixed(arr_ptr, 2, "IJKL"))
  -- Manual array: no release callback, just free
end

-- ============================================================
-- Tests: null bitmap
-- ============================================================

print("=== null bitmap ===")

do
  -- Array with some nulls: values [10, NULL, 30, NULL, 50]
  local arr = build_int32_array({10, 0, 30, 0, 50}, {false, true, false, true, false})
  local schema = {{ name = "val", type = "int32" }}
  local reader = arrow.gen_reader(schema)

  local check_valid = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.is_valid.val(`@batch, row)]
  end

  local read_val = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("null: [0] valid", check_valid(ptr, 0) == true)
  check("null: [1] null", check_valid(ptr, 1) == false)
  check("null: [2] valid", check_valid(ptr, 2) == true)
  check("null: [3] null", check_valid(ptr, 3) == false)
  check("null: [4] valid", check_valid(ptr, 4) == true)
  check("null: valid value [0] = 10", read_val(ptr, 0) == 10)
  check("null: valid value [2] = 30", read_val(ptr, 2) == 30)
  check("null: valid value [4] = 50", read_val(ptr, 4) == 50)
  na.na_array_release(arr)
end

do
  -- All-valid array (no nulls) — bitmap should be nil
  local arr = build_int32_array({1, 2, 3})
  local schema = {{ name = "val", type = "int32" }}
  local reader = arrow.gen_reader(schema)

  local check_valid = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.is_valid.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("null: all-valid [0]", check_valid(ptr, 0) == true)
  check("null: all-valid [1]", check_valid(ptr, 1) == true)
  check("null: all-valid [2]", check_valid(ptr, 2) == true)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: string with nulls
-- ============================================================

print("=== utf8 with nulls ===")

do
  local arr = build_string_array({"hello", "", "world"}, {false, true, false})
  local schema = {{ name = "val", type = "utf8" }}
  local reader = arrow.gen_reader(schema)

  local check_valid = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.is_valid.val(`@batch, row)]
  end

  local Cstr = terralib.includec("string.h")
  local check_str = terra(batch: &ArrowArray, row: int64, expected: rawstring, expected_len: int32) : bool
    var s = [reader.get.val(`@batch, row)]
    if s.len ~= expected_len then return false end
    return Cstr.memcmp(s.data, expected, s.len) == 0
  end

  local ptr = ffi.cast("void*", arr)
  check("utf8+null: [0] valid", check_valid(ptr, 0) == true)
  check("utf8+null: [1] null", check_valid(ptr, 1) == false)
  check("utf8+null: [2] valid", check_valid(ptr, 2) == true)
  check("utf8+null: read 'hello'", check_str(ptr, 0, "hello", 5))
  check("utf8+null: read 'world'", check_str(ptr, 2, "world", 5))
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: vectorized filter
-- ============================================================

print("=== vectorized filter ===")

do
  -- 8 values: [10, 25, 30, 5, 40, 15, 50, 20]
  -- filter: > 20 → expect bits at indices 1,2,4,6 = 0b01010110 = 0x56
  local arr = build_int32_array({10, 25, 30, 5, 40, 15, 50, 20})
  local schema = {{ name = "val", type = "int32" }}

  local filter_gen = arrow.gen_compare_filter(schema, "val", ">", 20)

  local run_filter = terra(batch: &ArrowArray) : uint64
    var mask: uint64[1]
    [filter_gen(`@batch, `&mask[0])]
    return mask[0]
  end

  local ptr = ffi.cast("void*", arr)
  local mask = run_filter(ptr)
  -- Indices > 20: 1(25), 2(30), 4(40), 6(50) → bits 1,2,4,6 → 0b01010110 = 86
  check("filter >20: bit 0 (10)", bit.band(mask, 1) == 0)
  check("filter >20: bit 1 (25)", bit.band(mask, 2) ~= 0)
  check("filter >20: bit 2 (30)", bit.band(mask, 4) ~= 0)
  check("filter >20: bit 3 (5)", bit.band(mask, 8) == 0)
  check("filter >20: bit 4 (40)", bit.band(mask, 16) ~= 0)
  check("filter >20: bit 5 (15)", bit.band(mask, 32) == 0)
  check("filter >20: bit 6 (50)", bit.band(mask, 64) ~= 0)
  check("filter >20: bit 7 (20)", bit.band(mask, 128) == 0)
  na.na_array_release(arr)
end

do
  -- Nulls should never pass compare filters.
  -- Values: [10, NULL, 30, NULL], filter > 20 => only index 2.
  local arr = build_int32_array({10, 99, 30, 40}, {false, true, false, true})
  local schema = {{ name = "val", type = "int32" }}
  local filter_gen = arrow.gen_compare_filter(schema, "val", ">", 20)

  local run_filter = terra(batch: &ArrowArray) : uint64
    var mask: uint64[1]
    [filter_gen(`@batch, `&mask[0])]
    return mask[0]
  end

  local mask = run_filter(ffi.cast("void*", arr))
  check("filter null-aware: bit 0 out", bit.band(mask, 1) == 0)
  check("filter null-aware: bit 1 NULL out", bit.band(mask, 2) == 0)
  check("filter null-aware: bit 2 in", bit.band(mask, 4) ~= 0)
  check("filter null-aware: bit 3 NULL out", bit.band(mask, 8) == 0)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: compound filter (AND)
-- ============================================================

print("=== compound filter ===")

do
  -- Values: [10, 25, 30, 5, 40, 15, 50, 20]
  -- filter: > 10 AND < 40
  -- > 10: indices 1,2,4,5,6,7 → but wait: 25>10, 30>10, 40>10, 15>10, 50>10, 20>10
  -- < 40: indices 0,1,2,3,5,7 → 10<40, 25<40, 30<40, 5<40, 15<40, 20<40
  -- AND:  indices 1,2,5,7 → 25, 30, 15, 20
  local arr = build_int32_array({10, 25, 30, 5, 40, 15, 50, 20})
  local schema = {{ name = "val", type = "int32" }}

  local gt10 = arrow.gen_compare_filter(schema, "val", ">", 10)
  local lt40 = arrow.gen_compare_filter(schema, "val", "<", 40)
  local combined = arrow.gen_and_filter(gt10, lt40)

  local run_filter = terra(batch: &ArrowArray) : uint64
    var mask: uint64[1]
    [combined(`@batch, `&mask[0])]
    return mask[0]
  end

  local ptr = ffi.cast("void*", arr)
  local mask = run_filter(ptr)
  check("AND: bit 0 (10) out", bit.band(mask, 1) == 0)
  check("AND: bit 1 (25) in", bit.band(mask, 2) ~= 0)
  check("AND: bit 2 (30) in", bit.band(mask, 4) ~= 0)
  check("AND: bit 3 (5) out", bit.band(mask, 8) == 0)
  check("AND: bit 4 (40) out", bit.band(mask, 16) == 0)
  check("AND: bit 5 (15) in", bit.band(mask, 32) ~= 0)
  check("AND: bit 6 (50) out", bit.band(mask, 64) == 0)
  check("AND: bit 7 (20) in", bit.band(mask, 128) ~= 0)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: OR filter
-- ============================================================

print("=== OR filter ===")

do
  local arr = build_int32_array({10, 25, 30, 5, 40, 15, 50, 20})
  local schema = {{ name = "val", type = "int32" }}

  local lt10 = arrow.gen_compare_filter(schema, "val", "<", 10)
  local gt40 = arrow.gen_compare_filter(schema, "val", ">", 40)
  local combined = arrow.gen_or_filter(lt10, gt40)

  local run_filter = terra(batch: &ArrowArray) : uint64
    var mask: uint64[1]
    [combined(`@batch, `&mask[0])]
    return mask[0]
  end

  local ptr = ffi.cast("void*", arr)
  local mask = run_filter(ptr)
  -- <10: index 3 (5). >40: index 6 (50). OR: indices 3,6
  check("OR: bit 3 (5) in", bit.band(mask, 8) ~= 0)
  check("OR: bit 6 (50) in", bit.band(mask, 64) ~= 0)
  check("OR: bit 0 (10) out", bit.band(mask, 1) == 0)
  check("OR: bit 1 (25) out", bit.band(mask, 2) == 0)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: NOT filter
-- ============================================================

print("=== NOT filter ===")

do
  local arr = build_int32_array({10, 25, 30})
  local schema = {{ name = "val", type = "int32" }}

  local gt20 = arrow.gen_compare_filter(schema, "val", ">", 20)
  local not_gt20 = arrow.gen_not_filter(gt20)

  local run_filter = terra(batch: &ArrowArray) : uint64
    var mask: uint64[1]
    [not_gt20(`@batch, `&mask[0])]
    return mask[0]
  end

  local ptr = ffi.cast("void*", arr)
  local mask = run_filter(ptr)
  -- >20: bits 1,2. NOT: only bit 0 should be set.
  check("NOT: bit 0 (10) in", bit.band(mask, 1) ~= 0)
  check("NOT: bit 1 (25) out", bit.band(mask, 2) == 0)
  check("NOT: bit 2 (30) out", bit.band(mask, 4) == 0)
  check("NOT: bit 3 (tail) out", bit.band(mask, 8) == 0)
  na.na_array_release(arr)
end

do
  -- Large batch (> 1024 mask blocks) to exercise dynamic filter scratch buffers.
  local n = 70000
  local n_blocks = math.floor((n + 63) / 64)

  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[2]")
  local vals = ffi.new("int32_t[?]", n)
  for i = 0, n - 1 do vals[i] = i end
  bufs[0] = nil
  bufs[1] = vals
  arr.length = n
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 0
  arr.buffers = bufs
  arr.children = nil
  arr.dictionary = nil

  local schema = {{ name = "val", type = "int32" }}
  local gt = arrow.gen_compare_filter(schema, "val", ">", 69990)
  local lt = arrow.gen_compare_filter(schema, "val", "<", 70000)
  local andf = arrow.gen_and_filter(gt, lt)
  local orf = arrow.gen_or_filter(arrow.gen_compare_filter(schema, "val", "<", 2),
                                  arrow.gen_compare_filter(schema, "val", ">", 69998))
  local notf = arrow.gen_not_filter(gt)

  local run_filter = terra(batch: &ArrowArray, out_first: &uint64, out_last: &uint64, which: int32)
    var mask: uint64[ [n_blocks] ]
    if which == 0 then
      [andf(`@batch, `&mask[0])]
    elseif which == 1 then
      [orf(`@batch, `&mask[0])]
    else
      [notf(`@batch, `&mask[0])]
    end
    out_first[0] = mask[0]
    out_last[0] = mask[ [n_blocks - 1] ]
  end

  local has_bit = terra(v: uint64, i: int32) : bool
    return (v and ([uint64](1) << i)) ~= 0
  end

  local first = ffi.new("uint64_t[1]")
  local last = ffi.new("uint64_t[1]")
  local ptr = to_terra_ptr(arr)

  run_filter(ptr, first, last, 0)
  check("AND large: row69999 in", has_bit(last[0], 47))
  check("AND large: row69990 out", not has_bit(last[0], 38))

  run_filter(ptr, first, last, 1)
  check("OR large: row0 in", has_bit(first[0], 0))
  check("OR large: row1 in", has_bit(first[0], 1))
  check("OR large: row69999 in", has_bit(last[0], 47))

  run_filter(ptr, first, last, 2)
  check("NOT large: row69999 out", not has_bit(last[0], 47))
  check("NOT large: row69990 in", has_bit(last[0], 38))
  check("NOT large: trailing bit48 out", not has_bit(last[0], 48))
end

-- ============================================================
-- Tests: gen_scan (row scanner)
-- ============================================================

print("=== gen_scan ===")

do
  local arr = build_int32_array({10, 20, 30, 40, 50})
  local schema = {{ name = "val", type = "int32" }}

  local scan_result = global(int64, 0)

  local sum_fn = arrow.gen_scan(schema, function(reader, batch, row)
    return quote
      scan_result = scan_result + [reader.get.val(batch, row)]
    end
  end)

  local run_scan = terra(batch: &ArrowArray)
    scan_result = 0
    sum_fn(batch)
  end

  local ptr = ffi.cast("void*", arr)
  run_scan(ptr)
  check("scan: sum = 150", scan_result:get() == 150)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: multi-column
-- ============================================================

print("=== multi-column ===")

do
  -- Build two separate arrays, then manually construct a "batch" with children
  local int_arr = build_int32_array({100, 200, 300})
  local str_arr = build_string_array({"foo", "bar", "baz"})

  -- For multi-column, each column is a separate ArrowArray.
  -- In Arrow C Data Interface, a record batch is a struct array whose children are columns.
  -- We test by generating readers for individual column arrays.
  local int_schema = {{ name = "count", type = "int32" }}
  local str_schema = {{ name = "name", type = "utf8" }}
  local int_reader = arrow.gen_reader(int_schema)
  local str_reader = arrow.gen_reader(str_schema)

  local Cstr = terralib.includec("string.h")

  local read_int = terra(batch: &ArrowArray, row: int64) : int32
    return [int_reader.get.count(`@batch, row)]
  end

  local check_name = terra(batch: &ArrowArray, row: int64, expected: rawstring, elen: int32) : bool
    var s = [str_reader.get.name(`@batch, row)]
    if s.len ~= elen then return false end
    return Cstr.memcmp(s.data, expected, s.len) == 0
  end

  local int_ptr = ffi.cast("void*", int_arr)
  local str_ptr = ffi.cast("void*", str_arr)
  check("multi: int [0] = 100", read_int(int_ptr, 0) == 100)
  check("multi: int [2] = 300", read_int(int_ptr, 2) == 300)
  check("multi: str [0] = foo", check_name(str_ptr, 0, "foo", 3))
  check("multi: str [1] = bar", check_name(str_ptr, 1, "bar", 3))
  na.na_array_release(int_arr)
  na.na_array_release(str_arr)
end

-- ============================================================
-- Tests: schema validation errors
-- ============================================================

print("=== schema validation ===")

check_error("schema: unknown type", function()
  arrow.gen_reader({{ name = "x", type = "definitely_not_a_type" }})
end)

check_error("schema: missing name", function()
  arrow.gen_reader({{ type = "int32" }})
end)

check_error("schema: missing type", function()
  arrow.gen_reader({{ name = "x" }})
end)

check_error("schema: fixed_binary no width", function()
  arrow.gen_reader({{ name = "x", type = "fixed_binary" }})
end)

check_error("filter: bool not supported", function()
  arrow.gen_compare_filter({{ name = "x", type = "bool" }}, "x", ">", 1)
end)

check_error("filter: unknown column", function()
  arrow.gen_compare_filter({{ name = "x", type = "int32" }}, "y", ">", 1)
end)

check_error("filter: unknown op", function()
  arrow.gen_compare_filter({{ name = "x", type = "int32" }}, "x", "~=", 1)
end)

-- ============================================================
-- Tests: int8
-- ============================================================

print("=== int8 ===")

do
  local arr = build_int8_array({-128, 0, 127})
  local schema = {{ name = "val", type = "int8" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : int8
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("int8: read [0] = -128", read_val(ptr, 0) == -128)
  check("int8: read [1] = 0", read_val(ptr, 1) == 0)
  check("int8: read [2] = 127", read_val(ptr, 2) == 127)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: int16
-- ============================================================

print("=== int16 ===")

do
  local arr = build_int16_array({-32768, 0, 32767})
  local schema = {{ name = "val", type = "int16" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : int16
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("int16: read [0] = -32768", read_val(ptr, 0) == -32768)
  check("int16: read [1] = 0", read_val(ptr, 1) == 0)
  check("int16: read [2] = 32767", read_val(ptr, 2) == 32767)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: uint8
-- ============================================================

print("=== uint8 ===")

do
  local arr = build_uint8_array({0, 128, 255})
  local schema = {{ name = "val", type = "uint8" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : uint8
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("uint8: read [0] = 0", read_val(ptr, 0) == 0)
  check("uint8: read [1] = 128", read_val(ptr, 1) == 128)
  check("uint8: read [2] = 255", read_val(ptr, 2) == 255)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: uint16
-- ============================================================

print("=== uint16 ===")

do
  local arr = build_uint16_array({0, 1000, 65535})
  local schema = {{ name = "val", type = "uint16" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : uint16
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("uint16: read [0] = 0", read_val(ptr, 0) == 0)
  check("uint16: read [1] = 1000", read_val(ptr, 1) == 1000)
  check("uint16: read [2] = 65535", read_val(ptr, 2) == 65535)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: uint32
-- ============================================================

print("=== uint32 ===")

do
  local arr = build_uint32_array({0, 100000, 4294967295ULL})
  local schema = {{ name = "val", type = "uint32" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : uint32
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("uint32: read [0] = 0", read_val(ptr, 0) == 0)
  check("uint32: read [1] = 100000", read_val(ptr, 1) == 100000)
  check("uint32: read [2] = max", read_val(ptr, 2) == 4294967295ULL)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: uint64
-- ============================================================

print("=== uint64 ===")

do
  local arr = build_uint64_array({0, 1000000, 9999999999ULL})
  local schema = {{ name = "val", type = "uint64" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : uint64
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("uint64: read [0] = 0", read_val(ptr, 0) == 0)
  check("uint64: read [1] = 1000000", read_val(ptr, 1) == 1000000)
  check("uint64: read [2] = 9999999999", read_val(ptr, 2) == 9999999999ULL)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: large_binary
-- ============================================================

print("=== large_binary ===")

do
  local arr = build_large_binary_array({"\x01\x02\x03\x04", "\xDE\xAD", "\xFF"})
  local schema = {{ name = "val", type = "large_binary" }}
  local reader = arrow.gen_reader(schema)

  local read_len = terra(batch: &ArrowArray, row: int64) : int64
    var s = [reader.get.val(`@batch, row)]
    return s.len
  end

  local read_byte = terra(batch: &ArrowArray, row: int64, idx: int32) : uint8
    var s = [reader.get.val(`@batch, row)]
    return s.data[idx]
  end

  local ptr = ffi.cast("void*", arr)
  check("large_binary: len [0] = 4", read_len(ptr, 0) == 4)
  check("large_binary: len [1] = 2", read_len(ptr, 1) == 2)
  check("large_binary: len [2] = 1", read_len(ptr, 2) == 1)
  check("large_binary: byte [0][0] = 0x01", read_byte(ptr, 0, 0) == 0x01)
  check("large_binary: byte [0][3] = 0x04", read_byte(ptr, 0, 3) == 0x04)
  check("large_binary: byte [1][0] = 0xDE", read_byte(ptr, 1, 0) == 0xDE)
  check("large_binary: byte [2][0] = 0xFF", read_byte(ptr, 2, 0) == 0xFF)
  na.na_array_release(arr)
end

do
  -- Large-binary length should preserve 64-bit offset deltas.
  local huge = 3000000000
  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[3]")
  local offs = ffi.new("int64_t[2]", {0, huge})
  local data = ffi.new("uint8_t[1]", {0})
  bufs[0] = nil
  bufs[1] = offs
  bufs[2] = data
  arr.length = 1
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 3
  arr.n_children = 0
  arr.buffers = bufs
  arr.children = nil
  arr.dictionary = nil

  local reader = arrow.gen_reader({{ name = "val", type = "large_binary" }})
  local read_len = terra(batch: &ArrowArray, row: int64) : int64
    var s = [reader.get.val(`@batch, row)]
    return s.len
  end

  local ptr = to_terra_ptr(arr)
  check("large_binary: len preserves int64", read_len(ptr, 0) == huge)
end

-- ============================================================
-- Tests: type object schema style
-- ============================================================

print("=== type object schema ===")

do
  -- Same data as int32 test, but using type object instead of string
  local arr = build_int32_array({10, 20, 30, 40, 50})
  local schema = {{ name = "val", type = T.int32 }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.get.val(`@batch, row)]
  end

  local ptr = ffi.cast("void*", arr)
  check("type obj int32: read [0]", read_val(ptr, 0) == 10)
  check("type obj int32: read [2]", read_val(ptr, 2) == 30)
  check("type obj int32: read [4]", read_val(ptr, 4) == 50)
  na.na_array_release(arr)
end

do
  -- Type object utf8
  local arr = build_string_array({"hello", "world"})
  local schema = {{ name = "val", type = T.utf8 }}
  local reader = arrow.gen_reader(schema)

  local Cstr = terralib.includec("string.h")
  local check_str = terra(batch: &ArrowArray, row: int64, expected: rawstring, expected_len: int32) : bool
    var s = [reader.get.val(`@batch, row)]
    if s.len ~= expected_len then return false end
    return Cstr.memcmp(s.data, expected, s.len) == 0
  end

  local ptr = ffi.cast("void*", arr)
  check("type obj utf8: read 'hello'", check_str(ptr, 0, "hello", 5))
  check("type obj utf8: read 'world'", check_str(ptr, 1, "world", 5))
  na.na_array_release(arr)
end

do
  -- Parameterized type object: fixed_binary
  local arr_ptr = build_fixed_binary_array({"WXYZ"}, 4)
  local schema = {{ name = "val", type = T.fixed_binary(4) }}
  local reader = arrow.gen_reader(schema)

  local Cstr = terralib.includec("string.h")
  local check_fixed = terra(batch: &ArrowArray, row: int64, expected: rawstring) : bool
    var s = [reader.get.val(`@batch, row)]
    if s.len ~= 4 then return false end
    return Cstr.memcmp(s.data, expected, 4) == 0
  end

  check("type obj fixed_binary: read 'WXYZ'", check_fixed(arr_ptr, 0, "WXYZ"))
end

-- ============================================================
-- Tests: nested type constructors
-- ============================================================

print("=== nested type constructors ===")

do
  local list_t = T.list(T.int32)
  check("list: id", list_t.id == "list")
  check("list: format", list_t.format == "+l")
  check("list: n_buffers", list_t.n_buffers == 2)
  check("list: child.id", list_t.child.id == "int32")
  check("list: n_children", list_t.n_children == 1)

  local large_list_t = T.large_list(T.utf8)
  check("large_list: id", large_list_t.id == "large_list")
  check("large_list: format", large_list_t.format == "+L")
  check("large_list: child.id", large_list_t.child.id == "utf8")
  check("large_list: n_children", large_list_t.n_children == 1)

  local fixed_list_t = T.fixed_list(T.float64, 3)
  check("fixed_list: id", fixed_list_t.id == "fixed_list")
  check("fixed_list: format", fixed_list_t.format == "+w:3")
  check("fixed_list: child.id", fixed_list_t.child.id == "float64")
  check("fixed_list: list_size", fixed_list_t.list_size == 3)
  check("fixed_list: n_children", fixed_list_t.n_children == 1)

  local struct_ctor = T["struct"]
  local rec_t = struct_ctor({
    { name = "x", type = T.float64 },
    { name = "y", type = T.float64 },
  })
  check("struct: id", rec_t.id == "struct")
  check("struct: format", rec_t.format == "+s")
  check("struct: n_children", rec_t.n_children == 2)
  check("struct: fields[1].name", rec_t.fields[1].name == "x")
  check("struct: fields[2].name", rec_t.fields[2].name == "y")
end

-- ============================================================
-- Tests: format strings
-- ============================================================

print("=== format strings ===")

do
  check("format: na", T.na.format == "n")
  check("format: int8", T.int8.format == "c")
  check("format: int16", T.int16.format == "s")
  check("format: int32", T.int32.format == "i")
  check("format: int64", T.int64.format == "l")
  check("format: uint8", T.uint8.format == "C")
  check("format: uint16", T.uint16.format == "S")
  check("format: uint32", T.uint32.format == "I")
  check("format: uint64", T.uint64.format == "L")
  check("format: half_float", T.half_float.format == "e")
  check("format: float32", T.float32.format == "f")
  check("format: float64", T.float64.format == "g")
  check("format: bool", T.bool.format == "b")
  check("format: date32", T.date32.format == "tdD")
  check("format: date64", T.date64.format == "tdm")
  check("format: interval_months", T.interval_months.format == "tiM")
  check("format: interval_day_time", T.interval_day_time.format == "tiD")
  check("format: interval_month_day_nano", T.interval_month_day_nano.format == "tin")
  check("format: time32_s", T.time32_s.format == "tts")
  check("format: time32_ms", T.time32_ms.format == "ttm")
  check("format: time64_us", T.time64_us.format == "ttu")
  check("format: time64_ns", T.time64_ns.format == "ttn")
  check("format: timestamp_ns(UTC)", T.timestamp("n", "UTC").format == "tsn:UTC")
  check("format: duration_us", T.duration_us.format == "tDu")
  check("format: decimal32", T.decimal32(7, 2).format == "d:7,2,32")
  check("format: decimal64", T.decimal64(18, 3).format == "d:18,3,64")
  check("format: decimal128", T.decimal128(38, 10).format == "d:38,10")
  check("format: decimal256", T.decimal256(76, 4).format == "d:76,4,256")
  check("format: utf8", T.utf8.format == "u")
  check("format: large_utf8", T.large_utf8.format == "U")
  check("format: binary", T.binary.format == "z")
  check("format: large_binary", T.large_binary.format == "Z")
  check("format: string_view", T.string_view.format == "vu")
  check("format: binary_view", T.binary_view.format == "vz")
  check("format: fixed_binary(16)", T.fixed_binary(16).format == "w:16")
  check("format: list_view", T.list_view(T.int32).format == "+vl")
  check("format: large_list_view", T.large_list_view(T.int32).format == "+vL")
  check("format: map", T.map(T.int32, T.int32).format == "+m")
  check("format: sparse_union", T.sparse_union({{name="a", type=T.int32}}, {7}).format == "+us:7")
  check("format: dense_union", T.dense_union({{name="a", type=T.int32}}, {9}).format == "+ud:9")
  check("format: run_end_encoded", T.run_end_encoded(T.int32, T.int32).format == "+r")
  check("format: extension(storage)", T.extension(T.int32, "x").format == "i")
  check("format: dictionary(storage=index)", T.dictionary(T.int16, T.utf8).format == "s")
end

-- ============================================================
-- Tests: vectorized filter on uint32
-- ============================================================

print("=== vectorized filter uint32 ===")

do
  local arr = build_uint32_array({10, 25, 30, 5, 40, 15, 50, 20})
  local schema = {{ name = "val", type = "uint32" }}

  local filter_gen = arrow.gen_compare_filter(schema, "val", ">", 20)

  local run_filter = terra(batch: &ArrowArray) : uint64
    var mask: uint64[1]
    [filter_gen(`@batch, `&mask[0])]
    return mask[0]
  end

  local ptr = ffi.cast("void*", arr)
  local mask = run_filter(ptr)
  check("uint32 filter >20: bit 0 (10) out", bit.band(mask, 1) == 0)
  check("uint32 filter >20: bit 1 (25) in", bit.band(mask, 2) ~= 0)
  check("uint32 filter >20: bit 2 (30) in", bit.band(mask, 4) ~= 0)
  check("uint32 filter >20: bit 3 (5) out", bit.band(mask, 8) == 0)
  check("uint32 filter >20: bit 4 (40) in", bit.band(mask, 16) ~= 0)
  check("uint32 filter >20: bit 5 (15) out", bit.band(mask, 32) == 0)
  check("uint32 filter >20: bit 6 (50) in", bit.band(mask, 64) ~= 0)
  check("uint32 filter >20: bit 7 (20) out", bit.band(mask, 128) == 0)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: nested types — Struct<x: int32, y: int32>
-- ============================================================

print("=== struct ===")

do
  -- Build struct array with nanoarrow: Struct<x: int32, y: int32>
  -- 3 rows: (1, 10), (2, 20), (3, 30)
  local struct_arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(struct_arr, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(struct_arr, 2) == 0)

  -- Init children as int32
  assert(na.na_array_init(struct_arr.children[0], NA_INT32) == 0)
  assert(na.na_array_init(struct_arr.children[1], NA_INT32) == 0)

  -- Start appending (recursively starts children too)
  assert(na.na_array_start(struct_arr) == 0)

  -- Row 0: (1, 10)
  assert(na.na_array_append_int(struct_arr.children[0], 1) == 0)
  assert(na.na_array_append_int(struct_arr.children[1], 10) == 0)
  assert(na.na_array_finish_element(struct_arr) == 0)

  -- Row 1: (2, 20)
  assert(na.na_array_append_int(struct_arr.children[0], 2) == 0)
  assert(na.na_array_append_int(struct_arr.children[1], 20) == 0)
  assert(na.na_array_finish_element(struct_arr) == 0)

  -- Row 2: (3, 30)
  assert(na.na_array_append_int(struct_arr.children[0], 3) == 0)
  assert(na.na_array_append_int(struct_arr.children[1], 30) == 0)
  assert(na.na_array_finish_element(struct_arr) == 0)

  -- Finish
  assert(na.na_array_finish(struct_arr) == 0)

  local ListSlice = arrow.ListSlice
  local struct_type = T["struct"]({
    { name = "x", type = T.int32 },
    { name = "y", type = T.int32 },
  })
  local schema = {{ name = "point", type = struct_type }}
  local reader = arrow.gen_reader(schema)

  -- Struct has no reader.get.point — access through child
  check("struct: no get.point", reader.get.point == nil)
  check("struct: child.point exists", reader.child.point ~= nil)
  check("struct: child.point.get.x exists", reader.child.point.get.x ~= nil)
  check("struct: child.point.get.y exists", reader.child.point.get.y ~= nil)

  local read_x = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.point.get.x(`@batch, row)]
  end

  local read_y = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.point.get.y(`@batch, row)]
  end

  local ptr = ffi.cast("void*", struct_arr)
  check("struct: x[0] = 1", read_x(ptr, 0) == 1)
  check("struct: x[1] = 2", read_x(ptr, 1) == 2)
  check("struct: x[2] = 3", read_x(ptr, 2) == 3)
  check("struct: y[0] = 10", read_y(ptr, 0) == 10)
  check("struct: y[1] = 20", read_y(ptr, 1) == 20)
  check("struct: y[2] = 30", read_y(ptr, 2) == 30)
  na.na_array_release(struct_arr)
end

-- ============================================================
-- Tests: nested types — List<int32>
-- ============================================================

print("=== list<int32> ===")

do
  -- Build list array: 3 rows: [10, 20], [30], [40, 50, 60]
  local list_arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(list_arr, NA_LIST) == 0)
  assert(na.na_array_allocate_children(list_arr, 1) == 0)
  assert(na.na_array_init(list_arr.children[0], NA_INT32) == 0)

  assert(na.na_array_start(list_arr) == 0)

  -- Row 0: [10, 20]
  assert(na.na_array_append_int(list_arr.children[0], 10) == 0)
  assert(na.na_array_append_int(list_arr.children[0], 20) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)

  -- Row 1: [30]
  assert(na.na_array_append_int(list_arr.children[0], 30) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)

  -- Row 2: [40, 50, 60]
  assert(na.na_array_append_int(list_arr.children[0], 40) == 0)
  assert(na.na_array_append_int(list_arr.children[0], 50) == 0)
  assert(na.na_array_append_int(list_arr.children[0], 60) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)

  assert(na.na_array_finish(list_arr) == 0)

  local ListSlice = arrow.ListSlice
  local schema = {{ name = "tags", type = T.list(T.int32) }}
  local reader = arrow.gen_reader(schema)

  check("list: get.tags exists", reader.get.tags ~= nil)
  check("list: child.tags exists", reader.child.tags ~= nil)
  check("list: child.tags.get.elem exists", reader.child.tags.get.elem ~= nil)

  local read_slice = terra(batch: &ArrowArray, row: int64) : ListSlice
    return [reader.get.tags(`@batch, row)]
  end

  local read_elem = terra(child_arr: &ArrowArray, idx: int64) : int32
    return [reader.child.tags.get.elem(`@child_arr, idx)]
  end

  local get_child = terra(batch: &ArrowArray) : &ArrowArray
    return [reader.child.tags.array(`@batch)]
  end

  local ptr = ffi.cast("void*", list_arr)

  -- Row 0: [10, 20] → start=0, len=2
  local s0 = read_slice(ptr, 0)
  check("list: row 0 start=0", s0.start == 0)
  check("list: row 0 len=2", s0.len == 2)

  -- Row 1: [30] → start=2, len=1
  local s1 = read_slice(ptr, 1)
  check("list: row 1 start=2", s1.start == 2)
  check("list: row 1 len=1", s1.len == 1)

  -- Row 2: [40, 50, 60] → start=3, len=3
  local s2 = read_slice(ptr, 2)
  check("list: row 2 start=3", s2.start == 3)
  check("list: row 2 len=3", s2.len == 3)

  -- Read child elements
  local child_ptr = get_child(ptr)
  check("list: elem[0] = 10", read_elem(child_ptr, 0) == 10)
  check("list: elem[1] = 20", read_elem(child_ptr, 1) == 20)
  check("list: elem[2] = 30", read_elem(child_ptr, 2) == 30)
  check("list: elem[3] = 40", read_elem(child_ptr, 3) == 40)
  check("list: elem[4] = 50", read_elem(child_ptr, 4) == 50)
  check("list: elem[5] = 60", read_elem(child_ptr, 5) == 60)
  na.na_array_release(list_arr)
end

-- ============================================================
-- Tests: nested types — List<Struct<x: float64, y: float64>> (GeoArrow)
-- ============================================================

print("=== list<struct<x,y>> (GeoArrow) ===")

do
  -- Build List<Struct<x: float64, y: float64>>
  -- 2 rows: row 0 = [(1.0, 2.0), (3.0, 4.0)], row 1 = [(5.0, 6.0)]
  local list_arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(list_arr, NA_LIST) == 0)
  assert(na.na_array_allocate_children(list_arr, 1) == 0)

  -- Child is struct
  local struct_child = list_arr.children[0]
  assert(na.na_array_init(struct_child, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(struct_child, 2) == 0)

  -- Struct children: x (float64), y (float64)
  assert(na.na_array_init(struct_child.children[0], NA_DOUBLE) == 0)
  assert(na.na_array_init(struct_child.children[1], NA_DOUBLE) == 0)

  -- Start appending (recursively starts all children)
  assert(na.na_array_start(list_arr) == 0)

  -- Row 0: [(1.0, 2.0), (3.0, 4.0)]
  -- Point (1.0, 2.0)
  assert(na.na_array_append_double(struct_child.children[0], 1.0) == 0)
  assert(na.na_array_append_double(struct_child.children[1], 2.0) == 0)
  assert(na.na_array_finish_element(struct_child) == 0)
  -- Point (3.0, 4.0)
  assert(na.na_array_append_double(struct_child.children[0], 3.0) == 0)
  assert(na.na_array_append_double(struct_child.children[1], 4.0) == 0)
  assert(na.na_array_finish_element(struct_child) == 0)
  -- Finish list element (row 0)
  assert(na.na_array_finish_element(list_arr) == 0)

  -- Row 1: [(5.0, 6.0)]
  assert(na.na_array_append_double(struct_child.children[0], 5.0) == 0)
  assert(na.na_array_append_double(struct_child.children[1], 6.0) == 0)
  assert(na.na_array_finish_element(struct_child) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)

  -- Finish (only top-level needed; children are finished recursively)
  assert(na.na_array_finish(list_arr) == 0)

  local ListSlice = arrow.ListSlice
  local geom_type = T.list(T["struct"]({
    { name = "x", type = T.float64 },
    { name = "y", type = T.float64 },
  }))
  local schema = {{ name = "geom", type = geom_type }}
  local reader = arrow.gen_reader(schema)

  check("geoarrow: get.geom exists", reader.get.geom ~= nil)
  check("geoarrow: child.geom exists", reader.child.geom ~= nil)
  check("geoarrow: child.geom.get.x exists", reader.child.geom.get.x ~= nil)
  check("geoarrow: child.geom.get.y exists", reader.child.geom.get.y ~= nil)

  local read_slice = terra(batch: &ArrowArray, row: int64) : ListSlice
    return [reader.get.geom(`@batch, row)]
  end

  local get_struct_child = terra(batch: &ArrowArray) : &ArrowArray
    return [reader.child.geom.array(`@batch)]
  end

  local read_x = terra(struct_arr: &ArrowArray, idx: int64) : double
    return [reader.child.geom.get.x(`@struct_arr, idx)]
  end

  local read_y = terra(struct_arr: &ArrowArray, idx: int64) : double
    return [reader.child.geom.get.y(`@struct_arr, idx)]
  end

  local ptr = ffi.cast("void*", list_arr)

  -- Row 0: 2 points starting at 0
  local s0 = read_slice(ptr, 0)
  check("geoarrow: row 0 start=0", s0.start == 0)
  check("geoarrow: row 0 len=2", s0.len == 2)

  -- Row 1: 1 point starting at 2
  local s1 = read_slice(ptr, 1)
  check("geoarrow: row 1 start=2", s1.start == 2)
  check("geoarrow: row 1 len=1", s1.len == 1)

  -- Get struct child array and read coordinates
  local coords = get_struct_child(ptr)

  check("geoarrow: x[0] = 1.0", math.abs(read_x(coords, 0) - 1.0) < 1e-9)
  check("geoarrow: y[0] = 2.0", math.abs(read_y(coords, 0) - 2.0) < 1e-9)
  check("geoarrow: x[1] = 3.0", math.abs(read_x(coords, 1) - 3.0) < 1e-9)
  check("geoarrow: y[1] = 4.0", math.abs(read_y(coords, 1) - 4.0) < 1e-9)
  check("geoarrow: x[2] = 5.0", math.abs(read_x(coords, 2) - 5.0) < 1e-9)
  check("geoarrow: y[2] = 6.0", math.abs(read_y(coords, 2) - 6.0) < 1e-9)

  na.na_array_release(list_arr)
end

-- ============================================================
-- Tests: nested types — FixedList<int32, 3>
-- ============================================================

print("=== fixed_list<int32, 3> ===")

do
  -- Build FixedList<int32, 3> manually
  -- 2 rows: [10, 20, 30], [40, 50, 60]
  -- Fixed-size list: no offsets buffer, child has all elements contiguously
  -- buffer[0] = validity bitmap (nil for no nulls)
  -- children[0] = child array with n_rows * list_size elements
  local C_alloc = terralib.includec("stdlib.h")

  local build = terra() : &ArrowArray
    var arr = [&ArrowArray](C_alloc.calloc(1, sizeof(ArrowArray)))
    arr.length = 2
    arr.null_count = 0
    arr.offset = 0
    arr.n_buffers = 1
    arr.n_children = 1

    -- Buffers: just validity (nil)
    var bufs = [&&opaque](C_alloc.calloc(1, sizeof([&opaque])))
    bufs[0] = nil
    arr.buffers = bufs

    -- Child array: 6 int32 values
    var child = [&ArrowArray](C_alloc.calloc(1, sizeof(ArrowArray)))
    child.length = 6
    child.null_count = 0
    child.offset = 0
    child.n_buffers = 2
    child.n_children = 0

    var child_bufs = [&&opaque](C_alloc.calloc(2, sizeof([&opaque])))
    child_bufs[0] = nil  -- no null bitmap

    var data = [&int32](C_alloc.calloc(6, sizeof(int32)))
    data[0] = 10; data[1] = 20; data[2] = 30
    data[3] = 40; data[4] = 50; data[5] = 60
    child_bufs[1] = data
    child.buffers = child_bufs

    -- Wire child into parent
    var children = [&&ArrowArray](C_alloc.calloc(1, sizeof([&ArrowArray])))
    children[0] = child
    arr.children = children

    return arr
  end

  local arr_ptr = build()

  local ListSlice = arrow.ListSlice
  local schema = {{ name = "vec", type = T.fixed_list(T.int32, 3) }}
  local reader = arrow.gen_reader(schema)

  local read_slice = terra(batch: &ArrowArray, row: int64) : ListSlice
    return [reader.get.vec(`@batch, row)]
  end

  local get_child_arr = terra(batch: &ArrowArray) : &ArrowArray
    return [reader.child.vec.array(`@batch)]
  end

  local read_elem = terra(child_arr: &ArrowArray, idx: int64) : int32
    return [reader.child.vec.get.elem(`@child_arr, idx)]
  end

  -- Row 0: start=0, len=3
  local s0 = read_slice(arr_ptr, 0)
  check("fixed_list: row 0 start=0", s0.start == 0)
  check("fixed_list: row 0 len=3", s0.len == 3)

  -- Row 1: start=3, len=3
  local s1 = read_slice(arr_ptr, 1)
  check("fixed_list: row 1 start=3", s1.start == 3)
  check("fixed_list: row 1 len=3", s1.len == 3)

  -- Read elements
  local child_ptr = get_child_arr(arr_ptr)
  check("fixed_list: elem[0] = 10", read_elem(child_ptr, 0) == 10)
  check("fixed_list: elem[1] = 20", read_elem(child_ptr, 1) == 20)
  check("fixed_list: elem[2] = 30", read_elem(child_ptr, 2) == 30)
  check("fixed_list: elem[3] = 40", read_elem(child_ptr, 3) == 40)
  check("fixed_list: elem[4] = 50", read_elem(child_ptr, 4) == 50)
  check("fixed_list: elem[5] = 60", read_elem(child_ptr, 5) == 60)
  -- Manual array: no release callback
end

-- ============================================================
-- Tests: nested types — Struct null bitmap
-- ============================================================

print("=== struct null bitmap ===")

do
  -- Build Struct<x: int32, y: int32> with row 1 null
  -- 3 rows: (1, 10), NULL, (3, 30)
  local struct_arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(struct_arr, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(struct_arr, 2) == 0)

  assert(na.na_array_init(struct_arr.children[0], NA_INT32) == 0)
  assert(na.na_array_init(struct_arr.children[1], NA_INT32) == 0)

  assert(na.na_array_start(struct_arr) == 0)

  -- Row 0: (1, 10)
  assert(na.na_array_append_int(struct_arr.children[0], 1) == 0)
  assert(na.na_array_append_int(struct_arr.children[1], 10) == 0)
  assert(na.na_array_finish_element(struct_arr) == 0)

  -- Row 1: NULL (struct null recursively appends empty to children)
  assert(na.na_array_append_null(struct_arr) == 0)

  -- Row 2: (3, 30)
  assert(na.na_array_append_int(struct_arr.children[0], 3) == 0)
  assert(na.na_array_append_int(struct_arr.children[1], 30) == 0)
  assert(na.na_array_finish_element(struct_arr) == 0)

  assert(na.na_array_finish(struct_arr) == 0)

  local struct_type = T["struct"]({
    { name = "x", type = T.int32 },
    { name = "y", type = T.int32 },
  })
  local schema = {{ name = "point", type = struct_type }}
  local reader = arrow.gen_reader(schema)

  -- Struct-level validity (reader.is_valid.point)
  local check_valid = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.is_valid.point(`@batch, row)]
  end

  local read_x = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.point.get.x(`@batch, row)]
  end

  local ptr = ffi.cast("void*", struct_arr)
  check("struct null: [0] valid", check_valid(ptr, 0) == true)
  check("struct null: [1] null", check_valid(ptr, 1) == false)
  check("struct null: [2] valid", check_valid(ptr, 2) == true)
  check("struct null: x[0] = 1", read_x(ptr, 0) == 1)
  check("struct null: x[2] = 3", read_x(ptr, 2) == 3)
  na.na_array_release(struct_arr)
end

-- ============================================================
-- Tests: array offset handling
-- ============================================================

print("=== array offsets ===")

do
  -- Primitive offset
  local arr = build_int32_array({10, 20, 30, 40, 50})
  arr.offset = 1
  arr.length = 3

  local schema = {{ name = "val", type = "int32" }}
  local reader = arrow.gen_reader(schema)

  local read_val = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.get.val(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  check("offset int32: [0] = 20", read_val(ptr, 0) == 20)
  check("offset int32: [1] = 30", read_val(ptr, 1) == 30)
  check("offset int32: [2] = 40", read_val(ptr, 2) == 40)
  na.na_array_release(arr)
end

do
  -- Validity bitmap with offset
  local arr = build_int32_array({10, 0, 30, 40}, {false, true, false, false})
  arr.offset = 1
  arr.length = 3

  local schema = {{ name = "val", type = "int32" }}
  local reader = arrow.gen_reader(schema)
  local is_valid = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.is_valid.val(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  check("offset valid: [0] null", is_valid(ptr, 0) == false)
  check("offset valid: [1] valid", is_valid(ptr, 1) == true)
  check("offset valid: [2] valid", is_valid(ptr, 2) == true)
  na.na_array_release(arr)
end

do
  -- Struct child access with parent offset
  local struct_arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(struct_arr, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(struct_arr, 2) == 0)
  assert(na.na_array_init(struct_arr.children[0], NA_INT32) == 0)
  assert(na.na_array_init(struct_arr.children[1], NA_INT32) == 0)
  assert(na.na_array_start(struct_arr) == 0)

  for i = 1, 4 do
    assert(na.na_array_append_int(struct_arr.children[0], i) == 0)
    assert(na.na_array_append_int(struct_arr.children[1], i * 10) == 0)
    assert(na.na_array_finish_element(struct_arr) == 0)
  end
  assert(na.na_array_finish(struct_arr) == 0)

  struct_arr.offset = 1
  struct_arr.length = 2

  local struct_type = T["struct"]({
    { name = "x", type = T.int32 },
    { name = "y", type = T.int32 },
  })
  local schema = {{ name = "point", type = struct_type }}
  local reader = arrow.gen_reader(schema)

  local read_x = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.point.get.x(`@batch, row)]
  end

  local ptr = to_terra_ptr(struct_arr)
  check("offset struct: x[0] = 2", read_x(ptr, 0) == 2)
  check("offset struct: x[1] = 3", read_x(ptr, 1) == 3)
  na.na_array_release(struct_arr)
end

do
  -- List offset
  local list_arr = ffi.new("struct ArrowArray")
  assert(na.na_array_init(list_arr, NA_LIST) == 0)
  assert(na.na_array_allocate_children(list_arr, 1) == 0)
  assert(na.na_array_init(list_arr.children[0], NA_INT32) == 0)
  assert(na.na_array_start(list_arr) == 0)

  -- Row 0: [1]
  assert(na.na_array_append_int(list_arr.children[0], 1) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)
  -- Row 1: [2,3]
  assert(na.na_array_append_int(list_arr.children[0], 2) == 0)
  assert(na.na_array_append_int(list_arr.children[0], 3) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)
  -- Row 2: [4,5,6]
  assert(na.na_array_append_int(list_arr.children[0], 4) == 0)
  assert(na.na_array_append_int(list_arr.children[0], 5) == 0)
  assert(na.na_array_append_int(list_arr.children[0], 6) == 0)
  assert(na.na_array_finish_element(list_arr) == 0)
  assert(na.na_array_finish(list_arr) == 0)

  list_arr.offset = 1
  list_arr.length = 2

  local reader = arrow.gen_reader({{ name = "vals", type = T.list(T.int32) }})
  local ListSlice = arrow.ListSlice
  local read_slice = terra(batch: &ArrowArray, row: int64) : ListSlice
    return [reader.get.vals(`@batch, row)]
  end

  local ptr = to_terra_ptr(list_arr)
  local s0 = read_slice(ptr, 0)
  local s1 = read_slice(ptr, 1)
  check("offset list: row0 start=1", s0.start == 1)
  check("offset list: row0 len=2", s0.len == 2)
  check("offset list: row1 start=3", s1.start == 3)
  check("offset list: row1 len=3", s1.len == 3)
  na.na_array_release(list_arr)
end

do
  -- Batch reader offset propagation
  local col = build_int32_array({100, 200, 300, 400})
  local batch = ffi.new("struct ArrowArray")
  local kids = ffi.new("struct ArrowArray*[1]")
  kids[0] = col
  batch.length = 2
  batch.offset = 1
  batch.n_children = 1
  batch.children = kids
  batch.n_buffers = 1
  batch.buffers = nil

  local reader = arrow.gen_batch_reader({{ name = "x", type = "int32" }})
  local read_x = terra(batch_arr: &ArrowArray, row: int64) : int32
    return [reader.get.x(`@batch_arr, row)]
  end

  local ptr = to_terra_ptr(batch)
  check("offset batch reader: x[0] = 200", read_x(ptr, 0) == 200)
  check("offset batch reader: x[1] = 300", read_x(ptr, 1) == 300)
  na.na_array_release(col)
end

-- ============================================================
-- Tests: temporal types
-- ============================================================

print("=== temporal types ===")

do
  local d32 = build_int32_array({18628, 18629, 18630})
  local d64 = build_int64_array({1609459200000, 1609545600000})
  local t32 = build_int32_array({1, 2, 3})
  local t64 = build_int64_array({1000, 2000, 3000})
  local ts = build_int64_array({1700000000000000, 1700000000000100})
  local dur = build_int64_array({1000, 2000, 3000})

  local r_d32 = arrow.gen_reader({{ name = "v", type = "date32" }})
  local r_d64 = arrow.gen_reader({{ name = "v", type = "date64" }})
  local r_t32 = arrow.gen_reader({{ name = "v", type = "time32_s" }})
  local r_t64 = arrow.gen_reader({{ name = "v", type = "time64_ns" }})
  local r_ts = arrow.gen_reader({{ name = "v", type = "timestamp_us" }})
  local r_dur = arrow.gen_reader({{ name = "v", type = "duration_ms" }})

  local read_d32 = terra(batch: &ArrowArray, row: int64) : int32
    return [r_d32.get.v(`@batch, row)]
  end
  local read_d64 = terra(batch: &ArrowArray, row: int64) : int64
    return [r_d64.get.v(`@batch, row)]
  end
  local read_t32 = terra(batch: &ArrowArray, row: int64) : int32
    return [r_t32.get.v(`@batch, row)]
  end
  local read_t64 = terra(batch: &ArrowArray, row: int64) : int64
    return [r_t64.get.v(`@batch, row)]
  end
  local read_ts = terra(batch: &ArrowArray, row: int64) : int64
    return [r_ts.get.v(`@batch, row)]
  end
  local read_dur = terra(batch: &ArrowArray, row: int64) : int64
    return [r_dur.get.v(`@batch, row)]
  end

  check("date32: [1] = 18629", read_d32(to_terra_ptr(d32), 1) == 18629)
  check("date64: [0] = 1609459200000", read_d64(to_terra_ptr(d64), 0) == 1609459200000)
  check("time32_s: [2] = 3", read_t32(to_terra_ptr(t32), 2) == 3)
  check("time64_ns: [1] = 2000", read_t64(to_terra_ptr(t64), 1) == 2000)
  check("timestamp_us: [1] = 1700000000000100", read_ts(to_terra_ptr(ts), 1) == 1700000000000100)
  check("duration_ms: [2] = 3000", read_dur(to_terra_ptr(dur), 2) == 3000)

  na.na_array_release(d32)
  na.na_array_release(d64)
  na.na_array_release(t32)
  na.na_array_release(t64)
  na.na_array_release(ts)
  na.na_array_release(dur)
end

-- ============================================================
-- Tests: dictionary decode
-- ============================================================

print("=== dictionary ===")

do
  local dict_vals = build_string_array({"apple", "banana", "pear"})
  local indices = build_int32_array({0, 2, 1, 2, 0})
  indices.dictionary = dict_vals

  local reader = arrow.gen_reader({
    { name = "fruit", type = T.dictionary(T.int32, T.utf8) }
  })
  local Cstr = terralib.includec("string.h")

  local check_fruit = terra(batch: &ArrowArray, row: int64, expected: rawstring, elen: int32) : bool
    var s = [reader.get.fruit(`@batch, row)]
    if s.len ~= elen then return false end
    return Cstr.memcmp(s.data, expected, s.len) == 0
  end

  local ptr = to_terra_ptr(indices)
  check("dictionary: [0] = apple", check_fruit(ptr, 0, "apple", 5))
  check("dictionary: [1] = pear", check_fruit(ptr, 1, "pear", 4))
  check("dictionary: [2] = banana", check_fruit(ptr, 2, "banana", 6))
  check("dictionary: [3] = pear", check_fruit(ptr, 3, "pear", 4))
  check("dictionary: [4] = apple", check_fruit(ptr, 4, "apple", 5))

  -- Release explicitly to avoid recursive release ownership ambiguity.
  indices.dictionary = nil
  na.na_array_release(indices)
  na.na_array_release(dict_vals)
end

do
  -- Dictionary with nested struct values.
  local dict_struct = ffi.new("struct ArrowArray")
  assert(na.na_array_init(dict_struct, NA_STRUCT) == 0)
  assert(na.na_array_allocate_children(dict_struct, 2) == 0)
  assert(na.na_array_init(dict_struct.children[0], NA_INT32) == 0)
  assert(na.na_array_init(dict_struct.children[1], NA_INT32) == 0)
  assert(na.na_array_start(dict_struct) == 0)

  local rows = {
    {10, 100},
    {20, 200},
    {30, 300},
  }
  for _, r in ipairs(rows) do
    assert(na.na_array_append_int(dict_struct.children[0], r[1]) == 0)
    assert(na.na_array_append_int(dict_struct.children[1], r[2]) == 0)
    assert(na.na_array_finish_element(dict_struct) == 0)
  end
  assert(na.na_array_finish(dict_struct) == 0)

  local indices = build_int32_array({2, 0, 1, 2})
  indices.dictionary = dict_struct

  local point_t = T["struct"]({
    { name = "x", type = T.int32 },
    { name = "y", type = T.int32 },
  })
  local reader = arrow.gen_reader({
    { name = "point", type = T.dictionary(T.int32, point_t) }
  })

  local dict_idx = terra(batch: &ArrowArray, row: int64) : int64
    return [reader.child.point.dict_index(`@batch, row)]
  end
  local dict_arr = terra(batch: &ArrowArray) : &ArrowArray
    return [reader.child.point.array(`@batch)]
  end
  local read_x = terra(darr: &ArrowArray, idx: int64) : int32
    return [reader.child.point.get.x(`@darr, idx)]
  end
  local read_y = terra(darr: &ArrowArray, idx: int64) : int32
    return [reader.child.point.get.y(`@darr, idx)]
  end

  local ptr = to_terra_ptr(indices)
  local darr = dict_arr(ptr)
  local i0 = dict_idx(ptr, 0)
  local i1 = dict_idx(ptr, 1)
  local i2 = dict_idx(ptr, 2)
  check("dict<struct>: idx[0]=2", i0 == 2)
  check("dict<struct>: idx[1]=0", i1 == 0)
  check("dict<struct>: idx[2]=1", i2 == 1)
  check("dict<struct>: row0.x=30", read_x(darr, i0) == 30)
  check("dict<struct>: row1.y=100", read_y(darr, i1) == 100)
  check("dict<struct>: row2.x=20", read_x(darr, i2) == 20)

  indices.dictionary = nil
  na.na_array_release(indices)
  na.na_array_release(dict_struct)
end

-- ============================================================
-- Tests: additional scalar coverage
-- ============================================================

print("=== scalar coverage extras ===")

do
  -- NA / null type
  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[1]")
  bufs[0] = nil
  arr.length = 3
  arr.null_count = 3
  arr.offset = 0
  arr.n_buffers = 1
  arr.n_children = 0
  arr.buffers = bufs
  arr.children = nil
  arr.dictionary = nil

  local reader = arrow.gen_reader({{ name = "v", type = "na" }})
  local read_v = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.get.v(`@batch, row)]
  end
  local valid_v = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.is_valid.v(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  check("na: value always false", read_v(ptr, 1) == false)
  check("na: validity always false", valid_v(ptr, 2) == false)
end

do
  -- Half float: accessor decodes IEEE-754 binary16 into float32.
  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[2]")
  local data = ffi.new("uint16_t[3]", {0x3c00, 0x4000, 0xc000})
  bufs[0] = nil
  bufs[1] = data
  arr.length = 3
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 0
  arr.buffers = bufs
  arr.children = nil
  arr.dictionary = nil

  local reader = arrow.gen_reader({{ name = "h", type = "half_float" }})
  local read_h = terra(batch: &ArrowArray, row: int64) : float
    return [reader.get.h(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  check("half_float: [0] = 1.0", math.abs(read_h(ptr, 0) - 1.0) < 1e-6)
  check("half_float: [1] = 2.0", math.abs(read_h(ptr, 1) - 2.0) < 1e-6)
  check("half_float: [2] = -2.0", math.abs(read_h(ptr, 2) + 2.0) < 1e-6)
end

do
  -- interval_months uses int32 storage
  local arr = build_int32_array({-1, 0, 12})
  local reader = arrow.gen_reader({{ name = "iv", type = "interval_months" }})
  local read_iv = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.get.iv(`@batch, row)]
  end
  local ptr = to_terra_ptr(arr)
  check("interval_months: [-1]", read_iv(ptr, 0) == -1)
  check("interval_months: [12]", read_iv(ptr, 2) == 12)
  na.na_array_release(arr)
end

do
  -- interval_day_time: struct {days:int32, ms:int32}
  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[2]")
  local data = ffi.new("int32_t[6]", {1, 500, -2, 2500, 10, -1})
  bufs[0] = nil
  bufs[1] = data
  arr.length = 3
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 0
  arr.buffers = bufs
  arr.children = nil
  arr.dictionary = nil

  local IntervalDayTime = arrow.IntervalDayTime
  local reader = arrow.gen_reader({{ name = "iv", type = "interval_day_time" }})
  local read_iv = terra(batch: &ArrowArray, row: int64) : IntervalDayTime
    return [reader.get.iv(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  local v0 = read_iv(ptr, 0)
  local v1 = read_iv(ptr, 1)
  check("interval_day_time: row0 days", v0.days == 1)
  check("interval_day_time: row0 ms", v0.ms == 500)
  check("interval_day_time: row1 days", v1.days == -2)
  check("interval_day_time: row1 ms", v1.ms == 2500)
end

do
  -- interval_month_day_nano
  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[2]")
  local data = ffi.new("struct ArrowIntervalMonthDayNano[2]")
  data[0].months = 1
  data[0].days = 2
  data[0].ns = 300
  data[1].months = -3
  data[1].days = 4
  data[1].ns = 5000
  bufs[0] = nil
  bufs[1] = data
  arr.length = 2
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 0
  arr.buffers = bufs
  arr.children = nil
  arr.dictionary = nil

  local IntervalMonthDayNano = arrow.IntervalMonthDayNano
  local reader = arrow.gen_reader({{ name = "iv", type = "interval_month_day_nano" }})
  local read_iv = terra(batch: &ArrowArray, row: int64) : IntervalMonthDayNano
    return [reader.get.iv(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  local v0 = read_iv(ptr, 0)
  local v1 = read_iv(ptr, 1)
  check("interval_month_day_nano: row0 months", v0.months == 1)
  check("interval_month_day_nano: row0 days", v0.days == 2)
  check("interval_month_day_nano: row0 ns", v0.ns == 300)
  check("interval_month_day_nano: row1 months", v1.months == -3)
  check("interval_month_day_nano: row1 days", v1.days == 4)
  check("interval_month_day_nano: row1 ns", v1.ns == 5000)
end

do
  -- Decimal families use fixed-width little-endian byte slices.
  local arr32 = ffi.new("struct ArrowArray")
  local bufs32 = ffi.new("const void*[2]")
  local data32 = ffi.new("uint8_t[8]", {1, 2, 3, 4, 5, 6, 7, 8})
  bufs32[0] = nil
  bufs32[1] = data32
  arr32.length = 2
  arr32.null_count = 0
  arr32.offset = 0
  arr32.n_buffers = 2
  arr32.n_children = 0
  arr32.buffers = bufs32

  local arr64 = ffi.new("struct ArrowArray")
  local bufs64 = ffi.new("const void*[2]")
  local data64 = ffi.new("uint8_t[8]", {9, 8, 7, 6, 5, 4, 3, 2})
  bufs64[0] = nil
  bufs64[1] = data64
  arr64.length = 1
  arr64.null_count = 0
  arr64.offset = 0
  arr64.n_buffers = 2
  arr64.n_children = 0
  arr64.buffers = bufs64

  local arr128 = ffi.new("struct ArrowArray")
  local bufs128 = ffi.new("const void*[2]")
  local data128 = ffi.new("uint8_t[16]")
  for i = 0, 15 do data128[i] = 15 - i end
  bufs128[0] = nil
  bufs128[1] = data128
  arr128.length = 1
  arr128.null_count = 0
  arr128.offset = 0
  arr128.n_buffers = 2
  arr128.n_children = 0
  arr128.buffers = bufs128

  local arr256 = ffi.new("struct ArrowArray")
  local bufs256 = ffi.new("const void*[2]")
  local data256 = ffi.new("uint8_t[32]")
  for i = 0, 31 do data256[i] = i end
  bufs256[0] = nil
  bufs256[1] = data256
  arr256.length = 1
  arr256.null_count = 0
  arr256.offset = 0
  arr256.n_buffers = 2
  arr256.n_children = 0
  arr256.buffers = bufs256

  local r32 = arrow.gen_reader({{ name = "d", type = T.decimal32(7, 2) }})
  local r64 = arrow.gen_reader({{ name = "d", type = T.decimal64(18, 3) }})
  local r128 = arrow.gen_reader({{ name = "d", type = T.decimal128(38, 6) }})
  local r256 = arrow.gen_reader({{ name = "d", type = T.decimal256(76, 0) }})
  local read_len32 = terra(batch: &ArrowArray, row: int64) : int64
    var s = [r32.get.d(`@batch, row)]
    return s.len
  end
  local read_b32 = terra(batch: &ArrowArray, row: int64, i: int32) : uint8
    var s = [r32.get.d(`@batch, row)]
    return s.data[i]
  end
  local read_len256 = terra(batch: &ArrowArray, row: int64) : int64
    var s = [r256.get.d(`@batch, row)]
    return s.len
  end
  local read_b256 = terra(batch: &ArrowArray, row: int64, i: int32) : uint8
    var s = [r256.get.d(`@batch, row)]
    return s.data[i]
  end
  local read_len64 = terra(batch: &ArrowArray, row: int64) : int64
    var s = [r64.get.d(`@batch, row)]
    return s.len
  end
  local read_len128 = terra(batch: &ArrowArray, row: int64) : int64
    var s = [r128.get.d(`@batch, row)]
    return s.len
  end

  check("decimal32: len=4", read_len32(to_terra_ptr(arr32), 0) == 4)
  check("decimal32: row1 byte0=5", read_b32(to_terra_ptr(arr32), 1, 0) == 5)
  check("decimal64: len=8", read_len64(to_terra_ptr(arr64), 0) == 8)
  check("decimal128: len=16", read_len128(to_terra_ptr(arr128), 0) == 16)
  check("decimal256: len=32", read_len256(to_terra_ptr(arr256), 0) == 32)
  check("decimal256: byte31=31", read_b256(to_terra_ptr(arr256), 0, 31) == 31)
end

-- ============================================================
-- Tests: view/list_view/map/union/run-end/extension
-- ============================================================

print("=== nested coverage extras ===")

do
  -- string_view with one inline and one out-of-line value
  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[3]")
  local views = ffi.new("struct ArrowBinaryView[2]")
  local long_data = ffi.new("uint8_t[14]")
  local long_str = "longer-than-12"
  for i = 1, #long_str do long_data[i - 1] = long_str:byte(i) end

  views[0].size = 3
  views[0].prefix0 = string.byte("c")
  views[0].prefix1 = string.byte("a")
  views[0].prefix2 = string.byte("t")

  views[1].size = #long_str
  views[1].prefix0 = string.byte("l")
  views[1].prefix1 = string.byte("o")
  views[1].prefix2 = string.byte("n")
  views[1].prefix3 = string.byte("g")
  views[1].buffer_index = 0
  views[1].offset = 0

  bufs[0] = nil
  bufs[1] = views
  bufs[2] = long_data

  arr.length = 2
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 0
  arr.buffers = bufs
  arr.children = nil
  arr.dictionary = nil

  local reader = arrow.gen_reader({{ name = "sv", type = T.string_view }})
  local read_len = terra(batch: &ArrowArray, row: int64) : int64
    var s = [reader.get.sv(`@batch, row)]
    return s.len
  end
  local read_byte = terra(batch: &ArrowArray, row: int64, i: int32) : uint8
    var s = [reader.get.sv(`@batch, row)]
    return s.data[i]
  end

  local ptr = to_terra_ptr(arr)
  check("string_view: inline len", read_len(ptr, 0) == 3)
  check("string_view: inline byte0=c", read_byte(ptr, 0, 0) == string.byte("c"))
  check("string_view: inline byte2=t", read_byte(ptr, 0, 2) == string.byte("t"))
  check("string_view: var len", read_len(ptr, 1) == #long_str)
  check("string_view: var byte0=l", read_byte(ptr, 1, 0) == string.byte("l"))
  check("string_view: var byte13=2", read_byte(ptr, 1, 13) == string.byte("2"))
end

do
  -- binary_view inline path
  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[2]")
  local views = ffi.new("struct ArrowBinaryView[1]")
  views[0].size = 2
  views[0].prefix0 = 0xaa
  views[0].prefix1 = 0xbb
  bufs[0] = nil
  bufs[1] = views
  arr.length = 1
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 0
  arr.buffers = bufs

  local reader = arrow.gen_reader({{ name = "bv", type = T.binary_view }})
  local read_len = terra(batch: &ArrowArray, row: int64) : int64
    var s = [reader.get.bv(`@batch, row)]
    return s.len
  end
  local read_byte = terra(batch: &ArrowArray, row: int64, i: int32) : uint8
    var s = [reader.get.bv(`@batch, row)]
    return s.data[i]
  end

  local ptr = to_terra_ptr(arr)
  check("binary_view: len=2", read_len(ptr, 0) == 2)
  check("binary_view: byte0", read_byte(ptr, 0, 0) == 0xaa)
  check("binary_view: byte1", read_byte(ptr, 0, 1) == 0xbb)
end

do
  -- list_view<int32>
  local child = ffi.new("struct ArrowArray")
  local child_bufs = ffi.new("const void*[2]")
  local child_data = ffi.new("int32_t[5]", {10, 20, 30, 40, 50})
  child_bufs[0] = nil
  child_bufs[1] = child_data
  child.length = 5
  child.null_count = 0
  child.offset = 0
  child.n_buffers = 2
  child.n_children = 0
  child.buffers = child_bufs

  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[3]")
  local starts = ffi.new("int32_t[3]", {0, 2, 2})
  local sizes = ffi.new("int32_t[3]", {2, 0, 3})
  local kids = ffi.new("struct ArrowArray*[1]")
  kids[0] = child
  bufs[0] = nil
  bufs[1] = starts
  bufs[2] = sizes
  arr.length = 3
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 3
  arr.n_children = 1
  arr.buffers = bufs
  arr.children = kids

  local reader = arrow.gen_reader({{ name = "lv", type = T.list_view(T.int32) }})
  local ListSlice = arrow.ListSlice
  local read_slice = terra(batch: &ArrowArray, row: int64) : ListSlice
    return [reader.get.lv(`@batch, row)]
  end
  local child_arr = terra(batch: &ArrowArray) : &ArrowArray
    return [reader.child.lv.array(`@batch)]
  end
  local read_elem = terra(ca: &ArrowArray, idx: int64) : int32
    return [reader.child.lv.get.elem(`@ca, idx)]
  end

  local ptr = to_terra_ptr(arr)
  local s0 = read_slice(ptr, 0)
  local s1 = read_slice(ptr, 1)
  local s2 = read_slice(ptr, 2)
  check("list_view: row0 start", s0.start == 0)
  check("list_view: row0 len", s0.len == 2)
  check("list_view: row1 len=0", s1.len == 0)
  check("list_view: row2 start", s2.start == 2)
  check("list_view: row2 len", s2.len == 3)
  local cp = child_arr(ptr)
  check("list_view: child[0]=10", read_elem(cp, 0) == 10)
  check("list_view: child[4]=50", read_elem(cp, 4) == 50)
end

do
  -- large_list_view<int32>
  local child = ffi.new("struct ArrowArray")
  local child_bufs = ffi.new("const void*[2]")
  local child_data = ffi.new("int32_t[4]", {5, 6, 7, 8})
  child_bufs[0] = nil
  child_bufs[1] = child_data
  child.length = 4
  child.null_count = 0
  child.offset = 0
  child.n_buffers = 2
  child.n_children = 0
  child.buffers = child_bufs

  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[3]")
  local starts = ffi.new("int64_t[2]", {0, 1})
  local sizes = ffi.new("int64_t[2]", {1, 3})
  local kids = ffi.new("struct ArrowArray*[1]")
  kids[0] = child
  bufs[0] = nil
  bufs[1] = starts
  bufs[2] = sizes
  arr.length = 2
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 3
  arr.n_children = 1
  arr.buffers = bufs
  arr.children = kids

  local reader = arrow.gen_reader({{ name = "lv", type = T.large_list_view(T.int32) }})
  local ListSlice = arrow.ListSlice
  local read_slice = terra(batch: &ArrowArray, row: int64) : ListSlice
    return [reader.get.lv(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  local s0 = read_slice(ptr, 0)
  local s1 = read_slice(ptr, 1)
  check("large_list_view: row0 start=0", s0.start == 0)
  check("large_list_view: row0 len=1", s0.len == 1)
  check("large_list_view: row1 start=1", s1.start == 1)
  check("large_list_view: row1 len=3", s1.len == 3)
end

do
  -- map<int32, int32> as list<struct<key,value>>
  local key_arr = ffi.new("struct ArrowArray")
  local key_bufs = ffi.new("const void*[2]")
  local key_data = ffi.new("int32_t[3]", {1, 2, 3})
  key_bufs[0] = nil
  key_bufs[1] = key_data
  key_arr.length = 3
  key_arr.n_buffers = 2
  key_arr.n_children = 0
  key_arr.buffers = key_bufs

  local val_arr = ffi.new("struct ArrowArray")
  local val_bufs = ffi.new("const void*[2]")
  local val_data = ffi.new("int32_t[3]", {100, 200, 300})
  val_bufs[0] = nil
  val_bufs[1] = val_data
  val_arr.length = 3
  val_arr.n_buffers = 2
  val_arr.n_children = 0
  val_arr.buffers = val_bufs

  local entries = ffi.new("struct ArrowArray")
  local entries_bufs = ffi.new("const void*[1]")
  local entry_children = ffi.new("struct ArrowArray*[2]")
  entries_bufs[0] = nil
  entry_children[0] = key_arr
  entry_children[1] = val_arr
  entries.length = 3
  entries.null_count = 0
  entries.offset = 0
  entries.n_buffers = 1
  entries.n_children = 2
  entries.buffers = entries_bufs
  entries.children = entry_children

  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[2]")
  local offsets = ffi.new("int32_t[3]", {0, 2, 3})
  local kids = ffi.new("struct ArrowArray*[1]")
  bufs[0] = nil
  bufs[1] = offsets
  kids[0] = entries
  arr.length = 2
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 1
  arr.buffers = bufs
  arr.children = kids

  local reader = arrow.gen_reader({{ name = "m", type = T.map(T.int32, T.int32) }})
  local ListSlice = arrow.ListSlice
  local read_slice = terra(batch: &ArrowArray, row: int64) : ListSlice
    return [reader.get.m(`@batch, row)]
  end
  local entry_arr = terra(batch: &ArrowArray) : &ArrowArray
    return [reader.child.m.array(`@batch)]
  end
  local read_key = terra(ea: &ArrowArray, idx: int64) : int32
    return [reader.child.m.get.key(`@ea, idx)]
  end
  local read_val = terra(ea: &ArrowArray, idx: int64) : int32
    return [reader.child.m.get.value(`@ea, idx)]
  end

  local ptr = to_terra_ptr(arr)
  local s0 = read_slice(ptr, 0)
  local s1 = read_slice(ptr, 1)
  check("map: row0 start=0", s0.start == 0)
  check("map: row0 len=2", s0.len == 2)
  check("map: row1 start=2", s1.start == 2)
  check("map: row1 len=1", s1.len == 1)
  local ep = entry_arr(ptr)
  check("map: key[0]=1", read_key(ep, 0) == 1)
  check("map: val[0]=100", read_val(ep, 0) == 100)
  check("map: key[2]=3", read_key(ep, 2) == 3)
  check("map: val[2]=300", read_val(ep, 2) == 300)
end

do
  -- sparse_union<int32,int32>
  local child0 = ffi.new("struct ArrowArray")
  local child0_bufs = ffi.new("const void*[2]")
  local child0_data = ffi.new("int32_t[3]", {11, 22, 33})
  child0_bufs[0] = nil
  child0_bufs[1] = child0_data
  child0.length = 3
  child0.n_buffers = 2
  child0.n_children = 0
  child0.buffers = child0_bufs

  local child1 = ffi.new("struct ArrowArray")
  local child1_bufs = ffi.new("const void*[2]")
  local child1_data = ffi.new("int32_t[3]", {101, 202, 303})
  child1_bufs[0] = nil
  child1_bufs[1] = child1_data
  child1.length = 3
  child1.n_buffers = 2
  child1.n_children = 0
  child1.buffers = child1_bufs

  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[1]")
  local type_ids = ffi.new("int8_t[3]", {0, 1, 0})
  local kids = ffi.new("struct ArrowArray*[2]")
  bufs[0] = type_ids
  kids[0] = child0
  kids[1] = child1
  arr.length = 3
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 1
  arr.n_children = 2
  arr.buffers = bufs
  arr.children = kids

  local utype = T.sparse_union({
    { name = "a", type = T.int32 },
    { name = "b", type = T.int32 },
  }, {0, 1})
  local reader = arrow.gen_reader({{ name = "u", type = utype }})
  local read_tid = terra(batch: &ArrowArray, row: int64) : int8
    return [reader.child.u.get.type_id(`@batch, row)]
  end
  local read_off = terra(batch: &ArrowArray, row: int64) : int64
    return [reader.child.u.get.child_offset(`@batch, row)]
  end
  local read_a = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.u.get.a(`@batch, row)]
  end
  local read_b = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.u.get.b(`@batch, row)]
  end
  local read_valid = terra(batch: &ArrowArray, row: int64) : bool
    return [reader.is_valid.u(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  check("sparse_union: valid row0", read_valid(ptr, 0))
  check("sparse_union: type_id row1=1", read_tid(ptr, 1) == 1)
  check("sparse_union: child_offset row2=2", read_off(ptr, 2) == 2)
  check("sparse_union: a row2=33", read_a(ptr, 2) == 33)
  check("sparse_union: b row1=202", read_b(ptr, 1) == 202)
end

do
  -- dense_union<int32,int32>
  local child0 = ffi.new("struct ArrowArray")
  local child0_bufs = ffi.new("const void*[2]")
  local child0_data = ffi.new("int32_t[2]", {7, 8})
  child0_bufs[0] = nil
  child0_bufs[1] = child0_data
  child0.length = 2
  child0.n_buffers = 2
  child0.n_children = 0
  child0.buffers = child0_bufs

  local child1 = ffi.new("struct ArrowArray")
  local child1_bufs = ffi.new("const void*[2]")
  local child1_data = ffi.new("int32_t[2]", {70, 80})
  child1_bufs[0] = nil
  child1_bufs[1] = child1_data
  child1.length = 2
  child1.n_buffers = 2
  child1.n_children = 0
  child1.buffers = child1_bufs

  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[2]")
  local type_ids = ffi.new("int8_t[4]", {0, 1, 0, 1})
  local offsets = ffi.new("int32_t[4]", {0, 0, 1, 1})
  local kids = ffi.new("struct ArrowArray*[2]")
  bufs[0] = type_ids
  bufs[1] = offsets
  kids[0] = child0
  kids[1] = child1
  arr.length = 4
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 2
  arr.n_children = 2
  arr.buffers = bufs
  arr.children = kids

  local utype = T.dense_union({
    { name = "a", type = T.int32 },
    { name = "b", type = T.int32 },
  }, {0, 1})
  local reader = arrow.gen_reader({{ name = "u", type = utype }})
  local read_tid = terra(batch: &ArrowArray, row: int64) : int8
    return [reader.child.u.get.type_id(`@batch, row)]
  end
  local read_off = terra(batch: &ArrowArray, row: int64) : int64
    return [reader.child.u.get.child_offset(`@batch, row)]
  end
  local read_a = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.u.get.a(`@batch, row)]
  end
  local read_b = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.u.get.b(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  check("dense_union: type_id row3=1", read_tid(ptr, 3) == 1)
  check("dense_union: child_offset row2=1", read_off(ptr, 2) == 1)
  check("dense_union: a row2=8", read_a(ptr, 2) == 8)
  check("dense_union: b row1=70", read_b(ptr, 1) == 70)
  check("dense_union: b row3=80", read_b(ptr, 3) == 80)
end

do
  -- run_end_encoded<int32, int32>
  local run_ends = ffi.new("struct ArrowArray")
  local run_ends_bufs = ffi.new("const void*[2]")
  local run_ends_data = ffi.new("int32_t[3]", {2, 5, 6})
  run_ends_bufs[0] = nil
  run_ends_bufs[1] = run_ends_data
  run_ends.length = 3
  run_ends.n_buffers = 2
  run_ends.n_children = 0
  run_ends.buffers = run_ends_bufs

  local values = ffi.new("struct ArrowArray")
  local values_bufs = ffi.new("const void*[2]")
  local values_data = ffi.new("int32_t[3]", {10, 20, 30})
  values_bufs[0] = nil
  values_bufs[1] = values_data
  values.length = 3
  values.n_buffers = 2
  values.n_children = 0
  values.buffers = values_bufs

  local arr = ffi.new("struct ArrowArray")
  local bufs = ffi.new("const void*[1]")
  local kids = ffi.new("struct ArrowArray*[2]")
  bufs[0] = nil
  kids[0] = run_ends
  kids[1] = values
  arr.length = 6
  arr.null_count = 0
  arr.offset = 0
  arr.n_buffers = 1
  arr.n_children = 2
  arr.buffers = bufs
  arr.children = kids

  local re_type = T.run_end_encoded(T.int32, T.int32)
  local reader = arrow.gen_reader({{ name = "re", type = re_type }})
  local read_run = terra(batch: &ArrowArray, row: int64) : int64
    return [reader.get.re(`@batch, row)]
  end
  local read_val = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.child.re.get.value(`@batch, row)]
  end

  local ptr = to_terra_ptr(arr)
  check("run_end: row0 run=0", read_run(ptr, 0) == 0)
  check("run_end: row3 run=1", read_run(ptr, 3) == 1)
  check("run_end: row5 run=2", read_run(ptr, 5) == 2)
  check("run_end: row0 val=10", read_val(ptr, 0) == 10)
  check("run_end: row4 val=20", read_val(ptr, 4) == 20)
  check("run_end: row5 val=30", read_val(ptr, 5) == 30)
end

do
  -- extension delegates access and shape to storage type
  local arr = build_int32_array({9, 8, 7})
  local ext_t = T.extension(T.int32, "my.ext", "meta")
  local reader = arrow.gen_reader({{ name = "v", type = ext_t }})
  local read_v = terra(batch: &ArrowArray, row: int64) : int32
    return [reader.get.v(`@batch, row)]
  end
  local ptr = to_terra_ptr(arr)
  check("extension<int32>: row0=9", read_v(ptr, 0) == 9)
  check("extension<int32>: row2=7", read_v(ptr, 2) == 7)
  na.na_array_release(arr)
end

-- ============================================================
-- Tests: nanoarrow wrapper coverage
-- ============================================================

print("=== nano wrappers ===")

do
  local rc_schema, schema = nano.schema_init(nano.types.INT32)
  check("nano schema_init rc=0", rc_schema == 0)

  local rc_sv, sv, err_sv = nano.schema_view_init(schema)
  check("nano schema_view_init rc=0", rc_sv == 0)
  check("nano schema_view type=int32", rc_sv == 0 and sv.type == nano.types.INT32)
  check("nano schema_view no error", rc_sv == 0 or (err_sv and #err_sv > 0))

  local arr = build_int32_array({11, 22, 33})
  local rc_vinit, view, _storage, err_vinit = nano.array_view_new_from_schema(schema)
  check("nano view init rc=0", rc_vinit == 0)
  check("nano view init no error", rc_vinit == 0 or (err_vinit and #err_vinit > 0))

  local rc_vset, err_vset = nano.array_view_set_array(view, arr, false)
  check("nano view set rc=0", rc_vset == 0)
  check("nano view set no error", rc_vset == 0 or (err_vset and #err_vset > 0))

  local rc_vval, err_vval = nano.array_view_validate(view, nano.validation.FULL)
  check("nano view validate rc=0", rc_vval == 0)
  check("nano view validate no error", rc_vval == 0 or (err_vval and #err_vval > 0))
  check("nano view length=3", nano.array_view_length(view) == 3)
  check("nano view get_int[1]=22", nano.array_view_get_int(view, 1) == 22)
  check("nano view is_null[0]=false", nano.array_view_is_null(view, 0) == false)
  nano.array_view_reset(view)

  local rc_ai, arr_build = nano.array_init(nano.types.INT32)
  check("nano array_init rc=0", rc_ai == 0)
  check("nano array_start rc=0", nano.array_start(arr_build) == 0)
  check("nano append_int rc=0", nano.array_append_int(arr_build, 7) == 0)
  check("nano append_int rc=0 (2)", nano.array_append_int(arr_build, 8) == 0)
  check("nano array_finish rc=0", nano.array_finish(arr_build) == 0)

  local r = arrow.gen_reader({{ name = "v", type = "int32" }})
  local read_v = terra(batch: &ArrowArray, row: int64) : int32
    return [r.get.v(`@batch, row)]
  end
  check("nano built array[0]=7", read_v(ffi.cast("void*", arr_build), 0) == 7)
  check("nano built array[1]=8", read_v(ffi.cast("void*", arr_build), 1) == 8)
  nano.array_release(arr_build)

  local rc_aift, arr_default = nano.array_init_from_type(nano.types.INT32)
  check("nano ArrowArrayInitFromType rc=0", rc_aift == 0)
  local rc_fb, err_fb = nano.array_finish_building_default(arr_default)
  check("nano finish_building_default rc=0", rc_fb == 0)
  check("nano finish_building_default no error", rc_fb == 0 or (err_fb and #err_fb > 0))
  nano.array_release(arr_default)

  na.na_array_release(arr)
  nano.schema_release(schema)
end

do
  -- Basic stream wrappers
  local rc_schema, schema = nano.schema_init(nano.types.INT32)
  check("nano stream schema_init rc=0", rc_schema == 0)

  local arr1 = build_int32_array({1, 2})
  local arr2 = build_int32_array({10, 20, 30})
  local rc_stream, stream, err_stream = nano.basic_array_stream_init(schema, {arr1, arr2})
  check("nano stream init rc=0", rc_stream == 0)
  check("nano stream init no error", rc_stream == 0 or (err_stream and #err_stream > 0))

  local rc_get_schema, out_schema = nano.basic_array_stream_get_schema(stream)
  check("nano stream get_schema rc=0", rc_get_schema == 0)
  if rc_get_schema == 0 then
    check("nano stream schema format=i", ffi.string(out_schema.format) == "i")
    if out_schema.release ~= nil then out_schema.release(out_schema) end
  end

  local rc_next1, out1 = nano.basic_array_stream_get_next(stream)
  check("nano stream next1 rc=0", rc_next1 == 0)
  if rc_next1 == 0 then
    check("nano stream next1 len=2", out1.length == 2)
    if out1.release ~= nil then out1.release(out1) end
  end

  local rc_next2, out2 = nano.basic_array_stream_get_next(stream)
  check("nano stream next2 rc=0", rc_next2 == 0)
  if rc_next2 == 0 then
    check("nano stream next2 len=3", out2.length == 3)
    if out2.release ~= nil then out2.release(out2) end
  end

  local rc_next3, out3 = nano.basic_array_stream_get_next(stream)
  check("nano stream next3 rc=0", rc_next3 == 0)
  if rc_next3 == 0 then
    check("nano stream next3 eof", out3.release == nil)
  end

  nano.basic_array_stream_release(stream)
end

-- ============================================================
-- Summary
-- ============================================================

print(string.format("\narrow: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
