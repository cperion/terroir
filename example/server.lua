-- Luvit HTMX server loading Ignis-compiled templates
-- Run: luvit example/server.lua

local http = require("http")
local ffi = require("ffi")

ffi.cdef[[
  typedef struct { uint8_t* data; int32_t len; int32_t cap; } Buffer;

  typedef struct {
    const char* name;
    const char* kind;
    bool visible;
    int32_t id;
    int32_t feature_count;
  } Layer;

  typedef struct { Layer* data; int32_t len; } LayerList;

  typedef struct {
    const char* title;
    const char* project_name;
    int32_t layer_count;
    int32_t visible_count;
    LayerList layers;
  } PageData;

  typedef struct { LayerList layers; } RowsData;

  void render_page(PageData* data, Buffer* buf);
  void render_row(Layer* data, Buffer* buf);
  void render_rows(RowsData* data, Buffer* buf);
  void buf_init(Buffer* buf);
  void buf_free(Buffer* buf);
]]

local lib = ffi.load("./build/page.so")

-- ============================================================
-- Application state
-- ============================================================

local layers = {
  { id = 1,  name = "Buildings",          kind = "polygon",    visible = true,  feature_count = 12847 },
  { id = 2,  name = "Roads & Highways",   kind = "linestring", visible = true,  feature_count = 38914 },
  { id = 3,  name = "Parcels",            kind = "polygon",    visible = true,  feature_count = 9201  },
  { id = 4,  name = "Hydrology",          kind = "polygon",    visible = false, feature_count = 4312  },
  { id = 5,  name = "Elevation Contours", kind = "linestring", visible = false, feature_count = 71023 },
  { id = 6,  name = "Points of Interest", kind = "point",      visible = true,  feature_count = 2156  },
  { id = 7,  name = "Zoning Districts",   kind = "polygon",    visible = true,  feature_count = 847   },
  { id = 8,  name = "Transit <Stops>",    kind = "point",      visible = false, feature_count = 1893  },
  { id = 9,  name = "Aerial Imagery",     kind = "raster",     visible = true,  feature_count = 1     },
  { id = 10, name = "Land Use & Cover",   kind = "polygon",    visible = false, feature_count = 5621  },
}

-- ============================================================
-- Helpers
-- ============================================================

local function render_buf(fn, data)
  local buf = ffi.new("Buffer")
  lib.buf_init(buf)
  fn(data, buf)
  local html = ffi.string(buf.data, buf.len)
  lib.buf_free(buf)
  return html
end

local function make_layer_array(list)
  local n = #list
  if n == 0 then return nil, 0 end
  local arr = ffi.new("Layer[?]", n)
  for i, l in ipairs(list) do
    arr[i-1].id = l.id
    arr[i-1].name = l.name
    arr[i-1].kind = l.kind
    arr[i-1].visible = l.visible
    arr[i-1].feature_count = l.feature_count
  end
  return arr, n
end

local function visible_count()
  local c = 0
  for _, l in ipairs(layers) do if l.visible then c = c + 1 end end
  return c
end

local function find_layer(id)
  for i, l in ipairs(layers) do
    if l.id == id then return i, l end
  end
  return nil
end

local function filter_layers(query)
  if not query or query == "" then return layers end
  local q = query:lower()
  local results = {}
  for _, l in ipairs(layers) do
    if l.name:lower():find(q, 1, true) or l.kind:lower():find(q, 1, true) then
      results[#results + 1] = l
    end
  end
  return results
end

local function parse_form(body)
  local params = {}
  for pair in body:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]+)=?(.*)")
    if k then
      params[k] = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
  end
  return params
end

local function parse_query(url)
  local q = url:match("%?(.+)$")
  if not q then return {} end
  return parse_form(q)
end

local function read_body(req, cb)
  local chunks = {}
  req:on("data", function(chunk) chunks[#chunks + 1] = chunk end)
  req:on("end", function() cb(table.concat(chunks)) end)
end

local function respond(res, status, html)
  res.statusCode = status
  res:setHeader("Content-Type", "text/html; charset=utf-8")
  res:setHeader("Content-Length", #html)
  res:finish(html)
end

-- ============================================================
-- Routes
-- ============================================================

local function handle_page(req, res)
  local arr, n = make_layer_array(layers)
  local data = ffi.new("PageData", {
    "Terroir", "Downtown GIS Survey",
    #layers, visible_count(),
    { arr, n },
  })
  respond(res, 200, render_buf(lib.render_page, data))
end

local function handle_toggle(req, res)
  read_body(req, function(body)
    local params = parse_form(body)
    local id = tonumber(params.id)
    local idx, layer = find_layer(id)
    if not layer then return respond(res, 404, "") end

    layer.visible = not layer.visible
    local c_layer = ffi.new("Layer", {
      layer.name, layer.kind, layer.visible, layer.id, layer.feature_count,
    })
    local html = render_buf(lib.render_row, c_layer)
    respond(res, 200, html)
    io.write(string.format("  toggle layer %d -> %s\n", id, tostring(layer.visible)))
  end)
end

local function handle_delete(req, res)
  read_body(req, function(body)
    local params = parse_form(body)
    local id = tonumber(params.id)
    local idx = find_layer(id)
    if idx then
      table.remove(layers, idx)
      io.write(string.format("  delete layer %d\n", id))
    end
    respond(res, 200, "")
  end)
end

local function handle_search(req, res)
  local params = parse_query(req.url)
  local q = params.q or ""
  local results = filter_layers(q)

  if #results == 0 then
    respond(res, 200, '<tr><td colspan="4" class="empty-row">No layers match your search</td></tr>')
    return
  end

  local arr, n = make_layer_array(results)
  local data = ffi.new("RowsData", { { arr, n } })
  respond(res, 200, render_buf(lib.render_rows, data))
end

-- ============================================================
-- Server
-- ============================================================

local PORT = 8080

http.createServer(function(req, res)
  local path = req.url:match("^([^?]+)")
  local method = req.method
  io.write(string.format("%s %s\n", method, req.url))

  if method == "GET" and path == "/" then
    handle_page(req, res)
  elseif method == "POST" and path == "/toggle" then
    handle_toggle(req, res)
  elseif method == "POST" and path == "/delete" then
    handle_delete(req, res)
  elseif method == "GET" and path == "/search" then
    handle_search(req, res)
  else
    res.statusCode = 404
    res:finish("not found")
  end
end):listen(PORT)

print(string.format("http://localhost:%d", PORT))
