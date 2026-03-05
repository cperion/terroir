-- Instrument pot.t for timing
-- This modifies pot.t in memory before using it

-- Read pot.t source
local f = io.open("pot.t", "r")
local pot_source = f:read("*a")
f:close()

-- Add timing infrastructure at the top
local timing_code = [[
local _Ctime = terralib.includec("time.h")
local _timings = {}
local function _tic(name) _timings[name] = _timings[name] or {start=0, total=0} _timings[name].start = os.clock() end
local function _toc(name) local t = _timings[name]; if t and t.start > 0 then t.total = t.total + (os.clock() - t.start); t.start = 0 end end
local function _get_timings() local r = {} for k,v in pairs(_timings) do r[k] = v.total * 1000 end return r end
]]

-- Insert after requires
local insert_pos = pot_source:find("\nlocal POT")
if insert_pos then
    pot_source = pot_source:sub(1, insert_pos) .. timing_code .. pot_source:sub(insert_pos + 1)
end

-- Add timing to key functions
pot_source = pot_source:gsub("local function parse_wasm%(bytes%)", "local function parse_wasm(bytes) _tic('parse_wasm')")
pot_source = pot_source:gsub("(local function compile_function%([^)]+%))", "%1 _tic('compile_function')")
pot_source = pot_source:gsub("(local function compile_module_core%([^)]+%))", "%1 _tic('compile_module_core')")

-- Add _toc before returns in these functions
-- This is a bit hacky but works for these specific functions
pot_source = pot_source:gsub("(parse_wasm[^)]*return [^\n]+)", "_toc('parse_wasm') %1")
pot_source = pot_source:gsub("(compile_function[^)]*return [^\n]+)", "_toc('compile_function') %1")

-- Add timing export
local export_pos = pot_source:find("return POT")
if export_pos then
    pot_source = pot_source:sub(1, export_pos - 1) .. 
        "POT._timings = _get_timings\n\n" .. 
        pot_source:sub(export_pos)
end

-- Save modified version
local f = io.open("pot_instrumented.t", "w")
f:write(pot_source)
f:close()

io.stderr:write("Created pot_instrumented.t\n")

-- Now use it
package.loaded.pot = nil
package.loaded.pot_instrumented = nil
dofile("pot_instrumented.t")
local POT = require("pot_instrumented")

local wasm_file = arg[1] or "examples/bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

io.stderr:write(string.format("\n=== Compilation Profile for %s ===\n", wasm_file))

local t0 = os.clock()
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
local t1 = os.clock()

io.stderr:write(string.format("\nTotal load_module: %.2f ms\n\n", (t1 - t0) * 1000))

io.stderr:write("Timings from instrumentation:\n")
local timings = POT._timings()
for name, ms in pairs(timings) do
    io.stderr:write(string.format("  %s: %.2f ms\n", name, ms))
end

if exports._start then exports._start() end
