-- Timing without WASI
local POT = require("pot")
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end

-- Use bench.wasm from root which has no WASI
local wasm_file = arg[1] or "bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

io.stderr:write(string.format("=== TIMING: %s (%d bytes) ===\n", wasm_file, #wasm_bytes))

local t0 = now_ns()
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
local t1 = now_ns()

io.stderr:write(string.format("Compile: %.2f ms\n", ms(t1 - t0)))

-- Call each export and time it
for name, fn in pairs(exports) do
    if type(fn) == "function" then
        local t2 = now_ns()
        local ok, result = pcall(fn)
        local t3 = now_ns()
        if ok then
            io.stderr:write(string.format("  %s: %.2f ms (result: %s)\n", name, ms(t3 - t2), tostring(result)))
        end
    end
end
