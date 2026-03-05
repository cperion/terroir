local M = {}

local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local _dir = _src:match("^(.*)/[^/]+$") or "."
local Mod = dofile(_dir .. "/util/module.t")
local ROOT = Mod.this_dir(1)
local function load(rel) return Mod.load_relative(ROOT, rel) end

local pipeline = load("compiler/pipeline.t")
local runtime = load("runtime/instance.t")

M.VERSION = "0.2.0-migration"
M.ARCH = "strata-clean"

function M.parse_wasm(wasm_bytes)
  return pipeline.parse_wasm(wasm_bytes)
end

function M.build_ir(wasm_bytes, host_functions, opts)
  return pipeline.build_ir(wasm_bytes, host_functions or {}, opts or {})
end

function M.instantiate(wasm_bytes, host_functions, opts)
  local ir = pipeline.build_ir(wasm_bytes, host_functions or {}, opts or {})
  return runtime.instantiate_from_ir(ir, wasm_bytes, host_functions or {}, opts or {})
end

function M.instance_init(instance)
  return runtime.instance_init(instance)
end

function M.instance_deinit(instance)
  return runtime.instance_deinit(instance)
end

function M.instance_export_count(instance)
  return runtime.instance_export_count(instance)
end

function M.instance_export_name(instance, i)
  return runtime.instance_export_name(instance, i)
end

function M.instance_export_sig(instance, i)
  return runtime.instance_export_sig(instance, i)
end

function M.instance_export_ptr(instance, i, ctype)
  return runtime.instance_export_ptr(instance, i, ctype)
end

function M.instance_memory(instance)
  return runtime.instance_memory(instance)
end

function M.instance_memory_size(instance)
  return runtime.instance_memory_size(instance)
end

-- Compatibility wrappers while we migrate call sites.
function M.load_module(wasm_bytes, host_functions, opts)
  return runtime.load_module_compat(M.instantiate(wasm_bytes, host_functions, opts))
end

function M.load_file(path, host_functions, opts)
  local f = assert(io.open(path, "rb"), "cannot open: " .. tostring(path))
  local bytes = f:read("*a")
  f:close()
  return M.load_module(bytes, host_functions, opts)
end

function M.run(wasm_bytes, args)
  local exports = M.load_module(wasm_bytes, { _wasi_args = args or {} })
  if exports._start then
    exports._start()
  elseif exports._initialize then
    exports._initialize()
  end
  return exports
end

return M
