# Ignis

### A Compiled HTML Template Engine for Terra

*Internal Technical Paper — v1.0*

---

## 1. What Ignis Is

Ignis is a template compiler. It takes HTML template definitions written as Lua DSL calls, analyzes them at compile time, and generates either byte-buffer write sequences (for server-side rendering) or DOM mutation functions (for client-side WASM). The templates are fully consumed by the compiler. What ships is native code that does nothing but the work: writing bytes or mutating DOM nodes.

Within Terroir, Ignis compiles the `output = html { ... }` stage of UI pipelines. It reads data from Arrow record batches produced by DataFusion and writes HTML directly to a response buffer or patches a live DOM tree. But Ignis is a standalone compiler — it can be used independently of Terroir for any application that needs compiled HTML templates.

Ignis uses Strata for AST nodes, traversal, and diagnostics.

---

## 2. Template Language

Templates are Lua function calls that build an AST consumed by the compiler. The syntax mirrors HTML structure while being ordinary Lua — the full power of Lua is available at the meta level.

### 2.1 Elements and Text

```lua
local PageHeader = component {
  header {
    class = "site-header";
    nav {
      a { href = "/home"; "Home" };
      a { href = "/about"; "About" };
    };
    h1 { field "title" };
  };
}
```

Tag names (`header`, `nav`, `a`, `h1`) are Lua functions returning AST nodes. String literals (`"Home"`) become static text children. `field` marks a dynamic binding — a value from a typed data struct at render time.

### 2.2 Components

```lua
local LayerRow = component {
  tr {
    class = when("visible", "active", "inactive");
    td { field "name" };
    td { field "type" };
    td { LayerToggle { bind = "toggle_data" } };
    td { DeleteButton { bind = "delete_data" } };
  };
}
```

Components compose. `LayerToggle { bind = "toggle_data" }` embeds a sub-component bound to a sub-struct of the parent data. At compile time, the sub-component's logic is inlined into the parent — no component boundary at runtime.

### 2.3 Lists

```lua
local LayerTable = component {
  table {
    thead { tr { th {"Name"}; th {"Type"}; th {"Visible"}; th {""} } };
    tbody {
      each("layers", key "id") {
        LayerRow {}
      };
    };
  };
}
```

`each` generates list reconciliation code (client target) or iteration code (SSR target). `key` designates the identity field for efficient insert/remove/reorder.

### 2.4 Slots

```lua
local Card = component {
  div {
    class = "card";
    div { class = "card-header"; slot "header" };
    div { class = "card-body"; slot "body" };
  };
}

Card {
  header = { h2 { field "title" } };
  body   = { p { field "description" } };
}
```

Slots are compile-time insertion points. Caller content is inlined at the slot site during compilation.

---

## 3. Type-Safe Escaping

Every `field` reference resolves against a typed struct at compile time. The field's type determines the escaping strategy. This is not configurable — it follows from the type system.

```
rawstring  →  always escaped           (safe, pays escape cost)
SafeHTML   →  never escaped            (caller guarantees cleanliness)
int/float  →  never escaped            (compiler proves safety)
bool       →  becomes attribute flag   (no value written)
```

The default is escaped. Numeric types cannot contain HTML special characters — the compiler skips escaping. `SafeHTML` is an explicit opt-out requiring the caller to sanitize. Passing a `rawstring` where `SafeHTML` is expected is a compile error.

```lua
-- compile error: field "user_bio" is rawstring, not SafeHTML
local Page = component {
  div { field "user_bio" :as(SafeHTML) }
}

-- correct: explicit sanitization at the call site
var safe = SafeHTML { inner = sanitize(user.bio) }
```

XSS from unescaped content becomes a compile error instead of a runtime vulnerability.

---

## 4. Attributes

Four kinds, each with specialized codegen.

### 4.1 Static

```lua
class = "btn btn-primary";
```

Compiled to a string constant: `' class="btn btn-primary"'`. One buffer write.

### 4.2 Dynamic

```lua
id = field "button_id";
```

Three writes: static prefix `' id="'`, escaped field value, closing `'"'`. The attribute name is never computed at runtime.

### 4.3 Boolean

```lua
disabled = when "is_disabled";
```

Conditional: if true, write `' disabled'`; if false, write nothing. Per the HTML spec for boolean attributes.

### 4.4 Concatenated

```lua
class = concat("btn ", field "variant");
```

Sequential writes: `' class="btn '`, escaped field value, `'"'`. No string concatenation at runtime — the `concat` is unrolled at compile time into separate writes.

---

## 5. Event Bindings

Ignis targets server-rendered HTML with hypermedia interactions (HTMX-style) as the primary model.

### 5.1 Hypermedia Events

```lua
local LayerToggle = component {
  input {
    type = "checkbox";
    checked = field "is_visible";
    ["hx-post"]   = endpoint "layers/toggle";
    ["hx-target"] = "closest tr";
    ["hx-vals"]   = json { layer_id = field "layer_id" };
    ["hx-swap"]   = "outerHTML";
  };
}
```

`endpoint` validates the route at compile time (see §6). `json` compiles to sequential writes — no JSON library at runtime:

```
buf → {"layer_id":" → escaped(data.layer_id) → "}
```

### 5.2 Data Islands

For client interactions requiring JavaScript:

```lua
local MapViewer = component {
  div {
    id = "map";
    ["data-config"] = json {
      center    = field "center";
      zoom      = field "zoom";
      layer_ids = each(field "layers", function(l) return field(l, "id") end);
    };
  };
}
```

The `json` macro typechecks the data island against the struct at compile time. Referencing a nonexistent field is a compile error.

---

## 6. Route Integration

If a route table is available (provided by the Terroir pipeline compiler or declared locally), `endpoint` validates references at compile time.

```lua
local routes = route_table {
  route("POST",   "layers/toggle", { id = int }),
  route("DELETE",  "layers/delete", { id = int }),
  route("GET",     "layers/list"),
}
```

Three checks:

**Route existence.** `endpoint "layers/frobnicate"` fails if no route matches.

**Parameter types.** `endpoint_with("layers/delete", field "layer_id")` verifies the route accepts `layer_id` and that its type matches.

**HTTP method.** `hx-post = endpoint "layers/list"` fails because the route is GET. Catches integration bugs at compile time.

After validation, `endpoint_with("layers/delete", field "layer_id")` compiles to:

```
buf → /layers/delete/ → write_number(data.layer_id)
```

No URL encoding library.

---

## 7. Compile-Time Shape Analysis

Before generating code, the compiler analyzes the template AST into a shape descriptor: a compile-time representation of every node's static and dynamic properties.

```lua
local function analyze_shape(node)
  return {
    tag          = node.tag,
    handle_slot  = next_slot(),
    static_attrs  = { ... },   -- name/value pairs, baked into binary
    dynamic_attrs = { ... },   -- name/field/type/kind tuples
    dynamic_text  = nil or { name, type },
    children      = { ... },   -- recursive shapes
  }
end
```

Static attributes appear only in mount code. Dynamic attributes appear in both mount and patch. This classification drives all subsequent codegen.

---

## 8. SSR Backend

The SSR backend generates a Terra function that writes HTML bytes to a buffer. Every node in the template becomes one or more `buf:write` calls.

For the `LayerRow` component, the generated function is approximately:

```terra
terra render_layer_row(data: &LayerRowData, buf: &Buffer)
  buf:write_raw("<tr class=\"")
  if data.visible then buf:write_raw("active") else buf:write_raw("inactive") end
  buf:write_raw("\"><td>")
  buf:write_escaped(data.name)
  buf:write_raw("</td><td>")
  buf:write_escaped(data.type_)
  buf:write_raw("</td><td><input type=\"checkbox\"")
  if data.visible then buf:write_raw(" checked") end
  buf:write_raw(" hx-post=\"/layers/toggle\" hx-vals=\"{\"id\":\"")
  buf:write_number(data.id)
  buf:write_raw("\"}\" hx-target=\"closest tr\" hx-swap=\"outerHTML\"/></td></tr>")
end
```

Adjacent static content is merged into a single constant string at compile time. The entire row renders with ~8 buffer writes: a few constant strings, a few escaped dynamic values, a couple of conditionals. No template interpreter, no DOM construction, no string concatenation.

### 8.1 Arrow Data Source

When Ignis operates within a Terroir pipeline, the data source is an Arrow record batch from DataFusion. The template compiler generates Arrow column accessors using the same codegen pattern as other pipeline stages:

```lua
local function gen_arrow_field(col_idx, col_type)
  if col_type == "int32" then
    return function(batch, row)
      return `[&int32](batch.columns[col_idx].buffers[1])[row]
    end
  elseif col_type == "utf8" then
    return function(batch, row)
      return quote
        var offsets = [&int32](batch.columns[col_idx].buffers[1])
        var data = [&uint8](batch.columns[col_idx].buffers[2])
        var start = offsets[row]
        var len = offsets[row + 1] - start
      in
        { data = data + start, len = len }
      end
    end
  end
end
```

The template iterates Arrow rows directly — no intermediate struct, no field-name lookup, no deserialization. The same Arrow buffers allocated by DataFusion are read in place by the template renderer.

---

## 9. WASM DOM Backend

The same template definition compiles to a WASM module that creates and updates DOM elements directly. Two functions are generated: `mount` (create the full tree) and `patch` (update only what changed).

### 9.1 The Handle Table

WASM operates on integers. The DOM operates on objects. The bridge is a handle table: a JS-side array of live DOM nodes indexed by integer.

```javascript
const nodeTable = [];
let nextHandle = 0;

const imports = {
  env: {
    dom_createElement:  (tagId) => { /* ... return handle */ },
    dom_setAttr_ss:     (h, nameId, valId) => { /* static name, static val */ },
    dom_setAttr_sd:     (h, nameId, ptr, len) => { /* static name, dynamic val */ },
    dom_setText_d:      (h, ptr, len) => { /* dynamic text */ },
    dom_setProperty:    (h, nameId, val) => { /* boolean property */ },
    dom_appendChild:    (parent, child) => { /* append */ },
    dom_removeChild:    (parent, child) => { /* remove */ },
  }
};
```

Each DOM node is assigned a fixed handle slot at compile time. The compiler knows the exact DOM structure, so handle indices are constants in the generated code.

### 9.2 DOM Function Variants

Each operation has variants optimized for static vs. dynamic arguments:

| Variant | Name Arg | Value Arg | Decode Cost |
|---|---|---|---|
| `setAttr_ss` | interned ID | interned ID | 0 |
| `setAttr_sd` | interned ID | ptr + len | 1 decode |
| `setText_s` | — | interned ID | 0 |
| `setText_d` | — | ptr + len | 1 decode |
| `setAttr_num` | interned ID | raw number | 0 |
| `setProperty` | interned ID | raw int | 0 |

The compiler selects the variant based on compile-time knowledge.

### 9.3 String Interning

Every static string in the template (tag names, attribute names, literal values) is assigned an integer ID at compile time and packed into a contiguous string table in WASM linear memory. At module initialization, the JS host decodes this table once into a JS array:

```javascript
const STRINGS = [];
// decode string table from WASM memory once at init
```

After initialization, static strings are never decoded again. `setAttr_ss(handle, 3, 17)` is two array lookups and one `setAttribute`.

Dynamic strings cross the boundary as `(pointer, length)` pairs. JS reads them with `TextDecoder.decode(mem.subarray(ptr, ptr+len))` — one decode, zero byte copies.

Numbers pass as raw values. JS engine handles number-to-string coercion.

### 9.4 Memory Layout

```
WASM Linear Memory
0x0000  String table      (read-only after init)
0x10000 Scratch buffer    (32KB bump allocator, reset per frame)
0x18000 Handle array      (int32[], compile-time slot → DOM handle)
0x1C000 Data structs      (double-buffered: old + new for diff)
0x20000 List recon tables (key → handle maps for each `each` block)
```

No heap allocator. Scratch buffer resets with `offset = 0` per frame.

### 9.5 Generated Mount

Mount creates the full DOM tree. Straight-line code — no tree walking, no conditionals except for boolean attributes:

```
createElement("tr")          → handle[0]
setAttr_sd(h0, "class", ...)
createElement("td")          → handle[1]
setText_d(h1, name)
appendChild(h0, h1)
createElement("td")          → handle[2]
setText_d(h2, type)
appendChild(h0, h2)
createElement("input")       → handle[3]
setAttr_ss(h3, "type", "checkbox")
setProperty(h3, "checked", is_visible)
setAttr_ss(h3, "hx-post", "/layers/toggle")
...
```

### 9.6 Generated Patch

The patch function compares old and new data field by field. Each dynamic binding maps to a known DOM handle. The entire update is a flat sequence of comparisons and targeted mutations:

```terra
terra patch(handles: &int32, old: &Data, new: &Data)
  if new.name ~= old.name then
    DOM.setText_d(handles[1], new.name.data, new.name.len)
  end
  if new.visible ~= old.visible then
    DOM.setProperty(handles[3], intern("checked"), new.visible)
    if new.visible then
      DOM.setAttr_ss(handles[0], intern("class"), intern("active"))
    else
      DOM.setAttr_ss(handles[0], intern("class"), intern("inactive"))
    end
  end
  if new.is_locked ~= old.is_locked then
    if new.is_locked then
      DOM.setAttr_ss(handles[5], intern("disabled"), intern(""))
    else
      DOM.removeAttr(handles[5], intern("disabled"))
    end
  end
end
```

Complexity: O(dynamic field count) — typically single digits. No virtual DOM, no tree diff, no reconciler, no allocations.

### 9.7 List Reconciliation

Lists are the one case where structural changes occur. Ignis uses keyed reconciliation in three O(n) passes with hash-table lookups:

**Pass 1 — Remove.** Old keys not in new set: `removeChild`.

**Pass 2 — Add.** New keys not in old set: call generated `mount` for the item.

**Pass 3 — Patch.** Keys in both sets: call generated `patch` for the item.

For a list of 200 items where 1 changed: 200 hash lookups, 1 flat patch.

---

## 10. Component Inlining

When a parent embeds a child component, the compiler inlines the child's mount and patch logic into the parent's functions. No component boundary at runtime, no indirection, no vtable.

A page with 50 components has one `page_mount` and one `page_patch` function — flat sequences of DOM calls and field comparisons covering the entire page. The handle array spans all components contiguously.

---

## 11. Dual Compilation Targets

The same template definition compiles to two backends. The shape analysis, type checking, route validation, and escaping decisions are shared. Only the final codegen differs.

```
            template AST
                │
    ┌───────────┴───────────┐
    ▼                       ▼
SSR backend             WASM DOM backend
buf:write_raw           DOM.createElement
buf:write_escaped       DOM.setAttr_sd
→ byte stream           DOM.setText_d
                        → mount/patch functions
```

A template that compiles for SSR produces the same structure when compiled for WASM DOM. The server renders HTML on first load; the client patches the DOM on updates. Same template, same data, same type safety.

---

## 12. Compile-Time Guarantee Summary

| Bug Class | Traditional | Ignis |
|---|---|---|
| XSS from unescaped content | Runtime (if caught) | Compile error: type mismatch |
| Broken route reference | Integration test | Compile error: route not in table |
| HTTP method mismatch | Integration test | Compile error: hx-post on GET route |
| Missing data field | Runtime undefined | Compile error: field not in struct |
| Type mismatch in binding | Runtime coercion | Compile error: type mismatch |
| JSON referencing bad field | Runtime undefined | Compile error: field not in struct |

---

## 13. Performance Characteristics

### SSR

| Operation | Cost |
|---|---|
| Static element | 1 memcpy of precomputed constant |
| Dynamic text (string) | 1 escape pass + 1 write |
| Dynamic text (number) | 1 itoa + 1 write |
| Dynamic attribute | 2-3 writes |
| Boolean attribute | 1 branch + 0 or 1 write |
| JSON body | N sequential writes, 0 allocations |

### Client WASM

| Operation | Cost |
|---|---|
| Static string reference | 1 array lookup |
| Dynamic text update | 1 field compare + 1 decode |
| Number update | 1 field compare + 1 call, 0 decodes |
| Boolean attr flip | 1 field compare + 1 setAttribute |
| List add | 1 mount sequence |
| List remove | 1 removeChild |
| List item update | 1 flat patch |

---

## 14. Usage Within Terroir

In a Terroir pipeline, Ignis is the output stage for UI services:

```lua
local layer_manager = pipeline {
  name = "view_layer_manager";

  input = { project_id = int };

  source = datafusion {
    sql = "SELECT id, name, type, visible, locked FROM layers WHERE project_id = $1";
  };

  output = html {
    template = component {
      div { class = "layer-manager";
        h2 { "Layers" };
        div { class = "layer-list";
          each("layers", key "id") {
            LayerRow {}
          };
        };
      };
    };
  };
}
```

The compiled pipeline receives Arrow batches from DataFusion, iterates them using generated Arrow accessors, and renders HTML using Ignis's generated buffer-write functions. Data flows from DataFusion through the template without conversion — the Arrow column reader feeds directly into the escaping and writing functions.

For client-side rendering, the same pipeline produces a `.wasm` module that mounts and patches DOM elements. HTMX handles server interactions; Ignis handles the reactive DOM updates.

---

## 15. Standalone Usage

Ignis can be used outside Terroir as a standalone template compiler. The data source is any Terra struct:

```lua
local S = require("strata")
local ignis = require("ignis")

struct PageData {
  title: rawstring
  user_name: rawstring
  is_admin: bool
  item_count: int
}

local page = ignis.compile(component {
  html {
    head { title { field "title" } };
    body {
      h1 { field "title" };
      p { "Welcome, "; field "user_name" };
      when("is_admin", div { class = "admin-panel"; "Admin tools here" });
      p { field "item_count"; " items" };
    };
  };
}, PageData)

-- page.render is a Terra function: (data: &PageData, buf: &Buffer) -> ()
-- page.mount is a Terra function (WASM target): (data: &PageData) -> ()
-- page.patch is a Terra function (WASM target): (old: &PageData, new: &PageData) -> ()
```

The compiled functions are native code. Integrate with any server — call through FFI from any language with a C FFI.

---

## 16. Implementation Notes

Ignis is built with Strata. Template nodes use `S.schema`:

```lua
local T = S.schema {
  Element   = { "tag", "attrs", "children" },
  Text      = { "value" },
  Field     = { "name", "type?", "escape?" },
  When      = { "cond", "then_", "else_?" },
  Each      = { "collection", "key", "item_template" },
  Component = { "name", "bindings", "template" },
  Slot      = { "name" },
  Json      = { "fields" },
  Endpoint  = { "path", "params?" },
}
```

Shape analysis, type checking, route validation, and codegen are Lua functions using `S.walk`, `S.map`, and `S.diag`. The entire compiler is approximately 800 lines of Lua/Terra.

---

*Ignis: the template is the compiler's fuel. What ships is the heat.*
