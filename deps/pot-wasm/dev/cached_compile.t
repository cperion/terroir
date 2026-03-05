-- Profile with POT module cached
local ffi = require("ffi")
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end

-- Stage 1: Compile POT module itself (one-time cost)
io.stderr:write("=== POT Compilation Breakdown ===\n\n")
local t0 = now_ns()
local POT = require("pot")
local t1 = now_ns()
io.stderr:write(string.format("1. POT module compile:      %8.2f ms (one-time)\n", ms(t1 - t0)))

-- Load WASM
local wasm_file = arg[1] or "examples/bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

-- Stage 2: Parse
local t1 = now_ns()
local mod = POT.parse_wasm(wasm_bytes)
local t2 = now_ns()
io.stderr:write(string.format("2. Parse WASM:              %8.2f ms\n", ms(t2 - t1)))

-- Stage 3: compile_module_core (Terra AST generation)
local t2 = now_ns()
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
local t3 = now_ns()
io.stderr:write(string.format("3. compile + JIT:           %8.2f ms\n", ms(t3 - t2)))

io.stderr:write(string.format("\nTotal per-WASM:             %8.2f ms\n", ms(t3 - t1)))
io.stderr:write(string.format("  (excluding POT module:    %8.2f ms)\n", ms(t3 - t1)))
io.stderr:write(string.format("\nModule stats:\n"))
io.stderr:write(string.format("  Functions: %d\n", #mod.funcs))
io.stderr:write(string.format("  Codes:     %d\n", #mod.codes))
io.stderr:write(string.format("  ms/func:   %.2f\n", ms(t3 - t2) / #mod.funcs))

-- Run
if exports._start then exports._start() end
