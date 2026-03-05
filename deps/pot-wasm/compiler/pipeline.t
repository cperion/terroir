local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local ROOT = _src:match("^(.*)/[^/]+$") or "."
local Mod = dofile(ROOT .. "/../util/module.t")
local frontend = Mod.load_relative(ROOT, "frontend.t")
local lower = Mod.load_relative(ROOT, "lower.t")
local normalize = Mod.load_relative(ROOT, "passes/normalize.t")

local M = {}

function M.parse_wasm(wasm_bytes)
  return frontend.parse_wasm(wasm_bytes)
end

function M.build_ir(wasm_bytes, host_functions, opts)
  local parsed = frontend.parse_wasm(wasm_bytes)
  local ir = lower.to_ir(parsed)
  ir = normalize.run(ir)
  ir._host_functions = host_functions
  ir._opts = opts
  return ir
end

return M
