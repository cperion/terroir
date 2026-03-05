-- Arrow: compile-time schema → typed pointer arithmetic into Arrow columnar buffers
-- Generates Terra functions that read columns from Arrow's C Data Interface structs
-- No Arrow library at runtime — the layout IS the interface.

local C = terralib.includec("stdlib.h")
local Cstr = terralib.includec("string.h")
local Cmath = terralib.includec("math.h")

local arrow = {}

-- ============================================================
-- Arrow C Data Interface Structs
-- ============================================================

struct arrow.ArrowSchema {
  format: rawstring
  name: rawstring
  metadata: rawstring
  flags: int64
  n_children: int64
  children: &&arrow.ArrowSchema
  dictionary: &arrow.ArrowSchema
  release: {&arrow.ArrowSchema} -> {}
  private_data: &opaque
}

struct arrow.ArrowArray {
  length: int64
  null_count: int64
  offset: int64
  n_buffers: int64
  n_children: int64
  buffers: &&opaque
  children: &&arrow.ArrowArray
  dictionary: &arrow.ArrowArray
  release: {&arrow.ArrowArray} -> {}
  private_data: &opaque
}

local ArrowArray = arrow.ArrowArray

-- Variable-length slice returned by utf8/binary/fixed_binary accessors
struct arrow.Slice {
  data: &uint8
  len: int64
}

local Slice = arrow.Slice

-- Range within a child array returned by list/large_list/fixed_list accessors
struct arrow.ListSlice {
  start: int64
  len: int64
}

local ListSlice = arrow.ListSlice

-- Interval payloads
struct arrow.IntervalDayTime {
  days: int32
  ms: int32
}

struct arrow.IntervalMonthDayNano {
  months: int32
  days: int32
  ns: int64
}

local IntervalDayTime = arrow.IntervalDayTime
local IntervalMonthDayNano = arrow.IntervalMonthDayNano

-- Union lookup result
struct arrow.UnionRef {
  type_id: int8
  child_offset: int64
}

local UnionRef = arrow.UnionRef

-- Arrow BinaryView payload (16 bytes) used by string_view/binary_view.
-- The first 12 bytes after size hold inline bytes for short values.
-- For larger values, buffer_index/offset reference variadic buffers.
struct arrow.BinaryView {
  size: int32
  prefix0: uint8
  prefix1: uint8
  prefix2: uint8
  prefix3: uint8
  buffer_index: int32
  offset: int32
}

local BinaryView = arrow.BinaryView

-- ============================================================
-- Type objects
-- ============================================================

local string_types
local T = {}

-- Fixed-width numeric types: all share one accessor pattern
local function fixed_type(id, format, terra_t, bits, numeric)
  if numeric == nil then numeric = true end
  return {
    id = id, format = format, terra_type = terra_t,
    n_buffers = 2, fixed = true, numeric = numeric, bitwidth = bits,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var col = [&terra_t]([batch_sym].buffers[1])
      in col[idx] end
    end,
  }
end

local function fixed_bytes_type(id, format, byte_width)
  return {
    id = id, format = format, terra_type = Slice,
    n_buffers = 2, fixed = true, numeric = false, bitwidth = byte_width * 8,
    byte_width = byte_width,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var data = [&uint8]([batch_sym].buffers[1])
      in
        Slice { data + idx * [byte_width], [byte_width] }
      end
    end,
  }
end

local function interval_day_time_type()
  return {
    id = "interval_day_time", format = "tiD", terra_type = IntervalDayTime,
    n_buffers = 2, fixed = true, numeric = false, bitwidth = 64,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var data = [&IntervalDayTime]([batch_sym].buffers[1])
      in
        data[idx]
      end
    end,
  }
end

local function interval_month_day_nano_type()
  return {
    id = "interval_month_day_nano", format = "tin", terra_type = IntervalMonthDayNano,
    n_buffers = 2, fixed = true, numeric = false, bitwidth = 128,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var data = [&IntervalMonthDayNano]([batch_sym].buffers[1])
      in
        data[idx]
      end
    end,
  }
end

local function decimal_type(id, precision, scale, bits)
  assert(precision and precision > 0, id .. ": precision must be > 0")
  local byte_width = bits / 8
  local fmt
  if bits == 128 then
    fmt = "d:" .. precision .. "," .. scale
  else
    fmt = "d:" .. precision .. "," .. scale .. "," .. bits
  end

  local t = fixed_bytes_type(id, fmt, byte_width)
  t.precision = precision
  t.scale = scale
  t.decimal_bits = bits
  return t
end

local function view_binary_type(id, format)
  return {
    id = id, format = format, terra_type = Slice,
    n_buffers = 2, fixed = false, numeric = false,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var views = [&BinaryView]([batch_sym].buffers[1])
        var view = views[idx]
        var len = view.size
        var ptr: &uint8
        if len <= 12 then
          ptr = [&uint8](&views[idx].prefix0)
        else
          -- BinaryView variadic data buffers start at index n_buffers (2).
          ptr = [&uint8]([batch_sym].buffers[2 + view.buffer_index]) + view.offset
        end
      in
        Slice { ptr, len }
      end
    end,
  }
end

local function list_view_type(id, format, offset_t)
  return {
    id = id, format = format, n_buffers = 3, fixed = false,
    child = nil, n_children = 1,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var starts = [&offset_t]([batch_sym].buffers[1])
        var sizes = [&offset_t]([batch_sym].buffers[2])
      in
        ListSlice { [int64](starts[idx]), [int64](sizes[idx]) }
      end
    end,
  }
end

local function make_union_type(id, format_prefix, fields, type_ids)
  assert(type(fields) == "table" and #fields > 0, id .. ": fields must be non-empty")
  local ids = {}
  if type_ids then
    assert(#type_ids == #fields, id .. ": type_ids size mismatch")
    for i = 1, #type_ids do ids[i] = type_ids[i] end
  else
    for i = 1, #fields do ids[i] = i - 1 end
  end

  local id_list = {}
  local id_to_child = {}
  for i = 1, #ids do
    id_list[#id_list + 1] = tostring(ids[i])
    id_to_child[ids[i]] = i - 1
  end

  local fmt = format_prefix .. ":" .. table.concat(id_list, ",")
  local dense = id == "dense_union"
  return {
    id = id,
    format = fmt,
    fields = fields,
    type_ids = ids,
    id_to_child = id_to_child,
    terra_type = UnionRef,
    n_buffers = dense and 2 or 1,
    fixed = false,
    numeric = false,
    n_children = #fields,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var type_ids_buf = [&int8]([batch_sym].buffers[0])
        var ref: UnionRef
        ref.type_id = type_ids_buf[idx]
        if [dense] then
          var offs = [&int32]([batch_sym].buffers[1])
          ref.child_offset = offs[idx]
        else
          ref.child_offset = idx
        end
      in
        ref
      end
    end,
  }
end

local run_end_index_ids = { int16 = true, int32 = true, int64 = true }

local function run_end_encoded_type(run_end_type, value_type)
  assert(type(run_end_type) == "table", "run_end_encoded run_end_type must be a type object")
  assert(type(value_type) == "table", "run_end_encoded value_type must be a type object")
  assert(run_end_index_ids[run_end_type.id], "run_end_encoded run_end_type must be int16/int32/int64")

  return {
    id = "run_end_encoded",
    format = "+r",
    run_end_type = run_end_type,
    value_type = value_type,
    n_buffers = 1,
    n_children = 2,
    fixed = false,
    numeric = false,
    terra_type = int64,
    gen_get = function(batch_sym, row_sym)
      return quote
        var logical_idx = [row_sym] + [batch_sym].offset
        var run_ends = [batch_sym].children[0]
        var n_runs = run_ends.length
        var lo: int64 = 0
        var hi: int64 = n_runs

        while lo < hi do
          var mid = lo + (hi - lo) / 2
          var end_idx = [int64]([run_end_type.gen_get(`run_ends, `mid)])
          if end_idx <= logical_idx then
            lo = mid + 1
          else
            hi = mid
          end
        end

        if lo >= n_runs and n_runs > 0 then
          lo = n_runs - 1
        end
      in
        lo
      end
    end,
  }
end

local function extension_type(storage_type, extension_name, extension_metadata)
  assert(type(storage_type) == "table", "extension storage_type must be a type object")
  return {
    id = "extension",
    format = storage_type.format,
    terra_type = storage_type.terra_type,
    n_buffers = storage_type.n_buffers,
    n_children = storage_type.n_children,
    fixed = storage_type.fixed,
    numeric = storage_type.numeric,
    storage_type = storage_type,
    extension_name = extension_name,
    extension_metadata = extension_metadata,
    gen_get = function(batch_sym, row_sym)
      return storage_type.gen_get(batch_sym, row_sym)
    end,
  }
end

local half_to_float = terra(bits: uint16) : float
  var sign = (bits >> 15) and 1
  var exp = (bits >> 10) and 0x1f
  var frac = bits and 0x03ff
  var out: float

  if exp == 0 then
    if frac == 0 then
      out = 0.0
    else
      -- subnormal: frac * 2^-24
      out = Cmath.ldexpf([float](frac), -24)
    end
  elseif exp == 31 then
    if frac == 0 then
      out = [float](1.0) / [float](0.0)
    else
      out = [float](0.0) / [float](0.0)
    end
  else
    -- (1024 + frac) * 2^(exp - 25)
    out = Cmath.ldexpf([float](1024 + frac), exp - 25)
  end

  if sign == 1 then
    out = -out
  end

  return out
end

T.na = {
  id = "na", format = "n", terra_type = bool,
  n_buffers = 1, fixed = true, numeric = false, bitwidth = 0,
  gen_get = function(_, _) return `false end,
}

T.int8    = fixed_type("int8",    "c", int8,   8)
T.int16   = fixed_type("int16",   "s", int16,  16)
T.int32   = fixed_type("int32",   "i", int32,  32)
T.int64   = fixed_type("int64",   "l", int64,  64)
T.uint8   = fixed_type("uint8",   "C", uint8,  8)
T.uint16  = fixed_type("uint16",  "S", uint16, 16)
T.uint32  = fixed_type("uint32",  "I", uint32, 32)
T.uint64  = fixed_type("uint64",  "L", uint64, 64)
T.half_float = {
  id = "half_float", format = "e", terra_type = float,
  n_buffers = 2, fixed = true, numeric = true, bitwidth = 16,
  gen_get = function(batch_sym, row_sym)
    return quote
      var idx = [row_sym] + [batch_sym].offset
      var col = [&uint16]([batch_sym].buffers[1])
    in
      half_to_float(col[idx])
    end
  end,
}
T.float32 = fixed_type("float32", "f", float,  32)
T.float64 = fixed_type("float64", "g", double, 64)
T.date32 = fixed_type("date32", "tdD", int32, 32, false)
T.date64 = fixed_type("date64", "tdm", int64, 64, false)
T.interval_months = fixed_type("interval_months", "tiM", int32, 32, false)
T.interval_day_time = interval_day_time_type()
T.interval_month_day_nano = interval_month_day_nano_type()

function T.time32(unit)
  assert(unit == "s" or unit == "m", "time32 unit must be 's' or 'm'")
  return fixed_type("time32", "tt" .. unit, int32, 32, false)
end

function T.time64(unit)
  assert(unit == "u" or unit == "n", "time64 unit must be 'u' or 'n'")
  return fixed_type("time64", "tt" .. unit, int64, 64, false)
end

function T.timestamp(unit, timezone)
  assert(unit == "s" or unit == "m" or unit == "u" or unit == "n",
    "timestamp unit must be one of: s, m, u, n")
  local tz = timezone or ""
  return fixed_type("timestamp", "ts" .. unit .. ":" .. tz, int64, 64, false)
end

function T.duration(unit)
  assert(unit == "s" or unit == "m" or unit == "u" or unit == "n",
    "duration unit must be one of: s, m, u, n")
  return fixed_type("duration", "tD" .. unit, int64, 64, false)
end

function T.decimal32(precision, scale)
  return decimal_type("decimal32", precision or 9, scale or 0, 32)
end

function T.decimal64(precision, scale)
  return decimal_type("decimal64", precision or 18, scale or 0, 64)
end

function T.decimal128(precision, scale)
  return decimal_type("decimal128", precision or 38, scale or 0, 128)
end

function T.decimal256(precision, scale)
  return decimal_type("decimal256", precision or 76, scale or 0, 256)
end

T.time32_s = T.time32("s")
T.time32_ms = T.time32("m")
T.time64_us = T.time64("u")
T.time64_ns = T.time64("n")
T.timestamp_s = T.timestamp("s")
T.timestamp_ms = T.timestamp("m")
T.timestamp_us = T.timestamp("u")
T.timestamp_ns = T.timestamp("n")
T.duration_s = T.duration("s")
T.duration_ms = T.duration("m")
T.duration_us = T.duration("u")
T.duration_ns = T.duration("n")

-- Bool: bit extraction pattern
T.bool = {
  id = "bool", format = "b", terra_type = bool,
  n_buffers = 2, fixed = true, numeric = false, bitwidth = 1,
  gen_get = function(batch_sym, row_sym)
    return quote
      var idx = [row_sym] + [batch_sym].offset
      var bools = [&uint8]([batch_sym].buffers[1])
      var byte_idx = idx >> 3
      var bit_idx = idx and 7
      var val = ((bools[byte_idx] >> bit_idx) and 1) == 1
    in
      val
    end
  end,
}

-- Variable-width types: offsets + data pattern
local function varlen_type(id, format, offset_type)
  return {
    id = id, format = format, terra_type = Slice,
    n_buffers = 3, fixed = false, numeric = false,
    gen_get = function(batch_sym, row_sym)
      return quote
        var offsets = [&offset_type]([batch_sym].buffers[1])
        var data = [&uint8]([batch_sym].buffers[2])
        var idx = [row_sym] + [batch_sym].offset
        var start = offsets[idx]
        var slen = [int64](offsets[idx + 1] - start)
      in
        Slice { data + start, slen }
      end
    end,
  }
end

T.utf8        = varlen_type("utf8",        "u", int32)
T.large_utf8  = varlen_type("large_utf8",  "U", int64)
T.binary      = varlen_type("binary",      "z", int32)
T.large_binary = varlen_type("large_binary", "Z", int64)
T.string_view = view_binary_type("string_view", "vu")
T.binary_view = view_binary_type("binary_view", "vz")

-- Fixed-size binary: parameterized constructor
function T.fixed_binary(byte_width)
  return {
    id = "fixed_binary", format = "w:" .. byte_width,
    terra_type = Slice, n_buffers = 2, fixed = false, numeric = false,
    byte_width = byte_width,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var data = [&uint8]([batch_sym].buffers[1])
      in
        Slice { data + idx * [byte_width], [byte_width] }
      end
    end,
  }
end

-- Nested types
function T.list(child)
  return {
    id = "list", format = "+l", n_buffers = 2, fixed = false,
    child = child, n_children = 1,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var offsets = [&int32]([batch_sym].buffers[1])
        var start = offsets[idx]
        var count = offsets[idx + 1] - start
      in
        ListSlice { [int64](start), [int64](count) }
      end
    end,
  }
end

function T.large_list(child)
  return {
    id = "large_list", format = "+L", n_buffers = 2, fixed = false,
    child = child, n_children = 1,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var offsets = [&int64]([batch_sym].buffers[1])
        var start = offsets[idx]
        var count = offsets[idx + 1] - start
      in
        ListSlice { start, count }
      end
    end,
  }
end

function T.fixed_list(child, size)
  return {
    id = "fixed_list", format = "+w:" .. size, n_buffers = 1, fixed = false,
    child = child, list_size = size, n_children = 1,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var start = [int64](idx) * [size]
      in
        ListSlice { start, [int64]([size]) }
      end
    end,
  }
end

function T.list_view(child)
  local t = list_view_type("list_view", "+vl", int32)
  t.child = child
  return t
end

function T.large_list_view(child)
  local t = list_view_type("large_list_view", "+vL", int64)
  t.child = child
  return t
end

function T.map(key_type, value_type)
  local entries = T["struct"]({
    { name = "key", type = key_type },
    { name = "value", type = value_type },
  })
  return {
    id = "map", format = "+m", n_buffers = 2, fixed = false,
    child = entries, n_children = 1,
    gen_get = function(batch_sym, row_sym)
      return quote
        var idx = [row_sym] + [batch_sym].offset
        var offsets = [&int32]([batch_sym].buffers[1])
        var start = offsets[idx]
        var count = offsets[idx + 1] - start
      in
        ListSlice { [int64](start), [int64](count) }
      end
    end,
  }
end

function T.sparse_union(fields, type_ids)
  return make_union_type("sparse_union", "+us", fields, type_ids)
end

function T.dense_union(fields, type_ids)
  return make_union_type("dense_union", "+ud", fields, type_ids)
end

function T.run_end_encoded(run_end_type, value_type)
  return run_end_encoded_type(run_end_type, value_type)
end

function T.extension(storage_type, extension_name, extension_metadata)
  return extension_type(storage_type, extension_name, extension_metadata)
end

local dictionary_index_ids = {
  int8 = true, int16 = true, int32 = true, int64 = true,
  uint8 = true, uint16 = true, uint32 = true, uint64 = true,
}

function T.dictionary(index_type, value_type)
  assert(type(index_type) == "table", "dictionary index_type must be a type object")
  assert(type(value_type) == "table", "dictionary value_type must be a type object")
  assert(dictionary_index_ids[index_type.id],
    "dictionary index_type must be one of int8/int16/int32/int64/uint8/uint16/uint32/uint64")

  return {
    id = "dictionary",
    -- In Arrow C Data Interface, dictionary arrays use index storage format.
    format = index_type.format,
    terra_type = value_type.terra_type,
    n_buffers = index_type.n_buffers,
    fixed = value_type.fixed,
    numeric = value_type.numeric,
    index_type = index_type,
    value_type = value_type,
    gen_get = function(batch_sym, row_sym)
      local idx_expr = index_type.gen_get(batch_sym, row_sym)
      return quote
        var dict_arr = [batch_sym].dictionary
        var dict_idx = [int64]([idx_expr])
      in
        [value_type.gen_get(`dict_arr, `dict_idx)]
      end
    end,
  }
end

T["struct"] = function(fields)
  return {
    id = "struct", format = "+s", n_buffers = 1, fixed = false,
    fields = fields, n_children = #fields,
    gen_field = function(field_name, batch_sym, row_sym)
      for i, f in ipairs(fields) do
        if f.name == field_name then
          local child_type = (type(f.type) == "table") and f.type or string_types[f.type]
          return child_type.gen_get(`[batch_sym].children[ [i-1] ], row_sym)
        end
      end
      error("struct field not found: " .. field_name)
    end,
  }
end

arrow.types = T

-- ============================================================
-- Type resolution (backward compat: strings → type objects)
-- ============================================================

string_types = {
  na = T.na, ["null"] = T.na,
  int8 = T.int8, int16 = T.int16, int32 = T.int32, int64 = T.int64,
  uint8 = T.uint8, uint16 = T.uint16, uint32 = T.uint32, uint64 = T.uint64,
  half_float = T.half_float,
  float32 = T.float32, float64 = T.float64,
  date32 = T.date32, date64 = T.date64,
  interval_months = T.interval_months,
  interval_day_time = T.interval_day_time,
  interval_month_day_nano = T.interval_month_day_nano,
  decimal32 = T.decimal32(), decimal64 = T.decimal64(),
  decimal128 = T.decimal128(), decimal256 = T.decimal256(),
  time32 = T.time32_ms, time64 = T.time64_us,
  timestamp = T.timestamp_us, duration = T.duration_ms,
  time32_s = T.time32_s, time32_ms = T.time32_ms,
  time64_us = T.time64_us, time64_ns = T.time64_ns,
  timestamp_s = T.timestamp_s, timestamp_ms = T.timestamp_ms,
  timestamp_us = T.timestamp_us, timestamp_ns = T.timestamp_ns,
  duration_s = T.duration_s, duration_ms = T.duration_ms,
  duration_us = T.duration_us, duration_ns = T.duration_ns,
  bool = T.bool,
  utf8 = T.utf8, large_utf8 = T.large_utf8,
  binary = T.binary, large_binary = T.large_binary,
  string_view = T.string_view, binary_view = T.binary_view,
}

local function resolve_type(col)
  if type(col.type) == "table" then return col.type end
  if col.type == "fixed_binary" then return T.fixed_binary(col.byte_width) end
  return string_types[col.type]
end

-- ============================================================
-- Schema validation
-- ============================================================

local function validate_schema(schema)
  for i, col in ipairs(schema) do
    assert(col.name, "column " .. i .. ": missing name")
    assert(col.type, "column " .. i .. " (" .. col.name .. "): missing type")
    local typ = resolve_type(col)
    assert(typ, "column " .. i .. " (" .. col.name .. "): unknown type '" .. tostring(col.type) .. "'")
    if type(col.type) == "string" and col.type == "fixed_binary" then
      assert(col.byte_width and col.byte_width > 0,
        "column " .. i .. " (" .. col.name .. "): fixed_binary requires byte_width > 0")
    end
  end
end

-- ============================================================
-- Accessor generation
-- ============================================================

-- Generate a validity check function for a given array
local function gen_validity(batch_sym, row_sym)
  return quote
    var bitmap = [&uint8]([batch_sym].buffers[0])
    var idx = [row_sym] + [batch_sym].offset
    var valid: bool
    if bitmap == nil then
      valid = true
    else
      var byte_idx = idx >> 3
      var bit_idx = idx and 7
      valid = ((bitmap[byte_idx] >> bit_idx) and 1) == 1
    end
  in
    valid
  end
end

local function unwrap_extension(typ)
  if typ and typ.id == "extension" then return typ.storage_type end
  return typ
end

local function unwrap_logical_type(typ)
  typ = unwrap_extension(typ)
  if typ and typ.id == "dictionary" then
    return unwrap_logical_type(typ.value_type)
  end
  return typ
end

local function is_list_like(typ)
  local id = typ.id
  return id == "list" or id == "large_list" or id == "fixed_list"
      or id == "list_view" or id == "large_list_view" or id == "map"
end

local function is_union_like(typ)
  return typ.id == "dense_union" or typ.id == "sparse_union"
end

local function gen_typed_validity(typ, batch_sym, row_sym)
  local logical = unwrap_logical_type(typ)
  if logical.id == "na" then
    return `false
  end
  if is_union_like(logical) then
    return `true
  end
  return gen_validity(batch_sym, row_sym)
end

-- Build a child reader table for a nested type
local function gen_child_reader(typ)
  typ = unwrap_logical_type(typ)
  if typ.id == "struct" then
    local child_get = {}
    local child_is_valid = {}
    local child_child = {}
    for i, f in ipairs(typ.fields) do
      local child_type = (type(f.type) == "table") and f.type or string_types[f.type]
      local child_idx = i - 1

      child_is_valid[f.name] = function(struct_sym, row_sym)
        return gen_typed_validity(child_type,
          `[struct_sym].children[ [child_idx] ], `([row_sym] + [struct_sym].offset))
      end

      local effective_child_type = unwrap_logical_type(child_type)

      if effective_child_type.id == "struct" then
        -- Nested struct: no direct get, recurse into child
        child_child[f.name] = gen_child_reader(effective_child_type)
        child_child[f.name].array = function(parent_sym)
          return `[parent_sym].children[ [child_idx] ]
        end
      elseif is_list_like(effective_child_type) or is_union_like(effective_child_type)
          or effective_child_type.id == "run_end_encoded" then
        child_get[f.name] = function(struct_sym, row_sym)
          return child_type.gen_get(`[struct_sym].children[ [child_idx] ], `([row_sym] + [struct_sym].offset))
        end
        local nested_child = gen_child_reader(effective_child_type)
        nested_child.array = function(parent_sym)
          return `[parent_sym].children[ [child_idx] ]
        end
        child_child[f.name] = nested_child
      else
        child_get[f.name] = function(struct_sym, row_sym)
          return child_type.gen_get(`[struct_sym].children[ [child_idx] ], `([row_sym] + [struct_sym].offset))
        end
      end
    end
    return { get = child_get, is_valid = child_is_valid, child = child_child }

  elseif is_list_like(typ) then
    local child_type = typ.child
    local result = {
      array = function(list_sym)
        return `[list_sym].children[0]
      end,
    }

    local effective_child_type = unwrap_logical_type(child_type)
    if effective_child_type.id == "struct" then
      -- List<Struct<...>>: flatten struct fields into child reader
      local struct_reader = gen_child_reader(effective_child_type)
      result.get = struct_reader.get
      result.is_valid = struct_reader.is_valid
      if next(struct_reader.child) then
        result.child = struct_reader.child
      end
    else
      -- List<scalar>: single "elem" accessor
      result.get = {
        elem = function(child_sym, row_sym)
          return child_type.gen_get(child_sym, row_sym)
        end,
      }
      result.is_valid = {
        elem = function(child_sym, row_sym)
          return gen_typed_validity(child_type, child_sym, row_sym)
        end,
      }
    end
    return result

  elseif is_union_like(typ) then
    local child_get = {
      type_id = function(union_sym, row_sym)
        return `[typ.gen_get(union_sym, row_sym)].type_id
      end,
      child_offset = function(union_sym, row_sym)
        return `[typ.gen_get(union_sym, row_sym)].child_offset
      end,
    }
    local child_is_valid = {}
    local child_child = {}

    for i, f in ipairs(typ.fields) do
      local field_type = (type(f.type) == "table") and f.type or string_types[f.type]
      local eff_field_type = unwrap_logical_type(field_type)
      local child_idx = i - 1
      child_get[f.name] = function(union_sym, row_sym)
        return quote
          var ref = [typ.gen_get(union_sym, row_sym)]
        in
          [field_type.gen_get(`[union_sym].children[ [child_idx] ], `ref.child_offset)]
        end
      end
      child_is_valid[f.name] = function(union_sym, row_sym)
        return quote
          var ref = [typ.gen_get(union_sym, row_sym)]
        in
          [gen_typed_validity(field_type, `[union_sym].children[ [child_idx] ], `ref.child_offset)]
        end
      end

      if eff_field_type.id == "struct" or is_list_like(eff_field_type)
          or is_union_like(eff_field_type) or eff_field_type.id == "run_end_encoded" then
        local nested_child = gen_child_reader(eff_field_type)
        nested_child.array = function(parent_sym)
          return `[parent_sym].children[ [child_idx] ]
        end
        child_child[f.name] = nested_child
      end
    end

    return { get = child_get, is_valid = child_is_valid, child = child_child }

  elseif typ.id == "run_end_encoded" then
    local value_type = unwrap_logical_type(typ.value_type)
    local result = {
      array = function(re_sym)
        return `[re_sym].children[1]
      end,
      run_ends_array = function(re_sym)
        return `[re_sym].children[0]
      end,
      get = {
        run_index = function(re_sym, row_sym)
          return typ.gen_get(re_sym, row_sym)
        end,
      },
      is_valid = {},
    }

    result.get.value = function(re_sym, row_sym)
      return quote
        var run_idx = [typ.gen_get(re_sym, row_sym)]
      in
        [typ.value_type.gen_get(`[re_sym].children[1], `run_idx)]
      end
    end

    result.is_valid.value = function(re_sym, row_sym)
      return quote
        var run_idx = [typ.gen_get(re_sym, row_sym)]
      in
        [gen_typed_validity(typ.value_type, `[re_sym].children[1], `run_idx)]
      end
    end

    if value_type.id == "struct" or is_list_like(value_type)
        or is_union_like(value_type) or value_type.id == "run_end_encoded" then
      local nested = gen_child_reader(value_type)
      nested.array = function(re_sym)
        return `[re_sym].children[1]
      end
      result.child = nested
    end

    return result

  else
    return nil
  end
end

function arrow.gen_reader(schema)
  validate_schema(schema)

  local get = {}
  local is_valid = {}
  local child = {}

  for i, col in ipairs(schema) do
    local typ = resolve_type(col)
    local shape_typ = unwrap_logical_type(typ)

    is_valid[col.name] = function(batch_sym, row_sym)
      return gen_typed_validity(typ, batch_sym, row_sym)
    end

    if shape_typ.id == "struct" then
      -- Struct: no single-value get, build child reader.
      local cr = gen_child_reader(shape_typ)
      if typ.id == "dictionary" then
        cr.array = function(batch_sym)
          return `[batch_sym].dictionary
        end
        cr.dict_index = function(batch_sym, row_sym)
          return `[int64]([typ.index_type.gen_get(batch_sym, row_sym)])
        end
      end
      child[col.name] = cr
    elseif is_list_like(shape_typ) or is_union_like(shape_typ) or shape_typ.id == "run_end_encoded" then
      -- Nested/container types expose both get + child readers.
      get[col.name] = typ.gen_get
      local cr = gen_child_reader(shape_typ)
      if typ.id == "dictionary" then
        child[col.name] = {
          get = cr.get,
          is_valid = cr.is_valid,
          child = cr.child,
          array = function(batch_sym)
            return cr.array(`[batch_sym].dictionary)
          end,
          dict_index = function(batch_sym, row_sym)
            return `[int64]([typ.index_type.gen_get(batch_sym, row_sym)])
          end,
        }
      else
        child[col.name] = cr
      end
    else
      -- Flat types: gen_get required
      assert(typ.gen_get, "type " .. typ.id .. " does not support accessor generation")
      get[col.name] = typ.gen_get
    end
  end

  return { get = get, is_valid = is_valid, child = child }
end

-- ============================================================
-- Record batch reader (struct array → per-column accessors)
-- ============================================================

-- Like gen_reader, but accessors take (batch_sym, row_sym) where
-- batch_sym is a struct ArrowArray (record batch). Each column
-- accessor indexes into batch.children[i] automatically.
function arrow.gen_batch_reader(schema)
  validate_schema(schema)

  local get = {}
  local is_valid = {}
  local child = {}

  for i, col in ipairs(schema) do
    local typ = resolve_type(col)
    local shape_typ = unwrap_logical_type(typ)
    local col_idx = i - 1

    is_valid[col.name] = function(batch_sym, row_sym)
      return gen_typed_validity(typ,
        `[batch_sym].children[ [col_idx] ], `([row_sym] + [batch_sym].offset))
    end

    if shape_typ.id == "struct" then
      -- Struct column: child reader rooted at batch.children[col_idx]
      local cr = gen_child_reader(shape_typ)
      local out = {
        get = {},
        is_valid = cr.is_valid,
        child = cr.child,
      }
      if typ.id == "dictionary" then
        out.array = function(batch_sym)
          return `[batch_sym].children[ [col_idx] ].dictionary
        end
        out.dict_index = function(batch_sym, row_sym)
          return `[int64]([typ.index_type.gen_get(
            `[batch_sym].children[ [col_idx] ], `([row_sym] + [batch_sym].offset))])
        end
      else
        out.array = function(batch_sym)
          return `[batch_sym].children[ [col_idx] ]
        end
      end
      -- Wrap get functions to navigate from batch to struct child
      for fname, fn in pairs(cr.get) do
        if typ.id == "dictionary" then
          out.get[fname] = function(batch_sym, row_sym)
            return quote
              var col_arr = [batch_sym].children[ [col_idx] ]
              var dict_idx = [int64]([typ.index_type.gen_get(`col_arr, `([row_sym] + [batch_sym].offset))])
            in
              [fn(`col_arr.dictionary, `dict_idx)]
            end
          end
        else
          out.get[fname] = function(batch_sym, row_sym)
            return fn(`[batch_sym].children[ [col_idx] ], `([row_sym] + [batch_sym].offset))
          end
        end
      end
      child[col.name] = out
    elseif is_list_like(shape_typ) or is_union_like(shape_typ) or shape_typ.id == "run_end_encoded" then
      -- Nested/container column: get + child readers from batch.children[col_idx].
      get[col.name] = function(batch_sym, row_sym)
        return typ.gen_get(`[batch_sym].children[ [col_idx] ], `([row_sym] + [batch_sym].offset))
      end
      local cr = gen_child_reader(shape_typ)
      if typ.id == "dictionary" then
        child[col.name] = {
          get = cr.get,
          is_valid = cr.is_valid,
          child = cr.child,
          array = function(batch_sym)
            return cr.array(`[batch_sym].children[ [col_idx] ].dictionary)
          end,
          dict_index = function(batch_sym, row_sym)
            return `[int64]([typ.index_type.gen_get(
              `[batch_sym].children[ [col_idx] ], `([row_sym] + [batch_sym].offset))])
          end,
        }
      else
        child[col.name] = {
          get = cr.get,
          is_valid = cr.is_valid,
          child = cr.child,
          array = function(batch_sym)
            return cr.array(`[batch_sym].children[ [col_idx] ])
          end,
        }
      end
    else
      -- Flat column: accessor navigates to batch.children[col_idx]
      get[col.name] = function(batch_sym, row_sym)
        return typ.gen_get(`[batch_sym].children[ [col_idx] ], `([row_sym] + [batch_sym].offset))
      end
    end
  end

  return { get = get, is_valid = is_valid, child = child }
end

-- ============================================================
-- Vectorized filter codegen
-- ============================================================

-- Comparison operators
local compare_ops = {
  [">"]  = function(a, b) return `a > b end,
  ["<"]  = function(a, b) return `a < b end,
  [">="] = function(a, b) return `a >= b end,
  ["<="] = function(a, b) return `a <= b end,
  ["=="] = function(a, b) return `a == b end,
  ["!="] = function(a, b) return `a ~= b end,
}

function arrow.gen_compare_filter(schema, col_name, op, threshold)
  validate_schema(schema)
  local op_fn = compare_ops[op]
  assert(op_fn, "unknown operator: " .. tostring(op))

  -- Find column
  local col_idx, col
  for i, c in ipairs(schema) do
    if c.name == col_name then
      col_idx = i - 1
      col = c
      break
    end
  end
  assert(col, "column not found: " .. col_name)

  local typ = resolve_type(col)
  local logical_typ = unwrap_logical_type(typ)
  assert(logical_typ.numeric, "vectorized filter only supports numeric types, got: " .. logical_typ.id)

  local thresh_val = threshold

  return function(batch_sym, mask_sym)
    return quote
      var n = [batch_sym].length
      var n_blocks = (n + 63) / 64

      for block = 0, n_blocks do
        var bits: uint64 = 0
        var base = block * 64
        for j = 0, 64 do
          var idx = base + j
          if idx < n then
            var valid = [gen_typed_validity(typ, batch_sym, `idx)]
            if valid then
              var v = [typ.gen_get(batch_sym, `idx)]
              if [op_fn(`v, `[thresh_val])] then
                bits = bits or ([uint64](1) << j)
              end
            end
          end
        end
        [mask_sym][block] = bits
      end
    end
  end
end

function arrow.gen_and_filter(left_gen, right_gen)
  return function(batch_sym, mask_sym)
    return quote
      var n = [batch_sym].length
      var n_blocks = (n + 63) / 64
      var left_mask = [&uint64](C.calloc(n_blocks, sizeof(uint64)))
      var right_mask = [&uint64](C.calloc(n_blocks, sizeof(uint64)))
      if left_mask == nil or right_mask == nil then
        if left_mask ~= nil then C.free(left_mask) end
        if right_mask ~= nil then C.free(right_mask) end
        for block = 0, n_blocks do
          [mask_sym][block] = 0
        end
      else
        [left_gen(batch_sym, `left_mask)]
        [right_gen(batch_sym, `right_mask)]
        for block = 0, n_blocks do
          [mask_sym][block] = left_mask[block] and right_mask[block]
        end
        C.free(left_mask)
        C.free(right_mask)
      end
    end
  end
end

function arrow.gen_or_filter(left_gen, right_gen)
  return function(batch_sym, mask_sym)
    return quote
      var n = [batch_sym].length
      var n_blocks = (n + 63) / 64
      var left_mask = [&uint64](C.calloc(n_blocks, sizeof(uint64)))
      var right_mask = [&uint64](C.calloc(n_blocks, sizeof(uint64)))
      if left_mask == nil or right_mask == nil then
        if left_mask ~= nil then C.free(left_mask) end
        if right_mask ~= nil then C.free(right_mask) end
        for block = 0, n_blocks do
          [mask_sym][block] = 0
        end
      else
        [left_gen(batch_sym, `left_mask)]
        [right_gen(batch_sym, `right_mask)]
        for block = 0, n_blocks do
          [mask_sym][block] = left_mask[block] or right_mask[block]
        end
        C.free(left_mask)
        C.free(right_mask)
      end
    end
  end
end

function arrow.gen_not_filter(inner_gen)
  return function(batch_sym, mask_sym)
    return quote
      var n = [batch_sym].length
      var n_blocks = (n + 63) / 64
      var inner_mask = [&uint64](C.calloc(n_blocks, sizeof(uint64)))
      if inner_mask == nil then
        for block = 0, n_blocks do
          [mask_sym][block] = 0
        end
      else
        [inner_gen(batch_sym, `inner_mask)]
        for block = 0, n_blocks do
          [mask_sym][block] = not inner_mask[block]
        end
        if n_blocks > 0 then
          var valid_bits = n and 63
          if valid_bits ~= 0 then
            var tail_mask = ([uint64](1) << valid_bits) - 1
            [mask_sym][n_blocks - 1] = [mask_sym][n_blocks - 1] and tail_mask
          end
        end
        C.free(inner_mask)
      end
    end
  end
end

-- ============================================================
-- Row scanner convenience
-- ============================================================

function arrow.gen_scan(schema, body_fn)
  local reader = arrow.gen_reader(schema)
  local batch_sym = symbol(&ArrowArray, "batch")
  local row_sym = symbol(int64, "row")

  local body = body_fn(reader, batch_sym, row_sym)

  return terra([batch_sym])
    for [row_sym] = 0, [batch_sym].length do
      [body]
    end
  end
end

return arrow
