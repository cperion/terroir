-- Measure POT overhead vs raw Terra
local Ctime = terralib.includec("time.h")
local ffi = require("ffi")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end

-- Load a real minimal WASM (fib_rec is simple)
local wasm_file = "bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

io.stderr:write("=== POT Overhead Analysis ===\n")
io.stderr:write(string.format("WASM file: %s (%d bytes)\n\n", wasm_file, #wasm_bytes))

-- 1. Raw Terra equivalent of fib_rec(35)
local terra terra_fib(n: int32) : int32
    if n <= 1 then return n end
    return terra_fib(n - 1) + terra_fib(n - 2)
end

local t0 = now_ns()
terra_fib:compile()
local t1 = now_ns()
io.stderr:write(string.format("1. Raw Terra fib compile:   %6.2f ms\n", ms(t1 - t0)))

-- 2. POT compile the same
local POT = require("pot")
local t2 = now_ns()
local exports = POT.load_module(wasm_bytes, {})
local t3 = now_ns()
io.stderr:write(string.format("2. POT load_module:         %6.2f ms\n", ms(t3 - t2)))

-- 3. Time just the exports compile
local exports2 = POT.load_module(wasm_bytes, {})
local t4 = now_ns()
for name, fn in pairs(exports2) do
    if type(fn) == "function" then
        fn:compile()
    end
end
local t5 = now_ns()

io.stderr:write(string.format("3. POT exports compile:     %6.2f ms\n", ms(t5 - t4)))

-- 4. Run both to verify
local r1 = terra_fib(35)
local r2 = exports.fib_rec(35)
io.stderr:write(string.format("\nResults: Terra=%d, POT=%d\n", r1, r2))
io.stderr:write(string.format("Overhead: %.1fx (%.2f ms extra)\n", 
    ms(t3 - t2) / ms(t1 - t0), ms(t3 - t2) - ms(t1 - t0)))
