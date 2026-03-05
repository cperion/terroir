-- Profile POT compilation by wrapping key functions
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end
local timings = {}
local function timing_wrap(name, fn)
    return function(...)
        local t0 = now_ns()
        local result = fn(...)
        local t1 = now_ns()
        timings[name] = (timings[name] or 0) + ms(t1 - t0)
        return result
    end
end

-- Wrap key POT functions
local POT = require("pot")

-- Store originals
local orig_parse = POT.parse_wasm
local orig_load = POT.load_module

POT.parse_wasm = timing_wrap("parse_wasm", orig_parse)

-- Load and profile
local wasm_file = arg[1] or "bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

local t_total_start = now_ns()
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
local t_total_end = now_ns()

-- Print results
io.stderr:write("\n=== POT Compilation Profile ===\n")
io.stderr:write(string.format("File: %s (%d bytes)\n\n", wasm_file, #wasm_bytes))

for name, time in pairs(timings) do
    io.stderr:write(string.format("  %s: %.2f ms\n", name, time))
end

io.stderr:write(string.format("\nTotal load_module: %.2f ms\n", ms(t_total_end - t_total_start)))
io.stderr:write(string.format("Unaccounted: %.2f ms\n", 
    ms(t_total_end - t_total_start) - (timings.parse_wasm or 0)))
