# Strata

### A Compiler Construction Library for Terra

*Internal Technical Paper — v1.0*

---

## 1. What Strata Is

Strata is approximately 300 lines of Lua providing three things that are tedious to write from scratch and identical across every compiler: schema-driven AST nodes with traversal, structural pattern matching, and source-mapped diagnostics.

Everything else — passes, type systems, rewrites, code generation — is direct Lua and Terra code. Strata has no opinion about these because they are specific to the language being compiled. It provides the mechanical foundation and gets out of the way.

Strata is used within Terroir to build the pipeline compiler, the filter expression compiler, the style rule compiler, the MVT encoder generator, and Ignis (the template compiler). Each of these is a separate compiler sharing the same Strata primitives.

---

## 2. Design Principles

**Lua tables all the way down.** AST nodes are tables. Schemas are tables. Diagnostics are tables. There are no opaque objects, no metatables hiding state, no framework abstractions. `print(node.op)` works. `for k,v in pairs(node)` works. Everything is inspectable at every point.

**Terra already is a compiler toolkit.** Lua functions are passes. Calling them in order is a pipeline. Terra quotes are codegen. `terralib.types.newstruct()` is dynamic type construction. Strata does not reimplement any of this. It provides only what Lua and Terra lack: schema-aware tree operations and structured error reporting.

**Plain Lua is always acceptable.** Pattern matching is provided for convenience. But `if node.kind == "BinOp" and node.op == "+" then` is fine and often clearer. Strata does not penalize direct Lua. The library is an option, not a requirement.

---

## 3. Nodes

### 3.1 Schema Declaration

```lua
local S = require("strata")

local N = S.schema {
  Literal  = { "value", "ty?" },
  BinOp    = { "op", "left", "right" },
  UnaryOp  = { "op", "expr" },
  Name     = { "name", "resolved?" },
  Call     = { "fn", "args" },
  Index    = { "expr", "index" },
  Field    = { "expr", "name" },
  If       = { "cond", "then_", "else_?" },
  Block    = { "stmts" },
  Func     = { "name", "params", "body", "ret_ty?" },
  Assign   = { "target", "value" },
  While    = { "cond", "body" },
  Return   = { "value?" },
}
```

Fields ending in `?` are optional (may be nil). All other fields are required — the constructor errors if they're missing.

The schema is stored as a Lua table (`N._schema`) accessible at compile time for traversal, codegen, and introspection.

### 3.2 Constructors

The schema generates constructor functions:

```lua
local ast = N.BinOp {
  op = "+",
  left = N.Literal { value = 1 },
  right = N.Name { name = "x" },
}
```

Constructors validate required fields, set `kind` on the resulting table, and attach source spans if a parser context is active. The result is a plain Lua table:

```lua
ast.kind      -- "BinOp"
ast.op        -- "+"
ast.left.kind -- "Literal"
ast.left.value -- 1
ast.span      -- { offset = 12, length = 5 } (if parser context active)
```

No wrappers, no proxies, no metatables. Tables.

### 3.3 Span Attachment

During parsing, a context tracks the current source position. Constructors created within a parser context inherit spans automatically:

```lua
local parser = S.parser_context(source_text, filename)

-- within the parser:
local node = parser:with_span(function()
  return N.BinOp { op = "+", left = parse_expr(), right = parse_expr() }
end)
-- node.span = { offset = <start>, length = <end - start> }
```

Spans propagate: if a node has no explicit span but its children do, the node's span covers from the first child's start to the last child's end.

---

## 4. Traversal

The schema knows which fields contain child nodes (tables with a `kind` field) and which contain data (strings, numbers, booleans, nil). Traversals use the schema to recurse correctly without the compiler author listing child fields.

### 4.1 walk

Top-down, depth-first. Visits every node. Does not modify the tree.

```lua
S.walk(ast, function(node)
  if node.kind == "Name" then
    print("found name: " .. node.name)
  end
end)
```

### 4.2 map

Bottom-up transform. Children are mapped before parents, so the visitor function sees already-transformed children. Returns a new tree — the original is not modified.

```lua
local new_ast = S.map(ast, function(node)
  -- children are already mapped when this runs
  if node.kind == "Literal" and node.value == 0 then
    return N.Literal { value = 0, ty = "int" }
  end
  return node  -- unchanged
end)
```

Returning the same node means no change. Returning a different node replaces it. The tree structure is rebuilt only along the path of changes — unchanged subtrees are shared.

### 4.3 collect

Gathers all nodes matching a predicate into a flat list. Top-down order.

```lua
local names = S.collect(ast, function(node)
  return node.kind == "Name"
end)
-- names is a list of all Name nodes in the tree
```

### 4.4 fold

Bottom-up accumulation. The visitor receives the node and a list of results from its children.

```lua
local depth = S.fold(ast, function(node, child_results)
  if #child_results == 0 then return 1 end
  return 1 + math.max(table.unpack(child_results))
end)
```

### 4.5 Custom Traversal

The schema is a Lua table. Writing a custom traversal is straightforward:

```lua
local function count_nodes(node)
  local total = 1
  for _, field_name in ipairs(N._fields[node.kind]) do
    local child = node[field_name]
    if type(child) == "table" then
      if child.kind then
        total = total + count_nodes(child)
      elseif #child > 0 then
        for _, item in ipairs(child) do
          if type(item) == "table" and item.kind then
            total = total + count_nodes(item)
          end
        end
      end
    end
  end
  return total
end
```

`N._fields[kind]` returns the ordered list of field names for a node kind, including optional fields. This is the same list the built-in traversals use.

---

## 5. Pattern Matching

Structural matching over AST nodes with captures.

### 5.1 Basic Usage

```lua
local result = S.match(node, {
  -- pattern, handler pairs
  { "BinOp", op = "+", left = { "Literal", value = 0 }, right = S.cap("e") },
  function(e) return e end,

  { "BinOp", op = S.cap("op"),
    left = { "Literal", value = S.cap("l") },
    right = { "Literal", value = S.cap("r") } },
  function(op, l, r)
    local ops = {
      ["+"] = function(a,b) return a+b end,
      ["*"] = function(a,b) return a*b end,
    }
    if ops[op] then return N.Literal { value = ops[op](l, r) } end
  end,

  S.otherwise,
  function(node) return node end,
})
```

### 5.2 Pattern Syntax

A pattern is a table. The first element (string) matches the node's `kind`. Named fields match the node's fields. Nested tables match recursively. Special values:

`S.cap("name")` — captures the value at this position, passed as an argument to the handler. Captures are passed in alphabetical order by name.

`S.any` — matches anything, does not capture.

`S.pred(fn)` — matches if `fn(value)` returns true.

`S.otherwise` — matches any node (default case).

### 5.3 Guards

Patterns can have guard conditions:

```lua
{ "BinOp", op = S.cap("op"), left = S.cap("l"), right = S.cap("r") },
S.guard(
  function(op, l, r) return l.kind == "Literal" and r.kind == "Literal" end,
  function(op, l, r) return N.Literal { value = eval_op(op, l.value, r.value) } end
),
```

The guard function receives the same captures as the handler. If it returns false, matching continues to the next pattern.

### 5.4 When Patterns Aren't Worth It

For simple checks, direct Lua is clearer:

```lua
-- this is fine
if node.kind == "BinOp" and node.op == "+" and
   node.left.kind == "Literal" and node.left.value == 0 then
  return node.right
end
```

Use patterns when you have multiple cases with structural destructuring. Use plain Lua for simple conditions and one-off checks.

---

## 6. Structural Equality

```lua
local equal = S.equal(ast1, ast2)
```

Deep structural comparison of two AST nodes. Two nodes are equal if they have the same `kind`, the same values for data fields, and structurally equal children. Ignores spans (source location metadata is not part of structural identity).

Used primarily for fixed-point rewriting:

```lua
local function rewrite_fixpoint(ast, rewrite_fn)
  local prev
  repeat
    prev = ast
    ast = rewrite_fn(ast)
  until S.equal(ast, prev)
  return ast
end
```

---

## 7. Diagnostics

Source-mapped error and warning accumulation with formatted display.

### 7.1 Creating a Diagnostic Context

```lua
local diag = S.diag(source_text, filename)
```

The context holds the source text, filename, and a list of accumulated diagnostics.

### 7.2 Reporting

```lua
-- error with span from an AST node
diag:err(node.span, "undefined variable '%s'", node.name)

-- error with a hint
diag:err(node.span, "type mismatch: expected %s, got %s", expected, actual)
    :hint("try wrapping in toFloat()")

-- error with a secondary span
diag:err(node.span, "duplicate definition of '%s'", name)
    :also(first_def.span, "first defined here")

-- warning
diag:warn(node.span, "unused variable '%s'", name)
```

### 7.3 Display

```lua
diag:print()
```

Renders all accumulated diagnostics with source context:

```
error: undefined variable 'user_nme'
  --> query.ql:7:15
   |
 7 |   WHERE user_nme = $id
   |         ^^^^^^^^
   = hint: did you mean 'user_name'?

error: type mismatch: expected int, got string
  --> query.ql:12:22
   |
12 |   AND price = "expensive"
   |                ^^^^^^^^^^
   = hint: try wrapping in toFloat()

warning: unused variable 'temp'
  --> query.ql:3:7
   |
 3 |   var temp = 0
   |       ^^^^
```

The formatter maps byte offsets to line/column positions, extracts the relevant source line, positions the underline from the span's offset and length, and appends hints and secondary locations.

### 7.4 Querying State

```lua
if diag:has_errors() then
  -- stop compilation after analysis, skip codegen
end

local count = diag:error_count()
local warnings = diag:warning_count()
```

---

## 8. The Compiler Pattern

There is no pipeline API. A compiler is a Lua function that calls other Lua functions.

```lua
function compile(source_text, filename)
  local diag = S.diag(source_text, filename)

  local ast = parse(source_text, diag)
  if diag:has_errors() then diag:print(); return nil end

  local symbols = resolve_names(ast, diag)
  if diag:has_errors() then diag:print(); return nil end

  typecheck(ast, symbols, diag)
  if diag:has_errors() then diag:print(); return nil end

  local optimized = fold_constants(ast)

  local fn = codegen(optimized, symbols)
  return fn, diag
end
```

Pass ordering is calling order. Data flow is arguments and return values. Error handling is `if diag:has_errors()`. There is nothing to register, configure, or declare.

---

## 9. The Codegen Pattern

The code generation pass maps AST nodes to Terra quotes. This is where Terra's unique power comes in: the output is LLVM IR, which compiles to machine code.

```lua
local function gen_expr(node, env)
  if node.kind == "Literal" then
    return `[node.value]

  elseif node.kind == "Name" then
    return `[env[node.resolved]]

  elseif node.kind == "BinOp" then
    local l = gen_expr(node.left, env)
    local r = gen_expr(node.right, env)
    if     node.op == "+" then return `l + r
    elseif node.op == "-" then return `l - r
    elseif node.op == "*" then return `l * r
    elseif node.op == "/" then return `l / r
    elseif node.op == ">" then return `l > r
    elseif node.op == "==" then return `l == r
    end

  elseif node.kind == "If" then
    local cond = gen_expr(node.cond, env)
    local then_ = gen_expr(node.then_, env)
    if node.else_ then
      local else_ = gen_expr(node.else_, env)
      return quote if [cond] then [then_] else [else_] end end
    else
      return quote if [cond] then [then_] end end
    end

  elseif node.kind == "Call" then
    local fn = gen_expr(node.fn, env)
    local args = node.args:map(function(a) return gen_expr(a, env) end)
    return `fn([args])
  end
end
```

Building functions:

```lua
local function gen_function(node, env)
  local params = {}
  for _, p in ipairs(node.params) do
    local sym = symbol(to_terra_type(p.ty), p.name)
    env[p.resolved] = sym
    table.insert(params, sym)
  end

  local body = gen_expr(node.body, env)
  local ret_type = to_terra_type(node.ret_ty)

  local terra fn([params]): ret_type
    return [body]
  end

  return fn
end
```

The output is a compiled Terra function. It can be called from Lua, saved to an object file, compiled to WASM, or specialized from WASM to native `.so` through the Terroir specializer.

---

## 10. The Type System Pattern

Most DSL type systems are small. Use Lua tables, not a framework.

```lua
local function PrimType(name) return { kind = "prim", name = name } end
local function ArrayType(elem) return { kind = "array", elem = elem } end
local function NullableType(inner) return { kind = "nullable", inner = inner } end
local function RecordType(fields) return { kind = "record", fields = fields } end

local Int    = PrimType("int")
local Float  = PrimType("float")
local String = PrimType("string")
local Bool   = PrimType("bool")

local function assignable(from, to)
  if from == to then return true end
  if from == Int and to == Float then return true end
  if to.kind == "nullable" then return assignable(from, to.inner) end
  if from.kind == "record" and to.kind == "record" then
    for name, ty in pairs(to.fields) do
      if not from.fields[name] or not assignable(from.fields[name], ty) then
        return false
      end
    end
    return true
  end
  return false
end
```

Map DSL types to Terra types:

```lua
local type_map = {
  [Int]    = int,
  [Float]  = double,
  [String] = rawstring,
  [Bool]   = bool,
}

local function to_terra_type(ty)
  if type_map[ty] then return type_map[ty] end
  if ty.kind == "array" then
    return struct { data: &to_terra_type(ty.elem); len: int }
  end
  if ty.kind == "record" then
    local s = terralib.types.newstruct()
    for name, field_ty in pairs(ty.fields) do
      s.entries:insert({ field = name, type = to_terra_type(field_ty) })
    end
    return s
  end
end
```

If you need type inference, write a unification function. It's about 40 lines. If your language has five types and explicit annotations, a lookup table is fine.

---

## 11. The Rewriting Pattern

Constant folding, desugaring, optimization — use `S.map` with `S.match`:

```lua
local function fold_constants(ast)
  return S.map(ast, function(node)
    return S.match(node, {
      { "BinOp", op = "+",
        left = { "Literal", value = S.cap("l") },
        right = { "Literal", value = S.cap("r") } },
      function(l, r) return N.Literal { value = l + r } end,

      { "BinOp", op = "+",
        left = { "Literal", value = 0 },
        right = S.cap("e") },
      function(e) return e end,

      { "BinOp", op = "*",
        left = { "Literal", value = 1 },
        right = S.cap("e") },
      function(e) return e end,

      S.otherwise,
      function(n) return n end,
    })
  end)
end
```

For fixed-point iteration:

```lua
local optimized = rewrite_fixpoint(ast, fold_constants)
```

---

## 12. Usage Within Terroir

Strata is used by five compilers within the Terroir platform:

**Pipeline compiler.** Transforms pipeline definitions into WASM modules. Uses Strata nodes for the pipeline AST (sources, transforms, outputs), diagnostics for schema validation errors.

**Filter expression compiler.** Compiles filter DSL expressions to vectorized native code operating on Arrow columns. Uses Strata nodes for expression ASTs, pattern matching for constant folding and predicate simplification.

**Style rule compiler.** Compiles map style rules to decision trees. Uses Strata nodes for style ASTs, pattern matching for rule optimization (merging adjacent zoom ranges, eliminating dead branches).

**MVT encoder generator.** Generates schema-specific protobuf encoding code. Uses Strata nodes to represent the encoding plan.

**Ignis (template compiler).** Compiles HTML templates to buffer-write sequences (SSR) or DOM-mutation sequences (WASM). Uses Strata nodes for the template AST, diagnostics for template validation errors. Documented separately.

Each compiler follows the same pattern: define nodes with `S.schema`, write passes as Lua functions, use `S.walk`/`S.map`/`S.match` for tree operations, accumulate errors with `S.diag`, emit Terra quotes in the codegen pass. Strata provides the common mechanics; each compiler provides the domain semantics.

---

## 13. API Reference

```
S.schema(defs)                          → node constructors table
S.walk(node, fn)                        → nil (side effects only)
S.map(node, fn)                         → new node
S.collect(node, pred)                   → list of nodes
S.fold(node, fn)                        → accumulated value
S.match(node, pattern_handler_pairs)    → result from matched handler
S.equal(a, b)                           → boolean
S.cap(name)                             → capture marker
S.any                                   → wildcard marker
S.pred(fn)                              → predicate marker
S.otherwise                             → default pattern
S.guard(pred_fn, handler_fn)            → guarded handler
S.diag(source, filename)                → diagnostic context
  :err(span, fmt, ...)                  → diagnostic (chainable)
  :warn(span, fmt, ...)                 → diagnostic (chainable)
  :hint(text)                           → adds hint to last diagnostic
  :also(span, text)                     → adds secondary location
  :has_errors()                         → boolean
  :error_count()                        → int
  :warning_count()                      → int
  :print()                              → renders all diagnostics to stderr
S.parser_context(source, filename)      → parser context
  :with_span(fn)                        → node with span attached
```

---

*Strata: just enough library to get out of your way.*
