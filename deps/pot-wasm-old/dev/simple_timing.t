-- Simple compilation timing
local POT = require("pot")
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end
local wasm_file = arg[1] or "examples/bench.wasm"

local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

io.stderr:write("Timing: " .. wasm_file .. " (" .. #wasm_bytes .. " bytes)\n")

local t0 = now_ns()
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
local t1 = now_ns()

io.stderr:write(string.format("Compile time: %.2f ms\n", ms(t1 - t0)))

if exports._start then exports._start() end
