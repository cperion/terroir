-- PO.T C embedding builder
-- Usage: terra po_build.t <input.wasm> <output.o> [output.h] [c_prefix]

local POT = require("pot")

local function usage()
    io.stderr:write(
        "Usage: terra po_build.t <input.wasm> <output.o> [output.h] [c_prefix]\n" ..
        "Example: terra po_build.t bench.wasm bench_embed.o bench_embed.h po_\n")
end

local wasm_path = arg[1]
local out_obj = arg[2]
local out_header = arg[3]
local c_prefix = arg[4] or "po_"

if not wasm_path or not out_obj then
    usage()
    os.exit(1)
end

if not out_header or out_header == "" then
    if out_obj:match("%.o$") then
        out_header = out_obj:gsub("%.o$", ".h")
    else
        out_header = out_obj .. ".h"
    end
end

local module_name = wasm_path:gsub("\\", "/"):match("([^/]+)$") or "po_module"
module_name = module_name:gsub("%.[^.]+$", "")
module_name = module_name:gsub("[^%w_]", "_")
if module_name == "" then module_name = "po_module" end
if module_name:match("^[0-9]") then module_name = "_" .. module_name end

local api = POT.save_c_module_file(wasm_path, out_obj, {
    header_path = out_header,
    module_name = module_name,
    c_prefix = c_prefix,
})

print("wrote: " .. api.object_path)
if api.header_path then
    print("wrote: " .. api.header_path)
end
print("exports:")
for _, e in ipairs(api.exports) do
    print(string.format("  %s -> %s", e.wasm_name, e.c_symbol))
end
if #api.imports > 0 then
    print("host imports to implement:")
    for _, i in ipairs(api.imports) do
        print(string.format("  %s -> %s", i.key, i.c_symbol))
    end
end
