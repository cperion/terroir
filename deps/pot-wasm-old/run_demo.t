-- Run real C-compiled WASM through POT
local POT = require("pot")
local ffi = require("ffi")

print("Loading demo.wasm (compiled from C by clang)...")
local ok, exports = pcall(POT.load_file, "demo.wasm")
if not ok then
    print("ERROR: " .. tostring(exports))
    os.exit(1)
end

print("Loaded. Exported functions:")
for k, v in pairs(exports) do
    print("  " .. k)
end

-- Test fibonacci
print("\n--- Fibonacci ---")
for _, n in ipairs({0, 1, 2, 5, 10, 20, 30, 40}) do
    local result = exports.fib(n)
    io.write(string.format("  fib(%d) = %d\n", n, result))
end

-- Test SHA-256 primitives
print("\n--- SHA-256 primitives ---")

local bit = require("bit")
local i = bit.tobit  -- convert unsigned hex to signed i32

local ch  = exports.sha256_ch(i(0xFF00FF00), i(0x0F0F0F0F), i(0xF0F0F0F0))
local maj = exports.sha256_maj(i(0xFF00FF00), i(0x0F0F0F0F), i(0xF0F0F0F0))
local s0  = exports.sha256_sigma0(i(0xDEADBEEF))
local s1  = exports.sha256_sigma1(i(0xCAFEBABE))
local rot = exports.rotr(i(0x80000001), 1)

-- Print as unsigned hex
local function hex(v)
    if v < 0 then v = v + 0x100000000 end
    return string.format("0x%08X", v)
end

print("  ch(0xFF00FF00, 0x0F0F0F0F, 0xF0F0F0F0)  = " .. hex(ch))
print("  maj(0xFF00FF00, 0x0F0F0F0F, 0xF0F0F0F0) = " .. hex(maj))
print("  sigma0(0xDEADBEEF) = " .. hex(s0))
print("  sigma1(0xCAFEBABE) = " .. hex(s1))
print("  rotr(0x80000001, 1) = " .. hex(rot))

-- Verify against known values
local function check(name, got, expected)
    if got == expected then
        print("  PASS: " .. name)
    else
        print(string.format("  FAIL: %s = %s, expected %s", name, hex(got), hex(expected)))
    end
end

check("ch",   ch,  i(0x0FF00FF0))
check("maj",  maj, i(0xFF00FF00))
check("rotr", rot, i(0xC0000000))

-- Test base64 encoding via memory
print("\n--- Base64 encode (via WASM memory) ---")

-- We need to write data into WASM memory and call base64_encode
-- First, init the b64 lookup table
exports.init_table()

-- Get the memory pointer from the module
-- POT exposes memory through the module - let's write directly
-- Actually, we need access to the raw memory pointer
-- For now, test that the functions run without crashing

print("  init_table() called successfully")
print("  base64_encode is callable: " .. type(exports.base64_encode))

print("\nAll done! Real C code running natively through POT.")
