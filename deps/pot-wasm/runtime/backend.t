local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local ROOT = _src:match("^(.*)/[^/]+$") or "."

local engine = terralib.loadfile(ROOT .. "/engine.t")()

local M = {}

local function resolve_memory_type(mod, mem_index_1based)
  local import_mem = 0
  for _, imp in ipairs(mod.imports or {}) do
    if imp.kind == "memory" then
      import_mem = import_mem + 1
      if import_mem == mem_index_1based then
        return { initial = imp.initial or 0, maximum = imp.maximum }
      end
    end
  end
  local local_idx = mem_index_1based - import_mem
  local m = mod.memory and mod.memory[local_idx] or nil
  if m then
    return { initial = m.initial or 0, maximum = m.maximum }
  end
  return nil
end

function M.instantiate_from_ir(ir, wasm_bytes, host_functions, opts)
  host_functions = host_functions or {}
  opts = opts or {}

  -- Build a fresh compiled module per instantiation to avoid mutable state
  -- sharing across module instances (memory/globals/start semantics).
  local compile_opts = {
    auto_wasi = opts.auto_wasi,
    auto_c_imports = opts.auto_c_imports,
  }
  local module = engine.compile_module(wasm_bytes, host_functions, compile_opts)
  local mod = module.mod

  local exports_by_name = {}
  local export_list = {}
  for name, exp in pairs(mod.exports) do
    if exp.kind == 0 then
      local item = {
        name = name,
        kind = "function",
        fn = module.exports[name],
        ftype = nil,
        ffi_sig = nil,
        ffi_sig_error = "signature metadata unavailable",
        ptr = nil,
      }
      exports_by_name[name] = item
      export_list[#export_list + 1] = item
    elseif exp.kind == 2 then
      local mem_ty = resolve_memory_type(mod, exp.index)
      exports_by_name[name] = {
        name = name,
        kind = "memory",
        initial = mem_ty and mem_ty.initial or 0,
        maximum = mem_ty and mem_ty.maximum or nil,
      }
    end
  end
  table.sort(export_list, function(a, b) return a.name < b.name end)

  local instance = {
    module = module,
    exports = exports_by_name,
    export_list = export_list,
    initialized = false,
    _ir = ir,
  }

  if opts.init ~= false then
    M.instance_init(instance)
  end
  if opts.eager then
    for _, e in ipairs(instance.export_list) do
      e.fn:compile()
    end
  end

  return instance
end

function M.instance_init(instance)
  if not instance.initialized then
    instance.module.init_fn()
    instance.initialized = true

    -- Execute start function automatically at instantiation time, once.
    local start_idx = instance.module.mod.start_fn
    if start_idx ~= nil then
      local entry = instance.module.module_env.functions[start_idx]
      if entry and entry.fn then
        entry.fn()
      end
    end
  end
end

function M.instance_deinit(instance)
  if instance.initialized then
    instance.module.deinit_fn()
    instance.initialized = false
  end
end

function M.instance_export_count(instance)
  return #instance.export_list
end

function M.instance_export_name(instance, i)
  local idx = tonumber(i)
  if not idx then return nil end
  idx = idx + 1
  if idx < 1 or idx > #instance.export_list then return nil end
  return instance.export_list[idx].name
end

function M.instance_export_sig(instance, i)
  local idx = tonumber(i)
  if not idx then return nil, "invalid index" end
  idx = idx + 1
  if idx < 1 or idx > #instance.export_list then return nil, "index out of range" end
  local e = instance.export_list[idx]
  return e.ffi_sig, e.ffi_sig_error
end

function M.instance_export_ptr(instance, i, ctype)
  local ffi = require("ffi")
  local idx = tonumber(i)
  if not idx then return nil, "invalid index" end
  idx = idx + 1
  if idx < 1 or idx > #instance.export_list then return nil, "index out of range" end
  local e = instance.export_list[idx]
  if e.ptr == nil then
    e.fn:compile()
    e.ptr = ffi.cast("void*", e.fn:getpointer())
  end
  if ctype then return ffi.cast(ctype, e.ptr) end
  return e.ptr
end

function M.instance_memory(instance)
  local ffi = require("ffi")
  return ffi.cast("void*", instance.module.memory_fn())
end

function M.instance_memory_size(instance)
  return tonumber(instance.module.memory_size_fn())
end

function M.load_module_compat(instance)
  local exports = {}
  for name, e in pairs(instance.exports) do
    if e.kind == "function" then
      exports[name] = e.fn
    elseif e.kind == "memory" then
      exports[name] = {
        initial = e.initial,
        maximum = e.maximum,
      }
    end
  end
  return exports
end

return M
