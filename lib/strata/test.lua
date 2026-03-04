-- Strata test suite
-- Run: luajit lib/strata/test.lua

package.path = "lib/?.lua;lib/?/init.lua;" .. package.path
local S = require("strata")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL: " .. name .. "\n") end
end

local function check_error(name, fn)
  local ok = pcall(fn)
  if not ok then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL (expected error): " .. name .. "\n") end
end

-- ============================================================
-- Schema
-- ============================================================

local N = S.schema {
  Literal  = { "value", "ty?" },
  BinOp    = { "op", "left", "right" },
  UnaryOp  = { "op", "expr" },
  Name     = { "name", "resolved?" },
  Call     = { "fn", "args" },
  If       = { "cond", "then_", "else_?" },
  Block    = { "stmts" },
}

-- constructors set kind
local lit = N.Literal { value = 42 }
check("schema: kind set", lit.kind == "Literal")
check("schema: value preserved", lit.value == 42)
check("schema: optional nil ok", lit.ty == nil)

-- optional field can be set
local lit2 = N.Literal { value = 1, ty = "int" }
check("schema: optional set", lit2.ty == "int")

-- required field missing errors
check_error("schema: missing required", function()
  N.BinOp { op = "+" }  -- missing left and right
end)

-- _fields and _schema
check("schema: _fields", #N._fields["BinOp"] == 3)
check("schema: _schema", N._schema["Literal"] ~= nil)
check("schema: _required", N._required["BinOp"]["op"] == true)
check("schema: _required optional", N._required["Literal"]["ty"] == nil)

-- registry populated
check("schema: registry", S._registry["BinOp"] ~= nil)

-- ============================================================
-- Test AST
-- ============================================================

-- (1 + x) * 2
local ast = N.BinOp {
  op = "*",
  left = N.BinOp {
    op = "+",
    left = N.Literal { value = 1 },
    right = N.Name { name = "x" },
  },
  right = N.Literal { value = 2 },
}

-- ============================================================
-- walk
-- ============================================================

local visited = {}
S.walk(ast, function(node)
  visited[#visited + 1] = node.kind
end)
check("walk: count", #visited == 5)
check("walk: top-down order", visited[1] == "BinOp")
check("walk: second is left child", visited[2] == "BinOp")
check("walk: leaf", visited[3] == "Literal")

-- walk with list children
local block = N.Block {
  stmts = {
    N.Literal { value = 1 },
    N.Literal { value = 2 },
    N.Literal { value = 3 },
  }
}
local block_visited = {}
S.walk(block, function(n) block_visited[#block_visited + 1] = n.kind end)
check("walk: list children", #block_visited == 4)  -- Block + 3 Literals

-- ============================================================
-- map
-- ============================================================

-- identity transform preserves nodes
local mapped = S.map(ast, function(n) return n end)
check("map: identity shares root", mapped == ast)

-- replace all Literal(1) with Literal(99)
local replaced = S.map(ast, function(n)
  if n.kind == "Literal" and n.value == 1 then
    return N.Literal { value = 99 }
  end
  return n
end)
check("map: root changed", replaced ~= ast)
check("map: replaced value", replaced.left.left.value == 99)
check("map: untouched leaf shared", replaced.right == ast.right)

-- bottom-up: children mapped before parent
local order = {}
S.map(ast, function(n)
  order[#order + 1] = n.kind .. (n.value and tostring(n.value) or "")
  return n
end)
check("map: bottom-up order", order[1] == "Literal1")  -- deepest leaf first

-- ============================================================
-- collect
-- ============================================================

local names = S.collect(ast, function(n) return n.kind == "Name" end)
check("collect: found names", #names == 1)
check("collect: correct name", names[1].name == "x")

local lits = S.collect(ast, function(n) return n.kind == "Literal" end)
check("collect: found literals", #lits == 2)

-- ============================================================
-- fold
-- ============================================================

local depth = S.fold(ast, function(node, child_results)
  if #child_results == 0 then return 1 end
  local max = 0
  for _, r in ipairs(child_results) do
    if r > max then max = r end
  end
  return 1 + max
end)
check("fold: tree depth", depth == 3)

local count = S.fold(ast, function(node, child_results)
  local sum = 1
  for _, r in ipairs(child_results) do sum = sum + r end
  return sum
end)
check("fold: node count", count == 5)

-- ============================================================
-- equal
-- ============================================================

local a1 = N.BinOp { op = "+", left = N.Literal { value = 1 }, right = N.Literal { value = 2 } }
local a2 = N.BinOp { op = "+", left = N.Literal { value = 1 }, right = N.Literal { value = 2 } }
local a3 = N.BinOp { op = "+", left = N.Literal { value = 1 }, right = N.Literal { value = 3 } }

check("equal: same structure", S.equal(a1, a2))
check("equal: different value", not S.equal(a1, a3))
check("equal: identity", S.equal(a1, a1))

-- ignores span
local s1 = N.Literal { value = 5 }
local s2 = N.Literal { value = 5 }
s1.span = { offset = 0, length = 1 }
s2.span = { offset = 99, length = 99 }
check("equal: ignores span", S.equal(s1, s2))

-- different kinds
check("equal: different kinds", not S.equal(N.Literal { value = 1 }, N.Name { name = "x" }))

-- list comparison
local b1 = N.Block { stmts = { N.Literal { value = 1 }, N.Literal { value = 2 } } }
local b2 = N.Block { stmts = { N.Literal { value = 1 }, N.Literal { value = 2 } } }
local b3 = N.Block { stmts = { N.Literal { value = 1 } } }
check("equal: lists same", S.equal(b1, b2))
check("equal: lists differ length", not S.equal(b1, b3))

-- ============================================================
-- match
-- ============================================================

-- basic kind match
local r1 = S.match(N.Literal { value = 42 }, {
  { "Literal", value = S.cap("v") },
  function(v) return v end,
})
check("match: basic capture", r1 == 42)

-- nested match with multiple captures (alphabetical order)
local r2 = S.match(a1, {
  { "BinOp", op = S.cap("op"),
    left = { "Literal", value = S.cap("l") },
    right = { "Literal", value = S.cap("r") } },
  function(l, op, r) return { l = l, op = op, r = r } end,
})
check("match: nested captures", r2.op == "+" and r2.l == 1 and r2.r == 2)

-- S.any matches anything
local r3 = S.match(a1, {
  { "BinOp", op = "+", left = S.any, right = S.cap("r") },
  function(r) return r end,
})
check("match: any", r3.kind == "Literal" and r3.value == 2)

-- S.pred
local r4 = S.match(N.Literal { value = 10 }, {
  { "Literal", value = S.pred(function(v) return v > 5 end) },
  function() return "big" end,

  S.otherwise,
  function() return "small" end,
})
check("match: pred true", r4 == "big")

local r5 = S.match(N.Literal { value = 3 }, {
  { "Literal", value = S.pred(function(v) return v > 5 end) },
  function() return "big" end,

  S.otherwise,
  function() return "small" end,
})
check("match: pred false -> otherwise", r5 == "small")

-- S.otherwise
local r6 = S.match(N.Name { name = "y" }, {
  { "Literal" },
  function() return "lit" end,

  S.otherwise,
  function(node) return node.kind end,
})
check("match: otherwise", r6 == "Name")

-- S.guard
local r7 = S.match(a1, {
  { "BinOp", op = S.cap("op"), left = S.cap("l"), right = S.cap("r") },
  S.guard(
    function(l, op, r) return true end,
    function(l, op, r) return "guarded:" .. op end
  ),
})
check("match: guard pass", r7 == "guarded:+")

-- guard failure falls through
local r8 = S.match(N.Literal { value = 1 }, {
  { "Literal", value = S.cap("v") },
  S.guard(
    function(v) return v > 100 end,  -- fails
    function(v) return "big" end
  ),

  S.otherwise,
  function() return "fallthrough" end,
})
check("match: guard fail falls through", r8 == "fallthrough")

-- no match returns nil
local r9 = S.match(N.Name { name = "z" }, {
  { "Literal" },
  function() return "lit" end,
})
check("match: no match nil", r9 == nil)

-- constant folding pattern (realistic example from doc)
local function fold_constants(ast_node)
  return S.map(ast_node, function(node)
    return S.match(node, {
      { "BinOp", op = "+",
        left = { "Literal", value = S.cap("l") },
        right = { "Literal", value = S.cap("r") } },
      function(l, r) return N.Literal { value = l + r } end,

      { "BinOp", op = "+",
        left = { "Literal", value = 0 },
        right = S.cap("e") },
      function(e) return e end,

      S.otherwise,
      function(n) return n end,
    })
  end)
end

local expr = N.BinOp {
  op = "+",
  left = N.Literal { value = 3 },
  right = N.Literal { value = 4 },
}
local folded = fold_constants(expr)
check("match: const fold", folded.kind == "Literal" and folded.value == 7)

local expr2 = N.BinOp {
  op = "+",
  left = N.Literal { value = 0 },
  right = N.Name { name = "x" },
}
local folded2 = fold_constants(expr2)
check("match: identity elim", folded2.kind == "Name" and folded2.name == "x")

-- ============================================================
-- diag
-- ============================================================

local source = "SELECT *\nFROM users\nWHERE user_nme = $id"
local diag = S.diag(source, "query.ql")

diag:err({ offset = 25, length = 8 }, "undefined variable '%s'", "user_nme")
    :hint("did you mean 'user_name'?")

diag:warn({ offset = 9, length = 4 }, "unused %s", "clause")

check("diag: has_errors", diag:has_errors())
check("diag: error_count", diag:error_count() == 1)
check("diag: warning_count", diag:warning_count() == 1)

-- secondary span
diag:err({ offset = 0, length = 6 }, "duplicate"):also({ offset = 9, length = 4 }, "first here")

check("diag: error_count after second", diag:error_count() == 2)

-- print (visual check — writes to stderr)
-- uncomment to see formatted output:
-- diag:print()

-- ============================================================
-- parser_context
-- ============================================================

local psrc = "hello world"
local pctx = S.parser_context(psrc, "test.lua")

check("parser: active", S._active_parser == pctx)

pctx.pos = 0
local pnode = pctx:with_span(function()
  pctx.pos = 5
  return N.Name { name = "hello" }
end)
check("parser: span offset", pnode.span.offset == 0)
check("parser: span length", pnode.span.length == 5)

-- nested with_span
pctx.pos = 6
local outer = pctx:with_span(function()
  pctx.pos = 11
  return N.BinOp {
    op = "+",
    left = N.Literal { value = 1 },
    right = N.Literal { value = 2 },
  }
end)
check("parser: nested span", outer.span.offset == 6 and outer.span.length == 5)

-- span propagation from children (without with_span)
pctx.pos = 100
local child1 = pctx:with_span(function()
  pctx.pos = 103
  return N.Literal { value = 1 }
end)

pctx.pos = 110
local child2 = pctx:with_span(function()
  pctx.pos = 115
  return N.Literal { value = 2 }
end)

-- parent constructed without with_span — should propagate
local parent = N.BinOp { op = "+", left = child1, right = child2 }
check("parser: propagated span", parent.span ~= nil)
check("parser: propagated offset", parent.span.offset == 100)
check("parser: propagated length", parent.span.length == 15)

pctx:close()
check("parser: closed", S._active_parser == nil)

-- ============================================================
-- Summary
-- ============================================================

print(string.format("strata: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
