local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then
	_src = _src:sub(2)
end
local ROOT = _src:match("^(.*)/[^/]+$") or "."
local Strata = dofile(ROOT .. "/../../../lib/strata/init.lua")

local N = Strata.schema({
	Module = { "functions", "exports", "imports?", "meta?" },
	Func = { "index", "type_idx?", "params?", "results?", "body?" },
	Export = { "name", "kind", "index" },
	Import = { "module", "name", "kind", "type_idx?" },
	Meta = { "source", "backend" },
})

return {
	Strata = Strata,
	N = N,
}
