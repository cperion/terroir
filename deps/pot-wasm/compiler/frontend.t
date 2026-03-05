local bit = require("bit")

local M = {}

local function decode_uleb128(bytes, pos)
  local result, shift = 0, 0
  while true do
    local b = bytes:byte(pos)
    if not b then error("unexpected EOF in uleb128") end
    result = result + bit.band(b, 0x7F) * (2 ^ shift)
    pos = pos + 1
    if bit.band(b, 0x80) == 0 then
      return result, pos
    end
    shift = shift + 7
  end
end

local function read_name(bytes, pos)
  local n
  n, pos = decode_uleb128(bytes, pos)
  local s = bytes:sub(pos, pos + n - 1)
  return s, pos + n
end

function M.parse_wasm(wasm_bytes)
  assert(type(wasm_bytes) == "string", "wasm_bytes must be a string")
  assert(#wasm_bytes >= 8, "wasm too small")

  assert(wasm_bytes:byte(1) == 0x00
    and wasm_bytes:byte(2) == 0x61
    and wasm_bytes:byte(3) == 0x73
    and wasm_bytes:byte(4) == 0x6D, "not a WASM binary")

  local version = wasm_bytes:byte(5)
    + wasm_bytes:byte(6) * 256
    + wasm_bytes:byte(7) * 65536
    + wasm_bytes:byte(8) * 16777216
  assert(version == 1, "unsupported WASM version: " .. tostring(version))

  local mod = {
    types = {},
    funcs = {},
    imports = {},
    exports = {},
    version = version,
  }

  local p = 9
  while p <= #wasm_bytes do
    local section_id = wasm_bytes:byte(p)
    p = p + 1
    local section_len
    section_len, p = decode_uleb128(wasm_bytes, p)
    local pend = p + section_len

    if section_id == 1 then
      local count
      count, p = decode_uleb128(wasm_bytes, p)
      for i = 1, count do
        assert(wasm_bytes:byte(p) == 0x60, "expected functype")
        p = p + 1

        local param_count
        param_count, p = decode_uleb128(wasm_bytes, p)
        for _ = 1, param_count do p = p + 1 end

        local result_count
        result_count, p = decode_uleb128(wasm_bytes, p)
        for _ = 1, result_count do p = p + 1 end

        mod.types[i] = { _raw = true }
      end

    elseif section_id == 2 then
      local count
      count, p = decode_uleb128(wasm_bytes, p)
      for _ = 1, count do
        local mod_name
        mod_name, p = read_name(wasm_bytes, p)
        local name
        name, p = read_name(wasm_bytes, p)
        local kind = wasm_bytes:byte(p)
        p = p + 1

        local imp = {
          module = mod_name,
          name = name,
          kind = (kind == 0 and "function") or (kind == 2 and "memory") or (kind == 3 and "global") or "other",
        }

        if kind == 0 then
          local type_idx
          type_idx, p = decode_uleb128(wasm_bytes, p)
          imp.type_idx = type_idx + 1
        elseif kind == 2 then
          local flags
          flags, p = decode_uleb128(wasm_bytes, p)
          local _
          _, p = decode_uleb128(wasm_bytes, p)
          if bit.band(flags, 1) == 1 then
            _, p = decode_uleb128(wasm_bytes, p)
          end
        elseif kind == 3 then
          p = p + 2
        elseif kind == 1 then
          p = p + 1
          local flags
          flags, p = decode_uleb128(wasm_bytes, p)
          local _
          _, p = decode_uleb128(wasm_bytes, p)
          if bit.band(flags, 1) == 1 then
            _, p = decode_uleb128(wasm_bytes, p)
          end
        elseif kind == 4 then
          -- tag import: tag type + type index
          local _
          _, p = decode_uleb128(wasm_bytes, p)
          _, p = decode_uleb128(wasm_bytes, p)
        else
          error("unsupported import kind: " .. tostring(kind))
        end

        mod.imports[#mod.imports + 1] = imp
      end

    elseif section_id == 3 then
      local count
      count, p = decode_uleb128(wasm_bytes, p)
      for i = 1, count do
        local type_idx
        type_idx, p = decode_uleb128(wasm_bytes, p)
        mod.funcs[i] = { type_idx = type_idx + 1 }
      end

    elseif section_id == 7 then
      local count
      count, p = decode_uleb128(wasm_bytes, p)
      for _ = 1, count do
        local name
        name, p = read_name(wasm_bytes, p)
        local kind = wasm_bytes:byte(p)
        p = p + 1
        local index
        index, p = decode_uleb128(wasm_bytes, p)
        mod.exports[name] = { kind = kind, index = index + 1 }
      end

    else
      p = pend
    end

    p = pend
  end

  return mod
end

return M
