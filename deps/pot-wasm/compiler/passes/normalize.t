local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local ROOT = _src:match("^(.*)/[^/]+$") or "."

local ast = dofile(ROOT .. "/../ast.t")
local Strata = ast.Strata
local N = ast.N

local M = {}

local function normalize_module_lists(mod)
  local exports = {}
  for i = 1, #(mod.exports or {}) do
    exports[i] = mod.exports[i]
  end
  table.sort(exports, function(a, b) return a.name < b.name end)

  local funcs = {}
  for i = 1, #(mod.functions or {}) do
    local f = mod.functions[i]
    funcs[i] = N.Func({
      index = f.index,
      type_idx = f.type_idx,
      params = f.params,
      results = f.results,
      body = f.body,
    })
  end

  return N.Module({
    functions = funcs,
    exports = exports,
    imports = mod.imports or {},
    meta = mod.meta,
  })
end

function M.run(ir)
  local mapped = Strata.map(ir, function(node)
    if node.kind == "Func" then
      return N.Func({
        index = node.index,
        type_idx = node.type_idx,
        params = node.params,
        results = node.results,
        body = node.body,
      })
    end
    if node.kind == "Export" then
      return N.Export({ name = node.name, kind = node.kind, index = node.index })
    end
    return node
  end)

  assert(mapped and mapped.kind == "Module", "normalize pass expected Module node")
  return normalize_module_lists(mapped)
end

return M
