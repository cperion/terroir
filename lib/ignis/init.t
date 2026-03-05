-- Ignis: compiled HTML template engine for Terra
-- Uses Strata for AST nodes, traversal, and diagnostics
-- Generates Terra functions that write HTML to a buffer

local S = require("strata")

local ignis = {}

-- ============================================================
-- Schema
-- ============================================================

local T = S.schema {
  Element   = { "tag", "attrs", "children" },
  Text      = { "value" },
  Field     = { "name", "type?", "esc?" },
  When      = { "cond", "then_?", "else_?" },
  Each      = { "collection", "key?", "body" },
  Component = { "name?", "bindings?", "template" },
  Slot      = { "name" },
  Concat    = { "parts" },
  Json      = { "fields" },
  Endpoint  = { "path", "params?" },
}

ignis.T = T

-- ============================================================
-- Buffer struct (Terra)
-- ============================================================

local C = terralib.includec("string.h")
local stdlib = terralib.includec("stdlib.h")
local stdio = terralib.includec("stdio.h")

struct ignis.Buffer {
  data: &uint8
  len: int32
  cap: int32
}

local Buffer = ignis.Buffer

terra Buffer:init()
  self.cap = 1024
  self.len = 0
  self.data = [&uint8](stdlib.malloc(self.cap))
end

terra Buffer:free()
  if self.data ~= nil then
    stdlib.free(self.data)
    self.data = nil
  end
  self.len = 0
  self.cap = 0
end

terra Buffer:ensure(n: int32)
  if self.len + n > self.cap then
    while self.len + n > self.cap do
      self.cap = self.cap * 2
    end
    self.data = [&uint8](stdlib.realloc(self.data, self.cap))
  end
end

terra Buffer:write_raw(s: &uint8, n: int32)
  self:ensure(n)
  C.memcpy(self.data + self.len, s, n)
  self.len = self.len + n
end

terra Buffer:write_str(s: rawstring)
  var n = [int32](C.strlen(s))
  self:write_raw([&uint8](s), n)
end

terra Buffer:write_byte(b: uint8)
  self:ensure(1)
  self.data[self.len] = b
  self.len = self.len + 1
end

local BYTE_AMP  = string.byte("&")
local BYTE_LT   = string.byte("<")
local BYTE_GT   = string.byte(">")
local BYTE_QUOT = string.byte('"')
local BYTE_APOS = string.byte("'")

terra Buffer:write_escaped(s: rawstring)
  var p = [&uint8](s)
  while @p ~= 0 do
    var c = @p
    if c == BYTE_AMP then
      self:write_str("&amp;")
    elseif c == BYTE_LT then
      self:write_str("&lt;")
    elseif c == BYTE_GT then
      self:write_str("&gt;")
    elseif c == BYTE_QUOT then
      self:write_str("&quot;")
    elseif c == BYTE_APOS then
      self:write_str("&#39;")
    else
      self:write_byte(c)
    end
    p = p + 1
  end
end

terra Buffer:write_int(v: int64)
  var tmp: int8[32]
  var n = stdio.snprintf([rawstring](&tmp[0]), 32, "%lld", v)
  self:write_raw([&uint8](&tmp[0]), n)
end

terra Buffer:write_double(v: double)
  var tmp: int8[64]
  var n = stdio.snprintf([rawstring](&tmp[0]), 64, "%g", v)
  self:write_raw([&uint8](&tmp[0]), n)
end

-- ============================================================
-- DSL Layer
-- ============================================================

-- Void elements (no closing tag)
local void_elements = {}
for _, tag in ipairs {
  "area", "base", "br", "col", "embed", "hr", "img", "input",
  "link", "meta", "param", "source", "track", "wbr"
} do
  void_elements[tag] = true
end

ignis.void_elements = void_elements

-- Tag function proxy
local tags = setmetatable({}, {
  __index = function(self, tag_name)
    local fn = function(tbl)
      local attrs = {}
      local children = {}
      for k, v in pairs(tbl) do
        if type(k) == "string" then
          attrs[#attrs + 1] = { name = k, value = v }
        end
      end
      table.sort(attrs, function(a, b) return a.name < b.name end)
      for i, v in ipairs(tbl) do
        if type(v) == "string" then
          children[#children + 1] = T.Text { value = v }
        elseif type(v) == "table" and v.kind then
          children[#children + 1] = v
        end
      end
      return T.Element { tag = tag_name, attrs = attrs, children = children }
    end
    rawset(self, tag_name, fn)
    return fn
  end,
})

ignis.tags = tags

-- field(name) -> Field node
local function field(name)
  return T.Field { name = name }
end
ignis.field = field

-- when(cond, then_, else_?) -> When node
local function when(cond, then_, else_)
  return T.When { cond = cond, then_ = then_, else_ = else_ }
end
ignis.when = when

-- key(name) -> plain string marker for each()
local function key(name)
  return name
end
ignis.key = key

-- each(collection, key?) -> callable that takes body
local function each(collection, key_val)
  local obj = {}
  setmetatable(obj, {
    __call = function(self, body_tbl)
      local body = body_tbl[1] or body_tbl
      return T.Each { collection = collection, key = key_val, body = body }
    end
  })
  return obj
end
ignis.each = each

-- slot(name) -> Slot node
local function slot(name)
  return T.Slot { name = name }
end
ignis.slot = slot

-- concat(parts...) -> Concat node
local function concat(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if type(p) == "string" then
      parts[#parts + 1] = T.Text { value = p }
    elseif type(p) == "table" and p.kind then
      parts[#parts + 1] = p
    end
  end
  return T.Concat { parts = parts }
end
ignis.concat = concat

-- json(fields) -> Json node
local function json(field_tbl)
  local fields = {}
  for k, v in pairs(field_tbl) do
    if type(k) == "string" then
      fields[#fields + 1] = { name = k, value = v }
    end
  end
  return T.Json { fields = fields }
end
ignis.json = json

-- endpoint(path, params?) -> Endpoint node
local function endpoint(path, params)
  return T.Endpoint { path = path, params = params }
end
ignis.endpoint = endpoint

-- component(template) -> callable component object
local function component(template)
  local comp = { _is_component = true, template = template }
  setmetatable(comp, {
    __call = function(self, bindings)
      return T.Component {
        name = self._name,
        bindings = bindings,
        template = self.template,
      }
    end,
  })
  return comp
end
ignis.component = component

-- ============================================================
-- Analysis: Component Inlining
-- ============================================================

local function inline_components(node)
  return S.map(node, function(n)
    if n.kind == "Component" then
      local tmpl = n.template
      local bindings = n.bindings or {}
      -- Replace Slot nodes in the template with bound content
      local inlined = S.map(tmpl, function(inner)
        if inner.kind == "Slot" then
          local replacement = bindings[inner.name]
          if replacement then
            -- If binding is a list, wrap in a synthetic element-like container
            if type(replacement) == "table" and not replacement.kind and #replacement > 0 then
              return replacement[1]
            end
            return replacement
          end
        end
        return inner
      end)
      return inlined
    end
    return n
  end)
end

ignis.inline_components = inline_components

-- ============================================================
-- Analysis: Type Resolution
-- ============================================================

local function resolve_field_type(field_name, DataType)
  local entries = DataType.entries
  for _, entry in ipairs(entries) do
    local entry_name = entry.field or tostring(entry[1])
    local entry_type = entry.type or entry[2]
    if entry_name == field_name then
      return entry_type
    end
  end
  return nil
end

local function classify_resolved(n, resolved)
  n.resolved_type = resolved
  if resolved == rawstring then
    n.esc = true
    n.type = "string"
  elseif resolved == int32 or resolved == int64 then
    n.esc = false
    n.type = "int"
  elseif resolved == float or resolved == double then
    n.esc = false
    n.type = "double"
  elseif resolved == bool then
    n.esc = false
    n.type = "bool"
  else
    n.esc = false
    n.type = "other"
  end
end

local function resolve_types(node, DataType, errors)
  if node.kind == "Field" then
    local resolved = resolve_field_type(node.name, DataType)
    if not resolved then
      if errors then
        errors[#errors + 1] = "field '" .. node.name .. "' not found in struct"
      end
      return node
    end
    classify_resolved(node, resolved)
  elseif node.kind == "Each" then
    -- Resolve collection field in parent type
    local col_type = resolve_field_type(node.collection, DataType)
    if col_type then
      -- Find the item type: collection is { data: &ItemType, len: int32 }
      local item_type
      for _, entry in ipairs(col_type.entries) do
        local ename = entry.field or tostring(entry[1])
        if ename == "data" then
          item_type = (entry.type or entry[2]).type  -- deref pointer
          break
        end
      end
      if item_type and node.body then
        resolve_types(node.body, item_type, errors)
      end
    end
  else
    -- Special handling for Element: resolve fields inside attributes
    if node.kind == "Element" and node.attrs then
      for _, attr in ipairs(node.attrs) do
        local v = attr.value
        if type(v) == "table" and v.kind then
          resolve_types(v, DataType, errors)
        end
      end
    end
    -- Special handling for Json: resolve fields inside field entries
    if node.kind == "Json" and node.fields then
      for _, fld in ipairs(node.fields) do
        local v = fld.value
        if type(v) == "table" and v.kind then
          resolve_types(v, DataType, errors)
        end
      end
    end
    -- Recurse into children
    local fields = S._registry[node.kind]
    if fields then
      for _, fname in ipairs(fields) do
        local child = node[fname]
        if child ~= nil then
          if type(child) == "table" and child.kind then
            resolve_types(child, DataType, errors)
          elseif type(child) == "table" and #child > 0 then
            for _, item in ipairs(child) do
              if type(item) == "table" and item.kind then
                resolve_types(item, DataType, errors)
              end
            end
          end
        end
      end
    end
  end
  return node
end

-- ============================================================
-- Analysis: Shape Analysis
-- ============================================================

local analyze_shape  -- forward declaration

local function classify_attr(attr)
  local v = attr.value
  if type(v) == "string" then
    return { kind = "static", name = attr.name, value = v }
  elseif type(v) == "table" and v.kind == "Field" then
    return { kind = "dynamic", name = attr.name, field = v }
  elseif type(v) == "table" and v.kind == "When" then
    if v.then_ or v.else_ then
      return { kind = "ternary", name = attr.name, cond = v.cond, then_ = v.then_, else_ = v.else_ }
    else
      return { kind = "boolean", name = attr.name, cond = v.cond }
    end
  elseif type(v) == "table" and v.kind == "Concat" then
    local part_shapes = {}
    for _, p in ipairs(v.parts) do
      part_shapes[#part_shapes + 1] = analyze_shape(p)
    end
    return { kind = "concat", name = attr.name, parts = part_shapes }
  elseif type(v) == "table" and v.kind == "Json" then
    return { kind = "json", name = attr.name, fields = v.fields }
  elseif type(v) == "table" and v.kind == "Endpoint" then
    return { kind = "endpoint", name = attr.name, path = v.path }
  elseif type(v) == "boolean" and v == true then
    return { kind = "boolean_literal", name = attr.name }
  else
    return { kind = "static", name = attr.name, value = tostring(v) }
  end
end

analyze_shape = function(node)
  if node.kind == "Element" then
    local static_attrs = {}
    local dynamic_attrs = {}
    for _, attr in ipairs(node.attrs) do
      local classified = classify_attr(attr)
      if classified.kind == "static" then
        static_attrs[#static_attrs + 1] = classified
      else
        dynamic_attrs[#dynamic_attrs + 1] = classified
      end
    end

    local child_shapes = {}
    for _, child in ipairs(node.children) do
      child_shapes[#child_shapes + 1] = analyze_shape(child)
    end

    return {
      kind = "element",
      tag = node.tag,
      is_void = void_elements[node.tag] or false,
      static_attrs = static_attrs,
      dynamic_attrs = dynamic_attrs,
      children = child_shapes,
    }
  elseif node.kind == "Text" then
    return { kind = "text", value = node.value }
  elseif node.kind == "Field" then
    return {
      kind = "field",
      name = node.name,
      type = node.type,
      esc = node.esc,
      resolved_type = node.resolved_type,
    }
  elseif node.kind == "When" then
    local then_shape = node.then_ and analyze_shape(node.then_) or nil
    local else_shape = node.else_ and analyze_shape(node.else_) or nil
    return {
      kind = "when",
      cond = node.cond,
      then_ = then_shape,
      else_ = else_shape,
    }
  elseif node.kind == "Each" then
    return {
      kind = "each",
      collection = node.collection,
      key = node.key,
      body = analyze_shape(node.body),
    }
  elseif node.kind == "Concat" then
    local part_shapes = {}
    for _, p in ipairs(node.parts) do
      part_shapes[#part_shapes + 1] = analyze_shape(p)
    end
    return { kind = "concat", parts = part_shapes }
  elseif node.kind == "Json" then
    return { kind = "json", fields = node.fields }
  elseif node.kind == "Endpoint" then
    return { kind = "endpoint", path = node.path }
  else
    return { kind = "unknown", node = node }
  end
end

ignis.analyze_shape = analyze_shape

-- ============================================================
-- Terra SSR Codegen
-- ============================================================

local function build_static_open(tag, static_attrs, is_void)
  local parts = { "<" .. tag }
  for _, attr in ipairs(static_attrs) do
    parts[#parts + 1] = " " .. attr.name .. "=\"" .. attr.value .. "\""
  end
  return table.concat(parts)
end

local function gen_shape(shape, buf, data, DataType)
  if shape.kind == "text" then
    local s = shape.value
    return quote [buf]:write_str(s) end

  elseif shape.kind == "field" then
    local name = shape.name
    if shape.type == "string" then
      return quote [buf]:write_escaped([data].[name]) end
    elseif shape.type == "int" then
      return quote [buf]:write_int([data].[name]) end
    elseif shape.type == "double" then
      return quote [buf]:write_double([data].[name]) end
    elseif shape.type == "bool" then
      return quote
        if [data].[name] then
          [buf]:write_str("true")
        else
          [buf]:write_str("false")
        end
      end
    else
      return quote end
    end

  elseif shape.kind == "when" then
    local cond_name = shape.cond
    local then_q = shape.then_ and gen_shape(shape.then_, buf, data, DataType) or quote end
    local else_q = shape.else_ and gen_shape(shape.else_, buf, data, DataType) or quote end
    return quote
      if [data].[cond_name] then
        [then_q]
      else
        [else_q]
      end
    end

  elseif shape.kind == "each" then
    local col_name = shape.collection
    local body_shape = shape.body
    -- Find item type from DataType
    local col_struct_type
    for _, entry in ipairs(DataType.entries) do
      local ename = entry.field or tostring(entry[1])
      if ename == col_name then
        col_struct_type = entry.type or entry[2]
        break
      end
    end
    -- col_struct_type is { data: &ItemType, len: int32 }
    local ItemType
    for _, entry in ipairs(col_struct_type.entries) do
      local ename = entry.field or tostring(entry[1])
      if ename == "data" then
        ItemType = (entry.type or entry[2]).type  -- deref pointer
        break
      end
    end
    local item = symbol(&ItemType, "item")
    local body_q = gen_shape(body_shape, buf, `@[item], ItemType)
    return quote
      for i = 0, [data].[col_name].len do
        var [item] = &[data].[col_name].data[i]
        [body_q]
      end
    end

  elseif shape.kind == "element" then
    local stmts = terralib.newlist()

    -- Opening tag with static attrs
    local open_str = build_static_open(shape.tag, shape.static_attrs, shape.is_void)

    -- Check if there are dynamic attrs
    local has_dynamic = #shape.dynamic_attrs > 0

    if has_dynamic then
      stmts:insert(quote [buf]:write_str(open_str) end)
    end

    -- Dynamic attributes
    for _, dattr in ipairs(shape.dynamic_attrs) do
      if dattr.kind == "dynamic" then
        local fname = dattr.field.name
        local attr_name = dattr.name
        if dattr.field.type == "string" then
          stmts:insert(quote
            [buf]:write_str([" " .. attr_name .. "=\""])
            [buf]:write_escaped([data].[fname])
            [buf]:write_str("\"")
          end)
        elseif dattr.field.type == "int" then
          stmts:insert(quote
            [buf]:write_str([" " .. attr_name .. "=\""])
            [buf]:write_int([data].[fname])
            [buf]:write_str("\"")
          end)
        elseif dattr.field.type == "double" then
          stmts:insert(quote
            [buf]:write_str([" " .. attr_name .. "=\""])
            [buf]:write_double([data].[fname])
            [buf]:write_str("\"")
          end)
        end
      elseif dattr.kind == "boolean" then
        local cond_name = dattr.cond
        local attr_name = dattr.name
        stmts:insert(quote
          if [data].[cond_name] then
            [buf]:write_str([" " .. attr_name])
          end
        end)
      elseif dattr.kind == "ternary" then
        local cond_name = dattr.cond
        local attr_name = dattr.name
        local then_val = dattr.then_
        local else_val = dattr.else_
        stmts:insert(quote
          [buf]:write_str([" " .. attr_name .. "=\""])
          if [data].[cond_name] then
            [buf]:write_str(then_val)
          else
            [buf]:write_str(else_val)
          end
          [buf]:write_str("\"")
        end)
      elseif dattr.kind == "concat" then
        local attr_name = dattr.name
        stmts:insert(quote [buf]:write_str([" " .. attr_name .. "=\""]) end)
        for _, part in ipairs(dattr.parts) do
          local pq = gen_shape(part, buf, data, DataType)
          stmts:insert(pq)
        end
        stmts:insert(quote [buf]:write_str("\"") end)
      elseif dattr.kind == "json" then
        local attr_name = dattr.name
        stmts:insert(quote [buf]:write_str([" " .. attr_name .. "='"]) end)
        stmts:insert(quote [buf]:write_str("{") end)
        for fi, fld in ipairs(dattr.fields) do
          if fi > 1 then
            stmts:insert(quote [buf]:write_str(",") end)
          end
          stmts:insert(quote [buf]:write_str(["\"" .. fld.name .. "\":"]) end)
          if type(fld.value) == "table" and fld.value.kind == "Field" then
            local fshape = analyze_shape(fld.value)
            if fshape.type == "string" then
              stmts:insert(quote [buf]:write_str("\"") end)
              stmts:insert(gen_shape(fshape, buf, data, DataType))
              stmts:insert(quote [buf]:write_str("\"") end)
            else
              stmts:insert(gen_shape(fshape, buf, data, DataType))
            end
          elseif type(fld.value) == "string" then
            stmts:insert(quote [buf]:write_str(["\"" .. fld.value .. "\""]) end)
          end
        end
        stmts:insert(quote [buf]:write_str("}") end)
        stmts:insert(quote [buf]:write_str("'") end)
      elseif dattr.kind == "endpoint" then
        local attr_name = dattr.name
        local path_val = dattr.path
        stmts:insert(quote [buf]:write_str([" " .. attr_name .. "=\"" .. path_val .. "\""]) end)
      elseif dattr.kind == "boolean_literal" then
        local attr_name = dattr.name
        stmts:insert(quote [buf]:write_str([" " .. attr_name]) end)
      end
    end

    -- Close opening tag
    if shape.is_void then
      if has_dynamic then
        stmts:insert(quote [buf]:write_str("/>") end)
      else
        stmts:insert(quote [buf]:write_str([open_str .. "/>"]) end)
      end
    else
      if has_dynamic then
        stmts:insert(quote [buf]:write_str(">") end)
      else
        stmts:insert(quote [buf]:write_str([open_str .. ">"]) end)
      end

      -- Children
      for _, child_shape in ipairs(shape.children) do
        stmts:insert(gen_shape(child_shape, buf, data, DataType))
      end

      -- Closing tag
      stmts:insert(quote [buf]:write_str(["</" .. shape.tag .. ">"]) end)
    end

    return quote [stmts] end

  elseif shape.kind == "concat" then
    local stmts = terralib.newlist()
    for _, part in ipairs(shape.parts) do
      stmts:insert(gen_shape(part, buf, data, DataType))
    end
    return quote [stmts] end

  elseif shape.kind == "json" then
    local stmts = terralib.newlist()
    stmts:insert(quote [buf]:write_str("{") end)
    for fi, fld in ipairs(shape.fields) do
      if fi > 1 then
        stmts:insert(quote [buf]:write_str(",") end)
      end
      stmts:insert(quote [buf]:write_str(["\"" .. fld.name .. "\":"]) end)
      if type(fld.value) == "table" and fld.value.kind == "Field" then
        local fshape = analyze_shape(fld.value)
        if fshape.type == "string" then
          stmts:insert(quote [buf]:write_str("\"") end)
          stmts:insert(gen_shape(fshape, buf, data, DataType))
          stmts:insert(quote [buf]:write_str("\"") end)
        else
          stmts:insert(gen_shape(fshape, buf, data, DataType))
        end
      end
    end
    stmts:insert(quote [buf]:write_str("}") end)
    return quote [stmts] end

  elseif shape.kind == "endpoint" then
    return quote [buf]:write_str(shape.path) end

  else
    return quote end
  end
end

-- ============================================================
-- compile(comp, DataType) -> terra function
-- ============================================================

local function compile(comp, DataType)
  -- Get the template from a component or use directly
  local tmpl
  if type(comp) == "table" and comp._is_component then
    tmpl = comp.template
  elseif type(comp) == "table" and comp.kind then
    tmpl = comp
  else
    error("compile: expected component or AST node", 2)
  end

  -- Phase 1: Inline components
  tmpl = inline_components(tmpl)

  -- Phase 2: Resolve types
  local errors = {}
  resolve_types(tmpl, DataType, errors)
  if #errors > 0 then
    error(table.concat(errors, "\n"), 2)
  end

  -- Phase 3: Analyze shape
  local shape = analyze_shape(tmpl)

  -- Phase 4: Generate Terra function
  local data_sym = symbol(&DataType, "data")
  local buf_sym = symbol(&Buffer, "buf")
  local body = gen_shape(shape, buf_sym, `@[data_sym], DataType)

  local render = terra([data_sym], [buf_sym])
    [body]
  end

  return render
end

ignis.compile = compile

return ignis
