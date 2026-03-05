-- Detailed compilation timing
local ffi = require("ffi")
local bit = require("bit")
local C = terralib.includec("stdlib.h")
local Cstr = terralib.includec("string.h")
local Cstdio = terralib.includec("stdio.h")
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end

-- Inline key functions from pot.t for timing
local function decode_uleb128(bytes, pos)
    local result, shift = 0, 0
    while true do
        local b = bytes:byte(pos)
        result = result + bit.band(b, 0x7F) * (2 ^ shift)
        pos = pos + 1
        if bit.band(b, 0x80) == 0 then return result, pos end
        shift = shift + 7
    end
end

local wasm_types = {
    [0x7F] = int32, [0x7E] = int64, [0x7D] = float, [0x7C] = double,
}

local section_parsers = {}
section_parsers[1] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        p = p + 1  -- skip 0x60
        local param_count; param_count, p = decode_uleb128(bytes, p)
        p = p + param_count
        local result_count; result_count, p = decode_uleb128(bytes, p)
        p = p + result_count
        mod.types[i] = true
    end
end
section_parsers[3] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    mod.num_funcs = count
end
section_parsers[10] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    mod.num_codes = count
end

local function quick_parse(bytes)
    local mod = { types = {}, num_funcs = 0, num_codes = 0 }
    local p = 9  -- skip magic + version
    while p <= #bytes do
        local section_id = bytes:byte(p); p = p + 1
        local section_len; section_len, p = decode_uleb128(bytes, p)
        local section_end = p + section_len
        local parser = section_parsers[section_id]
        if parser then parser(mod, bytes, p, section_end) end
        p = section_end
    end
    return mod
end

-- Load WASM
local wasm_file = arg[1] or "examples/bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

print("Detailed compilation timing for: " .. wasm_file)
print(string.rep("=", 60))

local times = {}
local t_start = now_ns()
local t_prev = t_start

-- Stage 1: Quick parse to get stats
local mod_info = quick_parse(wasm_bytes)
times["1. Quick parse"] = now_ns() - t_prev
t_prev = now_ns()

-- Stage 2: Full POT load_module
local POT = require("pot")
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
times["2. Full load_module"] = now_ns() - t_prev
t_prev = now_ns()

-- Stage 3: Run _start
if exports._start then
    exports._start()
end
times["3. Run _start"] = now_ns() - t_prev

print("")
print("Results:")
print(string.rep("=", 60))
for name, ns in pairs(times) do
    print(string.format("%-25s %8.2f ms", name, ms(ns)))
end
print(string.rep("=", 60))
print(string.format("%-25s %8.2f ms", "TOTAL", ms(now_ns() - t_start)))
print(string.rep("=", 60))

print("")
print("WASM module info:")
print(string.format("  Functions: %d", mod_info.num_funcs))
print(string.format("  Codes: %d", mod_info.num_codes))
print(string.format("  WASM size: %d bytes", #wasm_bytes))
print(string.format("  Compile rate: %.0f bytes/ms", #wasm_bytes / ms(times["2. Full load_module"])))
