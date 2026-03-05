-- Measure compilation stages
local POT = require("pot")
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end
local function count_table(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Load WASM
local wasm_file = arg[1] or "examples/bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

print("Timing compilation stages for: " .. wasm_file)
print(string.rep("=", 60))

local t0, t1, t2, t3, t4

-- Stage 1: Parse WASM binary
t0 = now_ns()
local mod = POT.parse_wasm(wasm_bytes)
t1 = now_ns()
print(string.format("1. WASM parsing:         %8.2f ms", ms(t1 - t0)))
print(string.format("   - Types: %d, Functions: %d, Codes: %d", 
    #mod.types, #mod.funcs, #mod.codes))

-- Stage 2: Compile module (Lua + Terra AST generation)
-- This uses load_module which does everything
t1 = now_ns()

-- Use load_module but we'll instrument it
-- Actually let's just time the full load_module
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })

t2 = now_ns()
print(string.format("2. Full load_module:     %8.2f ms", ms(t2 - t1)))
print(string.format("   - Exports: %d", count_table(exports)))

print(string.rep("=", 60))
print(string.format("TOTAL (parse + load):    %8.2f ms", ms(t2 - t0)))
print(string.rep("=", 60))

-- Run the module
print("\nRunning module...")
if exports._start then
    exports._start()
end
