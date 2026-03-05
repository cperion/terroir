local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local ROOT = _src:match("^(.*)/[^/]+$") or "."
local backend = dofile(ROOT .. "/backend.t")

local M = {}

function M.instantiate_from_ir(ir, wasm_bytes, host_functions, opts)
  return backend.instantiate_from_ir(ir, wasm_bytes, host_functions, opts)
end

function M.instance_init(instance)
  return backend.instance_init(instance)
end

function M.instance_deinit(instance)
  return backend.instance_deinit(instance)
end

function M.instance_export_count(instance)
  return backend.instance_export_count(instance)
end

function M.instance_export_name(instance, i)
  return backend.instance_export_name(instance, i)
end

function M.instance_export_sig(instance, i)
  return backend.instance_export_sig(instance, i)
end

function M.instance_export_ptr(instance, i, ctype)
  return backend.instance_export_ptr(instance, i, ctype)
end

function M.instance_memory(instance)
  return backend.instance_memory(instance)
end

function M.instance_memory_size(instance)
  return backend.instance_memory_size(instance)
end

function M.load_module_compat(instance)
  return backend.load_module_compat(instance)
end

return M
