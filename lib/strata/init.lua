-- Strata: schema-driven AST nodes, traversal, pattern matching, diagnostics
-- ~300 lines of Lua for LuaJIT 2.1

local S = {}
S._registry = {}   -- kind -> field_names (global, for traversals)
S._active_parser = nil

-- Markers

S.any = { _strata = "any" }
S.otherwise = { _strata = "otherwise" }

function S.cap(name)
  return { _strata = "cap", name = name }
end

function S.pred(fn)
  return { _strata = "pred", fn = fn }
end

function S.guard(pred_fn, handler_fn)
  return { _strata = "guard", pred = pred_fn, handler = handler_fn }
end

-- Node detection

local function is_node(v)
  return type(v) == "table" and type(v.kind) == "string"
end

-- Span propagation: compute covering span from children
local function propagate_span(tbl, field_names)
  local lo, hi
  for _, fname in ipairs(field_names) do
    local child = tbl[fname]
    if type(child) == "table" then
      if child.span then
        local cend = child.span.offset + child.span.length
        if not lo or child.span.offset < lo then lo = child.span.offset end
        if not hi or cend > hi then hi = cend end
      elseif not child.kind and #child > 0 then
        for _, item in ipairs(child) do
          if type(item) == "table" and item.span then
            local iend = item.span.offset + item.span.length
            if not lo or item.span.offset < lo then lo = item.span.offset end
            if not hi or iend > hi then hi = iend end
          end
        end
      end
    end
  end
  if lo and hi then
    tbl.span = { offset = lo, length = hi - lo }
  end
end

-- Schema

function S.schema(defs)
  local N = { _schema = defs, _fields = {}, _required = {} }

  for kind, raw_fields in pairs(defs) do
    local field_names = {}
    local required = {}

    for _, f in ipairs(raw_fields) do
      local name = f:match("^(.+)%?$")
      if name then
        field_names[#field_names + 1] = name
      else
        field_names[#field_names + 1] = f
        required[f] = true
      end
    end

    N._fields[kind] = field_names
    N._required[kind] = required
    S._registry[kind] = field_names

    N[kind] = function(tbl)
      for name in pairs(required) do
        if tbl[name] == nil then
          error("missing required field '" .. name .. "' for " .. kind, 2)
        end
      end
      tbl.kind = kind
      if S._active_parser and not tbl.span then
        propagate_span(tbl, field_names)
      end
      return tbl
    end
  end

  return N
end

-- Traversals

function S.walk(node, fn)
  fn(node)
  local fields = S._registry[node.kind]
  if not fields then return end
  for _, name in ipairs(fields) do
    local child = node[name]
    if child ~= nil then
      if is_node(child) then
        S.walk(child, fn)
      elseif type(child) == "table" and #child > 0 then
        for _, item in ipairs(child) do
          if is_node(item) then S.walk(item, fn) end
        end
      end
    end
  end
end

function S.map(node, fn)
  local fields = S._registry[node.kind]
  if not fields then return fn(node) end

  local changed = false
  local updates = {}

  for _, name in ipairs(fields) do
    local child = node[name]
    if child ~= nil then
      if is_node(child) then
        local mapped = S.map(child, fn)
        if mapped ~= child then
          changed = true
          updates[name] = mapped
        end
      elseif type(child) == "table" and #child > 0 then
        local new_list, list_changed = {}, false
        for i, item in ipairs(child) do
          if is_node(item) then
            local mapped = S.map(item, fn)
            new_list[i] = mapped
            if mapped ~= item then list_changed = true end
          else
            new_list[i] = item
          end
        end
        if list_changed then
          changed = true
          updates[name] = new_list
        end
      end
    end
  end

  if changed then
    local new_node = {}
    for k, v in pairs(node) do new_node[k] = v end
    for k, v in pairs(updates) do new_node[k] = v end
    return fn(new_node)
  else
    return fn(node)
  end
end

function S.collect(node, pred)
  local results = {}
  S.walk(node, function(n)
    if pred(n) then results[#results + 1] = n end
  end)
  return results
end

function S.fold(node, fn)
  local fields = S._registry[node.kind]
  if not fields then return fn(node, {}) end

  local child_results = {}
  for _, name in ipairs(fields) do
    local child = node[name]
    if child ~= nil then
      if is_node(child) then
        child_results[#child_results + 1] = S.fold(child, fn)
      elseif type(child) == "table" and #child > 0 then
        for _, item in ipairs(child) do
          if is_node(item) then
            child_results[#child_results + 1] = S.fold(item, fn)
          end
        end
      end
    end
  end

  return fn(node, child_results)
end

-- Structural equality (ignores span)

function S.equal(a, b)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return false end

  if is_node(a) then
    if not is_node(b) or a.kind ~= b.kind then return false end
    local fields = S._registry[a.kind]
    if not fields then return false end
    for _, name in ipairs(fields) do
      if not S.equal(a[name], b[name]) then return false end
    end
    return true
  end

  -- list comparison
  if #a ~= #b then return false end
  for i = 1, #a do
    if not S.equal(a[i], b[i]) then return false end
  end
  return true
end

-- Pattern matching

local function match_value(pat, val, caps)
  if type(pat) == "table" and pat._strata then
    if pat._strata == "cap" then
      caps[pat.name] = val
      return true
    elseif pat._strata == "any" then
      return true
    elseif pat._strata == "pred" then
      return pat.fn(val)
    elseif pat._strata == "otherwise" then
      return true
    end
    return false
  end

  if type(pat) == "table" then
    if type(val) ~= "table" then return false end
    if pat[1] then
      if not is_node(val) or val.kind ~= pat[1] then return false end
    end
    for k, v in pairs(pat) do
      if type(k) == "string" then
        if not match_value(v, val[k], caps) then return false end
      end
    end
    return true
  end

  return pat == val
end

local function sorted_cap_args(caps)
  local names = {}
  for name in pairs(caps) do names[#names + 1] = name end
  table.sort(names)
  local args = {}
  for _, name in ipairs(names) do args[#args + 1] = caps[name] end
  return args
end

function S.match(node, pairs_list)
  for i = 1, #pairs_list, 2 do
    local pat = pairs_list[i]
    local handler = pairs_list[i + 1]
    local caps = {}
    local matched

    if pat == S.otherwise then
      matched = true
    else
      matched = match_value(pat, node, caps)
    end

    if matched then
      local args = sorted_cap_args(caps)

      if type(handler) == "table" and handler._strata == "guard" then
        if handler.pred(unpack(args)) then
          return handler.handler(unpack(args))
        end
        -- guard failed, try next pattern
      else
        if pat == S.otherwise then
          return handler(node)
        else
          return handler(unpack(args))
        end
      end
    end
  end
  return nil
end

-- Diagnostics

local function offset_to_line_col(source, offset)
  local line, col = 1, 1
  for i = 1, math.min(offset, #source) do
    if source:sub(i, i) == "\n" then
      line, col = line + 1, 1
    else
      col = col + 1
    end
  end
  return line, col
end

local function extract_line(source, line_num)
  local cur = 1
  for i = 1, #source do
    if cur == line_num then
      local eol = source:find("\n", i)
      return eol and source:sub(i, eol - 1) or source:sub(i)
    end
    if source:sub(i, i) == "\n" then cur = cur + 1 end
  end
  return ""
end

local Diag = {}; Diag.__index = Diag

function Diag:hint(text)
  self.hints[#self.hints + 1] = text
  return self
end

function Diag:also(span, text)
  self.secondary[#self.secondary + 1] = { span = span, text = text }
  return self
end

local DiagCtx = {}; DiagCtx.__index = DiagCtx

function S.diag(source, filename)
  return setmetatable({
    source = source, filename = filename,
    _list = {}, _errors = 0, _warnings = 0,
  }, DiagCtx)
end

local function add_diag(ctx, level, span, fmt, ...)
  local d = setmetatable({
    level = level, span = span,
    message = string.format(fmt, ...),
    hints = {}, secondary = {},
  }, Diag)
  ctx._list[#ctx._list + 1] = d
  if level == "error" then ctx._errors = ctx._errors + 1
  else ctx._warnings = ctx._warnings + 1 end
  return d
end

function DiagCtx:err(span, fmt, ...)  return add_diag(self, "error", span, fmt, ...)   end
function DiagCtx:warn(span, fmt, ...) return add_diag(self, "warning", span, fmt, ...) end
function DiagCtx:has_errors()   return self._errors > 0 end
function DiagCtx:error_count()  return self._errors     end
function DiagCtx:warning_count() return self._warnings  end

function DiagCtx:print()
  for _, d in ipairs(self._list) do
    local line, col = offset_to_line_col(self.source, d.span.offset)
    local src = extract_line(self.source, line)
    local pad = string.rep(" ", #tostring(line))

    io.stderr:write(string.format("%s: %s\n", d.level, d.message))
    io.stderr:write(string.format("  --> %s:%d:%d\n", self.filename, line, col))
    io.stderr:write(string.format("   %s|\n", pad))
    io.stderr:write(string.format(" %s | %s\n", tostring(line), src))
    io.stderr:write(string.format("   %s| %s%s\n", pad,
      string.rep(" ", col - 1), string.rep("^", d.span.length or 1)))

    for _, h in ipairs(d.hints) do
      io.stderr:write(string.format("   %s= hint: %s\n", pad, h))
    end
    for _, sec in ipairs(d.secondary) do
      local sl, sc = offset_to_line_col(self.source, sec.span.offset)
      io.stderr:write(string.format("   %s= %s\n", pad, sec.text))
      io.stderr:write(string.format("  --> %s:%d:%d\n", self.filename, sl, sc))
      io.stderr:write(string.format(" %s | %s\n", tostring(sl), extract_line(self.source, sl)))
    end
    io.stderr:write("\n")
  end
end

-- Parser context

local Parser = {}; Parser.__index = Parser

function S.parser_context(source, filename)
  local ctx = setmetatable({ source = source, filename = filename, pos = 0 }, Parser)
  S._active_parser = ctx
  return ctx
end

function Parser:with_span(fn)
  local start = self.pos
  local result = fn()
  local finish = self.pos
  if type(result) == "table" and not result.span then
    result.span = { offset = start, length = finish - start }
  end
  return result
end

function Parser:close()
  if S._active_parser == self then S._active_parser = nil end
end

return S
