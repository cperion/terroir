local POT = require("pot")

local function usage()
  io.stderr:write("usage: terra scripts/pot_wasi_runner.t <module.wasm> [--env K=V]... [--dir HOST::GUEST]... [--] [args...]\n")
end

local argv = {...}
if #argv < 1 then
  usage()
  os.exit(2)
end

local wasm_path = argv[1]
local wasi_args = { wasm_path }
local wasi_env = {}
local wasi_dirs = {}

local i = 2
local passthrough = false
while i <= #argv do
  local a = argv[i]
  if not passthrough and a == "--" then
    passthrough = true
    i = i + 1
  elseif not passthrough and a == "--env" then
    local kv = argv[i + 1] or ""
    local eq = kv:find("=", 1, true)
    if not eq then
      io.stderr:write("invalid --env entry: " .. kv .. "\n")
      os.exit(2)
    end
    local k = kv:sub(1, eq - 1)
    local v = kv:sub(eq + 1)
    wasi_env[k] = v
    i = i + 2
  elseif not passthrough and a == "--dir" then
    local spec = argv[i + 1] or ""
    local sep = spec:find("::", 1, true)
    local host = spec
    local guest = spec
    if sep then
      host = spec:sub(1, sep - 1)
      guest = spec:sub(sep + 2)
    end
    wasi_dirs[#wasi_dirs + 1] = { host = host, guest = guest }
    i = i + 2
  else
    wasi_args[#wasi_args + 1] = a
    i = i + 1
  end
end

local f = assert(io.open(wasm_path, "rb"), "cannot open wasm module: " .. tostring(wasm_path))
local wasm_bytes = f:read("*a")
f:close()

local host = {
  _wasi_args = wasi_args,
  _wasi_env = wasi_env,
  _wasi_dirs = wasi_dirs,
}

local ok, err = pcall(function()
  local exports = POT.load_module(wasm_bytes, host, { auto_wasi = true })
  if exports._start then
    exports._start()
  elseif exports._initialize then
    exports._initialize()
  elseif exports.main then
    exports.main()
  end
end)

if not ok then
  io.stderr:write(tostring(err), "\n")
  os.exit(1)
end

os.exit(0)
