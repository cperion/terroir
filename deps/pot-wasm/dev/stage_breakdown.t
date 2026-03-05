-- Detailed stage breakdown
local ffi = require("ffi")
local bit = require("bit")
local C = terralib.includec("stdlib.h")
local Cstr = terralib.includec("string.h")
local Ctime = terralib.includec("time.h")
local Cstdio = terralib.includec("stdio.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end
local function diff(t1, t2) return ms(t2 - t1) end

-- Read pot.t and expose compile_module_core
local POT = require("pot")

-- We can't easily access compile_module_core, so let's time from outside
local wasm_file = arg[1] or "examples/bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

io.stderr:write(string.format("\n=== Stage Breakdown: %s ===\n\n", wasm_file))

-- Parse first to get module info
local mod = POT.parse_wasm(wasm_bytes)
io.stderr:write(string.format("Module: %d funcs, %d codes\n\n", #mod.funcs, #mod.codes))

-- Time the full load_module
local t0 = now_ns()
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
local t1 = now_ns()

io.stderr:write(string.format("Total load_module:          %8.2f ms\n", diff(t0, t1)))
io.stderr:write(string.format("  Per function:             %8.2f ms\n", diff(t0, t1) / #mod.funcs))

-- Now test just the parsing
local t2 = now_ns()
local mod2 = POT.parse_wasm(wasm_bytes)
local t3 = now_ns()
io.stderr:write(string.format("\nParse WASM:                 %8.2f ms\n", diff(t2, t3)))

-- Test function compile overhead
-- Create equivalent Terra functions
io.stderr:write("\n=== Reference: Raw Terra compilation ===\n")

local t4 = now_ns()
for i = 1, #mod.funcs do
    local terra dummy(x: int32) : int32
        return x + [i]
    end
    dummy:compile()
end
local t5 = now_ns()
io.stderr:write(string.format("%d trivial functions:       %8.2f ms (%.2f ms/fn)\n", 
    #mod.funcs, diff(t4, t5), diff(t4, t5) / #mod.funcs))

-- More realistic: functions with loops
local t6 = now_ns()
for i = 1, #mod.funcs do
    local terra withloop(x: int32) : int32
        var sum = 0
        for j = 0, 100 do
            sum = sum + x
        end
        return sum
    end
    withloop:compile()
end
local t7 = now_ns()
io.stderr:write(string.format("%d functions with loops:    %8.2f ms (%.2f ms/fn)\n", 
    #mod.funcs, diff(t6, t7), diff(t6, t7) / #mod.funcs))

-- Summary
io.stderr:write(string.format("\n=== Analysis ===\n"))
io.stderr:write(string.format("POT overhead vs trivial:    %8.2f ms (%.1fx)\n",
    diff(t0, t1) - diff(t4, t5), diff(t0, t1) / diff(t4, t5)))
io.stderr:write(string.format("POT overhead vs loops:      %8.2f ms (%.1fx)\n",
    diff(t0, t1) - diff(t6, t7), diff(t0, t1) / diff(t6, t7)))

if exports._start then exports._start() end
