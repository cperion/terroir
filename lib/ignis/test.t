-- Ignis test suite
-- Run: terra lib/ignis/test.t

package.terrapath = "lib/?.t;lib/?/init.t;" .. (package.terrapath or "")
package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local S = require("strata")
local ignis = require("ignis")

local T = ignis.T
local Buffer = ignis.Buffer
local tags = ignis.tags
local field = ignis.field
local when = ignis.when
local key = ignis.key
local each = ignis.each
local slot = ignis.slot
local concat = ignis.concat
local json = ignis.json
local endpoint = ignis.endpoint
local component = ignis.component
local compile = ignis.compile
local inline_components = ignis.inline_components
local analyze_shape = ignis.analyze_shape

local ffi = require("ffi")
local Cstr = terralib.includec("string.h")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL: " .. name .. "\n") end
end

local function check_error(name, fn)
  local ok, err = pcall(fn)
  if not ok then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL (expected error): " .. name .. "\n") end
end

-- Helper: render a compiled terra function to a Lua string.
-- make_runner should return a terra function: (buf: &Buffer) -> ()
-- that populates data and calls the render function.
local function run_render(runner_fn)
  local buf = terralib.new(Buffer)
  local init_buf = terra(b: &Buffer) b:init() end
  init_buf(buf)
  runner_fn(buf)
  local extract = terra(b: &Buffer) : rawstring
    b:ensure(1)
    b.data[b.len] = 0
    return [rawstring](b.data)
  end
  local s = extract(buf)
  local lua_str = ffi.string(s, buf.len)
  local free_buf = terra(b: &Buffer) b:free() end
  free_buf(buf)
  return lua_str
end

-- ============================================================
-- Schema
-- ============================================================

local elem = T.Element { tag = "div", attrs = {}, children = {} }
check("schema: Element kind", elem.kind == "Element")
check("schema: Element tag", elem.tag == "div")

local txt = T.Text { value = "hello" }
check("schema: Text kind", txt.kind == "Text")

local fld = T.Field { name = "title" }
check("schema: Field kind", fld.kind == "Field")
check("schema: Field optional type nil", fld.type == nil)

check_error("schema: Element missing tag", function()
  T.Element { attrs = {}, children = {} }
end)

-- ============================================================
-- DSL: Tag functions
-- ============================================================

local div = tags.div
check("dsl: tag function exists", type(div) == "function")

local node = tags.div { class = "box"; "Hello" }
check("dsl: tag creates Element", node.kind == "Element")
check("dsl: tag name", node.tag == "div")
check("dsl: attrs count", #node.attrs == 1)
check("dsl: attr name", node.attrs[1].name == "class")
check("dsl: attr value", node.attrs[1].value == "box")
check("dsl: children count", #node.children == 1)
check("dsl: text child", node.children[1].kind == "Text")
check("dsl: text value", node.children[1].value == "Hello")

-- Nested tags
local nested = tags.div { tags.span { "inner" } }
check("dsl: nested element", nested.children[1].kind == "Element")
check("dsl: nested tag", nested.children[1].tag == "span")

-- ============================================================
-- DSL: Helpers
-- ============================================================

local f = field("title")
check("dsl: field", f.kind == "Field" and f.name == "title")

local w = when("active", "yes", "no")
check("dsl: when", w.kind == "When" and w.cond == "active")
check("dsl: when then", w.then_ == "yes")
check("dsl: when else", w.else_ == "no")

local w2 = when("disabled")
check("dsl: when boolean", w2.kind == "When" and w2.cond == "disabled" and w2.then_ == nil)

local k = key("id")
check("dsl: key", k == "id")

local s = slot("header")
check("dsl: slot", s.kind == "Slot" and s.name == "header")

local cc = concat("btn ", field("variant"))
check("dsl: concat", cc.kind == "Concat")
check("dsl: concat parts", #cc.parts == 2)

local j = json { layer_id = field("id") }
check("dsl: json", j.kind == "Json")
check("dsl: json fields", #j.fields == 1)

local ep = endpoint("/layers/toggle")
check("dsl: endpoint", ep.kind == "Endpoint" and ep.path == "/layers/toggle")

-- ============================================================
-- DSL: each chaining
-- ============================================================

local each_node = each("items") { tags.li { field("name") } }
check("dsl: each creates node", each_node.kind == "Each")
check("dsl: each collection", each_node.collection == "items")
check("dsl: each body", each_node.body.kind == "Element")

local each_keyed = each("items", key("id")) { tags.li { "item" } }
check("dsl: each with key", each_keyed.key == "id")

-- ============================================================
-- Components
-- ============================================================

local Card = component(
  tags.div { class = "card"; slot("body") }
)
check("component: is component", Card._is_component == true)
check("component: template", Card.template.kind == "Element")

local card_inst = Card { body = tags.p { "content" } }
check("component: instance", card_inst.kind == "Component")
check("component: bindings", card_inst.bindings.body.kind == "Element")

-- ============================================================
-- Component Inlining
-- ============================================================

local SimpleComp = component(
  tags.div { class = "wrapper"; slot("content") }
)

local tree = tags.section {
  SimpleComp { content = tags.p { "Hello" } }
}

local inlined = inline_components(tree)
check("inline: root preserved", inlined.kind == "Element" and inlined.tag == "section")
check("inline: component replaced", inlined.children[1].kind == "Element")
check("inline: component tag", inlined.children[1].tag == "div")
local inner_children = inlined.children[1].children
check("inline: slot replaced", inner_children[1].kind == "Element" and inner_children[1].tag == "p")

-- ============================================================
-- Shape Analysis
-- ============================================================

local shape_node = tags.div {
  class = "static";
  id = field("my_id");
  disabled = when("is_disabled");
  tags.span { "text" };
}
for _, attr in ipairs(shape_node.attrs) do
  if attr.name == "id" and type(attr.value) == "table" and attr.value.kind == "Field" then
    attr.value.type = "string"
    attr.value.esc = true
  end
end

local shape = analyze_shape(shape_node)
check("shape: element kind", shape.kind == "element")
check("shape: tag", shape.tag == "div")
check("shape: static attrs", #shape.static_attrs == 1)
check("shape: static attr name", shape.static_attrs[1].name == "class")
check("shape: dynamic attrs count", #shape.dynamic_attrs == 2)
check("shape: void element br", analyze_shape(T.Element { tag = "br", attrs = {}, children = {} }).is_void == true)
check("shape: non-void div", shape.is_void == false)

local classified = nil
for _, da in ipairs(shape.dynamic_attrs) do
  if da.name == "disabled" then classified = da end
end
check("shape: boolean attr", classified and classified.kind == "boolean")

local ternary_node = tags.div { class = when("active", "on", "off") }
local ternary_shape = analyze_shape(ternary_node)
check("shape: ternary attr", ternary_shape.dynamic_attrs[1].kind == "ternary")

local concat_node = tags.div { class = concat("btn ", field("variant")) }
for _, attr in ipairs(concat_node.attrs) do
  if attr.name == "class" and type(attr.value) == "table" and attr.value.kind == "Concat" then
    attr.value.parts[2].type = "string"
    attr.value.parts[2].esc = true
  end
end
local concat_shape = analyze_shape(concat_node)
check("shape: concat attr", concat_shape.dynamic_attrs[1].kind == "concat")

local json_node = tags.div { ["data-config"] = json { id = field("layer_id") } }
local json_shape = analyze_shape(json_node)
check("shape: json attr", json_shape.dynamic_attrs[1].kind == "json")

local ep_node = tags.a { href = endpoint("/home") }
local ep_shape = analyze_shape(ep_node)
check("shape: endpoint attr", ep_shape.dynamic_attrs[1].kind == "endpoint")

-- ============================================================
-- Terra Codegen: Static elements
-- ============================================================

struct StaticData {}

local static_render = compile(
  component(tags.div { class = "box"; tags.span { "Hello" } }),
  StaticData
)
do
  local runner = terra(buf: &Buffer)
    var data: StaticData
    static_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: static element", html == '<div class="box"><span>Hello</span></div>')
end

-- ============================================================
-- Terra Codegen: Dynamic fields (string)
-- ============================================================

struct StringData { title: rawstring }

local str_render = compile(
  component(tags.h1 { field("title") }),
  StringData
)
do
  local runner = terra(buf: &Buffer)
    var data: StringData
    data.title = "My Page"
    str_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: string field", html == "<h1>My Page</h1>")
end

-- ============================================================
-- Terra Codegen: Dynamic fields (int)
-- ============================================================

struct IntData { count: int32 }

local int_render = compile(
  component(tags.span { field("count") }),
  IntData
)
do
  local runner = terra(buf: &Buffer)
    var data: IntData
    data.count = 42
    int_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: int field", html == "<span>42</span>")
end

-- ============================================================
-- Terra Codegen: HTML escaping (XSS prevention)
-- ============================================================

struct EscapeData { content: rawstring }

local esc_render = compile(
  component(tags.div { field("content") }),
  EscapeData
)
do
  local runner = terra(buf: &Buffer)
    var data: EscapeData
    data.content = '<script>alert("xss")</script>'
    esc_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: escaping", html == '<div>&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;</div>')
end

do
  local runner = terra(buf: &Buffer)
    var data: EscapeData
    data.content = "AT&T's"
    esc_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: escape amp and apos", html == "<div>AT&amp;T&#39;s</div>")
end

-- ============================================================
-- Terra Codegen: Boolean attributes
-- ============================================================

struct BoolData { is_disabled: bool }

local bool_render = compile(
  component(tags.input { type = "text"; disabled = when("is_disabled") }),
  BoolData
)
do
  local runner = terra(buf: &Buffer)
    var data: BoolData
    data.is_disabled = true
    bool_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: boolean attr true", html == '<input type="text" disabled/>')
end

do
  local runner = terra(buf: &Buffer)
    var data: BoolData
    data.is_disabled = false
    bool_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: boolean attr false", html == '<input type="text"/>')
end

-- ============================================================
-- Terra Codegen: Ternary attributes
-- ============================================================

struct TernaryData { active: bool }

local tern_render = compile(
  component(tags.div { class = when("active", "on", "off") }),
  TernaryData
)
do
  local runner = terra(buf: &Buffer)
    var data: TernaryData
    data.active = true
    tern_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: ternary true", html == '<div class="on"></div>')
end

do
  local runner = terra(buf: &Buffer)
    var data: TernaryData
    data.active = false
    tern_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: ternary false", html == '<div class="off"></div>')
end

-- ============================================================
-- Terra Codegen: Each iteration
-- ============================================================

struct Item { name: rawstring }
struct ItemList { data: &Item; len: int32 }
struct ListData { items: ItemList }

local each_render = compile(
  component(tags.ul { each("items") { tags.li { field("name") } } }),
  ListData
)
do
  local runner = terra(buf: &Buffer)
    var items: Item[3]
    items[0].name = "alpha"
    items[1].name = "beta"
    items[2].name = "gamma"
    var data: ListData
    data.items.data = &items[0]
    data.items.len = 3
    each_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: each", html == "<ul><li>alpha</li><li>beta</li><li>gamma</li></ul>")
end

do
  local runner = terra(buf: &Buffer)
    var data: ListData
    data.items.data = nil
    data.items.len = 0
    each_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: each empty", html == "<ul></ul>")
end

-- ============================================================
-- Terra Codegen: Concat attributes
-- ============================================================

struct ConcatData { variant: rawstring }

local concat_render = compile(
  component(tags.button { class = concat("btn btn-", field("variant")); "Click" }),
  ConcatData
)
do
  local runner = terra(buf: &Buffer)
    var data: ConcatData
    data.variant = "primary"
    concat_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: concat attr", html == '<button class="btn btn-primary">Click</button>')
end

-- ============================================================
-- Terra Codegen: Json attributes
-- ============================================================

struct JsonData { layer_id: int32 }

local json_render = compile(
  component(tags.input { type = "checkbox"; ["hx-vals"] = json { layer_id = field("layer_id") } }),
  JsonData
)
do
  local runner = terra(buf: &Buffer)
    var data: JsonData
    data.layer_id = 42
    json_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: json attr", html == [[<input type="checkbox" hx-vals='{"layer_id":42}'/>]])
end

-- ============================================================
-- Terra Codegen: Endpoint attributes
-- ============================================================

struct EndpointData {}

local ep_render = compile(
  component(tags.a { href = endpoint("/home"); "Home" }),
  EndpointData
)
do
  local runner = terra(buf: &Buffer)
    var data: EndpointData
    ep_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: endpoint attr", html == '<a href="/home">Home</a>')
end

-- ============================================================
-- Terra Codegen: Void elements
-- ============================================================

struct VoidData {}

local void_render = compile(
  component(tags.div { tags.br {}; tags.hr {}; tags.img { src = "pic.png" } }),
  VoidData
)
do
  local runner = terra(buf: &Buffer)
    var data: VoidData
    void_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: void elements", html == '<div><br/><hr/><img src="pic.png"/></div>')
end

-- ============================================================
-- Terra Codegen: Nested structures
-- ============================================================

struct NestedData { title: rawstring; count: int32 }

local nested_render = compile(
  component(tags.div { class = "outer";
    tags.h1 { field("title") };
    tags.p { "Count: "; field("count") };
  }),
  NestedData
)
do
  local runner = terra(buf: &Buffer)
    var data: NestedData
    data.title = "Test"
    data.count = 5
    nested_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: nested", html == '<div class="outer"><h1>Test</h1><p>Count: 5</p></div>')
end

-- ============================================================
-- Terra Codegen: Component with slots end-to-end
-- ============================================================

struct SlotData { heading: rawstring; body_text: rawstring }

local Wrapper = component(
  tags.div { class = "card";
    tags.div { class = "card-header"; slot("header") };
    tags.div { class = "card-body"; slot("body") };
  }
)

local slot_render = compile(
  component(Wrapper {
    header = tags.h2 { field("heading") };
    body = tags.p { field("body_text") };
  }),
  SlotData
)
do
  local runner = terra(buf: &Buffer)
    var data: SlotData
    data.heading = "Welcome"
    data.body_text = "Hello world"
    slot_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: component slots", html == '<div class="card"><div class="card-header"><h2>Welcome</h2></div><div class="card-body"><p>Hello world</p></div></div>')
end

-- ============================================================
-- Terra Codegen: When with children
-- ============================================================

struct WhenData { show: bool }

local when_render = compile(
  component(tags.div {
    when("show", tags.p { "Visible" }, tags.p { "Hidden" });
  }),
  WhenData
)
do
  local runner = terra(buf: &Buffer)
    var data: WhenData
    data.show = true
    when_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: when true", html == "<div><p>Visible</p></div>")
end

do
  local runner = terra(buf: &Buffer)
    var data: WhenData
    data.show = false
    when_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: when false", html == "<div><p>Hidden</p></div>")
end

-- ============================================================
-- Type errors: field not in struct
-- ============================================================

struct SmallData { name: rawstring }

check_error("type error: missing field", function()
  compile(component(tags.div { field("nonexistent") }), SmallData)
end)

-- ============================================================
-- Terra Codegen: Dynamic attribute (string field)
-- ============================================================

struct DynAttrData { my_id: rawstring }

local dynattr_render = compile(
  component(tags.div { id = field("my_id"); "content" }),
  DynAttrData
)
do
  local runner = terra(buf: &Buffer)
    var data: DynAttrData
    data.my_id = "main"
    dynattr_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: dynamic attr", html == '<div id="main">content</div>')
end

-- ============================================================
-- Realistic example: LayerRow-style
-- ============================================================

struct LayerRowData {
  name: rawstring
  layer_type: rawstring
  visible: bool
  layer_id: int32
}

local LayerRow = component(
  tags.tr {
    class = when("visible", "active", "inactive");
    tags.td { field("name") };
    tags.td { field("layer_type") };
    tags.td {
      tags.input {
        type = "checkbox";
        checked = when("visible");
        ["hx-vals"] = json { layer_id = field("layer_id") };
      };
    };
  }
)

local lr_render = compile(LayerRow, LayerRowData)
do
  local runner = terra(buf: &Buffer)
    var data: LayerRowData
    data.name = "Buildings"
    data.layer_type = "polygon"
    data.visible = true
    data.layer_id = 7
    lr_render(&data, buf)
  end
  local html = run_render(runner)
  check("realistic: visible layer", html == '<tr class="active"><td>Buildings</td><td>polygon</td><td><input type="checkbox" checked hx-vals=\'{"layer_id":7}\'/></td></tr>')
end

do
  local runner = terra(buf: &Buffer)
    var data: LayerRowData
    data.name = "Buildings"
    data.layer_type = "polygon"
    data.visible = false
    data.layer_id = 7
    lr_render(&data, buf)
  end
  local html = run_render(runner)
  check("realistic: hidden layer", html == '<tr class="inactive"><td>Buildings</td><td>polygon</td><td><input type="checkbox" hx-vals=\'{"layer_id":7}\'/></td></tr>')
end

-- ============================================================
-- Terra Codegen: Double field
-- ============================================================

struct DoubleData { value: double }

local dbl_render = compile(
  component(tags.span { field("value") }),
  DoubleData
)
do
  local runner = terra(buf: &Buffer)
    var data: DoubleData
    data.value = 3.14
    dbl_render(&data, buf)
  end
  local html = run_render(runner)
  check("codegen: double field", html == "<span>3.14</span>")
end

-- ============================================================
-- Summary
-- ============================================================

print(string.format("ignis: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
