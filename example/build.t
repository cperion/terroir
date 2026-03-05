-- Ignis HTMX demo: compile templates to shared library
-- Run: terra example/build.t

package.terrapath = "lib/?.t;lib/?/init.t;" .. (package.terrapath or "")
package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local ignis = require("ignis")
local Buffer = ignis.Buffer
local tags = ignis.tags
local field = ignis.field
local when = ignis.when
local each = ignis.each
local key = ignis.key
local slot = ignis.slot
local concat = ignis.concat
local json = ignis.json
local endpoint = ignis.endpoint
local component = ignis.component
local compile = ignis.compile

-- ============================================================
-- Data types
-- ============================================================

struct Layer {
  name: rawstring
  kind: rawstring
  visible: bool
  id: int32
  feature_count: int32
}

struct LayerList {
  data: &Layer
  len: int32
}

struct PageData {
  title: rawstring
  project_name: rawstring
  layer_count: int32
  visible_count: int32
  layers: LayerList
}

struct RowsData {
  layers: LayerList
}

-- ============================================================
-- CSS
-- ============================================================

local css = [[
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:system-ui,-apple-system,sans-serif;background:#0d1117;color:#c9d1d9;line-height:1.6}
.container{max-width:900px;margin:0 auto;padding:2rem 1.5rem}

header{margin-bottom:2rem}
header h1{font-size:1.75rem;color:#58a6ff;margin-bottom:.25rem}
header h1 span{color:#7ee787}
header p{color:#8b949e;font-size:.95rem}

.stats{display:flex;gap:.75rem;margin-bottom:1.5rem;flex-wrap:wrap}
.stat{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:.6rem 1rem;font-size:.9rem;color:#8b949e}
.stat strong{color:#c9d1d9;font-size:1.1rem;margin-left:.25rem}
.stat.highlight strong{color:#7ee787}

.panel{background:#161b22;border:1px solid #30363d;border-radius:10px;overflow:hidden;margin-bottom:1.5rem}
.panel-header{padding:.75rem 1.25rem;border-bottom:1px solid #30363d;display:flex;align-items:center;justify-content:space-between;gap:1rem}
.panel-header h2{font-size:1rem;color:#c9d1d9;font-weight:600}

.search-input{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:.4rem .75rem;color:#c9d1d9;font-size:.85rem;width:220px;outline:none;transition:border-color .2s}
.search-input:focus{border-color:#58a6ff}
.search-input::placeholder{color:#484f58}

table{width:100%;border-collapse:collapse}
thead th{padding:.6rem 1rem;text-align:left;font-size:.75rem;text-transform:uppercase;letter-spacing:.05em;color:#8b949e;font-weight:600;border-bottom:1px solid #30363d}
tbody tr{border-bottom:1px solid #21262d;transition:background .15s}
tbody tr:hover{background:#1c2128}
tbody td{padding:.65rem 1rem;font-size:.9rem;vertical-align:middle}

tr.row-active{}
tr.row-muted{opacity:.45}
tr.row-muted:hover{opacity:.7}

.cell-name{display:flex;align-items:center;gap:.6rem}
.layer-name{font-weight:500}

.badge{display:inline-block;padding:.1rem .5rem;border-radius:10px;font-size:.7rem;font-weight:600;text-transform:uppercase;letter-spacing:.03em}
.badge-polygon{background:#238636;color:#fff}
.badge-linestring{background:#1f6feb;color:#fff}
.badge-point{background:#d29922;color:#fff}
.badge-raster{background:#8957e5;color:#fff}

.cell-count{color:#8b949e;font-variant-numeric:tabular-nums}
.cell-toggle{text-align:center;width:80px}
.cell-actions{text-align:right;width:80px}

.toggle{position:relative;display:inline-block;width:36px;height:20px;cursor:pointer}
.toggle input{opacity:0;width:0;height:0}
.toggle-slider{position:absolute;inset:0;background:#30363d;border-radius:20px;transition:background .2s}
.toggle-slider:before{content:"";position:absolute;height:14px;width:14px;left:3px;bottom:3px;background:#c9d1d9;border-radius:50%;transition:transform .2s}
.toggle input:checked+.toggle-slider{background:#238636}
.toggle input:checked+.toggle-slider:before{transform:translateX(16px)}

.btn-delete{background:transparent;border:1px solid #30363d;color:#8b949e;border-radius:6px;padding:.25rem .6rem;font-size:.8rem;cursor:pointer;transition:all .15s}
.btn-delete:hover{border-color:#f85149;color:#f85149;background:rgba(248,81,73,.1)}

.empty-row{text-align:center;padding:2rem !important;color:#484f58;font-style:italic}

footer{text-align:center;color:#30363d;font-size:.8rem;margin-top:2rem;padding-top:1rem;border-top:1px solid #21262d}
footer em{color:#484f58}
footer strong{color:#58a6ff}

.htmx-swapping{opacity:.5;transition:opacity .2s}
tr.htmx-added{animation:fadeIn .3s}
@keyframes fadeIn{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:translateY(0)}}
]]

-- ============================================================
-- Components
-- ============================================================

-- [Feature: component + slot] Reusable panel wrapper
local Panel = component(
  tags.div { class = "panel";
    tags.div { class = "panel-header"; slot("header") };
    slot("body");
  }
)

-- [Feature: ternary attr, concat attr, boolean attr, json attr, endpoint attr]
-- [Feature: each iteration targets this for individual row rendering]
local LayerRow = component(
  tags.tr {
    -- [ternary attribute] row class based on visibility
    class = when("visible", "row-active", "row-muted");
    -- [concat attribute] dynamic id for targeting
    id = concat("layer-", field("id"));

    tags.td {
      tags.div { class = "cell-name";
        -- [escaped string field] name is rawstring, auto-escaped
        tags.span { class = "layer-name"; field("name") };
        -- [concat attribute] dynamic badge class from layer kind
        tags.span { class = concat("badge badge-", field("kind")); field("kind") };
      };
    };

    -- [int field] numeric rendering
    tags.td { class = "cell-count"; field("feature_count") };

    tags.td { class = "cell-toggle";
      tags.label { class = "toggle";
        tags.input {
          -- [void element] input is self-closing
          type = "checkbox";
          -- [boolean attribute] present when visible, absent when not
          checked = when("visible");
          -- [endpoint attribute] HTMX post target
          ["hx-post"] = endpoint("/toggle");
          -- [json attribute] sends {"id":N} as request body
          ["hx-vals"] = json { id = field("id") };
          ["hx-target"] = "closest tr";
          ["hx-swap"] = "outerHTML";
          ["hx-indicator"] = "closest tr";
        };
        tags.span { class = "toggle-slider" };
      };
    };

    tags.td { class = "cell-actions";
      tags.button {
        class = "btn-delete";
        ["hx-post"] = endpoint("/delete");
        ["hx-vals"] = json { id = field("id") };
        ["hx-target"] = "closest tr";
        ["hx-swap"] = "outerHTML";
        ["hx-confirm"] = "Remove this layer?";
        "Delete";
      };
    };
  }
)

-- Full page template
local Page = component(
  tags.html { lang = "en";
    tags.head {
      -- [void elements] meta, link
      tags.meta { charset = "utf-8" };
      tags.meta { name = "viewport"; content = "width=device-width, initial-scale=1" };
      tags.title { field("title") };
      tags.style { css };
      tags.script { src = "https://unpkg.com/htmx.org@2.0.4" };
    };
    tags.body {
      tags.div { class = "container";
        tags.header {
          -- [string fields] title and project name
          tags.h1 { field("title"); " "; tags.span { field("project_name") } };
          tags.p { "Compiled HTML templates serving a live HTMX interface" };
        };

        -- [int fields] stats
        tags.div { class = "stats";
          tags.div { class = "stat"; "Layers"; tags.strong { field("layer_count") } };
          tags.div { class = "stat highlight"; "Visible"; tags.strong { field("visible_count") } };
        };

        -- [component + slots] Panel wrapping the layer table
        Panel {
          header = tags.div {
            tags.h2 { "Layers" };
            tags.input {
              type = "search";
              name = "q";
              class = "search-input";
              placeholder = "Filter layers...";
              autocomplete = "off";
              -- [endpoint + static HTMX attrs] live search
              ["hx-get"] = endpoint("/search");
              ["hx-trigger"] = "input changed delay:200ms";
              ["hx-target"] = "#layer-tbody";
            };
          };
          body = tags.table {
            tags.thead {
              tags.tr {
                tags.th { "Layer" };
                tags.th { "Features" };
                tags.th { "Visible" };
                tags.th { "" };
              };
            };
            -- [each iteration] over layers collection
            tags.tbody { id = "layer-tbody";
              each("layers") {
                LayerRow {}
              };
            };
          };
        };

        tags.footer {
          tags.em {
            "Served by ";
            tags.strong { "Ignis" };
            " -- compiled HTML templates for Terra";
          };
        };
      };
    };
  }
)

-- ============================================================
-- Compile templates
-- ============================================================

-- Full page: PageData -> HTML document
local render_page = compile(Page, PageData)

-- Single row: Layer -> <tr> (for HTMX toggle swap)
local render_row = compile(LayerRow, Layer)

-- Multiple rows: RowsData -> <tr>... (for HTMX search results)
local render_rows = compile(
  component(each("layers") { LayerRow {} }),
  RowsData
)

-- ============================================================
-- Export shared library
-- ============================================================

local buf_init = terra(buf: &Buffer) buf:init() end
local buf_free = terra(buf: &Buffer) buf:free() end

terralib.saveobj("build/page.so", {
  render_page = render_page,
  render_row = render_row,
  render_rows = render_rows,
  buf_init = buf_init,
  buf_free = buf_free,
})

print("build/page.so written")
