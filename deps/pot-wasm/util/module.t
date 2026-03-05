local M = {}

function M.this_dir(stack_level)
  local src = debug.getinfo((stack_level or 1) + 1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return src:match("^(.*)/[^/]+$") or "."
end

function M.load_relative(base_dir, rel)
  return dofile(base_dir .. "/" .. rel)
end

return M
