-- Stage-by-stage timing
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

-- Copy key functions from pot.t to instrument them
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

local function decode_sleb128(bytes, pos)
    local result, shift = 0, 0
    local b
    repeat
        b = bytes:byte(pos)
        result = result + bit.band(b, 0x7F) * (2 ^ shift)
        pos = pos + 1
        shift = shift + 7
    until bit.band(b, 0x80) == 0
    if shift < 32 and bit.band(b, 0x40) ~= 0 then
        result = result - (2 ^ shift)
    end
    result = result % 4294967296
    if result >= 2147483648 then result = result - 4294967296 end
    return result, pos
end

local wasm_types = {
    [0x7F] = int32, [0x7E] = int64, [0x7D] = float, [0x7C] = double,
}

local section_parsers = {}
section_parsers[1] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        assert(bytes:byte(p) == 0x60); p = p + 1
        local param_count; param_count, p = decode_uleb128(bytes, p)
        for j = 1, param_count do p = p + 1 end
        local result_count; result_count, p = decode_uleb128(bytes, p)
        for j = 1, result_count do p = p + 1 end
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
    local p = 9
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

-- Main timing code
local wasm_file = arg[1] or "examples/bench.wasm"
local f = io.open(wasm_file, "rb")
local wasm_bytes = f:read("*a")
f:close()

print("Stage timing for: " .. wasm_file)
print("Size: " .. #wasm_bytes .. " bytes")
print("")

local t_start = now_ns()
local t_prev = t_start
local stages = {}

-- Stage 1: Quick parse
local mod_info = quick_parse(wasm_bytes)
stages["parse"] = now_ns() - t_prev
t_prev = now_ns()

-- Stage 2: Full POT compile (includes LLVM)
local POT = require("pot")
local exports = POT.load_module(wasm_bytes, { _wasi_args = {} })
stages["compile_total"] = now_ns() - t_prev
t_prev = now_ns()

-- Stage 3: Run
if exports._start then exports._start() end
stages["run"] = now_ns() - t_prev

print("")
print("Results:")
print(string.format("  Parse:      %8.2f ms", ms(stages["parse"])))
print(string.format("  Compile:    %8.2f ms", ms(stages["compile_total"])))
print(string.format("  Run:        %8.2f ms", ms(stages["run"])))
print(string.format("  Total:      %8.2f ms", ms(now_ns() - t_start)))
print("")
print("Module info:")
print(string.format("  Functions:  %d", mod_info.num_funcs))
print(string.format("  Compile/fn: %.2f ms", ms(stages["compile_total"]) / mod_info.num_funcs))
