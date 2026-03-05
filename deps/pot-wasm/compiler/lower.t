local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local ROOT = _src:match("^(.*)/[^/]+$") or "."
local ast = dofile(ROOT .. "/ast.t")

local N = ast.N

local M = {}

function M.to_ir(parsed_mod)
  local functions = {}
  for i, fn in ipairs(parsed_mod.funcs or {}) do
    functions[#functions + 1] = N.Func({
      index = i,
      type_idx = fn.type_idx,
    })
  end

  local exports = {}
  for name, e in pairs(parsed_mod.exports or {}) do
    exports[#exports + 1] = N.Export({
      name = name,
      kind = e.kind,
      index = e.index,
    })
  end

  table.sort(exports, function(a, b) return a.name < b.name end)

  local imports = {}
  for _, imp in ipairs(parsed_mod.imports or {}) do
    imports[#imports + 1] = N.Import({
      module = imp.module,
      name = imp.name,
      kind = imp.kind,
      type_idx = imp.type_idx,
    })
  end

  return N.Module({
    functions = functions,
    exports = exports,
    imports = imports,
    meta = N.Meta({
      source = "wasm-binary",
      backend = "pot-wasm-new",
    }),
  })
end

return M
