-- Test Terra's in-memory JIT options
local Ctime = terralib.includec("time.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end

io.stderr:write("=== Testing Terra JIT Modes ===\n\n")

------------------------------------------------------------------------------
-- Test 1: Individual fn:compile() calls (current POT approach)
------------------------------------------------------------------------------
io.stderr:write("Test 1: Individual fn:compile() per function\n")
local fns = terralib.newlist()
for i = 1, 10 do
    local terra fn(x: int32) : int32
        var sum = x
        for j = 0, 100 do
            sum = sum + j
        end
        return sum
    end
    fns:insert(fn)
end

local t1 = now_ns()
for _, fn in ipairs(fns) do
    fn:compile()
end
local t2 = now_ns()
io.stderr:write(string.format("  10 functions: %.2f ms (%.2f ms/fn)\n", ms(t2-t1), ms(t2-t1)/10))

------------------------------------------------------------------------------
-- Test 2: Define all functions in one terra block
------------------------------------------------------------------------------
io.stderr:write("\nTest 2: All functions in one terra block\n")

local t3 = now_ns()
local terra f1(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f2(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f3(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f4(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f5(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f6(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f7(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f8(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f9(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end
local terra f10(x: int32) : int32 var sum = x for j = 0, 100 do sum = sum + j end return sum end

-- Compile all at once
f1:compile(); f2:compile(); f3:compile(); f4:compile(); f5:compile()
f6:compile(); f7:compile(); f8:compile(); f9:compile(); f10:compile()
local t4 = now_ns()
io.stderr:write(string.format("  10 functions: %.2f ms (%.2f ms/fn)\n", ms(t4-t3), ms(t4-t3)/10))

------------------------------------------------------------------------------
-- Test 3: Using saveobj with "executable" mode (in-memory?)
------------------------------------------------------------------------------
io.stderr:write("\nTest 3: terralib.saveobj to check options\n")

-- Check what saveobj supports
local ok, result = pcall(function()
    return terralib.saveobj("/dev/null", "object", { main = f1 })
end)
io.stderr:write(string.format("  saveobj to /dev/null: %s\n", ok and "OK" or tostring(result)))

------------------------------------------------------------------------------
-- Test 4: Check terra.linklibrary
------------------------------------------------------------------------------
io.stderr:write("\nTest 4: Check for in-memory linking\n")

-- Try to use terralib.linklibrary
local has_linklib = terralib.linklibrary ~= nil
io.stderr:write(string.format("  terralib.linklibrary exists: %s\n", tostring(has_linklib)))

-- Check for other compilation options
io.stderr:write("\nTerra compilation functions:\n")
for k, v in pairs(terralib) do
    if type(v) == "function" and (k:find("compile") or k:find("link") or k:find("jit") or k:find("load")) then
        io.stderr:write(string.format("  terralib.%s\n", k))
    end
end

------------------------------------------------------------------------------
-- Test 5: Direct LLVM JIT (if available)
------------------------------------------------------------------------------
io.stderr:write("\nTest 5: Check for LLVM JIT options\n")

-- See if we can access LLVM directly
local has_llvm = terralib.llvm ~= nil or terralib.LLVM ~= nil
io.stderr:write(string.format("  LLVM access: %s\n", tostring(has_llvm)))

-- Check function compilation options
io.stderr:write("\nFunction compilation methods:\n")
local test_fn = terra(x: int32) return x + 1 end
for k, v in pairs(getmetatable(test_fn) or {}) do
    io.stderr:write(string.format("  fn:%s = %s\n", k, type(v)))
end

io.stderr:write("\n=== Summary ===\n")
io.stderr:write("Individual compile: " .. string.format("%.2f", ms(t2-t1)) .. " ms\n")
io.stderr:write("Batch compile: " .. string.format("%.2f", ms(t4-t3)) .. " ms\n")
