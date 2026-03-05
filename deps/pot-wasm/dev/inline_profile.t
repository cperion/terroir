-- Inline profiling by copying key parts of pot.t
local ffi = require("ffi")
local bit = require("bit")
local C = terralib.includec("stdlib.h")
local Cstr = terralib.includec("string.h")
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end
local function report(name, dt)
    io.stderr:write(string.format("  %-25s %8.2f ms\n", name, ms(dt)))
end

-- Load WASM file
local wasm_file = arg[1] or "examples/bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

io.stderr:write(string.format("\n=== Compilation Profile: %s (%d bytes) ===\n\n", 
    wasm_file, #wasm_bytes))

-- Stage 1: Load POT module (JIT compile the compiler)
local t0 = now_ns()
local POT = require("pot")
local t1 = now_ns()
report("1. Load POT module", t1 - t0)

-- Stage 2: Parse WASM
local t1 = now_ns()
local mod = POT.parse_wasm(wasm_bytes)
local t2 = now_ns()
report("2. Parse WASM", t2 - t1)
io.stderr:write(string.format("     -> %d types, %d funcs, %d codes\n", 
    #mod.types, #mod.funcs, #mod.codes))

-- Stage 3: Load module (compile everything)
local t2 = now_ns()
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
local t3 = now_ns()
report("3. Full compile", t3 - t2)

-- Break down compile_module_core
-- We can't easily instrument internal functions, but we can estimate:
local t4 = now_ns()
if exports._start then exports._start() end
local t5 = now_ns()
report("4. Run _start", t5 - t4)

io.stderr:write(string.format("\n=== Summary ===\n"))
io.stderr:write(string.format("Total: %.2f ms\n", ms(t3 - t0)))
io.stderr:write(string.format("Compile overhead: %.2f ms (%.1f ms per function)\n", 
    ms(t3 - t2) - ms(t2 - t1), (ms(t3 - t2) - ms(t2 - t1)) / #mod.funcs))
