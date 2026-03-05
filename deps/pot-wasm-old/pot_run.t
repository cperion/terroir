-- PO.T WASM Runner
-- Usage: ./po.t <file.wasm> [args...]

local POT = require("pot")

local wasm_file = arg[1]
if not wasm_file then
    io.stderr:write("Usage: ./po.t <file.wasm> [args...]\n")
    os.exit(1)
end

local f = io.open(wasm_file, "rb")
if not f then
    io.stderr:write("Error: cannot open " .. wasm_file .. "\n")
    os.exit(1)
end
local bytes = f:read("*a")
f:close()

local prog_args = { wasm_file }
for i = 2, #arg do
    prog_args[#prog_args + 1] = arg[i]
end

POT.run(bytes, prog_args)
