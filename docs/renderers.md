# Renderers

> Every renderer implements the five SAX callbacks of `abi.Parser`
> (`enter_block` / `leave_block` / `enter_span` / `leave_span` / `text`). They are
> plain Zig functions — no `callconv(.c)` — and the block or
> span type arrives as the active tag of a `*const abi.BlockDetail` /
> `*const abi.SpanDetail`, which each renderer resolves with an exhaustive
> `switch (detail.*)`. `text` takes a `[]const u8` slice, and `debug_log` a
> `[]const u8` message. See `docs/parser-api.md` for the callback table.

## HTML Renderer API (`src/renderers/md4x-html.zig`)

Convenience library that wraps `md_parse()` and produces HTML output:

```zig
pub fn md_html(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
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
    process_output: ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
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
    process_output: ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

Produces `{"nodes":[...],"frontmatter":{...},"meta":{}}` where each node is either a plain JSON string (text) or a tuple array `["tag", {props}, ...children]`. Frontmatter YAML is parsed into the top-level `frontmatter` object (not included in `nodes`). HTML comments are represented as `[null, {}, "comment body"]`. Footnotes take a Comark shape rather than mirroring the HTML renderer's markup: a reference is `["footnote-ref", {id, refId, label}]` and the deferred definitions are `["footnotes", {}, ["footnote", {id, label, refCount}, ...children]]`.

**Internal architecture:** Unlike the streaming HTML/ANSI renderers, the AST renderer builds an in-memory tree of `JsonNode` structs during parsing, then serializes the tree to JSON. The whole tree is **arena-allocated** (`JsonCtx.arena`) and freed wholesale, so there is no per-node free. Each node carries a **flat `Detail` struct** — one field per variant, not a union — which structurally rules out the type-confusion bug class the C renderer suffered from. Nodes with `tag_is_dynamic = true` are user-defined components. All tag dispatch (`jsonWriteProps`, `jsonSerializeNode`) must still resolve `tag_is_dynamic` / `tag_kind` **first**, so a component whose name collides with a built-in tag reads the right `Detail` field. See `AGENTS.md` for the full rule. On the input side, `jsonEnterBlock` / `jsonEnterSpan` switch on the incoming `abi.BlockDetail` / `abi.SpanDetail` union and resolve the dynamic-component arm before any built-in tag, so the same rule holds where the node is built.

**NUL bytes.** Every string a `JsonNode` holds is a **sentinel-terminated slice**, so its length is the exact byte count and is never recomputed with `strlen()` — a U+0000 is legal document content and used to truncate the value it appeared in. Strings that came from an `Attribute` (`href`, `title`, `src`, `target`, `language`, `filename`, footnote `label`) carry the parser's `.nullchar` substrings as **U+FFFD**, matching the text path and every other renderer's `render_attribute()`. Strings the parser hands over as raw source with no substring typing (component props/title, the code-block `meta` remainder, inline `{attrs}`) keep the raw byte; `json_write_escaped` emits it as `\u0000`, so the output stays valid JSON either way.

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
    process_output: ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
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
- Underline: underline (`\033[4m`)
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

## Meta Renderer API (`src/renderers/md4x-meta.zig`)

Lightweight metadata extractor that parses frontmatter and headings from Markdown:

```zig
pub fn md_meta(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int;
```

Produces a flat JSON object with frontmatter properties spread at the top level plus a `headings` array. No AST construction — uses SAX callbacks to capture only frontmatter text and heading plain text.

**Example output:**

```json
{
  "title": "Hello",
  "tags": ["a", "b"],
  "headings": [
    { "level": 1, "text": "My Doc" },
    { "level": 2, "text": "Section 1" }
  ]
}
```

### Renderer Flags (`MD_META_FLAG_*`)

| Flag                         | Value    | Description                                                |
| ---------------------------- | -------- | ---------------------------------------------------------- |
| `MD_META_FLAG_DEBUG`         | `0x0001` | Send debug output from `md_parse()` to stderr              |
| `MD_META_FLAG_SKIP_UTF8_BOM` | `0x0002` | Skip UTF-8 BOM at input start                              |
| `MD_META_FLAG_HEAL`          | `0x0100` | Run `md_heal()` on the input first, then render the result |

### Rendering Details

- Frontmatter YAML properties are spread as top-level JSON keys (using libyaml for full YAML 1.1 support)
- Headings are collected as `{"level": N, "text": "..."}` objects in the `headings` array
- Heading text is extracted as plain text — inline formatting (bold, italic, code, etc.) is stripped
- HTML entities in headings are resolved to UTF-8 characters
- Footnote blocks and references are ignored — they contribute nothing to frontmatter or the heading list
- Uses streaming renderer pattern (like HTML renderer), no AST construction

## Text Renderer API (`src/renderers/md4x-text.zig`)

Strips markdown formatting and produces plain text output:

```zig
pub fn md_text(
    input: [*c]const MD_CHAR,
    input_size: MD_SIZE,
    process_output: ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
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

- All inline formatting (bold, italic, underline, strikethrough, code spans) stripped — only text content remains
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
    process_output: ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void,
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
- Inline: `*em*`, `**strong**`, `` `code` ``, `~~del~~`, `==mark==`; underline has no Markdown spelling, so it is emitted as `<u>…</u>`
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
