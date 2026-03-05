-- Investigate Terra's JIT internals
io.stderr:write("=== Terra JIT Investigation ===\n\n")

-- Check terralib.jit
io.stderr:write("1. terralib.jit:\n")
if terralib.jit then
    for k, v in pairs(terralib.jit) do
        io.stderr:write(string.format("  jit.%s = %s\n", k, type(v)))
    end
end

-- Check terralib.linkllvmstring
io.stderr:write("\n2. terralib.linkllvmstring:\n")
io.stderr:write("  Type: " .. type(terralib.linkllvmstring) .. "\n")

-- Try compiling to LLVM IR string instead of object file
io.stderr:write("\n3. Testing compilation modes:\n")

local terra test_fn(x: int32) : int32
    return x * 2 + 1
end

-- Normal compile
local t1 = os.clock()
test_fn:compile()
local t2 = os.clock()
io.stderr:write(string.format("  Normal compile: %.2f ms\n", (t2-t1)*1000))

-- Get the function pointer
local ptr = test_fn:getpointer()
io.stderr:write(string.format("  Function pointer: %s\n", tostring(ptr)))

-- Test call
local result = test_fn(5)
io.stderr:write(string.format("  test_fn(5) = %d (expected 11)\n", result))

-- Check if we can compile without optimization
io.stderr:write("\n4. Testing setoptimized(false):\n")
local terra test_no_opt(x: int32) : int32
    return x * 3
end
test_no_opt:setoptimized(false)
local t3 = os.clock()
test_no_opt:compile()
local t4 = os.clock()
io.stderr:write(string.format("  No-opt compile: %.2f ms\n", (t4-t3)*1000))
io.stderr:write(string.format("  test_no_opt(5) = %d\n", test_no_opt(5)))

-- Check saveobj with different formats
io.stderr:write("\n5. saveobj formats:\n")
local ok, err = pcall(function()
    terralib.saveobj("/tmp/test_bc.bc", "bitcode", { test = test_fn })
end)
io.stderr:write(string.format("  bitcode: %s\n", ok and "OK" or tostring(err)))

local ok, err = pcall(function()
    terralib.saveobj("/tmp/test_ll.ll", "ll", { test = test_fn })
end)
io.stderr:write(string.format("  ll (IR): %s\n", ok and "OK" or tostring(err)))

local ok, err = pcall(function()
    terralib.saveobj("/tmp/test_o.o", "object", { test = test_fn })
end)
io.stderr:write(string.format("  object: %s\n", ok and "OK" or tostring(err)))

local ok, err = pcall(function()
    terralib.saveobj("/tmp/test_so.so", "sharedlib", { test = test_fn })
end)
io.stderr:write(string.format("  sharedlib: %s\n", ok and "OK" or tostring(err)))

-- Check what happens with forward declarations
io.stderr:write("\n6. Forward declaration pattern (POT uses this):\n")
local fwd = terralib.externfunction("pot_fwd_fn", {int32} -> int32)
io.stderr:write(string.format("  Forward declaration created\n"))
io.stderr:write(string.format("  fwd.isextern: %s\n", tostring(fwd:isextern())))

-- Reset with actual definition
local t5 = os.clock()
local terra real_fn(x: int32) : int32 return x + 100 end
fwd:resetdefinition(real_fn)
local t6 = os.clock()
io.stderr:write(string.format("  resetdefinition: %.2f ms\n", (t6-t5)*1000))
io.stderr:write(string.format("  fwd(5) = %d (expected 105)\n", fwd(5)))
