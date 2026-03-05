-- POT: A WebAssembly Runtime in Terra
-- pot de terre — clay vessel, WASM bytes in, native code out.

local ffi = require("ffi")
local bit = require("bit")
local C = terralib.includec("stdlib.h")
local Cstr = terralib.includec("string.h")
local Cstdio = terralib.includec("stdio.h")
local Cunistd = terralib.includec("unistd.h")
local Ctime = terralib.includec("time.h")
local Cfcntl = terralib.includec("fcntl.h")

local POT = {}

------------------------------------------------------------------------
-- Utilities: LEB128, float readers, type map
------------------------------------------------------------------------

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
    -- Sign-extend short encodings.
    if shift < 32 and bit.band(b, 0x40) ~= 0 then
        result = result - (2 ^ shift)
    end
    -- Canonicalize to signed i32 range.
    -- This handles both short encodings and full 5-byte encodings correctly.
    result = result % 4294967296
    if result >= 2147483648 then
        result = result - 4294967296
    end
    return result, pos
end

local function decode_sleb128_i64(bytes, pos)
    local result = ffi.new("int64_t", 0)
    local shift = 0
    local b
    repeat
        b = bytes:byte(pos)
        result = result + ffi.cast("int64_t", bit.band(b, 0x7F))
                        * ffi.cast("int64_t", 2LL ^ shift)
        pos = pos + 1
        shift = shift + 7
    until bit.band(b, 0x80) == 0
    if shift < 64 and bit.band(b, 0x40) ~= 0 then
        result = result - ffi.cast("int64_t", 2LL ^ shift)
    end
    return result, pos
end

local function decode_uleb128_i64(bytes, pos)
    local result = ffi.new("uint64_t", 0)
    local shift = 0
    while true do
        local b = bytes:byte(pos)
        result = result + ffi.cast("uint64_t", bit.band(b, 0x7F))
                        * ffi.cast("uint64_t", 2ULL ^ shift)
        pos = pos + 1
        if bit.band(b, 0x80) == 0 then return result, pos end
        shift = shift + 7
    end
end

local function read_f32(bytes, pos)
    local buf = ffi.new("uint8_t[4]")
    for i = 0, 3 do buf[i] = bytes:byte(pos + i) end
    return ffi.cast("float*", buf)[0]
end

local function read_f64(bytes, pos)
    local buf = ffi.new("uint8_t[8]")
    for i = 0, 7 do buf[i] = bytes:byte(pos + i) end
    return ffi.cast("double*", buf)[0]
end

local opaque_ptr_type = terralib.types.pointer(terralib.types.opaque)

local wasm_types = {
    [0x7F] = int32,
    [0x7E] = int64,
    [0x7D] = float,
    [0x7C] = double,
    [0x70] = opaque_ptr_type, -- funcref
    [0x6F] = opaque_ptr_type, -- externref
}

local opcode_handlers = {}

------------------------------------------------------------------------
-- Binary Parser
------------------------------------------------------------------------

local section_parsers = {}

local function parse_limits(bytes, p)
    local flags; flags, p = decode_uleb128(bytes, p)
    local initial; initial, p = decode_uleb128(bytes, p)
    local maximum = nil
    if bit.band(flags, 1) == 1 then
        maximum, p = decode_uleb128(bytes, p)
    end
    return {
        flags = flags,
        initial = initial,
        maximum = maximum,
    }, p
end

local function parse_const_expr(bytes, p)
    local ops = {}
    while true do
        local op = bytes:byte(p)
        assert(op ~= nil, "unexpected eof in const expr")
        p = p + 1
        if op == 0x0B then
            break
        end
        local entry = { op = op }
        if op == 0x41 then
            entry.value, p = decode_sleb128(bytes, p)
        elseif op == 0x42 then
            entry.value, p = decode_sleb128_i64(bytes, p)
        elseif op == 0x43 then
            entry.value = read_f32(bytes, p); p = p + 4
        elseif op == 0x44 then
            entry.value = read_f64(bytes, p); p = p + 8
        elseif op == 0x23 then
            local gidx; gidx, p = decode_uleb128(bytes, p)
            entry.index = gidx + 1
        elseif op == 0xD0 then
            entry.reftype = bytes:byte(p); p = p + 1
        elseif op == 0xD2 then
            local fidx; fidx, p = decode_uleb128(bytes, p)
            entry.index = fidx + 1
        else
            -- Extended-const integer ops (enabled by testsuite in some modules).
            if op ~= 0x6A and op ~= 0x6B and op ~= 0x6C
               and op ~= 0x7C and op ~= 0x7D and op ~= 0x7E then
                error(string.format("unsupported const expr opcode 0x%02X", op))
            end
        end
        ops[#ops + 1] = entry
    end
    return { ops = ops }, p
end

-- Custom section (ID 0)
section_parsers[0] = function(mod, bytes, p, pend)
    local name_len; name_len, p = decode_uleb128(bytes, p)
    local name = bytes:sub(p, p + name_len - 1)
    p = p + name_len
    local data = bytes:sub(p, pend - 1)
    mod.custom_sections[#mod.custom_sections + 1] = {
        name = name,
        data = data,
    }
end

-- Type section (ID 1)
section_parsers[1] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        assert(bytes:byte(p) == 0x60, "expected functype")
        p = p + 1
        local param_count; param_count, p = decode_uleb128(bytes, p)
        local params = {}
        for j = 1, param_count do
            params[j] = wasm_types[bytes:byte(p)]
            p = p + 1
        end
        local result_count; result_count, p = decode_uleb128(bytes, p)
        local results = {}
        for j = 1, result_count do
            results[j] = wasm_types[bytes:byte(p)]
            p = p + 1
        end
        mod.types[i] = { params = params, results = results }
    end
end

-- Import section (ID 2)
section_parsers[2] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local mod_len; mod_len, p = decode_uleb128(bytes, p)
        local mod_name = bytes:sub(p, p + mod_len - 1); p = p + mod_len
        local name_len; name_len, p = decode_uleb128(bytes, p)
        local name = bytes:sub(p, p + name_len - 1); p = p + name_len
        local kind = bytes:byte(p); p = p + 1
        if kind == 0x00 then -- function import
            local type_idx; type_idx, p = decode_uleb128(bytes, p)
            mod.imports[#mod.imports + 1] = {
                module = mod_name, name = name,
                kind = "function", type_idx = type_idx + 1,
            }
        elseif kind == 0x01 then -- table import
            local elemtype = bytes:byte(p); p = p + 1
            local limits; limits, p = parse_limits(bytes, p)
            mod.imports[#mod.imports + 1] = {
                module = mod_name, name = name,
                kind = "table",
                elemtype = elemtype,
                initial = limits.initial,
                maximum = limits.maximum,
            }
        elseif kind == 0x02 then -- memory import
            local limits; limits, p = parse_limits(bytes, p)
            mod.imports[#mod.imports + 1] = {
                module = mod_name, name = name,
                kind = "memory",
                initial = limits.initial, maximum = limits.maximum,
            }
        elseif kind == 0x03 then -- global import
            local content_type = wasm_types[bytes:byte(p)]; p = p + 1
            local mutability = bytes:byte(p); p = p + 1
            mod.imports[#mod.imports + 1] = {
                module = mod_name, name = name,
                kind = "global",
                type = content_type, mutable = mutability == 1,
            }
        elseif kind == 0x04 then -- tag import
            local tag_attr = bytes:byte(p); p = p + 1
            local type_idx; type_idx, p = decode_uleb128(bytes, p)
            mod.imports[#mod.imports + 1] = {
                module = mod_name, name = name,
                kind = "tag",
                attribute = tag_attr,
                type_idx = type_idx + 1,
            }
        else
            error(string.format("unsupported import kind 0x%02X", kind))
        end
    end
end

-- Function section (ID 3)
section_parsers[3] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local type_idx; type_idx, p = decode_uleb128(bytes, p)
        mod.funcs[i] = { type_idx = type_idx + 1 }
    end
end

-- Table section (ID 4)
section_parsers[4] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local elemtype = bytes:byte(p); p = p + 1
        local flags; flags, p = decode_uleb128(bytes, p)
        local initial; initial, p = decode_uleb128(bytes, p)
        local maximum = nil
        if bit.band(flags, 1) == 1 then
            maximum, p = decode_uleb128(bytes, p)
        end
        mod.tables[i] = { elemtype = elemtype, initial = initial, maximum = maximum }
    end
end

-- Memory section (ID 5)
section_parsers[5] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local flags; flags, p = decode_uleb128(bytes, p)
        local initial; initial, p = decode_uleb128(bytes, p)
        local maximum = nil
        if bit.band(flags, 1) == 1 then
            maximum, p = decode_uleb128(bytes, p)
        end
        mod.memory[i] = { initial = initial, maximum = maximum }
    end
end

-- Global section (ID 6)
section_parsers[6] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local content_type = wasm_types[bytes:byte(p)]; p = p + 1
        local mutability = bytes:byte(p); p = p + 1
        local init_expr; init_expr, p = parse_const_expr(bytes, p)
        mod.globals[i] = {
            type = content_type,
            mutable = mutability == 1,
            init = init_expr,
        }
    end
end

-- Export section (ID 7)
section_parsers[7] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local name_len; name_len, p = decode_uleb128(bytes, p)
        local name = bytes:sub(p, p + name_len - 1); p = p + name_len
        local kind = bytes:byte(p); p = p + 1
        local index; index, p = decode_uleb128(bytes, p)
        mod.exports[name] = { kind = kind, index = index + 1 }
    end
end

-- Start section (ID 8)
section_parsers[8] = function(mod, bytes, p, pend)
    mod.start_fn, p = decode_uleb128(bytes, p)
    mod.start_fn = mod.start_fn + 1
end

-- Element section (ID 9)
section_parsers[9] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local flags; flags, p = decode_uleb128(bytes, p)
        local elem = {
            mode = "active",
            table_idx = 0,
            offset = nil,
            elems = {},
        }
        if flags == 0 then
            elem.offset, p = parse_const_expr(bytes, p)
            local num_elems; num_elems, p = decode_uleb128(bytes, p)
            for j = 1, num_elems do
                local fidx; fidx, p = decode_uleb128(bytes, p)
                elem.elems[j] = fidx + 1
            end
        elseif flags == 1 then
            elem.mode = "passive"
            p = p + 1 -- elemkind
            local num_elems; num_elems, p = decode_uleb128(bytes, p)
            for j = 1, num_elems do
                local fidx; fidx, p = decode_uleb128(bytes, p)
                elem.elems[j] = fidx + 1
            end
        elseif flags == 2 then
            elem.table_idx, p = decode_uleb128(bytes, p)
            elem.offset, p = parse_const_expr(bytes, p)
            p = p + 1 -- elemkind
            local num_elems; num_elems, p = decode_uleb128(bytes, p)
            for j = 1, num_elems do
                local fidx; fidx, p = decode_uleb128(bytes, p)
                elem.elems[j] = fidx + 1
            end
        elseif flags == 3 then
            elem.mode = "declarative"
            p = p + 1 -- elemkind
            local num_elems; num_elems, p = decode_uleb128(bytes, p)
            for j = 1, num_elems do
                local fidx; fidx, p = decode_uleb128(bytes, p)
                elem.elems[j] = fidx + 1
            end
        elseif flags == 4 or flags == 5 or flags == 6 or flags == 7 then
            if flags == 6 then
                elem.table_idx, p = decode_uleb128(bytes, p)
            end
            if flags == 4 or flags == 6 then
                elem.offset, p = parse_const_expr(bytes, p)
            else
                elem.mode = (flags == 5) and "passive" or "declarative"
            end
            p = p + 1 -- reftype
            local num_elems; num_elems, p = decode_uleb128(bytes, p)
            for j = 1, num_elems do
                local expr; expr, p = parse_const_expr(bytes, p)
                local first = expr.ops[1]
                if first and first.op == 0xD2 then
                    elem.elems[j] = first.index
                else
                    elem.elems[j] = nil
                end
            end
        else
            error("unsupported element segment flags: " .. tostring(flags))
        end
        mod.elements[i] = elem
    end
end

-- Code section (ID 10)
section_parsers[10] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local body_size; body_size, p = decode_uleb128(bytes, p)
        local body_end = p + body_size
        local local_count; local_count, p = decode_uleb128(bytes, p)
        local locals = {}
        for j = 1, local_count do
            local n; n, p = decode_uleb128(bytes, p)
            local t = wasm_types[bytes:byte(p)]; p = p + 1
            for k = 1, n do
                locals[#locals + 1] = t
            end
        end
        mod.codes[i] = {
            locals = locals,
            bytecode = bytes,
            bc_start = p,
            bc_end = body_end,
        }
        p = body_end
    end
end

-- Data section (ID 11)
section_parsers[11] = function(mod, bytes, p, pend)
    local count; count, p = decode_uleb128(bytes, p)
    for i = 1, count do
        local flags; flags, p = decode_uleb128(bytes, p)
        local mem_idx = 0
        local offset = nil
        if flags == 0 then
            offset, p = parse_const_expr(bytes, p)
        elseif flags == 1 then
            -- passive segment: no memory index or offset
        elseif flags == 2 then
            mem_idx, p = decode_uleb128(bytes, p)
            offset, p = parse_const_expr(bytes, p)
        else
            error("unsupported data segment flags: " .. tostring(flags))
        end
        local data_len; data_len, p = decode_uleb128(bytes, p)
        local data = bytes:sub(p, p + data_len - 1)
        p = p + data_len
        mod.datas[i] = { mem_idx = mem_idx, offset = offset, data = data, mode = (flags == 1) and "passive" or "active" }
    end
end

local function parse_wasm(bytes)
    local mod = {
        types    = {},
        imports  = {},
        funcs    = {},
        tables   = {},
        memory   = {},
        globals  = {},
        exports  = {},
        elements = {},
        codes    = {},
        datas    = {},
        start_fn = nil,
        custom_sections = {},
    }

    local p = 1
    assert(bytes:byte(1) == 0x00 and bytes:byte(2) == 0x61
       and bytes:byte(3) == 0x73 and bytes:byte(4) == 0x6D,
       "not a WASM binary")
    p = 5

    local version = bytes:byte(5) + bytes:byte(6) * 256
                  + bytes:byte(7) * 65536 + bytes:byte(8) * 16777216
    assert(version == 1, "unsupported WASM version: " .. version)
    p = 9

    while p <= #bytes do
        local section_id = bytes:byte(p); p = p + 1
        local section_len; section_len, p = decode_uleb128(bytes, p)
        local section_end = p + section_len
        local parser = section_parsers[section_id]
        if parser then
            parser(mod, bytes, p, section_end)
        end
        p = section_end
    end

    return mod
end

------------------------------------------------------------------------
-- Stack Compiler
------------------------------------------------------------------------

local function make_stack()
    local stack = {}
    return {
        push = function(expr) stack[#stack + 1] = expr end,
        pop  = function()
            assert(#stack > 0, "stack underflow")
            local v = stack[#stack]
            stack[#stack] = nil
            return v
        end,
        peek = function() return stack[#stack] end,
        peek_at = function(offset) return stack[#stack - offset] end,
        depth = function() return #stack end,
        save  = function() return #stack end,
        restore = function(d)
            while #stack > d do stack[#stack] = nil end
        end,
        -- Replace all stack entries referencing sym with a temp snapshot
        snapshot_sym = function(sym, stmts, T)
            for i = 1, #stack do
                -- Check if this stack entry is `[sym]` by comparing the tree
                -- Terra quotes are opaque, so we tag tee'd entries
                if stack[i]._tee_sym == sym then
                    local tmp = symbol(T, "tee_snap")
                    stmts:insert(quote var [tmp] = [sym] end)
                    local q = `[tmp]
                    q._tee_sym = nil
                    stack[i] = q
                end
            end
        end,
    }
end

local function make_locals(func_type, code_entry)
    local locals = {}
    local param_syms = terralib.newlist()
    for i, T in ipairs(func_type.params) do
        local s = symbol(T, "p" .. i)
        param_syms:insert(s)
        locals[i - 1] = { sym = s, type = T }
    end
    local nparams = #func_type.params
    local init_stmts = terralib.newlist()
    for i, T in ipairs(code_entry.locals) do
        local s = symbol(T, "l" .. i)
        locals[nparams + i - 1] = { sym = s, type = T }
        init_stmts:insert(quote var [s] = [T](0) end)
    end
    return locals, param_syms, init_stmts
end

local function decode_block_type(bc, ip, mod)
    local block_type; block_type, ip = decode_sleb128(bc, ip)
    if block_type == -64 then
        return {}, {}, ip
    elseif block_type < 0 then
        local t = wasm_types[bit.band(block_type, 0x7F)]
        return {}, {t}, ip
    else
        local ftype = mod.types[block_type + 1]
        return ftype.params, ftype.results, ip
    end
end

local function make_ret_type(results)
    if #results == 0 then
        return nil
    elseif #results == 1 then
        return results[1]
    else
        return tuple(unpack(results))
    end
end

local function alloc_result_syms(stmts, result_types, prefix)
    local syms = {}
    for i, T in ipairs(result_types) do
        local s = symbol(T, prefix .. "_" .. i)
        stmts:insert(quote var [s] = [T](0) end)
        syms[i] = s
    end
    return syms
end

local function assign_results_from_stack(stk, stmts, result_syms)
    local vals = {}
    for i = #result_syms, 1, -1 do
        vals[i] = stk.pop()
    end
    for i, sym in ipairs(result_syms) do
        stmts:insert(quote [sym] = [vals[i]] end)
    end
end

local function push_result_syms(stk, result_syms)
    for _, sym in ipairs(result_syms) do
        stk.push(`[sym])
    end
end

local function make_block_entry(kind, lbl, result_types, param_types, stack_depth)
    return {
        kind = kind,
        label = lbl,
        result_types = result_types or {},
        param_types = param_types or {},
        stack_depth = stack_depth,
        result_syms = {},
    }
end

local function emit_branch(stk, stmts, block_stack, depth)
    local target = block_stack[#block_stack - depth]
    if target.kind == "loop" then
        -- br to loop: carry param values
        if target.param_syms and #target.param_syms > 0
           and stk.depth() > target.stack_depth then
            local vals = {}
            for i = #target.param_syms, 1, -1 do
                vals[i] = stk.pop()
            end
            for i, sym in ipairs(target.param_syms) do
                stmts:insert(quote [sym] = [vals[i]] end)
            end
        end
        stmts:insert(quote goto [target.label] end)
    else
        if #target.result_syms > 0 and stk.depth() > target.stack_depth then
            assign_results_from_stack(stk, stmts, target.result_syms)
        end
        stmts:insert(quote goto [target.label] end)
    end
end

-- Skip immediate operands of an opcode in unreachable code
local function skip_immediate(op, bc, ip)
    if op == 0x0C or op == 0x0D then -- br, br_if
        local _; _, ip = decode_uleb128(bc, ip)
    elseif op == 0x0E then -- br_table
        local cnt; cnt, ip = decode_uleb128(bc, ip)
        for i = 1, cnt + 1 do
            local _; _, ip = decode_uleb128(bc, ip)
        end
    elseif op == 0x10 then -- call
        local _; _, ip = decode_uleb128(bc, ip)
    elseif op == 0x11 then -- call_indirect
        local _; _, ip = decode_uleb128(bc, ip)
        local __; __, ip = decode_uleb128(bc, ip)
    elseif op == 0x20 or op == 0x21 or op == 0x22 then -- local.get/set/tee
        local _; _, ip = decode_uleb128(bc, ip)
    elseif op == 0x23 or op == 0x24 then -- global.get/set
        local _; _, ip = decode_uleb128(bc, ip)
    elseif op == 0x41 then -- i32.const
        local _; _, ip = decode_sleb128(bc, ip)
    elseif op == 0x42 then -- i64.const
        local _; _, ip = decode_sleb128_i64(bc, ip)
    elseif op == 0x43 then -- f32.const
        ip = ip + 4
    elseif op == 0x44 then -- f64.const
        ip = ip + 8
    elseif op >= 0x28 and op <= 0x3E then -- memory load/store
        local _; _, ip = decode_uleb128(bc, ip)
        local __; __, ip = decode_uleb128(bc, ip)
    elseif op == 0x3F or op == 0x40 then -- memory.size/grow
        local _; _, ip = decode_uleb128(bc, ip)
    elseif op == 0xFC then -- prefix opcodes
        local sub; sub, ip = decode_uleb128(bc, ip)
        if sub == 10 then ip = ip + 2       -- memory.copy: 2 memory indices
        elseif sub == 11 then ip = ip + 1   -- memory.fill: 1 memory index
        elseif sub == 8 then                -- memory.init
            local _; _, ip = decode_uleb128(bc, ip)
            ip = ip + 1
        elseif sub == 9 then                -- data.drop
            local _; _, ip = decode_uleb128(bc, ip)
        end
    end
    return ip
end

local function compile_function(mod, func_idx, module_env)
    local func = mod.funcs[func_idx]
    local code = mod.codes[func_idx]
    local ftype = mod.types[func.type_idx]

    local locals, param_syms, init_stmts = make_locals(ftype, code)
    local stk = make_stack()
    local stmts = terralib.newlist()
    stmts:insertall(init_stmts)

    local mem = module_env.memory_sym
    local mem_size = module_env.mem_size
    local globals = module_env.globals
    local fn_table = module_env.fn_table

    local bc = code.bytecode
    local ip = code.bc_start
    local block_stack = {}
    local unreachable = false

    -- Implicit function-level block (br to this = return)
    local fn_end_label = label("fn_end")
    local ret_type = make_ret_type(ftype.results)
    local fn_result_syms = alloc_result_syms(stmts, ftype.results, "fn_res")
    local fn_block = make_block_entry("block", fn_end_label, ftype.results, {}, stk.save())
    fn_block.result_syms = fn_result_syms
    block_stack[#block_stack + 1] = fn_block

    while ip < code.bc_end do
        local op = bc:byte(ip); ip = ip + 1

        if unreachable then
            -- Skip opcodes in unreachable code, only react to structure
            if op == 0x0B then -- end
                if #block_stack == 0 then
                    break
                end
                local block = block_stack[#block_stack]
                block_stack[#block_stack] = nil
                stk.restore(block.stack_depth)
                if block.kind == "block" or block.kind == "if" then
                    stmts:insert(quote ::[block.label]:: end)
                    if block.kind == "if" and not block.has_else then
                        stmts:insert(quote ::[block.else_label]:: end)
                    end
                elseif block.kind == "loop" and block.break_label then
                    stmts:insert(quote ::[block.break_label]:: end)
                end
                push_result_syms(stk, block.result_syms)
                unreachable = false
            elseif op == 0x05 then -- else
                local block = block_stack[#block_stack]
                block.has_else = true
                stk.restore(block.stack_depth)
                stmts:insert(quote goto [block.label] end)
                stmts:insert(quote ::[block.else_label]:: end)
                -- Re-push params for else-branch
                if block.param_syms then
                    for _, sym in ipairs(block.param_syms) do
                        stk.push(`[sym])
                    end
                end
                unreachable = false
            elseif op == 0x02 or op == 0x03 or op == 0x04 then
                local param_types, result_types
                param_types, result_types, ip = decode_block_type(bc, ip, module_env.mod)
                if op == 0x04 then
                    local end_label = label("dead_if_end")
                    local else_label = label("dead_if_else")
                    local blk = make_block_entry("if", end_label, result_types, param_types, stk.save())
                    blk.else_label = else_label
                    blk.has_else = false
                    block_stack[#block_stack + 1] = blk
                else
                    local lbl = label("dead_block")
                    local kind = op == 0x02 and "block" or "loop"
                    local blk = make_block_entry(kind, lbl, result_types, param_types, stk.save())
                    if kind == "loop" then blk.break_label = label("dead_loop_break") end
                    block_stack[#block_stack + 1] = blk
                end
            else
                -- Consume operands for known opcodes
                ip = skip_immediate(op, bc, ip)
            end
        else
            local handler = opcode_handlers[op]
            if handler then
                ip = handler(stk, stmts, locals, bc, ip, mem, mem_size,
                             globals, fn_table, block_stack, module_env)
                if op == 0x0C or op == 0x0F or op == 0x00 then
                    unreachable = true
                end
            else
                error(string.format(
                    "unimplemented opcode 0x%02X at position %d", op, ip - 1))
            end
        end
    end

    -- The function block's end opcode has been handled by the 0x0B handler,
    -- which places fn_end_label and pushes fn_result_sym.
    -- If there are still blocks on the stack, the final end wasn't reached
    -- (shouldn't happen with valid WASM).

    local terra_fn
    if #ftype.results == 0 then
        terra_fn = terra([param_syms])
            [stmts]
        end
    elseif #ftype.results == 1 then
        if stk.depth() > 0 then
            local ret_expr = stk.pop()
            terra_fn = terra([param_syms]) : ret_type
                [stmts]
                return [ret_expr]
            end
        else
            terra_fn = terra([param_syms]) : ret_type
                [stmts]
                return [ret_type](0)
            end
        end
    else
        -- Multi-value return
        local ret_stmts = terralib.newlist()
        if stk.depth() > 0 then
            local vals = {}
            for i = #ftype.results, 1, -1 do
                vals[i] = stk.pop()
            end
            for i, sym in ipairs(fn_result_syms) do
                ret_stmts:insert(quote [sym] = [vals[i]] end)
            end
        end
        local ret_list = terralib.newlist()
        for _, sym in ipairs(fn_result_syms) do
            ret_list:insert(`[sym])
        end
        terra_fn = terra([param_syms]) : ret_type
            [stmts]
            [ret_stmts]
            return [ret_list]
        end
    end

    return terra_fn
end

------------------------------------------------------------------------
-- Opcode Handlers: Constants
------------------------------------------------------------------------

-- 0x00: unreachable
opcode_handlers[0x00] = function(stk, stmts, locals, bc, ip, ...)
    stmts:insert(quote C.abort() end)
    return ip
end

-- 0x01: nop
opcode_handlers[0x01] = function(stk, stmts, locals, bc, ip, ...)
    return ip
end

-- 0x41: i32.const
opcode_handlers[0x41] = function(stk, stmts, locals, bc, ip, ...)
    local val; val, ip = decode_sleb128(bc, ip)
    stk.push(`[int32](val))
    return ip
end

-- 0x42: i64.const
opcode_handlers[0x42] = function(stk, stmts, locals, bc, ip, ...)
    local val; val, ip = decode_sleb128_i64(bc, ip)
    stk.push(`[int64](val))
    return ip
end

-- 0x43: f32.const
opcode_handlers[0x43] = function(stk, stmts, locals, bc, ip, ...)
    local val = read_f32(bc, ip); ip = ip + 4
    stk.push(`[float](val))
    return ip
end

-- 0x44: f64.const
opcode_handlers[0x44] = function(stk, stmts, locals, bc, ip, ...)
    local val = read_f64(bc, ip); ip = ip + 8
    stk.push(`[double](val))
    return ip
end

------------------------------------------------------------------------
-- Opcode Handlers: Variables
------------------------------------------------------------------------

-- 0x20: local.get
opcode_handlers[0x20] = function(stk, stmts, locals, bc, ip, ...)
    local idx; idx, ip = decode_uleb128(bc, ip)
    stk.push(`[locals[idx].sym])
    return ip
end

-- 0x21: local.set
opcode_handlers[0x21] = function(stk, stmts, locals, bc, ip, ...)
    local idx; idx, ip = decode_uleb128(bc, ip)
    local val = stk.pop()
    stmts:insert(quote [locals[idx].sym] = [val] end)
    return ip
end

-- 0x22: local.tee
opcode_handlers[0x22] = function(stk, stmts, locals, bc, ip, ...)
    local idx; idx, ip = decode_uleb128(bc, ip)
    local val = stk.pop()
    stmts:insert(quote [locals[idx].sym] = [val] end)
    stk.push(`[locals[idx].sym])
    return ip
end

-- 0x23: global.get
opcode_handlers[0x23] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, ...)
    local idx; idx, ip = decode_uleb128(bc, ip)
    -- Snapshot global value now.
    local g = globals[idx + 1]
    local tmp = symbol(g.type, "global_get")
    stmts:insert(quote var [tmp] = [g.sym] end)
    stk.push(`[tmp])
    return ip
end

-- 0x24: global.set
opcode_handlers[0x24] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, ...)
    local idx; idx, ip = decode_uleb128(bc, ip)
    local val = stk.pop()
    stmts:insert(quote [globals[idx + 1].sym] = [val] end)
    return ip
end

------------------------------------------------------------------------
-- Opcode Handlers: Misc
------------------------------------------------------------------------

-- 0x1A: drop
opcode_handlers[0x1A] = function(stk, stmts, locals, bc, ip, ...)
    stk.pop()
    return ip
end

-- 0x1B: select
opcode_handlers[0x1B] = function(stk, stmts, locals, bc, ip, ...)
    local cond = stk.pop()
    local val2 = stk.pop()
    local val1 = stk.pop()
    stk.push(`terralib.select([cond] ~= 0, [val1], [val2]))
    return ip
end

------------------------------------------------------------------------
-- Opcode Handlers: Numeric (generated)
------------------------------------------------------------------------

local function make_binop_handlers(ops, result_type)
    for opcode, spec in pairs(ops) do
        opcode_handlers[opcode] = function(stk, stmts, locals, bc, ip, ...)
            local b = stk.pop()
            local a = stk.pop()
            local expr = spec.emit(a, b)
            if result_type then
                local tmp = symbol(result_type, "binop")
                stmts:insert(quote var [tmp] = [expr] end)
                stk.push(`[tmp])
            else
                stk.push(expr)
            end
            return ip
        end
    end
end

local function make_unop_handlers(ops, result_type)
    for opcode, spec in pairs(ops) do
        opcode_handlers[opcode] = function(stk, stmts, locals, bc, ip, ...)
            local a = stk.pop()
            local expr = spec.emit(a)
            if result_type then
                local tmp = symbol(result_type, "unop")
                stmts:insert(quote var [tmp] = [expr] end)
                stk.push(`[tmp])
            else
                stk.push(expr)
            end
            return ip
        end
    end
end

local function make_compare_handlers(ops)
    for opcode, spec in pairs(ops) do
        opcode_handlers[opcode] = function(stk, stmts, locals, bc, ip, ...)
            local b = stk.pop()
            local a = stk.pop()
            local cond = spec.emit(a, b)
            local tmp = symbol(int32, "cmp")
            stmts:insert(quote
                var [tmp] = [int32](0)
                if [cond] then [tmp] = [int32](1) end
            end)
            stk.push(`[tmp])
            return ip
        end
    end
end

local function make_testop_handlers(ops)
    for opcode, spec in pairs(ops) do
        opcode_handlers[opcode] = function(stk, stmts, locals, bc, ip, ...)
            local a = stk.pop()
            local cond = spec.emit(a)
            local tmp = symbol(int32, "test")
            stmts:insert(quote
                var [tmp] = [int32](0)
                if [cond] then [tmp] = [int32](1) end
            end)
            stk.push(`[tmp])
            return ip
        end
    end
end

local function make_convert_handlers(ops, result_type)
    for opcode, spec in pairs(ops) do
        opcode_handlers[opcode] = function(stk, stmts, locals, bc, ip, ...)
            local a = stk.pop()
            local expr = spec.emit(a)
            if result_type then
                local tmp = symbol(result_type, "conv")
                stmts:insert(quote var [tmp] = [expr] end)
                stk.push(`[tmp])
            else
                stk.push(expr)
            end
            return ip
        end
    end
end

-- i32 binary ops
make_binop_handlers({
    -- WASM integer arithmetic wraps modulo 2^N.
    -- Use unsigned ops to avoid signed-overflow UB in generated native code.
    [0x6A] = { emit = function(a, b) return `[int32]([uint32](a) + [uint32](b)) end },
    [0x6B] = { emit = function(a, b) return `[int32]([uint32](a) - [uint32](b)) end },
    [0x6C] = { emit = function(a, b) return `[int32]([uint32](a) * [uint32](b)) end },
    [0x6D] = { emit = function(a, b)                                               -- div_s
        local r = symbol(int32, "div_s_r")
        return quote
            var [r] = [int32](0)
            var av, bv = [int32](a), [int32](b)
            if bv ~= 0 then
                if av == [int32](-2147483648) and bv == -1 then
                    [r] = [int32](-2147483648)
                else
                    [r] = av / bv
                end
            end
        in [r] end
    end },
    [0x6E] = { emit = function(a, b)                                               -- div_u
        local r = symbol(int32, "div_u_r")
        return quote
            var [r] = [int32](0)
            var bv = [uint32](b)
            if bv ~= 0 then [r] = [int32]([uint32](a) / bv) end
        in [r] end
    end },
    [0x6F] = { emit = function(a, b)                                               -- rem_s
        local r = symbol(int32, "rem_s_r")
        return quote
            var [r] = [int32](0)
            var av, bv = [int32](a), [int32](b)
            if bv ~= 0 and bv ~= -1 then [r] = av % bv end
        in [r] end
    end },
    [0x70] = { emit = function(a, b)                                               -- rem_u
        local r = symbol(int32, "rem_u_r")
        return quote
            var [r] = [int32](0)
            var bv = [uint32](b)
            if bv ~= 0 then [r] = [int32]([uint32](a) % bv) end
        in [r] end
    end },
    [0x71] = { emit = function(a, b) return `[int32]([uint32](a) and [uint32](b)) end },
    [0x72] = { emit = function(a, b) return `[int32]([uint32](a) or [uint32](b)) end },
    [0x73] = { emit = function(a, b) return `[int32]([uint32](a) ^ [uint32](b)) end },
    [0x74] = { emit = function(a, b) return `[int32]([uint32](a) << ([uint32](b) and 31)) end }, -- shl
    [0x75] = { emit = function(a, b) return `[int32](a) >> ([uint32](b) and 31) end },       -- shr_s
    [0x76] = { emit = function(a, b) return `[int32]([uint32](a) >> ([uint32](b) and 31)) end }, -- shr_u
    [0x77] = { emit = function(a, b)                                                 -- rotl
        return quote
            var ua = [uint32](a)
            var c = [uint32](b) and 31
        in
            [int32]((ua << c) or (ua >> (32 - c)))
        end
    end },
    [0x78] = { emit = function(a, b)                                                 -- rotr
        return quote
            var ua = [uint32](a)
            var c = [uint32](b) and 31
        in
            [int32]((ua >> c) or (ua << (32 - c)))
        end
    end },
}, int32)

-- i32 unary ops
local terra i32_clz(x : int32) : int32
    if x == 0 then return 32 end
    var n : int32 = 0
    var u = [uint32](x)
    if (u and 0xFFFF0000U) == 0 then n = n + 16; u = u << 16 end
    if (u and 0xFF000000U) == 0 then n = n + 8;  u = u << 8  end
    if (u and 0xF0000000U) == 0 then n = n + 4;  u = u << 4  end
    if (u and 0xC0000000U) == 0 then n = n + 2;  u = u << 2  end
    if (u and 0x80000000U) == 0 then n = n + 1 end
    return n
end

local terra i32_ctz(x : int32) : int32
    if x == 0 then return 32 end
    var n : int32 = 0
    var u = [uint32](x)
    if (u and 0x0000FFFF) == 0 then n = n + 16; u = u >> 16 end
    if (u and 0x000000FF) == 0 then n = n + 8;  u = u >> 8  end
    if (u and 0x0000000F) == 0 then n = n + 4;  u = u >> 4  end
    if (u and 0x00000003) == 0 then n = n + 2;  u = u >> 2  end
    if (u and 0x00000001) == 0 then n = n + 1 end
    return n
end

local terra i32_popcnt(x : int32) : int32
    var u = [uint32](x)
    u = u - ((u >> 1) and 0x55555555U)
    u = (u and 0x33333333U) + ((u >> 2) and 0x33333333U)
    u = (u + (u >> 4)) and 0x0F0F0F0FU
    return [int32]((u * 0x01010101U) >> 24)
end

make_unop_handlers({
    [0x67] = { emit = function(a) return `i32_clz(a) end },
    [0x68] = { emit = function(a) return `i32_ctz(a) end },
    [0x69] = { emit = function(a) return `i32_popcnt(a) end },
}, int32)

-- i32 test/compare ops
make_testop_handlers({
    [0x45] = { emit = function(a) return `a == [int32](0) end },  -- eqz
})

make_compare_handlers({
    [0x46] = { emit = function(a, b) return `[int32](a) == [int32](b) end },       -- eq
    [0x47] = { emit = function(a, b) return `[int32](a) ~= [int32](b) end },       -- ne
    [0x48] = { emit = function(a, b) return `[int32](a) < [int32](b) end },        -- lt_s
    [0x49] = { emit = function(a, b) return `[uint32](a) < [uint32](b) end },      -- lt_u
    [0x4A] = { emit = function(a, b) return `[int32](a) > [int32](b) end },        -- gt_s
    [0x4B] = { emit = function(a, b) return `[uint32](a) > [uint32](b) end },      -- gt_u
    [0x4C] = { emit = function(a, b) return `[int32](a) <= [int32](b) end },       -- le_s
    [0x4D] = { emit = function(a, b) return `[uint32](a) <= [uint32](b) end },     -- le_u
    [0x4E] = { emit = function(a, b) return `[int32](a) >= [int32](b) end },       -- ge_s
    [0x4F] = { emit = function(a, b) return `[uint32](a) >= [uint32](b) end },     -- ge_u
})

-- i64 binary ops
make_binop_handlers({
    [0x7C] = { emit = function(a, b) return `[int64]([uint64](a) + [uint64](b)) end },
    [0x7D] = { emit = function(a, b) return `[int64]([uint64](a) - [uint64](b)) end },
    [0x7E] = { emit = function(a, b) return `[int64]([uint64](a) * [uint64](b)) end },
    [0x7F] = { emit = function(a, b)                                               -- div_s
        local INT64_MIN = -9223372036854775807LL - 1LL
        local r = symbol(int64, "div_s_r")
        return quote
            var [r] = [int64](0)
            var av, bv = [int64](a), [int64](b)
            if bv ~= 0 then
                if av == [int64](INT64_MIN) and bv == -1 then
                    [r] = [int64](INT64_MIN)
                else
                    [r] = av / bv
                end
            end
        in [r] end
    end },
    [0x80] = { emit = function(a, b)                                               -- div_u
        local r = symbol(int64, "div_u_r")
        return quote
            var [r] = [int64](0)
            var bv = [uint64](b)
            if bv ~= 0 then [r] = [int64]([uint64](a) / bv) end
        in [r] end
    end },
    [0x81] = { emit = function(a, b)                                               -- rem_s
        local r = symbol(int64, "rem_s_r")
        return quote
            var [r] = [int64](0)
            var av, bv = [int64](a), [int64](b)
            if bv ~= 0 and bv ~= -1 then [r] = av % bv end
        in [r] end
    end },
    [0x82] = { emit = function(a, b)                                               -- rem_u
        local r = symbol(int64, "rem_u_r")
        return quote
            var [r] = [int64](0)
            var bv = [uint64](b)
            if bv ~= 0 then [r] = [int64]([uint64](a) % bv) end
        in [r] end
    end },
    [0x83] = { emit = function(a, b) return `[int64]([uint64](a) and [uint64](b)) end },
    [0x84] = { emit = function(a, b) return `[int64]([uint64](a) or [uint64](b)) end },
    [0x85] = { emit = function(a, b) return `[int64]([uint64](a) ^ [uint64](b)) end },
    [0x86] = { emit = function(a, b) return `[int64]([uint64](a) << ([uint64](b) and 63)) end }, -- shl
    [0x87] = { emit = function(a, b) return `[int64](a) >> ([uint64](b) and 63) end },       -- shr_s
    [0x88] = { emit = function(a, b) return `[int64]([uint64](a) >> ([uint64](b) and 63)) end }, -- shr_u
    [0x89] = { emit = function(a, b)                                                 -- rotl
        return quote
            var ua = [uint64](a)
            var c = [uint64](b) and 63
        in
            [int64]((ua << c) or (ua >> (64 - c)))
        end
    end },
    [0x8A] = { emit = function(a, b)                                                 -- rotr
        return quote
            var ua = [uint64](a)
            var c = [uint64](b) and 63
        in
            [int64]((ua >> c) or (ua << (64 - c)))
        end
    end },
}, int64)

-- i64 unary ops
local terra i64_clz(x : int64) : int64
    if x == 0 then return 64 end
    var n : int64 = 0
    var u = [uint64](x)
    if (u and 0xFFFFFFFF00000000ULL) == 0 then n = n + 32; u = u << 32 end
    if (u and 0xFFFF000000000000ULL) == 0 then n = n + 16; u = u << 16 end
    if (u and 0xFF00000000000000ULL) == 0 then n = n + 8;  u = u << 8  end
    if (u and 0xF000000000000000ULL) == 0 then n = n + 4;  u = u << 4  end
    if (u and 0xC000000000000000ULL) == 0 then n = n + 2;  u = u << 2  end
    if (u and 0x8000000000000000ULL) == 0 then n = n + 1 end
    return n
end

local terra i64_ctz(x : int64) : int64
    if x == 0 then return 64 end
    var n : int64 = 0
    var u = [uint64](x)
    if (u and 0x00000000FFFFFFFFULL) == 0 then n = n + 32; u = u >> 32 end
    if (u and 0x000000000000FFFFULL) == 0 then n = n + 16; u = u >> 16 end
    if (u and 0x00000000000000FFULL) == 0 then n = n + 8;  u = u >> 8  end
    if (u and 0x000000000000000FULL) == 0 then n = n + 4;  u = u >> 4  end
    if (u and 0x0000000000000003ULL) == 0 then n = n + 2;  u = u >> 2  end
    if (u and 0x0000000000000001ULL) == 0 then n = n + 1 end
    return n
end

local terra i64_popcnt(x : int64) : int64
    var u = [uint64](x)
    u = u - ((u >> 1) and 0x5555555555555555ULL)
    u = (u and 0x3333333333333333ULL) + ((u >> 2) and 0x3333333333333333ULL)
    u = (u + (u >> 4)) and 0x0F0F0F0F0F0F0F0FULL
    return [int64]((u * 0x0101010101010101ULL) >> 56)
end

make_unop_handlers({
    [0x79] = { emit = function(a) return `i64_clz(a) end },
    [0x7A] = { emit = function(a) return `i64_ctz(a) end },
    [0x7B] = { emit = function(a) return `i64_popcnt(a) end },
}, int64)

-- i64 test/compare ops
make_testop_handlers({
    [0x50] = { emit = function(a) return `a == [int64](0) end },  -- eqz
})

make_compare_handlers({
    [0x51] = { emit = function(a, b) return `[int64](a) == [int64](b) end },
    [0x52] = { emit = function(a, b) return `[int64](a) ~= [int64](b) end },
    [0x53] = { emit = function(a, b) return `[int64](a) < [int64](b) end },
    [0x54] = { emit = function(a, b) return `[uint64](a) < [uint64](b) end },
    [0x55] = { emit = function(a, b) return `[int64](a) > [int64](b) end },
    [0x56] = { emit = function(a, b) return `[uint64](a) > [uint64](b) end },
    [0x57] = { emit = function(a, b) return `[int64](a) <= [int64](b) end },
    [0x58] = { emit = function(a, b) return `[uint64](a) <= [uint64](b) end },
    [0x59] = { emit = function(a, b) return `[int64](a) >= [int64](b) end },
    [0x5A] = { emit = function(a, b) return `[uint64](a) >= [uint64](b) end },
})

-- f32 binary ops
local Cmath = terralib.includec("math.h")

-- WASM-compliant min/max: propagate NaN (C fmin/fmax return non-NaN instead)
local terra wasm_fminf(a: float, b: float): float
    if a ~= a then return a end
    if b ~= b then return b end
    return Cmath.fminf(a, b)
end
local terra wasm_fmaxf(a: float, b: float): float
    if a ~= a then return a end
    if b ~= b then return b end
    return Cmath.fmaxf(a, b)
end
local terra wasm_fmin(a: double, b: double): double
    if a ~= a then return a end
    if b ~= b then return b end
    return Cmath.fmin(a, b)
end
local terra wasm_fmax(a: double, b: double): double
    if a ~= a then return a end
    if b ~= b then return b end
    return Cmath.fmax(a, b)
end

make_binop_handlers({
    [0x92] = { emit = function(a, b) return `[float](a) + [float](b) end },
    [0x93] = { emit = function(a, b) return `[float](a) - [float](b) end },
    [0x94] = { emit = function(a, b) return `[float](a) * [float](b) end },
    [0x95] = { emit = function(a, b) return `[float](a) / [float](b) end },
    [0x96] = { emit = function(a, b) return `wasm_fminf(a, b) end },  -- min
    [0x97] = { emit = function(a, b) return `wasm_fmaxf(a, b) end },  -- max
    [0x98] = { emit = function(a, b) return `Cmath.copysignf(a, b) end },
}, float)

-- f32 unary ops
make_unop_handlers({
    [0x8B] = { emit = function(a) return `Cmath.fabsf(a) end },
    [0x8C] = { emit = function(a) return `-[float](a) end },
    [0x8D] = { emit = function(a) return `Cmath.ceilf(a) end },
    [0x8E] = { emit = function(a) return `Cmath.floorf(a) end },
    [0x8F] = { emit = function(a) return `Cmath.truncf(a) end },
    [0x90] = { emit = function(a) return `Cmath.nearbyintf(a) end },  -- nearest
    [0x91] = { emit = function(a) return `Cmath.sqrtf(a) end },
}, float)

-- f32 comparisons
make_compare_handlers({
    [0x5B] = { emit = function(a, b) return `[float](a) == [float](b) end },
    [0x5C] = { emit = function(a, b) return `[float](a) ~= [float](b) end },
    [0x5D] = { emit = function(a, b) return `[float](a) < [float](b) end },
    [0x5E] = { emit = function(a, b) return `[float](a) > [float](b) end },
    [0x5F] = { emit = function(a, b) return `[float](a) <= [float](b) end },
    [0x60] = { emit = function(a, b) return `[float](a) >= [float](b) end },
})

-- f64 binary ops
make_binop_handlers({
    [0xA0] = { emit = function(a, b) return `[double](a) + [double](b) end },
    [0xA1] = { emit = function(a, b) return `[double](a) - [double](b) end },
    [0xA2] = { emit = function(a, b) return `[double](a) * [double](b) end },
    [0xA3] = { emit = function(a, b) return `[double](a) / [double](b) end },
    [0xA4] = { emit = function(a, b) return `wasm_fmin(a, b) end },
    [0xA5] = { emit = function(a, b) return `wasm_fmax(a, b) end },
    [0xA6] = { emit = function(a, b) return `Cmath.copysign(a, b) end },
}, double)

-- f64 unary ops
make_unop_handlers({
    [0x99] = { emit = function(a) return `Cmath.fabs(a) end },
    [0x9A] = { emit = function(a) return `-[double](a) end },
    [0x9B] = { emit = function(a) return `Cmath.ceil(a) end },
    [0x9C] = { emit = function(a) return `Cmath.floor(a) end },
    [0x9D] = { emit = function(a) return `Cmath.trunc(a) end },
    [0x9E] = { emit = function(a) return `Cmath.nearbyint(a) end },
    [0x9F] = { emit = function(a) return `Cmath.sqrt(a) end },
}, double)

-- f64 comparisons
make_compare_handlers({
    [0x61] = { emit = function(a, b) return `[double](a) == [double](b) end },
    [0x62] = { emit = function(a, b) return `[double](a) ~= [double](b) end },
    [0x63] = { emit = function(a, b) return `[double](a) < [double](b) end },
    [0x64] = { emit = function(a, b) return `[double](a) > [double](b) end },
    [0x65] = { emit = function(a, b) return `[double](a) <= [double](b) end },
    [0x66] = { emit = function(a, b) return `[double](a) >= [double](b) end },
})

-- Conversions
make_convert_handlers({
    -- i32 conversions
    [0xA7] = { emit = function(a) return `[int32](a) end },                 -- i32.wrap_i64
    [0xA8] = { emit = function(a) return `[int32]([float](a)) end },        -- i32.trunc_f32_s
    [0xA9] = { emit = function(a) return `[int32]([uint32]([float](a))) end }, -- i32.trunc_f32_u
    [0xAA] = { emit = function(a) return `[int32]([double](a)) end },       -- i32.trunc_f64_s
    [0xAB] = { emit = function(a) return `[int32]([uint32]([double](a))) end }, -- i32.trunc_f64_u

    -- i64 conversions
    [0xAC] = { emit = function(a) return `[int64]([int32](a)) end },        -- i64.extend_i32_s
    [0xAD] = { emit = function(a) return `[int64]([uint32](a)) end },       -- i64.extend_i32_u
    [0xAE] = { emit = function(a) return `[int64]([float](a)) end },        -- i64.trunc_f32_s
    [0xAF] = { emit = function(a) return `[int64]([uint64]([float](a))) end }, -- i64.trunc_f32_u
    [0xB0] = { emit = function(a) return `[int64]([double](a)) end },       -- i64.trunc_f64_s
    [0xB1] = { emit = function(a) return `[int64]([uint64]([double](a))) end }, -- i64.trunc_f64_u

    -- f32 conversions
    [0xB2] = { emit = function(a) return `[float]([int32](a)) end },        -- f32.convert_i32_s
    [0xB3] = { emit = function(a) return `[float]([uint32](a)) end },       -- f32.convert_i32_u
    [0xB4] = { emit = function(a) return `[float]([int64](a)) end },        -- f32.convert_i64_s
    [0xB5] = { emit = function(a) return `[float]([uint64](a)) end },       -- f32.convert_i64_u
    [0xB6] = { emit = function(a) return `[float]([double](a)) end },       -- f32.demote_f64

    -- f64 conversions
    [0xB7] = { emit = function(a) return `[double]([int32](a)) end },       -- f64.convert_i32_s
    [0xB8] = { emit = function(a) return `[double]([uint32](a)) end },      -- f64.convert_i32_u
    [0xB9] = { emit = function(a) return `[double]([int64](a)) end },       -- f64.convert_i64_s
    [0xBA] = { emit = function(a) return `[double]([uint64](a)) end },      -- f64.convert_i64_u
    [0xBB] = { emit = function(a) return `[double]([float](a)) end },       -- f64.promote_f32

    -- Reinterpret (need a temp variable because & requires lvalue)
    [0xBC] = { emit = function(a) return quote var t = [float](a) in @[&int32](&t) end end },    -- i32.reinterpret_f32
    [0xBD] = { emit = function(a) return quote var t = [double](a) in @[&int64](&t) end end },   -- i64.reinterpret_f64
    [0xBE] = { emit = function(a) return quote var t = [int32](a) in @[&float](&t) end end },    -- f32.reinterpret_i32
    [0xBF] = { emit = function(a) return quote var t = [int64](a) in @[&double](&t) end end },   -- f64.reinterpret_i64
})

-- Sign-extension ops (0xC0-0xC4) -- post-MVP but commonly used
make_convert_handlers({
    [0xC0] = { emit = function(a) return `[int32]([int8](a)) end },         -- i32.extend8_s
    [0xC1] = { emit = function(a) return `[int32]([int16](a)) end },        -- i32.extend16_s
    [0xC2] = { emit = function(a) return `[int64]([int8](a)) end },         -- i64.extend8_s
    [0xC3] = { emit = function(a) return `[int64]([int16](a)) end },        -- i64.extend16_s
    [0xC4] = { emit = function(a) return `[int64]([int32](a)) end },        -- i64.extend32_s
})

------------------------------------------------------------------------
-- 0xFC prefix: saturating truncations + bulk memory
------------------------------------------------------------------------

local Cmath_sat = terralib.includec("math.h")

local sat_handlers = {
    -- i32.trunc_sat_f32_s
    [0] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int32, "sat")
        stmts:insert(quote
            var v = [float](a)
            var [s] = [int32](0)
            if v ~= v then s = 0
            elseif v >= 2147483647.0f then s = 2147483647
            elseif v <= -2147483648.0f then s = -2147483648
            else s = [int32](v) end
        end)
        stk.push(`[s])
    end,
    -- i32.trunc_sat_f32_u
    [1] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int32, "sat")
        stmts:insert(quote
            var v = [float](a)
            var [s] = [int32](0)
            if v ~= v then s = 0
            elseif v >= 4294967295.0f then s = [int32](0xFFFFFFFFU)
            elseif v <= 0.0f then s = 0
            else s = [int32]([uint32](v)) end
        end)
        stk.push(`[s])
    end,
    -- i32.trunc_sat_f64_s
    [2] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int32, "sat")
        stmts:insert(quote
            var v = [double](a)
            var [s] = [int32](0)
            if v ~= v then s = 0
            elseif v >= 2147483647.0 then s = 2147483647
            elseif v <= -2147483648.0 then s = -2147483648
            else s = [int32](v) end
        end)
        stk.push(`[s])
    end,
    -- i32.trunc_sat_f64_u
    [3] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int32, "sat")
        stmts:insert(quote
            var v = [double](a)
            var [s] = [int32](0)
            if v ~= v then s = 0
            elseif v >= 4294967295.0 then s = [int32](0xFFFFFFFFU)
            elseif v <= 0.0 then s = 0
            else s = [int32]([uint32](v)) end
        end)
        stk.push(`[s])
    end,
    -- i64.trunc_sat_f32_s
    [4] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int64, "sat")
        stmts:insert(quote
            var v = [float](a)
            var [s] = [int64](0)
            if v ~= v then s = 0
            elseif v >= 9223372036854775807.0f then s = 9223372036854775807LL
            elseif v <= -9223372036854775808.0f then s = -9223372036854775807LL - 1
            else s = [int64](v) end
        end)
        stk.push(`[s])
    end,
    -- i64.trunc_sat_f32_u
    [5] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int64, "sat")
        stmts:insert(quote
            var v = [float](a)
            var [s] = [int64](0)
            if v ~= v then s = 0
            elseif v <= 0.0f then s = 0
            elseif v >= 18446744073709551615.0f then s = [int64](0xFFFFFFFFFFFFFFFFULL)
            else s = [int64]([uint64](v)) end
        end)
        stk.push(`[s])
    end,
    -- i64.trunc_sat_f64_s
    [6] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int64, "sat")
        stmts:insert(quote
            var v = [double](a)
            var [s] = [int64](0)
            if v ~= v then s = 0
            elseif v >= 9223372036854775807.0 then s = 9223372036854775807LL
            elseif v <= -9223372036854775808.0 then s = -9223372036854775807LL - 1
            else s = [int64](v) end
        end)
        stk.push(`[s])
    end,
    -- i64.trunc_sat_f64_u
    [7] = function(stk, stmts)
        local a = stk.pop()
        local s = symbol(int64, "sat")
        stmts:insert(quote
            var v = [double](a)
            var [s] = [int64](0)
            if v ~= v then s = 0
            elseif v <= 0.0 then s = 0
            elseif v >= 18446744073709551615.0 then s = [int64](0xFFFFFFFFFFFFFFFFULL)
            else s = [int64]([uint64](v)) end
        end)
        stk.push(`[s])
    end,
    -- 8 = memory.init (skip for now)
    -- 9 = data.drop (skip for now)
    -- 10 = memory.copy
    [10] = function(stk, stmts, mem, mem_size)
        local n = stk.pop()
        local src = stk.pop()
        local dst = stk.pop()
        stmts:insert(quote
            Cstr.memmove(mem + [uint64]([uint32](dst)),
                         mem + [uint64]([uint32](src)), [uint32](n))
        end)
    end,
    -- 11 = memory.fill
    [11] = function(stk, stmts, mem, mem_size)
        local n = stk.pop()
        local val = stk.pop()
        local dst = stk.pop()
        stmts:insert(quote
            Cstr.memset(mem + [uint64]([uint32](dst)), [int32](val), [uint32](n))
        end)
    end,
}

opcode_handlers[0xFC] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local sub; sub, ip = decode_uleb128(bc, ip)
    local handler = sat_handlers[sub]
    if not handler then
        error(string.format("unimplemented 0xFC sub-opcode %d at position %d", sub, ip))
    end
    -- memory.copy and memory.fill have trailing 0x00 0x00 bytes (memory index)
    if sub == 10 then
        ip = ip + 2  -- skip two 0x00 memory indices
        handler(stk, stmts, mem, mem_size)
    elseif sub == 11 then
        ip = ip + 1  -- skip one 0x00 memory index
        handler(stk, stmts, mem, mem_size)
    else
        handler(stk, stmts)
    end
    return ip
end

------------------------------------------------------------------------
-- Opcode Handlers: Control Flow
------------------------------------------------------------------------

-- 0x02: block
opcode_handlers[0x02] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local param_types, result_types
    param_types, result_types, ip = decode_block_type(bc, ip, module_env.mod)

    local break_label = label("block_break")
    local result_syms = alloc_result_syms(stmts, result_types, "block_res")

    local block = make_block_entry("block", break_label,
                                    result_types, param_types,
                                    stk.save() - #param_types)
    block.result_syms = result_syms
    block_stack[#block_stack + 1] = block
    return ip
end

-- 0x03: loop
opcode_handlers[0x03] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local param_types, result_types
    param_types, result_types, ip = decode_block_type(bc, ip, module_env.mod)

    local continue_label = label("loop_continue")
    local break_label = label("loop_break")
    local result_syms = alloc_result_syms(stmts, result_types, "loop_res")

    -- Loop params: pop from stack, create param symbols, push back after label
    local param_syms = {}
    if #param_types > 0 then
        for i, T in ipairs(param_types) do
            param_syms[i] = symbol(T, "loop_param_" .. i)
            stmts:insert(quote var [param_syms[i]] end)
        end
        local vals = {}
        for i = #param_types, 1, -1 do
            vals[i] = stk.pop()
        end
        for i, sym in ipairs(param_syms) do
            stmts:insert(quote [sym] = [vals[i]] end)
        end
    end

    local block = make_block_entry("loop", continue_label,
                                    result_types, param_types,
                                    stk.save())
    block.result_syms = result_syms
    block.break_label = break_label
    block.param_syms = param_syms
    block_stack[#block_stack + 1] = block

    stmts:insert(quote ::[continue_label]:: end)

    -- Push param syms onto stack for loop body
    for _, sym in ipairs(param_syms) do
        stk.push(`[sym])
    end

    return ip
end

-- 0x04: if
opcode_handlers[0x04] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local param_types, result_types
    param_types, result_types, ip = decode_block_type(bc, ip, module_env.mod)
    local cond = stk.pop()

    local end_label = label("if_end")
    local else_label = label("if_else")

    local result_syms = alloc_result_syms(stmts, result_types, "if_res")

    -- If-with-params: save params to syms so else-branch can use them too
    local param_syms = {}
    if #param_types > 0 then
        for i, T in ipairs(param_types) do
            param_syms[i] = symbol(T, "if_param_" .. i)
        end
        local vals = {}
        for i = #param_types, 1, -1 do
            vals[i] = stk.pop()
        end
        for i, sym in ipairs(param_syms) do
            stmts:insert(quote var [sym] = [vals[i]] end)
        end
    end

    -- For if-without-else: init result_syms from param_syms so the
    -- false path passes params through as results
    local n_init = math.min(#param_syms, #result_syms)
    for i = 1, n_init do
        stmts:insert(quote [result_syms[i]] = [param_syms[i]] end)
    end

    local block = make_block_entry("if", end_label,
                                    result_types, param_types, stk.save())
    block.else_label = else_label
    block.has_else = false
    block.result_syms = result_syms
    block.param_syms = param_syms
    block_stack[#block_stack + 1] = block

    stmts:insert(quote
        if [cond] == 0 then goto [else_label] end
    end)

    -- Push params for the then-branch
    for _, sym in ipairs(param_syms) do
        stk.push(`[sym])
    end

    return ip
end

-- 0x05: else
opcode_handlers[0x05] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local block = block_stack[#block_stack]
    block.has_else = true

    if #block.result_syms > 0 and stk.depth() > block.stack_depth then
        assign_results_from_stack(stk, stmts, block.result_syms)
    end

    stk.restore(block.stack_depth)
    stmts:insert(quote goto [block.label] end)
    stmts:insert(quote ::[block.else_label]:: end)

    -- Re-push params for else-branch
    if block.param_syms then
        for _, sym in ipairs(block.param_syms) do
            stk.push(`[sym])
        end
    end

    return ip
end

-- 0x0B: end
opcode_handlers[0x0B] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    if #block_stack == 0 then
        return ip
    end

    local block = block_stack[#block_stack]
    block_stack[#block_stack] = nil

    if #block.result_syms > 0 and stk.depth() > block.stack_depth then
        assign_results_from_stack(stk, stmts, block.result_syms)
    end

    stk.restore(block.stack_depth)

    if block.kind == "block" or block.kind == "if" then
        stmts:insert(quote ::[block.label]:: end)
        if block.kind == "if" and not block.has_else then
            stmts:insert(quote ::[block.else_label]:: end)
        end
    elseif block.kind == "loop" then
        if block.break_label then
            stmts:insert(quote ::[block.break_label]:: end)
        end
    end

    push_result_syms(stk, block.result_syms)

    return ip
end

-- 0x0C: br
opcode_handlers[0x0C] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local depth; depth, ip = decode_uleb128(bc, ip)
    emit_branch(stk, stmts, block_stack, depth)
    return ip
end

-- 0x0D: br_if
opcode_handlers[0x0D] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local depth; depth, ip = decode_uleb128(bc, ip)
    local cond = stk.pop()
    local target = block_stack[#block_stack - depth]

    local target_syms, n
    if target.kind == "loop" then
        target_syms = target.param_syms or {}
        n = #(target.param_types or {})
    else
        target_syms = target.result_syms
        n = #target.result_syms
    end

    if n > 0 and #target_syms > 0 and stk.depth() > target.stack_depth then
        local assigns = terralib.newlist()
        for i = 1, n do
            local val = stk.peek_at(n - i)
            assigns:insert(quote [target_syms[i]] = [val] end)
        end
        stmts:insert(quote
            if [cond] ~= 0 then
                [assigns]
                goto [target.label]
            end
        end)
    else
        stmts:insert(quote
            if [cond] ~= 0 then goto [target.label] end
        end)
    end
    return ip
end

-- 0x0E: br_table
opcode_handlers[0x0E] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local count; count, ip = decode_uleb128(bc, ip)
    local targets = {}
    for i = 1, count do
        targets[i], ip = decode_uleb128(bc, ip)
    end
    local default_depth; default_depth, ip = decode_uleb128(bc, ip)

    local index = stk.pop()
    local idx_sym = symbol(int32, "br_idx")
    stmts:insert(quote var [idx_sym] = [index] end)

    local function emit_table_branch(target_depth)
        local target = block_stack[#block_stack - target_depth]
        local target_syms, n
        if target.kind == "loop" then
            target_syms = target.param_syms or {}
            n = #(target.param_types or {})
        else
            target_syms = target.result_syms
            n = #target.result_syms
        end
        if n > 0 and #target_syms > 0 and stk.depth() > target.stack_depth then
            local assigns = terralib.newlist()
            for i = 1, n do
                assigns:insert(quote [target_syms[i]] = [stk.peek_at(n - i)] end)
            end
            return quote [assigns] goto [target.label] end
        else
            return quote goto [target.label] end
        end
    end

    for i, depth in ipairs(targets) do
        stmts:insert(quote
            if [idx_sym] == [i - 1] then [emit_table_branch(depth)] end
        end)
    end

    stmts:insert(emit_table_branch(default_depth))
    return ip
end

-- 0x0F: return
opcode_handlers[0x0F] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    -- Return is equivalent to br to the outermost (function-level) block
    local depth = #block_stack - 1
    emit_branch(stk, stmts, block_stack, depth)
    return ip
end

------------------------------------------------------------------------
-- Opcode Handlers: Function Calls
------------------------------------------------------------------------

-- 0x10: call
opcode_handlers[0x10] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local func_idx; func_idx, ip = decode_uleb128(bc, ip)
    local target = module_env.resolve_function(func_idx)
    local ftype = target.type

    local args = terralib.newlist()
    for i = #ftype.params, 1, -1 do
        args:insert(1, stk.pop())
    end

    if #ftype.results == 0 then
        stmts:insert(quote [target.fn]([args]) end)
    elseif #ftype.results == 1 then
        local result_sym = symbol(ftype.results[1], "call_result")
        stmts:insert(quote
            var [result_sym] = [target.fn]([args])
        end)
        stk.push(`[result_sym])
    else
        local ret_type = make_ret_type(ftype.results)
        local ret_sym = symbol(ret_type, "call_ret")
        stmts:insert(quote var [ret_sym] = [target.fn]([args]) end)
        for i = 1, #ftype.results do
            local field = "_" .. (i - 1)
            local val_sym = symbol(ftype.results[i], "call_res_" .. i)
            stmts:insert(quote var [val_sym] = [ret_sym].[field] end)
            stk.push(`[val_sym])
        end
    end

    return ip
end

-- 0x11: call_indirect
opcode_handlers[0x11] = function(stk, stmts, locals, bc, ip, mem,
                                  mem_size, globals, fn_table,
                                  block_stack, module_env)
    local type_idx; type_idx, ip = decode_uleb128(bc, ip)
    local table_idx; table_idx, ip = decode_uleb128(bc, ip)
    local table_sym = module_env.fn_tables and module_env.fn_tables[table_idx + 1] or nil
    assert(table_sym ~= nil, "call_indirect references unknown table index " .. tostring(table_idx))

    local ftype = module_env.mod.types[type_idx + 1]

    -- Build Terra function pointer type
    local param_types = terralib.newlist()
    for _, T in ipairs(ftype.params) do param_types:insert(T) end
    local ret_type = make_ret_type(ftype.results) or terralib.types.unit
    local FnPtrType = param_types -> ret_type

    local idx = stk.pop()

    local args = terralib.newlist()
    for i = #ftype.params, 1, -1 do
        args:insert(1, stk.pop())
    end

    local fn_ptr_sym = symbol(&opaque, "indirect_fn")
    stmts:insert(quote var [fn_ptr_sym] = [table_sym][ [idx] ] end)

    if #ftype.results == 0 then
        stmts:insert(quote
            ([FnPtrType]([fn_ptr_sym]))([args])
        end)
    elseif #ftype.results == 1 then
        local result_sym = symbol(ftype.results[1], "indirect_result")
        stmts:insert(quote
            var [result_sym] = ([FnPtrType]([fn_ptr_sym]))([args])
        end)
        stk.push(`[result_sym])
    else
        local ret_sym = symbol(ret_type, "indirect_ret")
        stmts:insert(quote
            var [ret_sym] = ([FnPtrType]([fn_ptr_sym]))([args])
        end)
        for i = 1, #ftype.results do
            local field = "_" .. (i - 1)
            local val_sym = symbol(ftype.results[i], "indirect_res_" .. i)
            stmts:insert(quote var [val_sym] = [ret_sym].[field] end)
            stk.push(`[val_sym])
        end
    end

    return ip
end

------------------------------------------------------------------------
-- Opcode Handlers: Memory
------------------------------------------------------------------------

local function make_load_handler(opcode, result_type, load_type, width)
    opcode_handlers[opcode] = function(stk, stmts, locals, bc, ip,
                                        mem, mem_size, ...)
        local align; align, ip = decode_uleb128(bc, ip)
        local offset; offset, ip = decode_uleb128(bc, ip)
        local addr = stk.pop()

        local ea = `mem + [uint64]([uint32](addr)) + [uint64](offset)
        local loaded = symbol(result_type, "load")
        stmts:insert(quote
            var [loaded] = [result_type](@[&load_type]([ea]))
        end)
        stk.push(`[loaded])
        return ip
    end
end

local function make_store_handler(opcode, value_type, store_type, width)
    opcode_handlers[opcode] = function(stk, stmts, locals, bc, ip,
                                        mem, mem_size, ...)
        local align; align, ip = decode_uleb128(bc, ip)
        local offset; offset, ip = decode_uleb128(bc, ip)
        local val = stk.pop()
        local addr = stk.pop()

        local ea = `mem + [uint64]([uint32](addr)) + [uint64](offset)
        stmts:insert(quote
            @[&store_type]([ea]) = [store_type](val)
        end)
        return ip
    end
end

-- i32 loads
make_load_handler(0x28, int32,  int32,  4)  -- i32.load
make_load_handler(0x2C, int32,  int8,   1)  -- i32.load8_s
make_load_handler(0x2D, int32,  uint8,  1)  -- i32.load8_u
make_load_handler(0x2E, int32,  int16,  2)  -- i32.load16_s
make_load_handler(0x2F, int32,  uint16, 2)  -- i32.load16_u

-- i64 loads
make_load_handler(0x29, int64,  int64,  8)  -- i64.load
make_load_handler(0x30, int64,  int8,   1)  -- i64.load8_s
make_load_handler(0x31, int64,  uint8,  1)  -- i64.load8_u
make_load_handler(0x32, int64,  int16,  2)  -- i64.load16_s
make_load_handler(0x33, int64,  uint16, 2)  -- i64.load16_u
make_load_handler(0x34, int64,  int32,  4)  -- i64.load32_s
make_load_handler(0x35, int64,  uint32, 4)  -- i64.load32_u

-- f32/f64 loads
make_load_handler(0x2A, float,  float,  4)  -- f32.load
make_load_handler(0x2B, double, double, 8)  -- f64.load

-- Stores
make_store_handler(0x36, int32,  int32,  4)  -- i32.store
make_store_handler(0x37, int64,  int64,  8)  -- i64.store
make_store_handler(0x38, float,  float,  4)  -- f32.store
make_store_handler(0x39, double, double, 8)  -- f64.store
make_store_handler(0x3A, int32,  int8,   1)  -- i32.store8
make_store_handler(0x3B, int32,  int16,  2)  -- i32.store16
make_store_handler(0x3C, int64,  int8,   1)  -- i64.store8
make_store_handler(0x3D, int64,  int16,  2)  -- i64.store16
make_store_handler(0x3E, int64,  int32,  4)  -- i64.store32

-- 0x3F: memory.size
opcode_handlers[0x3F] = function(stk, stmts, locals, bc, ip,
                                  mem, mem_size, globals, fn_table,
                                  block_stack, module_env)
    local memidx; memidx, ip = decode_uleb128(bc, ip)
    local mem_size_sym = module_env.mem_sizes[memidx + 1] or module_env.mem_size
    local pages = symbol(int32, "mem_pages")
    stmts:insert(quote
        var [pages] = [int32]([mem_size_sym] / 65536)
    end)
    stk.push(`[pages])
    return ip
end

-- 0x40: memory.grow
opcode_handlers[0x40] = function(stk, stmts, locals, bc, ip,
                                  mem, mem_size, globals, fn_table,
                                  block_stack, module_env)
    local memidx; memidx, ip = decode_uleb128(bc, ip)
    local mem_sym = module_env.memory_syms[memidx + 1] or module_env.memory_sym
    local mem_size_sym = module_env.mem_sizes[memidx + 1] or module_env.mem_size
    local mem_max_sym = module_env.mem_maxes[memidx + 1] or module_env.mem_max
    local delta = stk.pop()
    local old_pages = symbol(int32, "old_pages")
    local delta_u = symbol(uint32, "delta_u")
    local delta_i64 = symbol(int64, "delta_i64")
    stmts:insert(quote
        var [delta_u] = [uint32]([delta])
        var [delta_i64] = [int64]([delta_u])
        var [old_pages] = [int32]([mem_size_sym] / 65536)
        var grow_ok = true
        if [mem_max_sym] >= 0 and ([int64]([old_pages]) + [delta_i64]) > [mem_max_sym] then
            grow_ok = false
        end

        if not grow_ok then
            [old_pages] = -1
        elseif [delta_i64] == 0 then
            -- No-op grow must succeed and keep memory pointer unchanged.
        else
            var new_size = [mem_size_sym] + [delta_i64] * 65536
            var new_ptr = [&uint8](C.realloc([mem_sym], [uint64](new_size)))
            if new_ptr == nil then
                [old_pages] = -1
            else
                -- Zero the new pages
                Cstr.memset([&opaque](new_ptr + [mem_size_sym]), 0, [uint64]([delta_i64]) * 65536)
                [mem_sym] = new_ptr
                [mem_size_sym] = new_size
            end
        end
    end)
    stk.push(`[old_pages])
    return ip
end

------------------------------------------------------------------------
-- Module Linking
------------------------------------------------------------------------

local function const_expr_i32_lua(expr)
    if type(expr) ~= "table" or type(expr.ops) ~= "table" then
        return nil
    end
    local stack = {}
    for _, e in ipairs(expr.ops) do
        if e.op == 0x41 then
            stack[#stack + 1] = e.value
        elseif e.op == 0x6A or e.op == 0x6B or e.op == 0x6C then
            if #stack < 2 then return nil end
            local b = stack[#stack]; stack[#stack] = nil
            local a = stack[#stack]; stack[#stack] = nil
            if e.op == 0x6A then
                stack[#stack + 1] = bit.tobit(a + b)
            elseif e.op == 0x6B then
                stack[#stack + 1] = bit.tobit(a - b)
            else
                stack[#stack + 1] = bit.tobit(a * b)
            end
        else
            return nil
        end
    end
    if #stack ~= 1 then return nil end
    return stack[1]
end

local function emit_const_expr(module_env, expr)
    assert(type(expr) == "table" and type(expr.ops) == "table", "invalid const expr")
    local stack = {}
    for _, e in ipairs(expr.ops) do
        if e.op == 0x41 then
            stack[#stack + 1] = `[int32]([e.value])
        elseif e.op == 0x42 then
            stack[#stack + 1] = `[int64]([e.value])
        elseif e.op == 0x43 then
            stack[#stack + 1] = `[float]([e.value])
        elseif e.op == 0x44 then
            stack[#stack + 1] = `[double]([e.value])
        elseif e.op == 0x23 then
            local src = module_env.globals[e.index]
            assert(src ~= nil, "const expr global.get references unknown global")
            stack[#stack + 1] = `[src.sym]
        elseif e.op == 0xD0 then
            stack[#stack + 1] = `([&opaque](nil))
        elseif e.op == 0xD2 then
            local fn_entry = module_env.functions[e.index]
            assert(fn_entry and fn_entry.fn, "const expr ref.func references unknown function")
            stack[#stack + 1] = `[&opaque]([fn_entry.fn])
        elseif e.op == 0x6A or e.op == 0x6B or e.op == 0x6C
            or e.op == 0x7C or e.op == 0x7D or e.op == 0x7E then
            assert(#stack >= 2, "const expr stack underflow")
            local rhs = stack[#stack]; stack[#stack] = nil
            local lhs = stack[#stack]; stack[#stack] = nil
            if e.op == 0x6A then
                stack[#stack + 1] = `[int32]([lhs] + [rhs])
            elseif e.op == 0x6B then
                stack[#stack + 1] = `[int32]([lhs] - [rhs])
            elseif e.op == 0x6C then
                stack[#stack + 1] = `[int32]([lhs] * [rhs])
            elseif e.op == 0x7C then
                stack[#stack + 1] = `[int64]([lhs] + [rhs])
            elseif e.op == 0x7D then
                stack[#stack + 1] = `[int64]([lhs] - [rhs])
            else
                stack[#stack + 1] = `[int64]([lhs] * [rhs])
            end
        else
            error(string.format("unsupported const expr opcode 0x%02X", e.op))
        end
    end
    assert(#stack == 1, "const expr must produce one value")
    return stack[1]
end

local function init_memory(mod, module_env, host_functions)
    local mem_defs = {}
    for _, imp in ipairs(mod.imports) do
        if imp.kind == "memory" then
            local pages = imp.initial or 0
            local max_pages = (imp.maximum ~= nil) and imp.maximum or -1
            local host_key = imp.module .. "." .. imp.name
            local host_mem = host_functions and host_functions[host_key] or nil
            if type(host_mem) == "table" then
                if host_mem.initial ~= nil then pages = host_mem.initial end
                if host_mem.maximum ~= nil then max_pages = host_mem.maximum end
            end
            mem_defs[#mem_defs + 1] = { pages = pages, max_pages = max_pages }
        end
    end
    for _, m in ipairs(mod.memory) do
        mem_defs[#mem_defs + 1] = {
            pages = m.initial or 0,
            max_pages = (m.maximum ~= nil) and m.maximum or -1,
        }
    end

    if #mem_defs == 0 then
        module_env.memory_sym = global(&uint8)
        module_env.mem_size = global(int64)
        module_env.mem_max = global(int64)
        module_env.mem_max:set(-1)
        module_env.memory_syms = { module_env.memory_sym }
        module_env.mem_sizes = { module_env.mem_size }
        module_env.mem_maxes = { module_env.mem_max }
        return terra() end
    end

    local init_stmts = terralib.newlist()
    for i, def in ipairs(mem_defs) do
        local mem_ptr = global(&uint8)
        local mem_len = global(int64)
        local mem_max = global(int64)
        module_env.memory_syms[i] = mem_ptr
        module_env.mem_sizes[i] = mem_len
        module_env.mem_maxes[i] = mem_max
        local byte_size = def.pages * 65536
        local max_pages = def.max_pages
        init_stmts:insert(quote
            if [byte_size] == 0 then
                [mem_ptr] = nil
            else
                [mem_ptr] = [&uint8](C.calloc([byte_size], 1))
            end
            [mem_len] = [int64](byte_size)
            [mem_max] = [int64](max_pages)
        end)
    end

    -- Backward-compatible aliases to memory 0.
    module_env.memory_sym = module_env.memory_syms[1]
    module_env.mem_size = module_env.mem_sizes[1]
    module_env.mem_max = module_env.mem_maxes[1]

    for _, seg in ipairs(mod.datas) do
        if seg.mode == "active" then
            local mem_idx = (seg.mem_idx or 0) + 1
            local mem_ptr = module_env.memory_syms[mem_idx]
            if mem_ptr ~= nil then
                local data_bytes = seg.data
                local data_len = #data_bytes
                local data_arr = global(int8[data_len])
                local data_init = terralib.new(int8[data_len])
                for j = 1, data_len do
                    data_init[j - 1] = data_bytes:byte(j)
                end
                data_arr:set(data_init)
                local offset_expr = seg.offset and emit_const_expr(module_env, seg.offset) or `[int32](0)
                init_stmts:insert(quote
                    var off = [uint64]([uint32]([offset_expr]))
                    Cstr.memcpy([&opaque]([mem_ptr] + off), [&opaque](&data_arr), [data_len])
                end)
            end
        end
    end

    local init_fn = terra()
        [init_stmts]
    end
    return init_fn
end

local function create_module_env(mod)
    local env = {
        mod = mod,
        functions = {},
        globals = {},
        defined_globals = {},
        import_global_count = 0,
        memory_sym = nil,
        mem_size = nil,
        mem_max = nil,
        memory_syms = {},
        mem_sizes = {},
        mem_maxes = {},
        fn_table = nil,
        fn_tables = nil,
    }

    for i, g in ipairs(mod.globals) do
        env.defined_globals[i] = {
            sym = global(g.type),
            type = g.type,
            init = g.init,
            mutable = g.mutable,
        }
    end

    local import_count = 0
    for _, imp in ipairs(mod.imports) do
        if imp.kind == "function" then
            import_count = import_count + 1
        end
    end

    env.resolve_function = function(idx)
        return env.functions[idx + 1]
    end

    env.import_count = import_count
    return env
end

local function bind_imports(mod, module_env, host_functions)
    local fn_idx = 1
    for _, imp in ipairs(mod.imports) do
        if imp.kind == "function" then
            local ftype = mod.types[imp.type_idx]
            local host_fn = host_functions[imp.module .. "." .. imp.name]
            if not host_fn then
                error("unresolved import: " .. imp.module .. "." .. imp.name)
            end
            module_env.functions[fn_idx] = {
                fn = host_fn,
                type = ftype,
            }
            fn_idx = fn_idx + 1
        elseif imp.kind == "global" then
            -- Global import: host provides symbol
            local g = host_functions[imp.module .. "." .. imp.name]
            if g then
                module_env.globals[#module_env.globals + 1] = {
                    sym = g,
                    type = imp.type,
                    mutable = imp.mutable,
                }
                module_env.import_global_count = module_env.import_global_count + 1
            else
                error("unresolved import: " .. imp.module .. "." .. imp.name)
            end
        end
    end

    -- WASM global index space is [imports..., defined globals...]
    for _, g in ipairs(module_env.defined_globals) do
        module_env.globals[#module_env.globals + 1] = g
    end
    return fn_idx
end

local function sanitize_c_ident(name)
    local s = name:gsub("[^%w_]", "_")
    if s == "" then s = "_" end
    if s:match("^[0-9]") then s = "_" .. s end
    return s
end

local function terra_type_to_c(T)
    if T == int32 then return "int32_t" end
    if T == int64 then return "int64_t" end
    if T == float then return "float" end
    if T == double then return "double" end
    error("unsupported type for C ABI: " .. tostring(T))
end

local function ftype_to_ffi_fnptr(ftype)
    if #ftype.results > 1 then
        return nil, "multi-value functions are not supported in LuaJIT FFI signatures"
    end
    local ret = "void"
    if #ftype.results == 1 then
        ret = terra_type_to_c(ftype.results[1])
    end
    local params = {}
    for i, T in ipairs(ftype.params) do
        params[i] = terra_type_to_c(T)
    end
    return ret .. "(*)(" .. table.concat(params, ", ") .. ")"
end

local function resolve_function_type(mod, fn_index)
    local import_idx = 0
    for _, imp in ipairs(mod.imports) do
        if imp.kind == "function" then
            import_idx = import_idx + 1
            if import_idx == fn_index then
                return mod.types[imp.type_idx]
            end
        end
    end

    local local_idx = fn_index - import_idx
    local f = mod.funcs[local_idx]
    if not f then return nil end
    return mod.types[f.type_idx]
end

local function compile_opts_key(opts)
    local auto_wasi = opts.auto_wasi
    if auto_wasi == nil then auto_wasi = true end
    local auto_c_imports = opts.auto_c_imports and true or false
    local noopt = os.getenv("POT_NOOPT") == "1"
    return table.concat({
        "auto_wasi=", tostring(auto_wasi),
        ";auto_c_imports=", tostring(auto_c_imports),
        ";noopt=", tostring(noopt),
    })
end

local function host_functions_key(host_functions)
    local keys = {}
    for k, _ in pairs(host_functions or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)

    local parts = {}
    for _, k in ipairs(keys) do
        local v = host_functions[k]
        if k == "_wasi_args" and type(v) == "table" then
            local args = {}
            for i = 1, #v do
                args[i] = tostring(v[i])
            end
            parts[#parts + 1] = k .. "=[" .. table.concat(args, "\31") .. "]"
        else
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
    end
    return table.concat(parts, "\30")
end

local function instantiate_cache_key(wasm_bytes, host_functions, opts)
    return table.concat({
        wasm_bytes,
        "\29",
        compile_opts_key(opts or {}),
        "\29",
        host_functions_key(host_functions or {}),
    })
end

local function add_missing_c_imports(mod, host_functions, opts)
    local generated = {}
    local prefix = opts.import_prefix or "pot_import_"
    local used = {}

    local function unique_sym(base)
        local sym = base
        local n = 2
        while used[sym] do
            sym = base .. "_" .. n
            n = n + 1
        end
        used[sym] = true
        return sym
    end

    for _, imp in ipairs(mod.imports) do
        if imp.kind == "function" then
            local key = imp.module .. "." .. imp.name
            if not host_functions[key] then
                local ftype = mod.types[imp.type_idx]
                local param_types = terralib.newlist()
                for _, T in ipairs(ftype.params) do
                    param_types:insert(T)
                end
                local ret_type = make_ret_type(ftype.results) or terralib.types.unit
                if #ftype.results > 1 then
                    error("cannot auto-stub multi-value import for C ABI: " .. key)
                end
                local c_sym = unique_sym(
                    prefix .. sanitize_c_ident(imp.module) .. "__" .. sanitize_c_ident(imp.name))
                local extern_fn = terralib.externfunction(c_sym, param_types -> ret_type)
                host_functions[key] = extern_fn
                generated[#generated + 1] = {
                    key = key,
                    module = imp.module,
                    name = imp.name,
                    c_symbol = c_sym,
                    ftype = ftype,
                }
            end
        end
    end

    return generated
end

local function init_table(mod, module_env)
    if #mod.tables == 0 and #mod.elements == 0 then
        module_env.fn_table = nil
        module_env.fn_tables = {}
        return terra() end
    end

    local table_sizes = {}
    for i, tbl in ipairs(mod.tables) do
        table_sizes[i] = tbl.initial or 0
    end
    for _, elem in ipairs(mod.elements) do
        if elem.mode == "active" then
            local off = const_expr_i32_lua(elem.offset)
            if off then
                local tidx = (elem.table_idx or 0) + 1
                if table_sizes[tidx] == nil then
                    table_sizes[tidx] = 0
                end
                local needed = off + #elem.elems
                if needed > table_sizes[tidx] then table_sizes[tidx] = needed end
            end
        end
    end

    local fn_tables = {}
    local n_tables = 0
    for i, sz in ipairs(table_sizes) do
        fn_tables[i] = global((&opaque)[sz])
        n_tables = i
    end
    module_env.fn_tables = fn_tables
    module_env.fn_table = fn_tables[1]

    return terra()
        -- Zero init handled by global
    end
end

------------------------------------------------------------------------
-- WASI Preview 1
------------------------------------------------------------------------

local function make_wasi(mod, module_env, wasi_args)
    local mem = module_env.memory_sym
    local mem_size = module_env.mem_size
    local wasi = {}
    local P = "wasi_snapshot_preview1."

    -- fd_write(fd, iovs, iovs_len, nwritten) -> errno
    wasi[P .. "fd_write"] = terra(
        fd: int32, iovs_ptr: int32, iovs_len: int32, nwritten_ptr: int32
    ) : int32
        var total : int32 = 0
        for i = 0, iovs_len do
            var base = mem + [uint64]([uint32](iovs_ptr)) + [uint64](i) * 8
            var buf_off = @[&uint32](base)
            var buf_len = @[&uint32](base + 4)
            var written = Cunistd.write(fd, mem + [uint64](buf_off), buf_len)
            if written < 0 then return 29 end -- ENOSYS-ish
            total = total + [int32](written)
        end
        @[&int32](mem + [uint64]([uint32](nwritten_ptr))) = total
        return 0
    end

    -- fd_read(fd, iovs, iovs_len, nread) -> errno
    wasi[P .. "fd_read"] = terra(
        fd: int32, iovs_ptr: int32, iovs_len: int32, nread_ptr: int32
    ) : int32
        var total : int32 = 0
        for i = 0, iovs_len do
            var base = mem + [uint64]([uint32](iovs_ptr)) + [uint64](i) * 8
            var buf_off = @[&uint32](base)
            var buf_len = @[&uint32](base + 4)
            var n = Cunistd.read(fd, mem + [uint64](buf_off), buf_len)
            if n < 0 then return 29 end
            total = total + [int32](n)
            if n < [int64](buf_len) then break end
        end
        @[&int32](mem + [uint64]([uint32](nread_ptr))) = total
        return 0
    end

    -- fd_close(fd) -> errno
    wasi[P .. "fd_close"] = terra(fd: int32) : int32
        if Cunistd.close(fd) < 0 then return 8 end
        return 0
    end

    -- fd_seek(fd, offset, whence, newoffset_ptr) -> errno
    wasi[P .. "fd_seek"] = terra(
        fd: int32, offset: int64, whence: int32, newoffset_ptr: int32
    ) : int32
        var result = Cunistd.lseek(fd, offset, whence)
        if result < 0 then return 29 end
        @[&int64](mem + [uint64]([uint32](newoffset_ptr))) = result
        return 0
    end

    -- fd_fdstat_get(fd, buf) -> errno
    wasi[P .. "fd_fdstat_get"] = terra(fd: int32, buf_ptr: int32) : int32
        var base = mem + [uint64]([uint32](buf_ptr))
        -- fdstat: u8 filetype, u16 flags, u64 rights_base, u64 rights_inheriting
        Cstr.memset(base, 0, 24)
        if fd <= 2 then
            @[&uint8](base) = 2  -- CHARACTER_DEVICE
        else
            @[&uint8](base) = 4  -- REGULAR_FILE
        end
        return 0
    end

    -- fd_prestat_get(fd, buf) -> errno  (no preopened dirs)
    wasi[P .. "fd_prestat_get"] = terra(fd: int32, buf_ptr: int32) : int32
        return 8 -- EBADF
    end

    -- fd_prestat_dir_name(fd, path, len) -> errno
    wasi[P .. "fd_prestat_dir_name"] = terra(
        fd: int32, path_ptr: int32, path_len: int32
    ) : int32
        return 8 -- EBADF
    end

    -- proc_exit(code)
    wasi[P .. "proc_exit"] = terra(code: int32)
        C.exit(code)
    end

    -- args: bake Lua strings into Terra constants
    local n_args = #wasi_args
    local arg_strs = {}
    local total_buf = 0
    for i = 1, n_args do
        arg_strs[i] = wasi_args[i]
        total_buf = total_buf + #wasi_args[i] + 1  -- +1 for null terminator
    end

    -- args_sizes_get(argc_ptr, argv_buf_size_ptr) -> errno
    wasi[P .. "args_sizes_get"] = terra(argc_ptr: int32, buf_size_ptr: int32) : int32
        @[&int32](mem + [uint64]([uint32](argc_ptr))) = [int32](n_args)
        @[&int32](mem + [uint64]([uint32](buf_size_ptr))) = [int32](total_buf)
        return 0
    end

    -- args_get(argv_ptr, argv_buf_ptr) -> errno
    local arg_constants = {}
    for i = 1, n_args do
        arg_constants[i] = global(int8[#arg_strs[i] + 1])
        local init = terralib.new(int8[#arg_strs[i] + 1])
        for j = 1, #arg_strs[i] do
            init[j - 1] = arg_strs[i]:byte(j)
        end
        init[#arg_strs[i]] = 0
        arg_constants[i]:set(init)
    end

    wasi[P .. "args_get"] = terra(argv_ptr: int32, argv_buf_ptr: int32) : int32
        var argv_base = mem + [uint64]([uint32](argv_ptr))
        var buf_base = mem + [uint64]([uint32](argv_buf_ptr))
        var buf_offset : int32 = 0
        escape
            for i = 1, n_args do
                local slen = #arg_strs[i] + 1
                local src = arg_constants[i]
                emit quote
                    -- Write pointer to argv[i]
                    @[&int32](argv_base + [uint64]((i - 1) * 4)) = argv_buf_ptr + buf_offset
                    -- Copy string to buf
                    Cstr.memcpy(buf_base + [uint64](buf_offset), &src, slen)
                    buf_offset = buf_offset + slen
                end
            end
        end
        return 0
    end

    -- environ_sizes_get(environc_ptr, environ_buf_size_ptr) -> errno
    wasi[P .. "environ_sizes_get"] = terra(
        environc_ptr: int32, buf_size_ptr: int32
    ) : int32
        @[&int32](mem + [uint64]([uint32](environc_ptr))) = 0
        @[&int32](mem + [uint64]([uint32](buf_size_ptr))) = 0
        return 0
    end

    -- environ_get(environ_ptr, environ_buf_ptr) -> errno
    wasi[P .. "environ_get"] = terra(
        environ_ptr: int32, environ_buf_ptr: int32
    ) : int32
        return 0
    end

    -- clock_time_get(id, precision, time_ptr) -> errno
    wasi[P .. "clock_time_get"] = terra(
        id: int32, precision: int64, time_ptr: int32
    ) : int32
        var ts : Ctime.timespec
        var clock_id : int32 = 0  -- CLOCK_REALTIME
        if id == 1 then clock_id = 1 end  -- CLOCK_MONOTONIC
        if Ctime.clock_gettime(clock_id, &ts) ~= 0 then return 29 end
        var ns = [int64](ts.tv_sec) * 1000000000LL + [int64](ts.tv_nsec)
        @[&int64](mem + [uint64]([uint32](time_ptr))) = ns
        return 0
    end

    -- random_get(buf, len) -> errno
    wasi[P .. "random_get"] = terra(buf_ptr: int32, buf_len: int32) : int32
        var base = mem + [uint64]([uint32](buf_ptr))
        for i = 0, buf_len do
            @[&uint8](base + i) = [uint8](C.rand() and 0xFF)
        end
        return 0
    end

    return wasi
end

local module_compile_serial = 0

local function compile_module_core(wasm_bytes, host_functions, opts)
    host_functions = host_functions or {}
    opts = opts or {}

    local mod = parse_wasm(wasm_bytes)
    local module_env = create_module_env(mod)

    local mem_init = init_memory(mod, module_env, host_functions)
    local tbl_init = init_table(mod, module_env)

    -- Auto-provide WASI if module imports from wasi_snapshot_preview1
    local auto_wasi = opts.auto_wasi
    if auto_wasi == nil then auto_wasi = true end
    if auto_wasi then
        for _, imp in ipairs(mod.imports) do
            if imp.module == "wasi_snapshot_preview1" then
                local wasi = make_wasi(mod, module_env,
                    host_functions._wasi_args or {})
                for k, v in pairs(wasi) do
                    if not host_functions[k] then host_functions[k] = v end
                end
                break
            end
        end
    end

    if opts.auto_c_imports then
        add_missing_c_imports(mod, host_functions, opts)
    end

    local next_idx = bind_imports(mod, module_env, host_functions)

    module_compile_serial = (module_compile_serial or 0) + 1
    local module_sym_prefix = "wasm_m" .. tostring(module_compile_serial) .. "_fn_"

    -- Pass 1: forward declarations
    for i, func in ipairs(mod.funcs) do
        local ftype = mod.types[func.type_idx]
        local param_types = terralib.newlist()
        for _, T in ipairs(ftype.params) do param_types:insert(T) end
        local ret_type = make_ret_type(ftype.results) or terralib.types.unit

        local fwd = terralib.externfunction(
            module_sym_prefix .. i, param_types -> ret_type)

        module_env.functions[next_idx + i - 1] = {
            fn = fwd,
            type = ftype,
        }
    end

    -- Pass 2: compile and replace forward declarations
    local noopt = os.getenv("POT_NOOPT") == "1"
    local profile_compile = os.getenv("POT_PROFILE_COMPILE") == "1"
    local compile_times = {}
    for i, func in ipairs(mod.funcs) do
        local ftype = mod.types[func.type_idx]
        module_env.current_ftype = ftype
        local t1 = profile_compile and os.clock() or nil
        local compiled = compile_function(mod, i, module_env)
        if profile_compile then
            compile_times[i] = os.clock() - t1
        end
        local entry = module_env.functions[next_idx + i - 1]
        if noopt and compiled.setoptimized then
            compiled:setoptimized(false)
        end
        entry.fn:resetdefinition(compiled)
    end
    if profile_compile then
        local total = 0
        for i, t in ipairs(compile_times) do
            total = total + t
            print(string.format("  fn %d: %.2f ms", i, t * 1000))
        end
        print(string.format("  TOTAL compile_function: %.2f ms", total * 1000))
    end

    -- Init globals
    local init_globals = terra()
        escape
            for i, g in ipairs(mod.globals) do
                local gsym = module_env.globals[module_env.import_global_count + i].sym
                local init_val = emit_const_expr(module_env, g.init)
                emit quote [gsym] = [g.type]([init_val]) end
            end
        end
    end

    -- Init table elements
    local init_elements = terra()
        escape
            for _, elem in ipairs(mod.elements) do
                if elem.mode == "active" then
                    local off_expr = elem.offset and emit_const_expr(module_env, elem.offset) or `[int32](0)
                    local table_sym = module_env.fn_tables and module_env.fn_tables[(elem.table_idx or 0) + 1] or nil
                    for j, fn_idx in ipairs(elem.elems) do
                        local fn_entry = module_env.functions[fn_idx]
                        if fn_entry and table_sym then
                            local tbl = table_sym
                            local j_off = j - 1
                            emit quote
                                var off = [int32]([off_expr]) + [int32]([j_off])
                                tbl[off] = [&opaque]([fn_entry.fn])
                            end
                        end
                    end
                end
            end
        end
    end

    -- Build export table
    local exports = {}
    for name, exp in pairs(mod.exports) do
        if exp.kind == 0 then  -- function
            local entry = module_env.functions[exp.index]
            if entry and entry.fn then
                exports[name] = entry.fn
            end
        end
    end

    return {
        mod = mod,
        module_env = module_env,
        exports = exports,
        mem_init = mem_init,
        init_globals = init_globals,
        tbl_init = tbl_init,
        init_elements = init_elements,
    }
end

function POT.compile_module(wasm_bytes, host_functions, opts)
    local compiled = compile_module_core(wasm_bytes, host_functions, opts)
    local mem_sym = compiled.module_env.memory_sym
    local mem_size_sym = compiled.module_env.mem_size
    local mem_syms = compiled.module_env.memory_syms or {}
    local mem_size_syms = compiled.module_env.mem_sizes or {}
    local mem_count = #mem_syms

    local init_fn = terra()
        [compiled.mem_init]()
        [compiled.init_globals]()
        [compiled.tbl_init]()
        [compiled.init_elements]()
    end

    local deinit_fn = terra()
        escape
            for i, ms in ipairs(mem_syms) do
                local mlen = mem_size_syms[i]
                emit quote
                    if [ms] ~= nil then
                        C.free([ms])
                        [ms] = nil
                    end
                    [mlen] = 0
                end
            end
        end
        if [mem_count] == 0 then
            if [mem_sym] ~= nil then
                C.free([mem_sym])
                [mem_sym] = nil
            end
            [mem_size_sym] = 0
        end
    end

    local mem_ptr_fn = terra() : &uint8
        return [mem_sym]
    end

    local mem_size_fn = terra() : int64
        return [mem_size_sym]
    end

    return {
        mod = compiled.mod,
        module_env = compiled.module_env,
        exports = compiled.exports,
        init_fn = init_fn,
        deinit_fn = deinit_fn,
        memory_fn = mem_ptr_fn,
        memory_size_fn = mem_size_fn,
    }
end

function POT.load_module(wasm_bytes, host_functions, opts)
    local inst = POT.instantiate(wasm_bytes, host_functions, opts)
    local compiled = {}
    for name, e in pairs(inst.exports) do
        compiled[name] = e.fn
    end
    return compiled
end

local instantiate_requests = {}
local instantiate_memoized = terralib.memoize(function(cache_key)
    local req = assert(instantiate_requests[cache_key], "missing instantiate request")
    local module = POT.compile_module(req.wasm_bytes, req.host_functions, req.compile_opts)
    local mod = module.mod

    local exports_by_name = {}
    local export_list = {}
    for name, exp in pairs(mod.exports) do
        if exp.kind == 0 then
            local ftype = resolve_function_type(mod, exp.index)
            local ffi_sig, ffi_err = ftype_to_ffi_fnptr(ftype)
            local item = {
                name = name,
                fn = module.exports[name],
                ftype = ftype,
                ffi_sig = ffi_sig,
                ffi_sig_error = ffi_err,
                ptr = nil,
            }
            exports_by_name[name] = item
            export_list[#export_list + 1] = item
        end
    end
    table.sort(export_list, function(a, b) return a.name < b.name end)

    return {
        module = module,
        exports = exports_by_name,
        export_list = export_list,
    }
end)

function POT.instantiate(wasm_bytes, host_functions, opts)
    host_functions = host_functions or {}
    opts = opts or {}

    local compile_opts = {
        auto_wasi = opts.auto_wasi,
        auto_c_imports = opts.auto_c_imports,
    }

    local key = instantiate_cache_key(wasm_bytes, host_functions, compile_opts)
    instantiate_requests[key] = {
        wasm_bytes = wasm_bytes,
        host_functions = host_functions,
        compile_opts = compile_opts,
    }
    local ok, instance_or_err = pcall(instantiate_memoized, key)
    instantiate_requests[key] = nil
    if not ok then
        error(instance_or_err, 2)
    end
    local template = instance_or_err
    local instance = {
        module = template.module,
        exports = {},
        export_list = {},
        initialized = false,
    }
    for name, e in pairs(template.exports) do
        instance.exports[name] = {
            name = e.name,
            fn = e.fn,
            ftype = e.ftype,
            ffi_sig = e.ffi_sig,
            ffi_sig_error = e.ffi_sig_error,
            ptr = nil,
        }
    end
    for i, e in ipairs(template.export_list) do
        instance.export_list[i] = instance.exports[e.name]
    end

    if opts.init ~= false then
        POT.instance_init(instance)
    end
    if opts.eager then
        for _, e in ipairs(instance.export_list) do
            e.fn:compile()
        end
    end
    return instance
end

function POT.instance_init(instance)
    assert(type(instance) == "table" and instance.module, "invalid instance")
    if not instance.initialized then
        instance.module.init_fn()
        instance.initialized = true
    end
end

function POT.instance_deinit(instance)
    assert(type(instance) == "table" and instance.module, "invalid instance")
    if instance.initialized then
        instance.module.deinit_fn()
        instance.initialized = false
    end
end

function POT.instance_export_count(instance)
    assert(type(instance) == "table" and instance.export_list, "invalid instance")
    return #instance.export_list
end

function POT.instance_export_name(instance, i)
    assert(type(instance) == "table" and instance.export_list, "invalid instance")
    local idx = tonumber(i)
    if not idx then return nil end
    idx = idx + 1
    if idx < 1 or idx > #instance.export_list then return nil end
    return instance.export_list[idx].name
end

function POT.instance_export_sig(instance, i)
    assert(type(instance) == "table" and instance.export_list, "invalid instance")
    local idx = tonumber(i)
    if not idx then return nil, "invalid index" end
    idx = idx + 1
    if idx < 1 or idx > #instance.export_list then return nil, "index out of range" end
    local e = instance.export_list[idx]
    return e.ffi_sig, e.ffi_sig_error
end

function POT.instance_export_ptr(instance, i, ctype)
    assert(type(instance) == "table" and instance.export_list, "invalid instance")
    local idx = tonumber(i)
    if not idx then return nil, "invalid index" end
    idx = idx + 1
    if idx < 1 or idx > #instance.export_list then return nil, "index out of range" end
    local e = instance.export_list[idx]
    if e.ptr == nil then
        e.fn:compile()
        e.ptr = ffi.cast("void*", e.fn:getpointer())
    end
    if ctype then return ffi.cast(ctype, e.ptr) end
    return e.ptr
end

function POT.instance_memory(instance)
    assert(type(instance) == "table" and instance.module, "invalid instance")
    return ffi.cast("void*", instance.module.memory_fn())
end

function POT.instance_memory_size(instance)
    assert(type(instance) == "table" and instance.module, "invalid instance")
    return tonumber(instance.module.memory_size_fn())
end

function POT.load_file(path, host_functions, opts)
    local f = io.open(path, "rb")
    assert(f, "cannot open: " .. path)
    local bytes = f:read("*a")
    f:close()
    return POT.load_module(bytes, host_functions, opts)
end

function POT.run(wasm_bytes, args)
    local exports = POT.load_module(wasm_bytes, { _wasi_args = args or {} })
    if exports._start then
        exports._start()
    elseif exports._initialize then
        exports._initialize()
    end
    return exports
end

------------------------------------------------------------------------
-- Exports
------------------------------------------------------------------------

POT.parse_wasm = parse_wasm

return POT
