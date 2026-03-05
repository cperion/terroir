local ffi = require("ffi")

local function try_typeof(name)
  return pcall(function() return ffi.typeof(name) end)
end

if not try_typeof("struct ArrowArray") then
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
  ]]
end

if not try_typeof("struct ArrowSchema") then
  ffi.cdef[[
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
  ]]
end

if not try_typeof("struct ArrowArrayStream") then
  ffi.cdef[[
    struct ArrowArrayStream {
      int (*get_schema)(struct ArrowArrayStream*, struct ArrowSchema* out);
      int (*get_next)(struct ArrowArrayStream*, struct ArrowArray* out);
      const char* (*get_last_error)(struct ArrowArrayStream*);
      void (*release)(struct ArrowArrayStream*);
      void* private_data;
    };
  ]]
end

if not try_typeof("struct ArrowError") then
  ffi.cdef[[
    struct ArrowError {
      char message[1024];
    };
  ]]
end

if not try_typeof("struct ArrowSchemaView") then
  ffi.cdef[[
    struct ArrowLayout {
      int32_t buffer_type[3];
      int32_t buffer_data_type[3];
      int64_t element_size_bits[3];
      int64_t child_size_elements;
    };

    struct ArrowStringView {
      const char* data;
      int64_t size_bytes;
    };

    struct ArrowSchemaView {
      const struct ArrowSchema* schema;
      int32_t type;
      int32_t storage_type;
      struct ArrowLayout layout;
      struct ArrowStringView extension_name;
      struct ArrowStringView extension_metadata;
      int32_t fixed_size;
      int32_t decimal_bitwidth;
      int32_t decimal_precision;
      int32_t decimal_scale;
      int32_t time_unit;
      const char* timezone;
      const char* union_type_ids;
    };
  ]]
end

if not try_typeof("struct ArrowArrayView *") then
  ffi.cdef[[
    struct ArrowArrayView;
  ]]
end

ffi.cdef[[
  int ArrowSchemaViewInit(struct ArrowSchemaView* schema_view,
                          const struct ArrowSchema* schema,
                          struct ArrowError* error);
  int ArrowArrayInitFromType(struct ArrowArray* array, int32_t type);
  int ArrowArrayFinishBuildingDefault(struct ArrowArray* array,
                                      struct ArrowError* error);
  int ArrowArrayViewInitFromSchema(struct ArrowArrayView* array_view,
                                   const struct ArrowSchema* schema,
                                   struct ArrowError* error);
  int ArrowArrayViewSetArray(struct ArrowArrayView* array_view,
                             const struct ArrowArray* array,
                             struct ArrowError* error);
  int ArrowArrayViewSetArrayMinimal(struct ArrowArrayView* array_view,
                                    const struct ArrowArray* array,
                                    struct ArrowError* error);
  int ArrowArrayViewValidate(struct ArrowArrayView* array_view,
                             int32_t validation_level,
                             struct ArrowError* error);
  int ArrowBasicArrayStreamInit(struct ArrowArrayStream* array_stream,
                                struct ArrowSchema* schema,
                                int64_t n_arrays);
  void ArrowBasicArrayStreamSetArray(struct ArrowArrayStream* array_stream,
                                     int64_t i,
                                     struct ArrowArray* array);
  int ArrowBasicArrayStreamValidate(const struct ArrowArrayStream* array_stream,
                                    struct ArrowError* error);

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

  int64_t na_view_sizeof(void);
  int32_t na_view_init_from_schema(void* out_view, const struct ArrowSchema* schema);
  int32_t na_view_set_array(void* view, const struct ArrowArray* array);
  int32_t na_view_set_array_minimal(void* view, const struct ArrowArray* array);
  void na_view_reset(void* view);
  double na_view_get_double(void* view, int64_t i);
  int64_t na_view_get_int(void* view, int64_t i);
  int8_t na_view_is_null(void* view, int64_t i);
  int64_t na_view_list_child_offset(void* view, int64_t i);
  void* na_view_child(void* view, int64_t i);
  int64_t na_view_length(void* view);
]]

local C = ffi.load("build/libnanoarrow.so")

local M = {}

M.types = {
  BOOL = 2,
  UINT8 = 3,
  INT8 = 4,
  UINT16 = 5,
  INT16 = 6,
  UINT32 = 7,
  INT32 = 8,
  UINT64 = 9,
  INT64 = 10,
  FLOAT = 12,
  DOUBLE = 13,
  STRING = 14,
  BINARY = 15,
  FIXED_BINARY = 16,
  LIST = 26,
  STRUCT = 27,
  LARGE_STRING = 35,
  LARGE_BINARY = 36,
}

M.validation = {
  NONE = 0,
  MINIMAL = 1,
  DEFAULT = 2,
  FULL = 3,
}

local function err_msg(err)
  if err == nil then return nil end
  local msg = ffi.string(err.message)
  if msg == "" then return nil end
  return msg
end

function M.schema_view_init(schema)
  local view = ffi.new("struct ArrowSchemaView")
  local err = ffi.new("struct ArrowError")
  local rc = C.ArrowSchemaViewInit(view, schema, err)
  return rc, view, err_msg(err)
end

function M.array_init_from_type(type_id)
  local arr = ffi.new("struct ArrowArray")
  local rc = C.ArrowArrayInitFromType(arr, type_id)
  return rc, arr
end

function M.array_finish_building_default(arr)
  local err = ffi.new("struct ArrowError")
  local rc = C.ArrowArrayFinishBuildingDefault(arr, err)
  return rc, err_msg(err)
end

function M.array_init(type_id)
  local arr = ffi.new("struct ArrowArray")
  local rc = C.na_array_init(arr, type_id)
  return rc, arr
end

function M.array_start(arr) return C.na_array_start(arr) end
function M.array_append_int(arr, v) return C.na_array_append_int(arr, v) end
function M.array_append_uint(arr, v) return C.na_array_append_uint(arr, v) end
function M.array_append_double(arr, v) return C.na_array_append_double(arr, v) end
function M.array_append_string(arr, s) return C.na_array_append_string(arr, s) end
function M.array_append_bytes(arr, p, n) return C.na_array_append_bytes(arr, p, n) end
function M.array_append_null(arr) return C.na_array_append_null(arr) end
function M.array_finish(arr) return C.na_array_finish(arr) end
function M.array_release(arr) C.na_array_release(arr) end

function M.schema_init(type_id)
  local schema = ffi.new("struct ArrowSchema")
  local rc = C.na_schema_init(schema, type_id)
  return rc, schema
end

function M.schema_set_fixed_size(schema, type_id, width)
  return C.na_schema_set_fixed_size(schema, type_id, width)
end

function M.schema_release(schema)
  C.na_schema_release(schema)
end

function M.array_view_new_from_schema(schema)
  local nbytes = tonumber(C.na_view_sizeof())
  local storage = ffi.new("uint8_t[?]", nbytes)
  local view = ffi.cast("struct ArrowArrayView*", storage)
  local err = ffi.new("struct ArrowError")
  local rc = C.ArrowArrayViewInitFromSchema(view, schema, err)
  return rc, view, storage, err_msg(err)
end

function M.array_view_set_array(view, arr, minimal)
  local err = ffi.new("struct ArrowError")
  local rc
  if minimal then
    rc = C.ArrowArrayViewSetArrayMinimal(view, arr, err)
  else
    rc = C.ArrowArrayViewSetArray(view, arr, err)
  end
  return rc, err_msg(err)
end

function M.array_view_validate(view, level)
  local err = ffi.new("struct ArrowError")
  local rc = C.ArrowArrayViewValidate(view, level or M.validation.DEFAULT, err)
  return rc, err_msg(err)
end

function M.array_view_reset(view)
  C.na_view_reset(ffi.cast("void*", view))
end

function M.array_view_length(view)
  return tonumber(C.na_view_length(ffi.cast("void*", view)))
end

function M.array_view_child(view, i)
  return ffi.cast("struct ArrowArrayView*", C.na_view_child(ffi.cast("void*", view), i))
end

function M.array_view_list_child_offset(view, i)
  return tonumber(C.na_view_list_child_offset(ffi.cast("void*", view), i))
end

function M.array_view_is_null(view, i)
  return C.na_view_is_null(ffi.cast("void*", view), i) ~= 0
end

function M.array_view_get_int(view, i)
  return tonumber(C.na_view_get_int(ffi.cast("void*", view), i))
end

function M.array_view_get_double(view, i)
  return tonumber(C.na_view_get_double(ffi.cast("void*", view), i))
end

function M.basic_array_stream_init(schema, arrays)
  local stream = ffi.new("struct ArrowArrayStream")
  local rc = C.ArrowBasicArrayStreamInit(stream, schema, #arrays)
  if rc ~= 0 then
    return rc, stream, "ArrowBasicArrayStreamInit failed"
  end

  for i = 1, #arrays do
    C.ArrowBasicArrayStreamSetArray(stream, i - 1, arrays[i])
  end

  local err = ffi.new("struct ArrowError")
  local vrc = C.ArrowBasicArrayStreamValidate(stream, err)
  if vrc ~= 0 then
    return vrc, stream, err_msg(err)
  end

  return 0, stream, nil
end

function M.basic_array_stream_get_schema(stream)
  local out = ffi.new("struct ArrowSchema")
  local rc = stream.get_schema(stream, out)
  return rc, out
end

function M.basic_array_stream_get_next(stream)
  local out = ffi.new("struct ArrowArray")
  local rc = stream.get_next(stream, out)
  if rc ~= 0 then
    local msg = stream.get_last_error ~= nil and ffi.string(stream.get_last_error(stream)) or nil
    return rc, out, msg
  end
  return 0, out, nil
end

function M.basic_array_stream_release(stream)
  if stream.release ~= nil then
    stream.release(stream)
  end
end

return M
