-- Benchmark: C→WASM→POT→native  vs  hand-written Terra→native  vs  C→native
local POT = require("pot")
local ffi = require("ffi")
local C = terralib.includec("stdio.h")
local Ctime = terralib.includec("time.h")

-- High-resolution timer
local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)  -- CLOCK_MONOTONIC
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function bench(name, f, ...)
    -- Warmup
    for i = 1, 3 do f(...) end
    -- Timed
    local N = 10
    local t0 = now_ns()
    local result
    for i = 1, N do
        result = f(...)
    end
    local t1 = now_ns()
    local avg_us = tonumber(t1 - t0) / N / 1000.0
    return avg_us, result
end

local function hex(v)
    if v < 0 then v = v + 0x100000000 end
    return string.format("0x%08X", v)
end

-- Load WASM module
io.write("Compiling WASM → native... ")
io.flush()
local t_load_0 = now_ns()
local wasm = POT.load_file("bench.wasm")
local t_load_1 = now_ns()
local compile_ms = tonumber(t_load_1 - t_load_0) / 1e6
print(string.format("done (%.1f ms)", compile_ms))

--------------------------------------------------------------------------------
-- Native Terra equivalents (same algorithms, hand-written)
--------------------------------------------------------------------------------

local terra fib_rec_terra(n: int32) : int32
    if n <= 1 then return n end
    return fib_rec_terra(n - 1) + fib_rec_terra(n - 2)
end

local terra fib_iter_terra(n: int32) : int32
    if n <= 1 then return n end
    var a : int32 = 0
    var b : int32 = 1
    for i = 2, n + 1 do
        var t = a + b
        a = b
        b = t
    end
    return b
end

local terra sha256_rounds_terra(n: int32) : int32
    var a : uint32 = 0x6a09e667U
    var b : uint32 = 0xbb67ae85U
    var c : uint32 = 0x3c6ef372U
    var d : uint32 = 0xa54ff53aU
    var e : uint32 = 0x510e527fU
    var f : uint32 = 0x9b05688cU
    var g : uint32 = 0x1f83d9abU
    var h : uint32 = 0x5be0cd19U
    var w : uint32 = 0x12345678U

    for i = 0, n do
        var S1 = ((e >> 6) or (e << 26)) ^ ((e >> 11) or (e << 21)) ^ ((e >> 25) or (e << 7))
        var ch = (e and f) ^ ((not e) and g)
        var temp1 = h + S1 + ch + 0x428a2f98U + w
        var S0 = ((a >> 2) or (a << 30)) ^ ((a >> 13) or (a << 19)) ^ ((a >> 22) or (a << 10))
        var maj = (a and b) ^ (a and c) ^ (b and c)
        var temp2 = S0 + maj

        h = g; g = f; f = e; e = d + temp1
        d = c; c = b; b = a; a = temp1 + temp2
        w = w ^ a
    end
    return [int32](a)
end

-- Pre-compile all Terra functions
fib_rec_terra:compile()
fib_iter_terra:compile()
sha256_rounds_terra:compile()

print("")
print("All times in microseconds (us). Lower is better.")
print("Ratio = WASM / Terra (1.00 = identical speed)")
print(string.rep("─", 72))

--------------------------------------------------------------------------------
-- 1. Recursive Fibonacci fib(35) - ~9.2M function calls
--------------------------------------------------------------------------------
print("\n  fib_rec(35)  —  tree-recursive, 2^35 calls")
local us_w1, r_w1 = bench("wasm",  wasm.fib_rec,      35)
local us_t1, r_t1 = bench("terra", fib_rec_terra,      35)
print(string.format("    POT (C→WASM→native):  %8.0f us   result=%d", us_w1, r_w1))
print(string.format("    Terra (hand-written):  %8.0f us   result=%d", us_t1, r_t1))
print(string.format("    Ratio: %.2fx", us_w1 / us_t1))

--------------------------------------------------------------------------------
-- 2. SHA-256 compression rounds - bitwise-heavy loop
--------------------------------------------------------------------------------
print("\n  sha256_rounds(1M)  —  rotate/xor/and in tight loop")
local us_w2, r_w2 = bench("wasm",  wasm.sha256_rounds,       1000000)
local us_t2, r_t2 = bench("terra", sha256_rounds_terra,       1000000)
print(string.format("    POT (C→WASM→native):  %8.0f us   result=%s", us_w2, hex(r_w2)))
print(string.format("    Terra (hand-written):  %8.0f us   result=%s", us_t2, hex(r_t2)))
print(string.format("    Ratio: %.2fx", us_w2 / us_t2))

--------------------------------------------------------------------------------
-- 3. Iterative Fibonacci fib(1B) - tight add loop, 1 billion iterations
--------------------------------------------------------------------------------
print("\n  fib_iter(1B)  —  tight add loop, 10^9 iterations")
local us_w3, r_w3 = bench("wasm",  wasm.fib_iter,       1000000000)
local us_t3, r_t3 = bench("terra", fib_iter_terra,       1000000000)
print(string.format("    POT (C→WASM→native):  %8.0f us   result=%d", us_w3, r_w3))
print(string.format("    Terra (hand-written):  %8.0f us   result=%d", us_t3, r_t3))
print(string.format("    Ratio: %.2fx", us_w3 / us_t3))

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print("\n" .. string.rep("─", 72))
print(string.format("  %-24s %10s %10s %8s", "Benchmark", "WASM (us)", "Terra (us)", "Ratio"))
print(string.rep("─", 72))
print(string.format("  %-24s %10.0f %10.0f %7.2fx", "fib_rec(35)",       us_w1, us_t1, us_w1/us_t1))
print(string.format("  %-24s %10.0f %10.0f %7.2fx", "sha256_rounds(1M)", us_w2, us_t2, us_w2/us_t2))
print(string.format("  %-24s %10.0f %10.0f %7.2fx", "fib_iter(1B)",      us_w3, us_t3, us_w3/us_t3))
print(string.rep("─", 72))
print("  1.00x = same speed as hand-written Terra (both go through LLVM)")
print(string.format("  WASM compile time: %.1f ms", compile_ms))
