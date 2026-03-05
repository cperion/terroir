-- POT runtime export inspector (no per-module AOT output)
-- Usage: terra po_build.t <input.wasm>

local POT = require("pot")

local function usage()
    io.stderr:write(
        "Usage: terra po_build.t <input.wasm>\n" ..
        "Example: terra po_build.t bench.wasm\n")
end

local wasm_path = arg[1]

if not wasm_path then
    usage()
    os.exit(1)
end

local f = assert(io.open(wasm_path, "rb"))
local bytes = f:read("*a")
f:close()

local inst = POT.instantiate(bytes, {}, { init = false, eager = false })
local n = POT.instance_export_count(inst)
print(string.format("module: %s", wasm_path))
print(string.format("exports: %d", n))
for i = 0, n - 1 do
    local name = POT.instance_export_name(inst, i)
    local sig, err = POT.instance_export_sig(inst, i)
    if sig then
        print(string.format("  [%d] %s :: %s", i, name, sig))
    else
        print(string.format("  [%d] %s :: <unsupported> (%s)", i, name, err))
    end
end
