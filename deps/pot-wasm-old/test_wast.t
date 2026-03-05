-- .wast spec test runner for POT
local POT = require("pot")
local ffi = require("ffi")
local bit = require("bit")

------------------------------------------------------------------------
-- S-expression tokenizer/parser
------------------------------------------------------------------------

-- Tokenize: returns list of tokens (strings, parens, atoms)
local function tokenize(text)
    local tokens = {}
    local i = 1
    local len = #text
    while i <= len do
        local c = text:sub(i, i)
        if c == ";" then
            -- Comment: skip to end of line
            if text:sub(i, i + 1) == ";;" then
                local nl = text:find("\n", i)
                i = nl and nl + 1 or len + 1
            else
                i = i + 1
            end
        elseif c == "(" then
            -- Check for block comment (; ... ;)
            if text:sub(i, i + 1) == "(;" then
                local close = text:find(";%)", i + 2)
                i = close and close + 2 or len + 1
            else
                tokens[#tokens + 1] = "("
                i = i + 1
            end
        elseif c == ")" then
            tokens[#tokens + 1] = ")"
            i = i + 1
        elseif c == "\"" then
            -- String literal
            local j = i + 1
            while j <= len do
                local sc = text:sub(j, j)
                if sc == "\\" then
                    j = j + 2
                elseif sc == "\"" then
                    break
                else
                    j = j + 1
                end
            end
            tokens[#tokens + 1] = text:sub(i, j)
            i = j + 1
        elseif c:match("%s") then
            i = i + 1
        else
            -- Atom
            local j = i
            while j <= len and not text:sub(j, j):match("[%s%(%)\"%;]") do
                j = j + 1
            end
            tokens[#tokens + 1] = text:sub(i, j - 1)
            i = j
        end
    end
    return tokens
end

-- Parse tokens into nested lists
local function parse_sexpr(tokens, pos)
    pos = pos or 1
    if tokens[pos] == "(" then
        local list = {}
        pos = pos + 1
        while pos <= #tokens and tokens[pos] ~= ")" do
            local val
            val, pos = parse_sexpr(tokens, pos)
            list[#list + 1] = val
        end
        pos = pos + 1  -- skip ")"
        return list, pos
    else
        return tokens[pos], pos + 1
    end
end

-- Parse all top-level forms from a .wast file
local function parse_wast(text)
    local tokens = tokenize(text)
    local forms = {}
    local pos = 1
    while pos <= #tokens do
        local form
        form, pos = parse_sexpr(tokens, pos)
        forms[#forms + 1] = form
    end
    return forms
end

------------------------------------------------------------------------
-- Extract text ranges for modules (to send to wat2wasm)
------------------------------------------------------------------------

-- Find matching top-level s-expressions by paren counting
local function split_toplevel(text)
    local segments = {}
    local i = 1
    local len = #text
    while i <= len do
        -- Skip whitespace and comments
        while i <= len do
            local c = text:sub(i, i)
            if c:match("%s") then
                i = i + 1
            elseif text:sub(i, i + 1) == ";;" then
                local nl = text:find("\n", i)
                i = nl and nl + 1 or len + 1
            elseif text:sub(i, i + 1) == "(;" then
                local close = text:find(";%)", i + 2)
                i = close and close + 2 or len + 1
            else
                break
            end
        end
        if i > len then break end
        if text:sub(i, i) == "(" then
            local depth = 0
            local start = i
            local in_string = false
            while i <= len do
                local c = text:sub(i, i)
                if in_string then
                    if c == "\\" then
                        i = i + 1
                    elseif c == "\"" then
                        in_string = false
                    end
                else
                    if c == "\"" then
                        in_string = true
                    elseif text:sub(i, i + 1) == ";;" then
                        local nl = text:find("\n", i)
                        i = nl and nl or len
                    elseif text:sub(i, i + 1) == "(;" then
                        local close = text:find(";%)", i + 2)
                        i = close and close + 1 or len
                    elseif c == "(" then
                        depth = depth + 1
                    elseif c == ")" then
                        depth = depth - 1
                        if depth == 0 then
                            segments[#segments + 1] = text:sub(start, i)
                            i = i + 1
                            break
                        end
                    end
                end
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return segments
end

------------------------------------------------------------------------
-- Value parsing from assertion args
------------------------------------------------------------------------

local function parse_i32_value(s)
    if not s then return 0 end
    s = tostring(s)
    -- Handle hex
    if s:sub(1, 2) == "0x" or s:sub(1, 3) == "-0x" then
        local neg = s:sub(1, 1) == "-"
        local hex = neg and s:sub(4) or s:sub(3)
        -- Remove underscores
        hex = hex:gsub("_", "")
        local val = tonumber(hex, 16) or 0
        if neg then val = -val end
        -- Wrap to i32
        if val < 0 then
            val = val + 4294967296
        end
        if val >= 2147483648 then
            val = val - 4294967296
        end
        return val
    end
    s = s:gsub("_", "")
    local val = tonumber(s) or 0
    -- Wrap unsigned to signed i32
    if val >= 2147483648 then
        val = val - 4294967296
    end
    return val
end

local function parse_i64_value(s)
    if not s then return 0LL end
    s = tostring(s)
    s = s:gsub("_", "")
    if s:sub(1, 2) == "0x" or s:sub(1, 3) == "-0x" then
        local neg = s:sub(1, 1) == "-"
        local hex = neg and s:sub(4) or s:sub(3)
        hex = hex:gsub("_", "")
        -- Parse hex i64 via FFI
        local val = ffi.new("uint64_t", 0)
        for ci = 1, #hex do
            local ch = hex:byte(ci)
            local digit
            if ch >= 48 and ch <= 57 then digit = ch - 48
            elseif ch >= 65 and ch <= 70 then digit = ch - 55
            elseif ch >= 97 and ch <= 102 then digit = ch - 87
            else digit = 0 end
            val = val * 16ULL + ffi.cast("uint64_t", digit)
        end
        if neg then
            return -ffi.cast("int64_t", val)
        end
        return ffi.cast("int64_t", val)
    end
    -- Decimal
    local neg = s:sub(1, 1) == "-"
    local ds = neg and s:sub(2) or s
    local val = ffi.new("uint64_t", 0)
    for ci = 1, #ds do
        local ch = ds:byte(ci)
        if ch >= 48 and ch <= 57 then
            val = val * 10ULL + ffi.cast("uint64_t", ch - 48)
        end
    end
    if neg then
        return -ffi.cast("int64_t", val)
    end
    return ffi.cast("int64_t", val)
end

local function parse_f32_value(s)
    if not s then return 0.0 end
    s = tostring(s)
    s = s:gsub("_", "")
    if s == "inf" then return math.huge
    elseif s == "-inf" then return -math.huge
    elseif s:find("nan") then return 0.0/0.0
    end
    return tonumber(s) or 0.0
end

local function parse_f64_value(s)
    return parse_f32_value(s)  -- same parsing, Lua uses doubles
end

------------------------------------------------------------------------
-- Assertion evaluation
------------------------------------------------------------------------

local function extract_args(form)
    -- form = {"invoke", "name", arg1, arg2, ...}
    -- args are like {"i32.const", "42"} or {"i64.const", "-1"}
    local name = form[2]
    -- Remove quotes from name
    if type(name) == "string" then
        name = name:gsub("^\"", ""):gsub("\"$", "")
    end
    local args = {}
    for i = 3, #form do
        local arg = form[i]
        if type(arg) == "table" then
            local type_str = arg[1]
            local val_str = arg[2]
            if type_str == "i32.const" then
                args[#args + 1] = { type = "i32", value = parse_i32_value(val_str) }
            elseif type_str == "i64.const" then
                args[#args + 1] = { type = "i64", value = parse_i64_value(val_str) }
            elseif type_str == "f32.const" then
                args[#args + 1] = { type = "f32", value = parse_f32_value(val_str) }
            elseif type_str == "f64.const" then
                args[#args + 1] = { type = "f64", value = parse_f64_value(val_str) }
            end
        end
    end
    return name, args
end

local function values_equal(got, expected, typ)
    if typ == "f32" then
        if got ~= got and expected ~= expected then return true end
        if got ~= got or expected ~= expected then return false end
        -- Compare as f32 (round both to float precision)
        local fg = ffi.new("float[1]", got)
        local fe = ffi.new("float[1]", expected)
        return fg[0] == fe[0]
    elseif typ == "f64" then
        if got ~= got and expected ~= expected then return true end
        if got ~= got or expected ~= expected then return false end
        return got == expected
    end
    return got == expected
end

------------------------------------------------------------------------
-- Main runner
------------------------------------------------------------------------

local function run_wast(path)
    local f = io.open(path, "r")
    if not f then
        print("ERROR: cannot open " .. path)
        return
    end
    local text = f:read("*a")
    f:close()

    print("Running: " .. path)

    local segments = split_toplevel(text)
    local exports = nil
    local passed, failed, skipped, errors = 0, 0, 0, 0

    for _, seg in ipairs(segments) do
        -- Determine type
        local trimmed = seg:match("^%s*(.-)%s*$")

        if trimmed:sub(1, 7) == "(module" then
            -- Compile module via wat2wasm
            local wat_path = os.tmpname() .. ".wat"
            local wasm_path = os.tmpname() .. ".wasm"
            local wf = io.open(wat_path, "w")
            wf:write(trimmed)
            wf:close()
            local ret = os.execute("wat2wasm " .. wat_path .. " -o " .. wasm_path .. " 2>/dev/null")
            if ret == 0 or ret == true then
                local wf2 = io.open(wasm_path, "rb")
                local bytes = wf2:read("*a")
                wf2:close()
                local ok, result = pcall(POT.load_module, bytes)
                if ok then
                    exports = result
                else
                    print("  MODULE ERROR: " .. tostring(result))
                    exports = nil
                    errors = errors + 1
                end
            else
                print("  WAT2WASM FAILED for module")
                exports = nil
                errors = errors + 1
            end
            os.remove(wat_path)
            os.remove(wasm_path)

        elseif trimmed:sub(1, 14) == "(assert_return" then
            if not exports then
                skipped = skipped + 1
            else
                local tokens = tokenize(trimmed)
                local form
                form = parse_sexpr(tokens, 1)
                -- form = {"assert_return", invoke_form, expected...}
                if type(form) ~= "table" or #form < 2 then
                    skipped = skipped + 1
                else
                    local invoke_form = form[2]
                    if type(invoke_form) ~= "table" or invoke_form[1] ~= "invoke" then
                        skipped = skipped + 1
                    else
                        local fn_name, args = extract_args(invoke_form)
                        local fn = exports[fn_name]
                        if not fn then
                            skipped = skipped + 1
                        else
                            -- Extract expected results
                            local expected = {}
                            for i = 3, #form do
                                local exp = form[i]
                                if type(exp) == "table" then
                                    if exp[1] == "i32.const" then
                                        expected[#expected + 1] = { type = "i32", value = parse_i32_value(exp[2]) }
                                    elseif exp[1] == "i64.const" then
                                        expected[#expected + 1] = { type = "i64", value = parse_i64_value(exp[2]) }
                                    elseif exp[1] == "f32.const" then
                                        expected[#expected + 1] = { type = "f32", value = parse_f32_value(exp[2]) }
                                    elseif exp[1] == "f64.const" then
                                        expected[#expected + 1] = { type = "f64", value = parse_f64_value(exp[2]) }
                                    end
                                end
                            end

                            -- Build arg values
                            local call_args = {}
                            for _, a in ipairs(args) do
                                call_args[#call_args + 1] = a.value
                            end

                            local ok, result = pcall(function()
                                return fn(unpack(call_args))
                            end)

                            if not ok then
                                failed = failed + 1
                                io.write(string.format("  FAIL: %s(%s) => ERROR: %s\n",
                                    fn_name,
                                    table.concat((function()
                                        local s = {}
                                        for _, a in ipairs(args) do s[#s+1] = tostring(a.value) end
                                        return s
                                    end)(), ", "),
                                    tostring(result)))
                            elseif #expected == 0 then
                                -- No expected return (void function)
                                passed = passed + 1
                            elseif #expected == 1 then
                                local exp = expected[1]
                                if values_equal(result, exp.value, exp.type) then
                                    passed = passed + 1
                                else
                                    failed = failed + 1
                                    io.write(string.format("  FAIL: %s(%s) = %s, expected %s\n",
                                        fn_name,
                                        table.concat((function()
                                            local s = {}
                                            for _, a in ipairs(args) do s[#s+1] = tostring(a.value) end
                                            return s
                                        end)(), ", "),
                                        tostring(result), tostring(exp.value)))
                                end
                            else
                                -- Multi-value: result is a tuple cdata
                                local all_match = true
                                for idx, exp in ipairs(expected) do
                                    local field = "_" .. (idx - 1)
                                    local got = result[field]
                                    if not values_equal(got, exp.value, exp.type) then
                                        all_match = false
                                        io.write(string.format(
                                            "  FAIL: %s(%s) result[%d] = %s, expected %s\n",
                                            fn_name,
                                            table.concat((function()
                                                local s = {}
                                                for _, a in ipairs(args) do s[#s+1] = tostring(a.value) end
                                                return s
                                            end)(), ", "),
                                            idx - 1, tostring(got), tostring(exp.value)))
                                        break
                                    end
                                end
                                if all_match then
                                    passed = passed + 1
                                else
                                    failed = failed + 1
                                end
                            end
                        end
                    end
                end
            end

        elseif trimmed:sub(1, 12) == "(assert_trap" then
            -- POT/Trusted skips trap assertions
            skipped = skipped + 1

        elseif trimmed:sub(1, 15) == "(assert_invalid"
            or trimmed:sub(1, 18) == "(assert_malformed"
            or trimmed:sub(1, 20) == "(assert_exhaustion"
            or trimmed:sub(1, 21) == "(assert_unlinkable" then
            skipped = skipped + 1
        end
    end

    print(string.format("  %d passed, %d failed, %d skipped, %d errors",
          passed, failed, skipped, errors))
    return passed, failed, skipped, errors
end

------------------------------------------------------------------------
-- CLI
------------------------------------------------------------------------

local args = {...}
if #args == 0 then
    print("Usage: terra test_wast.t <file.wast> [file2.wast ...]")
    os.exit(1)
end

local total_passed, total_failed = 0, 0
for _, path in ipairs(args) do
    local p, f = run_wast(path)
    if p then
        total_passed = total_passed + p
        total_failed = total_failed + f
    end
end

print(string.format("\nTotal: %d passed, %d failed", total_passed, total_failed))
if total_failed > 0 then
    os.exit(1)
end
