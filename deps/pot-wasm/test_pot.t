-- POT test harness
local POT = require("pot")

local passed, failed, total = 0, 0, 0

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " -- " .. tostring(err))
    end
end

local function assert_eq(got, expected, msg)
    if got ~= expected then
        error(string.format("%s: got %s, expected %s",
              msg or "assertion", tostring(got), tostring(expected)))
    end
end

-- Helper: compile .wat text to .wasm bytes via wat2wasm
local function wat2wasm(wat_text)
    local wat_path = os.tmpname() .. ".wat"
    local wasm_path = os.tmpname() .. ".wasm"
    local f = io.open(wat_path, "w")
    f:write(wat_text)
    f:close()
    local ret = os.execute("wat2wasm " .. wat_path .. " -o " .. wasm_path .. " 2>/dev/null")
    assert(ret == 0 or ret == true, "wat2wasm failed")
    local f2 = io.open(wasm_path, "rb")
    local bytes = f2:read("*a")
    f2:close()
    os.remove(wat_path)
    os.remove(wasm_path)
    return bytes
end

-- Helper: load .wat and return exports
local function load_wat(wat_text, host_fns)
    return POT.load_module(wat2wasm(wat_text), host_fns)
end

------------------------------------------------------------------------
print("=== M0: LEB128 / Parser basics ===")
------------------------------------------------------------------------

test("parse minimal module", function()
    local bytes = wat2wasm("(module)")
    local mod = POT.parse_wasm(bytes)
    assert(mod, "parse returned nil")
    assert_eq(#mod.types, 0, "types count")
    assert_eq(#mod.funcs, 0, "funcs count")
end)

test("parse module with one function", function()
    local bytes = wat2wasm([[
        (module
          (func (export "add") (param i32 i32) (result i32)
            local.get 0
            local.get 1
            i32.add))
    ]])
    local mod = POT.parse_wasm(bytes)
    assert_eq(#mod.types, 1, "types count")
    assert_eq(#mod.funcs, 1, "funcs count")
    assert_eq(#mod.codes, 1, "codes count")
    assert(mod.exports["add"], "export 'add' missing")
end)

------------------------------------------------------------------------
print("\n=== M2: First function (add) ===")
------------------------------------------------------------------------

test("i32.add(3, 4) = 7", function()
    local exports = load_wat([[
        (module
          (func (export "add") (param i32 i32) (result i32)
            local.get 0
            local.get 1
            i32.add))
    ]])
    assert_eq(exports.add(3, 4), 7, "add(3,4)")
end)

test("i32 sub/mul", function()
    local exports = load_wat([[
        (module
          (func (export "sub") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.sub)
          (func (export "mul") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.mul))
    ]])
    assert_eq(exports.sub(10, 3), 7, "sub(10,3)")
    assert_eq(exports.mul(6, 7), 42, "mul(6,7)")
end)

------------------------------------------------------------------------
print("\n=== M3: i32 arithmetic ===")
------------------------------------------------------------------------

test("i32 bitwise ops", function()
    local exports = load_wat([[
        (module
          (func (export "and") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.and)
          (func (export "or") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.or)
          (func (export "xor") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.xor))
    ]])
    assert_eq(exports["and"](0xFF, 0x0F), 0x0F, "and")
    assert_eq(exports["or"](0xF0, 0x0F), 0xFF, "or")
    assert_eq(exports["xor"](0xFF, 0x0F), 0xF0, "xor")
end)

test("i32 shifts", function()
    local exports = load_wat([[
        (module
          (func (export "shl") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.shl)
          (func (export "shr_u") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.shr_u)
          (func (export "shr_s") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.shr_s))
    ]])
    assert_eq(exports.shl(1, 10), 1024, "shl")
    assert_eq(exports.shr_u(1024, 10), 1, "shr_u")
end)

test("i32 clz/ctz/popcnt", function()
    local exports = load_wat([[
        (module
          (func (export "clz") (param i32) (result i32)
            local.get 0 i32.clz)
          (func (export "ctz") (param i32) (result i32)
            local.get 0 i32.ctz)
          (func (export "popcnt") (param i32) (result i32)
            local.get 0 i32.popcnt))
    ]])
    assert_eq(exports.clz(0), 32, "clz(0)")
    assert_eq(exports.clz(1), 31, "clz(1)")
    assert_eq(exports.ctz(0), 32, "ctz(0)")
    assert_eq(exports.ctz(2), 1, "ctz(2)")
    assert_eq(exports.popcnt(7), 3, "popcnt(7)")
end)

test("i32 comparisons", function()
    local exports = load_wat([[
        (module
          (func (export "eq") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.eq)
          (func (export "ne") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.ne)
          (func (export "lt_s") (param i32 i32) (result i32)
            local.get 0 local.get 1 i32.lt_s)
          (func (export "eqz") (param i32) (result i32)
            local.get 0 i32.eqz))
    ]])
    assert_eq(exports.eq(5, 5), 1, "eq")
    assert_eq(exports.eq(5, 6), 0, "eq")
    assert_eq(exports.ne(5, 6), 1, "ne")
    assert_eq(exports.lt_s(3, 5), 1, "lt_s")
    assert_eq(exports.eqz(0), 1, "eqz")
    assert_eq(exports.eqz(1), 0, "eqz")
end)

test("local.set and local.tee", function()
    local exports = load_wat([[
        (module
          (func (export "test") (param i32) (result i32)
            (local i32)
            local.get 0
            local.tee 1
            local.get 1
            i32.add))
    ]])
    assert_eq(exports.test(21), 42, "tee+add")
end)

test("drop and nop", function()
    local exports = load_wat([[
        (module
          (func (export "test") (param i32) (result i32)
            i32.const 99
            drop
            nop
            local.get 0))
    ]])
    assert_eq(exports.test(42), 42, "drop+nop")
end)

------------------------------------------------------------------------
print("\n=== M4: Control flow ===")
------------------------------------------------------------------------

test("simple block", function()
    local exports = load_wat([[
        (module
          (func (export "test") (result i32)
            (block (result i32)
              i32.const 42
              br 0)))
    ]])
    assert_eq(exports.test(), 42, "block+br")
end)

test("if/else", function()
    local exports = load_wat([[
        (module
          (func (export "test") (param i32) (result i32)
            (if (result i32) (local.get 0)
              (then (i32.const 1))
              (else (i32.const 0)))))
    ]])
    assert_eq(exports.test(1), 1, "if true")
    assert_eq(exports.test(0), 0, "if false")
end)

test("loop with br_if", function()
    local exports = load_wat([[
        (module
          (func (export "sum") (param $n i32) (result i32)
            (local $i i32)
            (local $acc i32)
            (local.set $i (local.get $n))
            (block $done
              (loop $loop
                (br_if $done (i32.eqz (local.get $i)))
                (local.set $acc (i32.add (local.get $acc) (local.get $i)))
                (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                (br $loop)))
            (local.get $acc)))
    ]])
    assert_eq(exports.sum(10), 55, "sum(10)")
    assert_eq(exports.sum(0), 0, "sum(0)")
end)

test("if without else (void)", function()
    local exports = load_wat([[
        (module
          (func (export "test") (param i32) (result i32)
            (local $x i32)
            (local.set $x (i32.const 10))
            (if (local.get 0)
              (then (local.set $x (i32.const 20))))
            (local.get $x)))
    ]])
    assert_eq(exports.test(1), 20, "if-no-else true")
    assert_eq(exports.test(0), 10, "if-no-else false")
end)

------------------------------------------------------------------------
print("\n=== M5: Function calls ===")
------------------------------------------------------------------------

test("simple call", function()
    local exports = load_wat([[
        (module
          (func $helper (param i32) (result i32)
            local.get 0 i32.const 1 i32.add)
          (func (export "test") (param i32) (result i32)
            local.get 0 call 0))
    ]])
    assert_eq(exports.test(41), 42, "call")
end)

test("forward.wast: even/odd mutual recursion", function()
    local exports = load_wat([[
        (module
          (func $even (export "even") (param $n i32) (result i32)
            (if (result i32) (i32.eq (local.get $n) (i32.const 0))
              (then (i32.const 1))
              (else (call $odd (i32.sub (local.get $n) (i32.const 1))))))
          (func $odd (export "odd") (param $n i32) (result i32)
            (if (result i32) (i32.eq (local.get $n) (i32.const 0))
              (then (i32.const 0))
              (else (call $even (i32.sub (local.get $n) (i32.const 1)))))))
    ]])
    assert_eq(exports.even(13), 0, "even(13)")
    assert_eq(exports.even(20), 1, "even(20)")
    assert_eq(exports.odd(13), 1, "odd(13)")
    assert_eq(exports.odd(20), 0, "odd(20)")
end)

test("return from middle of function", function()
    local exports = load_wat([[
        (module
          (func (export "test") (param i32) (result i32)
            (if (i32.gt_s (local.get 0) (i32.const 10))
              (then (return (i32.const 99))))
            (local.get 0)))
    ]])
    assert_eq(exports.test(5), 5, "no early return")
    assert_eq(exports.test(20), 99, "early return")
end)

------------------------------------------------------------------------
print("\n=== M6: i64 + select ===")
------------------------------------------------------------------------

test("i64 basic ops", function()
    local exports = load_wat([[
        (module
          (func (export "add") (param i64 i64) (result i64)
            local.get 0 local.get 1 i64.add)
          (func (export "mul") (param i64 i64) (result i64)
            local.get 0 local.get 1 i64.mul))
    ]])
    assert_eq(exports.add(100LL, 200LL), 300LL, "i64.add")
    assert_eq(exports.mul(6LL, 7LL), 42LL, "i64.mul")
end)

test("select", function()
    local exports = load_wat([[
        (module
          (func (export "test") (param i32 i32 i32) (result i32)
            local.get 0 local.get 1 local.get 2 select))
    ]])
    assert_eq(exports.test(10, 20, 1), 10, "select true")
    assert_eq(exports.test(10, 20, 0), 20, "select false")
end)

------------------------------------------------------------------------
print("\n=== M7: Memory ===")
------------------------------------------------------------------------

test("memory load/store", function()
    local exports = load_wat([[
        (module
          (memory 1)
          (func (export "store") (param i32 i32)
            local.get 0 local.get 1 i32.store)
          (func (export "load") (param i32) (result i32)
            local.get 0 i32.load))
    ]])
    exports.store(0, 42)
    assert_eq(exports.load(0), 42, "load after store")
    exports.store(100, 99)
    assert_eq(exports.load(100), 99, "load at offset 100")
end)

test("memory with data segment", function()
    local exports = load_wat([[
        (module
          (memory 1)
          (data (i32.const 0) "Hello")
          (func (export "load_byte") (param i32) (result i32)
            local.get 0 i32.load8_u))
    ]])
    assert_eq(exports.load_byte(0), 72, "H")  -- 'H' = 72
    assert_eq(exports.load_byte(1), 101, "e") -- 'e' = 101
end)

------------------------------------------------------------------------
print("\n=== M8: Globals ===")
------------------------------------------------------------------------

test("global get/set", function()
    local exports = load_wat([[
        (module
          (global $g (mut i32) (i32.const 0))
          (func (export "get") (result i32)
            global.get $g)
          (func (export "set") (param i32)
            local.get 0 global.set $g))
    ]])
    assert_eq(exports.get(), 0, "initial")
    exports.set(42)
    assert_eq(exports.get(), 42, "after set")
end)

------------------------------------------------------------------------
print("\n=== M9: Float ops ===")
------------------------------------------------------------------------

test("f64 arithmetic", function()
    local exports = load_wat([[
        (module
          (func (export "add") (param f64 f64) (result f64)
            local.get 0 local.get 1 f64.add)
          (func (export "sqrt") (param f64) (result f64)
            local.get 0 f64.sqrt))
    ]])
    local sum = exports.add(1.5, 2.5)
    assert(math.abs(sum - 4.0) < 1e-10, "f64.add: " .. tostring(sum))
    local sq = exports.sqrt(4.0)
    assert(math.abs(sq - 2.0) < 1e-10, "f64.sqrt: " .. tostring(sq))
end)

test("conversions i32<->f64", function()
    local exports = load_wat([[
        (module
          (func (export "to_f64") (param i32) (result f64)
            local.get 0 f64.convert_i32_s)
          (func (export "to_i32") (param f64) (result i32)
            local.get 0 i32.trunc_f64_s))
    ]])
    local f = exports.to_f64(42)
    assert(math.abs(f - 42.0) < 1e-10, "convert: " .. tostring(f))
    assert_eq(exports.to_i32(3.7), 3, "trunc")
end)

------------------------------------------------------------------------
print("\n=== M10: br_table ===")
------------------------------------------------------------------------

test("br_table dispatch", function()
    local exports = load_wat([[
        (module
          (func (export "dispatch") (param i32) (result i32)
            (block $b2 (result i32)
              (block $b1 (result i32)
                (block $b0 (result i32)
                  (i32.const 100)
                  (local.get 0)
                  (br_table $b0 $b1 $b2))
                (drop)
                (i32.const 10)
                (br $b2))
              (drop)
              (i32.const 20)
              (br $b2))))
    ]])
    assert_eq(exports.dispatch(0), 10, "case 0")
    assert_eq(exports.dispatch(1), 20, "case 1")
    assert_eq(exports.dispatch(2), 100, "default")
    assert_eq(exports.dispatch(99), 100, "out of range -> default")
end)

------------------------------------------------------------------------
print(string.format("\n=== Results: %d/%d passed ===", passed, total))
if failed > 0 then
    print(string.format("    %d FAILED", failed))
    os.exit(1)
end
