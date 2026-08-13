# Renderers

> Every renderer implements the five SAX callbacks of `abi.Parser`
> (`enter_block` / `leave_block` / `enter_span` / `leave_span` / `text`). They are
> plain Zig functions — no `callconv(.c)` — and the block or
> span type arrives as the active tag of a `*const abi.BlockDetail` /
> `*const abi.SpanDetail`, which each renderer resolves with an exhaustive
> `switch (detail.*)`. `text` takes a `[]const u8` slice, and `debug_log` a
> `[]const u8` message. See `docs/parser-api.md` for the callback table.
>
> **`process_output` is non-optional**, for the same reason the five SAX
> callbacks are: every renderer's sink is called unconditionally, so a `null`
> one was a null-function-pointer call (a panic in Debug/ReleaseSafe, undefined
> behavior in the shipping ReleaseFast build) rather than a way to discard
> output. A missing sink is now a compile error at the call site. Do not re-add
> `?`, and do not guard the sink call sites with `if (out) |f|` instead.

## HTML Renderer API (`src/renderers/md4x-html.zig`)

Convenience library that wraps `md_parse()` and produces HTML output:

```zig
pub fn md_html(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

Only `<body>` contents are generated. Frontmatter blocks are suppressed from output.

Extended API with full-HTML document generation:

```zig
pub const MD_HTML_OPTS = extern struct {
    title: ?[*:0]const u8 = null,   // Document title override (null = use frontmatter)
    css_url: ?[*:0]const u8 = null, // CSS stylesheet URL (null = omit)
};

pub fn md_html_ex(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
    opts: ?*const MD_HTML_OPTS,
) c_int;
```

When `MD_HTML_FLAG_FULL_HTML` is set, `md_html_ex()` generates a complete HTML document (`<!DOCTYPE html>`, `<head>`, `<body>`). If YAML frontmatter exists, `title` and `description` fields are used in `<head>`. `opts.title` overrides the frontmatter title. `opts` may be null.

### Renderer Flags (`MD_HTML_FLAG_*`)

| Flag                             | Value    | Description                                                |
| -------------------------------- | -------- | ---------------------------------------------------------- |
| `MD_HTML_FLAG_DEBUG`             | `0x0001` | Send debug output from `md_parse()` to stderr              |
| `MD_HTML_FLAG_VERBATIM_ENTITIES` | `0x0002` | Do not translate HTML entities                             |
| `MD_HTML_FLAG_SKIP_UTF8_BOM`     | `0x0004` | Skip UTF-8 BOM at input start                              |
| `MD_HTML_FLAG_FULL_HTML`         | `0x0008` | Generate full HTML document (requires `md_html_ex`)        |
| `MD_HTML_FLAG_CODE_META`         | `0x0010` | Append a code-block metadata JSON array after a NUL byte   |
| `MD_HTML_FLAG_HEAL`              | `0x0100` | Run `md_heal()` on the input first, then render the result |

`MD_HTML_FLAG_CODE_META` makes the renderer record, for every fenced/indented
code block, the byte range its rendered output occupies plus the block's
metadata. After a successful parse it flushes the body and appends a `NUL` byte
followed by a JSON array — one object per code block, in document order:

```json
[{ "s": 0, "e": 42, "l": "js", "f": "app.js", "h": [1, 2] }]
```

`s`/`e` are the start/end byte offsets in the emitted HTML; `l` (language), `f`
(filename) and `h` (highlight line numbers) are omitted when absent. The JS
bindings use this to support the `highlighter` callback — `md4x_to_html` (wasm)
and `renderToHtml` (napi) always pass this flag. `l` is capped at 64 bytes and
`f` at 256 bytes (fixed-size capture buffers).

`MD_HTML_FLAG_HEAL` is a pre-pass, not a rendering mode: `md_html_ex()` runs
`md_heal()` over the input, then re-enters itself with the healed buffer and the
flag cleared. It is what the CLI's `--heal` option sets for HTML output.

### Rendering Details

- Frontmatter blocks are suppressed (not rendered in HTML output)
- Wiki links render as `<x-wikilink>` tags
- LaTeX math renders as `<x-equation>` tags
- Task lists render with `<input type="checkbox">` elements
- Table cells get `align` attribute when alignment is specified
- URL attributes are percent-encoded; HTML content is entity-escaped
- Attribute **names** synthesized from a component key — a `{props}` key or a component-frontmatter YAML key — are emitted through `render_html_attr_name`, not the value escaper. An attribute name ends at whitespace, `/`, `=` or `>`, none of which entity-escaping covers, so a key like `x onload=alert(1)//` would otherwise tokenize into several attributes. Bytes `<= 0x20`, DEL, `/` and `=` are percent-encoded (`a b` → `a%20b`); `& < > "` keep their entity spelling; bytes `>= 0x80` pass through, so non-ASCII keys are unaffected. An **empty** key is dropped — HTML has no spelling for a zero-length attribute name. The AST renderer keeps every such key verbatim (it is a JSON string there), so the two renderers agree on which keys are acceptable; only the spelling differs
- Alerts render as `<blockquote class="alert alert-{type}">` (type lowercased in class)
- Footnote references render as `<sup><a href="#fn-N" id="fnref-N-K">N</a></sup>`; the deferred definitions render as `<section class="footnotes"><ol><li id="fn-N">…</li></ol></section>`, each `<li>` ending in one `&#8617;` back-reference anchor per reference

## Shared Property Parser (`src/renderers/md4x-props.zig`)

Zig module for parsing component property strings (`{key="value" bool #id .class :bind='json'}`). Imported by every renderer that handles props.

```zig
const props = @import("md4x-props.zig");

var parsed: props.MD_PARSED_PROPS = undefined;
props.md_parse_props(raw, size, &parsed);
```

**Parsed output (`MD_PARSED_PROPS`):**

| Field                     | Type                            | Description                                    |
| ------------------------- | ------------------------------- | ---------------------------------------------- |
| `props[32]`               | `[32]MD_PROP`                   | Parsed props (key/value pairs, booleans, bind) |
| `n_props`                 | `c_int`                         | Number of parsed props                         |
| `id` / `id_size`          | `[*c]const MD_CHAR` / `MD_SIZE` | `#id` shorthand (last wins)                    |
| `class_buf` / `class_len` | `[512]MD_CHAR` / `MD_SIZE`      | Merged `.class` values (space-separated)       |

**Prop types (`MD_PROP_TYPE`):**

| Type              | Syntax                                    | Description              |
| ----------------- | ----------------------------------------- | ------------------------ |
| `MD_PROP_STRING`  | `key="value"`, `key='value'`, `key=value` | String prop              |
| `MD_PROP_BOOLEAN` | `flag`                                    | Boolean prop (bare word) |
| `MD_PROP_BIND`    | `:key='json'`                             | JSON passthrough         |

All `key`/`value` pointers are zero-copy references into the original raw string (not null-terminated — use `*_size` fields).

## AST Renderer API (`src/renderers/md4x-ast.zig`)

Renders Markdown into a Comark AST (array-based JSON format):

```zig
pub fn md_ast(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

Produces `{"nodes":[...],"frontmatter":{...},"meta":{"headings":[...]}}` where each node is either a plain JSON string (text) or a tuple array `["tag", {props}, ...children]`. Frontmatter YAML is parsed into the top-level `frontmatter` object (not included in `nodes`). HTML comments are represented as `[null, {}, "comment body"]`. Footnotes take a Comark shape rather than mirroring the HTML renderer's markup: a reference is `["footnote-ref", {id, refId, label}]` and the deferred definitions are `["footnotes", {}, ["footnote", {id, label, refCount}, ...children]]`.

**Raw HTML is a node, not loose text.** An inline run is `["html", {}, "<b>"]` and an HTML block is `["html", { "block": true }, "…"]` — one node per source event, so `<b>` and `</b>` stay separate and the source bytes round-trip. Emitting them as text made them indistinguishable from a literal `<` in prose, which consumers could only resolve by re-parsing every text string containing `<` as an HTML _fragment_ — reviving block constructs the paragraph had already ruled out, and costing an extra render per text node.

**Headings carry an `id`.** A GitHub-compatible slug, de-duplicated within the document with a `-1`/`-2` suffix, published both on the node and in `meta.headings` (`{level, text, id}`) — the same arena slice, so the two cannot drift. `meta.headings` exists so that a table of contents needs no second parse through the meta renderer. Slugging and heading-text accumulation live in `src/renderers/md4x-slug.zig` and are driven from the SAX text stream in **both** renderers, which is the only form in which entities are resolved and raw HTML excluded.

**Two paragraphs the tree drops.** Markdown wraps loose block content in a paragraph unconditionally, and in two places that paragraph describes the source rather than the document. A paragraph holding only MDC components and whitespace is spliced out, so a component written on its own line lands at block level (matching `markdown-it-mdc`) while a mid-sentence one keeps its paragraph; and a `template` slot body that is exactly one paragraph is unwrapped. Both are the rule md4x already applies to a tight list item, which renders as `["li", {}, "one"]`. These live in the AST renderer, not the parser: every other renderer emits real markup, where the wrapper is harmless or required.

**Alert type is lowercased**, so `> [!NOTE]` and `::alert{type=note}` — two spellings of one node — agree. The parser detail keeps the author's casing for the markdown renderer's round-trip.

**Internal architecture:** Unlike the streaming HTML/ANSI renderers, the AST renderer builds an in-memory tree of `JsonNode` structs during parsing, then serializes the tree to JSON. The whole tree is **arena-allocated** (`JsonCtx.arena`) and freed wholesale, so there is no per-node free. Each node carries a **flat `Detail` struct** — one field per variant, not a union — which structurally rules out the type-confusion bug class the C renderer suffered from. Nodes with `tag_is_dynamic = true` are user-defined components. All tag dispatch (`jsonWriteProps`, `jsonSerializeNode`) must still resolve `tag_is_dynamic` / `tag_kind` **first**, so a component whose name collides with a built-in tag reads the right `Detail` field. See `AGENTS.md` for the full rule. On the input side, `jsonEnterBlock` / `jsonEnterSpan` switch on the incoming `abi.BlockDetail` / `abi.SpanDetail` union and resolve the dynamic-component arm before any built-in tag, so the same rule holds where the node is built.

**NUL bytes.** Every string a `JsonNode` holds is a **sentinel-terminated slice**, so its length is the exact byte count and is never recomputed with `strlen()` — a U+0000 is legal document content and used to truncate the value it appeared in. Strings that came from an `Attribute` (`href`, `title`, `src`, `target`, `language`, `filename`, footnote `label`) carry the parser's `.nullchar` substrings as **U+FFFD**, matching the text path and every other renderer's `render_attribute()`. Strings the parser hands over as raw source with no substring typing (component props/title, the code-block `meta` remainder, inline `{attrs}`) keep the raw byte; `json_write_escaped` emits it as `\u0000`, so the output stays valid JSON either way.

**Nesting depth.** Building a tree (and recursing over it once per level to serialize it) is what makes this the only renderer with a nesting limit: `JSON_MAX_DEPTH` = **1024 levels, counting the document node**. The parser imposes no container-nesting limit of its own, and the streaming renderers emit arbitrarily deep input, so anything deeper is the AST renderer's problem alone. Past the cap it **stops nesting rather than failing**: the block/span is not turned into a node, and its content — text included — collapses into the deepest node that was kept (the same shape as the existing "spans inside an image become alt text" suppression). Nothing is dropped, the output stays a valid `ComarkTree`, and the collapse is reported in the tree's top-level `meta` bag as `"meta":{"maxDepthExceeded":true}` (emitted only in that case). Previously the renderer set its error flag instead, so `md_ast()` returned `-1` and emitted **zero bytes** for the whole document — one deep blockquote or list anywhere in a file killed the entire render, and the JS bindings turned that into a thrown error.

The cap is bounded by stack, not memory. Measured cost of one serializer level: ~48–53 bytes in `ReleaseFast` (what ships), ~192 in `ReleaseSafe`, ~768 in `Debug`, so a native `ReleaseFast` build dies around depth 173 000 on an 8 MiB stack. On wasm the 16 MiB shadow stack is not the binding constraint — the engine spends its own ~1 MB native stack on the wasm frames and throws `RangeError: Maximum call stack size exceeded` first, at ~11 300 levels on Node/V8 and ~9 000 on Bun/JSC. 1024 sits ~9× under the tightest of those.

### AST Renderer Flags (`MD_AST_FLAG_*`)

| Flag                        | Value    | Description                                                |
| --------------------------- | -------- | ---------------------------------------------------------- |
| `MD_AST_FLAG_DEBUG`         | `0x0001` | Send debug output from `md_parse()` to stderr              |
| `MD_AST_FLAG_SKIP_UTF8_BOM` | `0x0002` | Skip UTF-8 BOM at input start                              |
| `MD_AST_FLAG_HEAL`          | `0x0100` | Run `md_heal()` on the input first, then render the result |

## ANSI Renderer API (`src/renderers/md4x-ansi.zig`)

Renders Markdown into ANSI terminal output with escape codes for styling:

```zig
pub fn md_ansi(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

### Renderer Flags (`MD_ANSI_FLAG_*`)

| Flag                            | Value    | Description                                                |
| ------------------------------- | -------- | ---------------------------------------------------------- |
| `MD_ANSI_FLAG_DEBUG`            | `0x0001` | Send debug output from `md_parse()` to stderr              |
| `MD_ANSI_FLAG_SKIP_UTF8_BOM`    | `0x0002` | Skip UTF-8 BOM at input start                              |
| `MD_ANSI_FLAG_NO_COLOR`         | `0x0004` | Suppress ANSI escape codes (plain text output)             |
| `MD_ANSI_FLAG_CODE_META`        | `0x0008` | Append code block metadata after null byte                 |
| `MD_ANSI_FLAG_SHOW_URLS`        | `0x0010` | Show link URLs after link text (default: OSC 8 only)       |
| `MD_ANSI_FLAG_SHOW_FRONTMATTER` | `0x0020` | Show frontmatter as dim text (default: suppressed)         |
| `MD_ANSI_FLAG_HEAL`             | `0x0100` | Run `md_heal()` on the input first, then render the result |

### Rendering Details

- Headings: bold magenta (`\033[1;35m`)
- Bold/strong: bold (`\033[1m`)
- Italic/emphasis: italic (`\033[3m`)
- Strikethrough: strikethrough (`\033[9m`)
- Highlight (`==x==`): reverse video (`\033[7m`) — legible on both light and dark themes
- Inline code: cyan (`\033[36m`)
- Code blocks: dim (`\033[2m`) with 2-space indent
- Links: underline blue (`\033[4;34m`) with OSC 8 clickable hyperlinks
- Blockquotes: dim vertical bar prefix (`│`)
- Horizontal rules: box-drawing line (`────────`)
- Lists: dim bullet/number prefix with nesting indentation
- Task lists: `[x]`/`[ ]` with green for checked items
- Images: `[image: alt]` in dim
- Footnote references: dim `[N]`; the definitions section is introduced by the same box-drawing rule as a table head and each definition is prefixed with a dim `[N] `. Only the numeric id is emitted, so no document bytes reach this path
- Alerts: colored thick left bar (`▌`) with type-specific colors (note/info=blue, tip/success=green, important=magenta, warning=yellow, caution/danger=red), bold type label on first line
- Components: cyan for generic; alert-like components (`::note`, `::tip`, `::important`, `::warning`, `::caution`) and `::alert{type="..."}` render with the same colored bar style as alerts
- Frontmatter: suppressed by default (enable with `MD_ANSI_FLAG_SHOW_FRONTMATTER` for dim text output)
- Raw HTML: stripped (not rendered)
- Entities resolved to UTF-8 characters
- Control bytes from the document — including ones a numeric character reference decodes to — are replaced with their Unicode control picture (`␛`, `␇`, `␍`, `␡`; U+2400 + ch, U+2421 for DEL) on every text path, so document content can never emit a terminal escape sequence. TAB and LF pass through: the renderer emits them itself as layout. One picture per byte keeps table columns aligned. Link destinations percent-encode those bytes instead (`%1B`), matching the `href="..."` the HTML renderer produces — escaping is impossible _inside_ the OSC 8 hyperlink string, which BEL or ST would otherwise terminate early. Only the renderer's own escape codes reach the terminal, which is what makes `MD_ANSI_FLAG_NO_COLOR` genuinely plain-text output rather than merely uncoloured.

Uses streaming renderer pattern (like HTML renderer), no AST construction.

## Shared JSON Writer (`src/renderers/md4x-json.zig`)

Zig module providing JSON serialization and YAML-to-JSON conversion helpers (libyaml-backed). Imported by the AST and meta renderers.

```zig
const json = @import("md4x-json.zig");
```

**Key components:**

- `JSON_WRITER` — Streaming JSON writer struct with callback-based output
- `json_write()` / `json_write_str()` — Raw and string output helpers
- `json_write_escaped()` / `json_write_string()` — JSON-escaped string output
- `json_write_yaml_props()` — Parses YAML frontmatter and writes key-value pairs as JSON properties (using libyaml). Returns the number of props actually written, which callers use to place the separating comma before whatever they append next.
- `md_yaml()` — Standalone YAML-to-JSON entry point (see below).

### YAML Entry Point (`md_yaml`)

```zig
pub fn md_yaml(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

Converts a standalone YAML document — not Markdown frontmatter — to JSON,
exposed to JS as `parseYAML()` / `yamlToJson()`. Without it, parsing a plain
`.yml` meant wrapping it in `---` fences, running it through the **markdown**
meta renderer, and stripping the heading list back off the result.

Unlike `json_write_yaml_props()` it accepts any root node (a sequence or a bare
scalar as readily as a mapping), and a stream with no document at all converts
to `null` — YAML's own reading of an empty file. Both flag words are unused; it
takes the renderer signature so it drops into the existing wasm/napi wrappers
unchanged. Malformed input follows the same forward-repair contract as
frontmatter, so the output always parses.

### Malformed YAML

The writer streams straight through `process_output`, so emitted bytes cannot be
retracted — and libyaml reports a syntax error only after emitting the events
that precede it. A mid-document YAML error is therefore repaired **forward**, on
the invariant that the emitted JSON is always balanced: the pairs that parsed
are kept, every container that was opened is closed, and a key whose value could
not be parsed receives an explicit `null`.

| Frontmatter        | Props emitted             |
| ------------------ | ------------------------- |
| `a: @bad`          | `{"a":null}`              |
| `title: Hi\nb: @x` | `{"title":"Hi","b":null}` |
| `a: [1`            | `{"a":[1]}`               |
| `a: {x: 1`         | `{"a":{"x":1}}`           |

The failing key is reported rather than dropped: dropping it would make a
truncated or malformed document indistinguishable from one where the author
simply omitted the field. Aliases are `null` too — libyaml's parser does not
compose, so anchors are never resolved.

### YAML nesting depth

The `json_write_yaml_*` functions walk libyaml's event stream **recursively**, so
a document's nesting depth is the native recursion depth — and libyaml's own limit
is far too high to protect the native stack (1000 levels, see below), while the
Markdown parser hands frontmatter over as opaque bytes. `YAML_MAX_DEPTH`
= **256 levels** therefore caps the descent, on all three paths that reach the
writer (`md_ast`, `md_meta`, `md_yaml`). At the cap the writer **ends the parse**:
the position that overflowed gets `null`, and the walk unwinds without reading
another event, closing every container it opened. The output stays well-formed
JSON; what is lost is the tail of that YAML document — the keys after the
overflowing value are not emitted. Unlike the AST renderer's cap it is not
reported in a `meta` bag either: `frontmatter` is a user-data object with no
reserved key to put a marker in.

Ending the parse rather than skipping to the end of the offending subtree is what
bounds the CPU as well as the stack. **libyaml's flow-collection handling is
O(depth²)** — a pre-existing defect, unrelated to this cap and driven by nesting
depth alone (50 000 flat keys cost 0.03 s, 50 000 _levels_ cost 4.6 s): `a: [` × n
through `--format=json` measured 1.2 s at n = 25 000, 4.6 s at 50 000, 19.1 s at
100 000 and 96.3 s at 200 000, on builds with and without the cap alike. Anything
that keeps reading events past the cap pays that in full; stopping there makes the
cost independent of the depth (~3 ms at every n above, including 1 000 000).

The quadratic is not fundamental to libyaml — `yaml_parser_stale_simple_keys` and
the head-position check in `yaml_parser_fetch_more_tokens` each sweep the whole
`simple_keys` stack (one entry per open `[`/`{`) on every token fetch; making them
examine only the top-most entry turns the curve linear (17.7 s → 10.7 ms at 80 000
levels, measured on a patched build). Upstream instead **bounds the depth**:
`build.zig.zon` pins a libyaml master commit whose scanner errors past
`MAX_NESTING_LEVEL` = 1000, so the worst case that still parses is 999 levels at
~2.3 ms. One consequence for this renderer: **past ~1000 levels the truncated
position is an empty container rather than `null`**, because libyaml's scanner
reads far enough ahead to hit its own limit before `YAML_MAX_DEPTH` sees those
events. Between 256 and ~1000 levels the `null` above is what you get.

The cap's number differs from the AST renderer's 1024 because the frame is ~3.5×
heavier — three frames per level, each holding libyaml's ~104-byte `yaml_event_t`
by value: ~177 bytes per level in `ReleaseFast` (what ships), ~194 in
`ReleaseSafe`, ~354 in `Debug`. The two caps therefore cost about the same ~45–50 KB
of stack. That is ~185× under a native 8 MiB stack, ~11× under a 512 KiB one, and
still ~2.8× under a musl default 128 KiB thread stack, while a deeply nested real
frontmatter is ~5 levels. Before the cap, `a: [[[[…` in frontmatter (or in a `.yml`
through `md_yaml`) ran until the stack was gone — a SIGSEGV natively, which also
skipped the AST renderer's arena teardown and `yaml_parser_delete`, and a trap
through the wasm binding, which leaked ~4 MB of linear memory per attempt.

## Meta Renderer API (`src/renderers/md4x-meta.zig`)

Lightweight metadata extractor that parses frontmatter and headings from Markdown:

```zig
pub fn md_meta(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

Produces a JSON object with the parsed frontmatter under `frontmatter` and a `headings` array beside it. No AST construction — uses SAX callbacks to capture only frontmatter text and heading plain text.

**Example output:**

```json
{
  "frontmatter": { "title": "Hello", "tags": ["a", "b"] },
  "headings": [
    { "level": 1, "text": "My Doc", "id": "my-doc" },
    { "level": 2, "text": "Section 1", "id": "section-1" }
  ]
}
```

Frontmatter is nested rather than spread across the top level: as siblings, a
document whose frontmatter declared its own `headings` key had it silently
overwritten by the parsed heading list, and there was no way to ask for the
frontmatter alone.

### Renderer Flags (`MD_META_FLAG_*`)

| Flag                         | Value    | Description                                                |
| ---------------------------- | -------- | ---------------------------------------------------------- |
| `MD_META_FLAG_DEBUG`         | `0x0001` | Send debug output from `md_parse()` to stderr              |
| `MD_META_FLAG_SKIP_UTF8_BOM` | `0x0002` | Skip UTF-8 BOM at input start                              |
| `MD_META_FLAG_HEAL`          | `0x0100` | Run `md_heal()` on the input first, then render the result |

### Rendering Details

- Frontmatter YAML is parsed under the `frontmatter` key (using libyaml for full YAML 1.1 support)
- Headings are collected as `{"level": N, "text": "...", "id": "..."}` objects in the `headings` array
- Heading text is extracted as plain text — inline formatting (bold, italic, code, etc.) is stripped
- HTML entities in headings are resolved to UTF-8 characters
- Raw HTML inside a heading is **excluded** from its text: `## a <b>x</b>` reads `a x`, which is what the id is slugged from
- `id` is a GitHub-compatible slug (case-folded, punctuation stripped, spaces to `-`) de-duplicated within the document with a `-1`/`-2` suffix. The slugging lives in `src/renderers/md4x-slug.zig` and is driven from the same SAX text stream in the AST renderer, so the two entry points cannot publish different ids for one heading
- Footnote blocks and references are ignored — they contribute nothing to frontmatter or the heading list
- Uses streaming renderer pattern (like HTML renderer), no AST construction

## Text Renderer API (`src/renderers/md4x-text.zig`)

Strips markdown formatting and produces plain text output:

```zig
pub fn md_text(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

### Renderer Flags (`MD_TEXT_FLAG_*`)

| Flag                         | Value    | Description                                                |
| ---------------------------- | -------- | ---------------------------------------------------------- |
| `MD_TEXT_FLAG_DEBUG`         | `0x0001` | Send debug output from `md_parse()` to stderr              |
| `MD_TEXT_FLAG_SKIP_UTF8_BOM` | `0x0002` | Skip UTF-8 BOM at input start                              |
| `MD_TEXT_FLAG_HEAL`          | `0x0100` | Run `md_heal()` on the input first, then render the result |

### Rendering Details

- All inline formatting (bold, italic, strikethrough, code spans) stripped — only text content remains
- Headings: plain text + newline
- Paragraphs: plain text + newline
- Lists: `- ` (unordered) or `1. ` (ordered) prefix with 2-space nesting indentation
- Task lists: `[x] ` / `[ ] ` prefix
- Code blocks: verbatim with 2-space indent
- Blockquotes: `> ` prefix (nested)
- Horizontal rules: `---`
- Tables: tab-separated cells
- Links: text content only (URL not shown)
- Images: alt text only
- Footnote references: `[N]` — the only span this renderer emits anything for, since the span is self-contained and would otherwise vanish. Definitions follow the body, each prefixed `[N] `
- Frontmatter: stripped (no output)
- Components/templates: transparent (children rendered normally)
- Alerts: type label + content with `> ` prefix
- Entities resolved to UTF-8 characters
- Raw HTML: stripped (no output)
- Control bytes from the document are replaced with their Unicode control picture, exactly as in the ANSI renderer above — this output is the CLI default whenever stdout is not a TTY, but it is still routinely read in a terminal
- Uses streaming renderer pattern (like HTML renderer), no AST construction

## Markdown Renderer API (`src/renderers/md4x-markdown.zig`)

Re-renders the parsed document back to Markdown (normalizing the source syntax):

```zig
pub fn md_markdown(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: *const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

Backs the CLI's `--format=markdown`. Because it renders from the SAX stream and not
from the source bytes, the output is normalized rather than round-tripped: setext
headings become ATX, indented code becomes fenced, autolinks and wiki links become
explicit `[text](url)` links, and anything with no Markdown spelling (raw HTML,
component props) is dropped or emitted as a tag.

### Renderer Flags (`MD_MARKDOWN_FLAG_*`)

| Flag                             | Value    | Description                                                |
| -------------------------------- | -------- | ---------------------------------------------------------- |
| `MD_MARKDOWN_FLAG_DEBUG`         | `0x0001` | Send debug output from `md_parse()` to stderr              |
| `MD_MARKDOWN_FLAG_SKIP_UTF8_BOM` | `0x0002` | Skip UTF-8 BOM at input start                              |
| `MD_MARKDOWN_FLAG_HEAL`          | `0x0100` | Run `md_heal()` on the input first, then render the result |

### Rendering Details

- Headings: ATX only — `#` repeated up to 6 times plus a space (setext input is normalized to ATX)
- Paragraphs: separated by a blank line
- Lists: `- ` (unordered) or `N. ` (ordered, numbered from the list's `start`), 2-space indent per nesting level
- Task lists: `- [x] ` / `- [ ] ` — the task marker takes precedence over the ordered-list number
- Blockquotes: `> ` prefix, repeated per nesting level; every emitted line carries the current quote + list prefix
- Alerts: rendered as a blockquote whose first line is `[!TYPE]`
- Horizontal rules: `---`
- Code blocks: always fenced (indented code included) — ` ``` `, or `~~~` when the source fence char was `~`; the full info string is re-emitted, including `[filename]` / `{1-3}` metadata
- Inline: `*em*`, `**strong**`, `` `code` ``, `~~del~~`, `==mark==`
- Links: `[text](href "title")` — the title is emitted only when present; images: `![alt](src "title")`
- Autolinks are expanded to the explicit form (`<https://a.b>` → `[https://a.b](https://a.b)`)
- Wiki links become regular links: `[[target]]` → `[target](target)`
- Footnote references round-trip as `[^label]`, and the definitions are re-emitted as `[^label]: …` — but at the **end of the document**, not their original position. That is a textual move, not a semantic one: a definition resolves the same wherever it sits. `[` is already escaped unconditionally in text, so a literal `[^1]` in prose comes back as `\[^1]` and does not become a reference
- LaTeX math: `$…$` and `$$…$$`
- Tables: pipe tables (`| cell |`), with a delimiter row emitted after the header row using the recorded per-column alignment (`:---`, `:---:`, `---:`, or `---` for default); alignment is tracked for at most 128 columns
- Hard breaks: `\` + newline; soft breaks: newline — both followed by the current indent
- Frontmatter: dropped entirely (delimiters and content)
- Raw HTML: stripped — HTML blocks, inline HTML, and comments alike
- Block components: `<name>` / `</name>` on their own lines with a blank line before the content; a component title is emitted as `title="…"`. Inline components: `<name>…</name>`. Props/attributes (`{...}`) are not re-emitted
- Slots (`template`) and attribute spans (`[text]{...}`) are transparent — children render normally
- Entities are resolved to UTF-8 characters; NUL characters become U+FFFD
- Text is re-escaped so it does not come back as markup: ``\ ` * [ ] <`` always;
  `_`, `$` and `~` unless intra-word; `&` when what follows it is shaped like an
  entity (spelled `&amp;`, not `\&`); `#`, `-`, `+`, `>`, `=`, `:` and `|` at the
  start of a line, `.` / `)` after leading digits, `|` inside a table, and `#`
  inside a heading (it would close the ATX sequence). LaTeX math and code-block
  content stay verbatim
- Link/image destinations are wrapped in `<…>` only when they carry whitespace or
  a control byte; otherwise `\`, `<`, `>` and parentheses are backslash-escaped.
  Titles are `"`-delimited with `\` and `"` escaped
- Code spans get a fence longer than the longest backtick run in their content,
  plus a space of padding when the content starts or ends with a backtick or a
  space — backslash escapes do not exist inside a code span
- Uses streaming renderer pattern (like the HTML renderer), no AST construction

## Heal Utility API (`src/renderers/md4x-heal.zig`)

Fixes incomplete/streaming Markdown text so it renders correctly mid-stream. This is a **pre-parser text transform** — it does not use `md_parse()` and has no parser dependency.

Inspired by [remend](https://github.com/vercel/streamdown/tree/main/packages/remend).

```zig
pub fn md_heal(
    input: [*]const u8,
    input_size: c_uint,
    process_output: *const fn ([*]const u8, c_uint, ?*anyopaque) void,
    userdata: ?*anyopaque,
) c_int;
```

Returns 0 on success, -1 on error.

### Healing Operations (applied in priority order)

1. **Comparison operators** — Escapes `>` as `\>` in list items where it's a comparison operator (e.g., `- > 5` → `- \> 5`)
2. **HTML tags** — Strips incomplete HTML tags at end of text (e.g., `text <div` → `text`)
3. **Setext headings** — Appends zero-width space to 1-2 char `-`/`=` lines to prevent misinterpretation as heading underlines
4. **Links/images** — Completes incomplete link URLs with `()`, removes incomplete link brackets, removes incomplete image markup entirely
5. **Bold-italic (`\***`)** — Closes unclosed `\*\*\*` markers
6. **Bold (`**`)** — Closes unclosed `**`markers, handles half-complete`**text\*`→`**text**`
7. **Italic (`__`)** — Closes unclosed `__` markers, handles half-complete `__text_` → `__text__`
8. **Italic (`*`)** — Closes unclosed single `*` markers
9. **Italic (`_`)** — Closes unclosed single `_` markers
10. **Inline code** — Closes unclosed backticks
11. **Strikethrough (`~~`)** — Closes unclosed `~~` markers, handles half-complete `~~text~` → `~~text~~`
12. **KaTeX (`$$`)** — Closes unclosed `$$` math blocks (preserves newlines for block math)
13. **Code blocks** — Closes unclosed fenced code blocks (` ``` `)

### Context Awareness

- Formatting inside fenced code blocks is never healed
- Complete inline code spans are respected (no emphasis healing inside them)
- Math blocks (`$`/`$$`) are tracked to avoid false emphasis healing
- Link/image URLs are tracked to avoid false underscore healing
- HTML tag context is tracked
- Trailing single spaces are stripped (double spaces preserved for line breaks)
