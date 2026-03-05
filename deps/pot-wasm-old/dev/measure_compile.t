-- Detailed compilation measurement
local POT = require("pot")
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end

local files = {
    "bench.wasm",
    "examples/bench.wasm", 
    "stress_test2.wasm",
    "test_i64_ops.wasm",
}

io.stderr:write(string.format("%-30s %8s %8s %8s %8s\n", "File", "Size", "Fns", "Time", "ms/fn"))
io.stderr:write(string.rep("-", 70) .. "\n")

for _, wasm_file in ipairs(files) do
    local f = io.open(wasm_file, "rb")
    if f then
        local wasm_bytes = f:read("*a")
        f:close()
        
        -- Get function count via POT.parse_wasm
        local mod = POT.parse_wasm(wasm_bytes)
        local num_funcs = #mod.funcs
        local num_codes = #mod.codes
        
        local t0 = now_ns()
        local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
        local t1 = now_ns()
        
        local compile_ms = ms(t1 - t0)
        local ms_per_fn = compile_ms / num_funcs
        
        io.stderr:write(string.format("%-30s %8d %8d %8.1f %8.1f\n", 
            wasm_file, #wasm_bytes, num_funcs, compile_ms, ms_per_fn))
    end
end
