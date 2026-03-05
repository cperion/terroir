-- Test Terra JIT compilation model
local Ctime = terralib.includec("time.h")
local Cstdio = terralib.includec("stdio.h")

local terra now_ns() : int64
    var ts : Ctime.timespec
    Ctime.clock_gettime(1, &ts)
    return [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
end

local function ms(ns) return tonumber(ns) / 1e6 end

-- Define a simple function
local terra simple_add(a: int32, b: int32) : int32
    return a + b
end

io.stderr:write("Testing Terra JIT model...\n")

-- Time the first compile
local t0 = now_ns()
simple_add:compile()
local t1 = now_ns()
io.stderr:write(string.format("First compile: %.3f ms\n", ms(t1 - t0)))

-- Time a second compile (should be cached)
local t2 = now_ns()
simple_add:compile()
local t3 = now_ns()
io.stderr:write(string.format("Second compile (cached): %.3f ms\n", ms(t3 - t2)))

-- Define 10 functions
local fns = terralib.newlist()
io.stderr:write("\nCompiling 10 functions...\n")
local t4 = now_ns()
for i = 1, 10 do
    local terra fn(a: int32) : int32
        var x = a
        for j = 0, 1000 do
            x = x + j
        end
        return x
    end
    fn:compile()
    fns:insert(fn)
end
local t5 = now_ns()
io.stderr:write(string.format("10 functions: %.2f ms (%.2f ms/fn)\n", ms(t5 - t4), ms(t5 - t4) / 10))

-- Now test saveobj model
io.stderr:write("\nTesting saveobj model...\n")
local t6 = now_ns()
terralib.saveobj("/tmp/test_jit.o", "object", { main = simple_add })
local t7 = now_ns()
io.stderr:write(string.format("saveobj to .o: %.2f ms\n", ms(t7 - t6)))

-- Compare
io.stderr:write(string.format("\nRatio: %.1fx slower for saveobj\n", ms(t7 - t6) / ms(t1 - t0)))
