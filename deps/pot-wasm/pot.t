-- New POT-WASM entrypoint.
-- Keep this file tiny: API lives in init.t.
local _src = debug.getinfo(1, "S").source
if _src:sub(1, 1) == "@" then _src = _src:sub(2) end
local ROOT = _src:match("^(.*)/[^/]+$") or "."
return terralib.loadfile(ROOT .. "/init.t")()
