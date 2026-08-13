// MD4X: Markdown parser for C
// (https://github.com/unjs/md4x)
//
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// Zig port of src/renderers/md4x-ast.c — byte-for-byte identical output.

const std = @import("std");

// MD_* types now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); only genuinely
// external C headers stay in a @cImport, bound as `sys`.
const c = @import("abi");
// Sibling units are imported directly (one Zig module per artifact), not
// resolved through link-time C-ABI symbols. `abi` holds types only.
const md4x = @import("../md4x.zig");
const heal = @import("md4x-heal.zig");
const sys = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("yaml.h");
});
const diag = @import("md4x-diag.zig");

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-ast.h). Heal flag value is shared (0x0100).
const MD_AST_FLAG_DEBUG: c_uint = 0x0001;
const MD_AST_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_AST_FLAG_HEAL: c_uint = 0x0100;

// Maximum nesting depth of the built tree. Unlike the streaming renderers, the
// AST renderer keeps a `current` stack while building and RECURSES once per
// level in jsonSerializeNode(), so tree depth is bounded by the stack rather
// than by memory. The parser imposes no container-nesting limit of its own --
// `'>' * 300000` parses fine and every streaming renderer emits it -- so the
// bound has to live here.
//
// Measured headroom (`'>' * n` binary-searched, temporary build with the cap
// lifted, so the numbers are where the recursion actually dies):
//
//   * native, cost per level is linear -- ~48-53 B in ReleaseFast (what ships),
//     ~192 B in ReleaseSafe, ~768 B in Debug. ReleaseFast therefore survives
//     ~173 000 levels on the usual 8 MiB stack and ~9 800 on a 512 KiB one.
//   * wasm: the 16 MiB shadow stack (`__stack_pointer` starts at 0x1000000,
//     stack-first, so an overflow traps instead of corrupting the data
//     segment) is NOT the binding constraint -- the engine spends its own
//     ~1 MB native stack on the wasm frames and throws
//     `RangeError: Maximum call stack size exceeded` first: ~11 300 levels on
//     Node 24 / V8, ~9 000 on Bun / JSC, i.e. ~90-115 B per level.
//
// 1024 is therefore ~9x under the tightest engine (Bun) and ~170x under a
// native 8 MiB stack, while being 4x the old cap and far past any real
// document. Past the cap the renderer stops nesting instead of failing; see
// jsonAtMaxDepth().
const JSON_MAX_DEPTH: usize = 1024;

// Non-optional — see the note on `md4x-json.zig`'s ProcessOutputFn.
const ProcessOutputFn = *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

// ============================================================================
// Shared JSON writer + YAML-to-JSON helpers (md4x-json.zig) and component
// property parser (md4x-props.zig). These were previously reimplemented inline
// here; they now live in shared Zig modules and are imported. Local aliases
// preserve the original call-site names used throughout this file.
// ============================================================================

const json = @import("md4x-json.zig");
const props = @import("md4x-props.zig");

// ---- JSON writer (md4x-json.zig) ----
const JsonWriter = json.JsonWriter;
const jsonWrite = json.json_write;
const jsonWriteStr = json.json_write_str;
const jsonWriteStrZ = json.json_write_strz;
const jsonWriteEscaped = json.json_write_escaped;
const jsonWriteString = json.json_write_string;
const jsonWriteYamlProps = json.json_write_yaml_props;

// ---- Props parser (md4x-props.zig) ----
const ParsedProps = props.MD_PARSED_PROPS;
const mdParseProps = props.md_parse_props;

// *************************************
// ***  JSON AST node data structs   ***
// *************************************

const JsonNodeKind = enum(c_int) {
    document,
    element,
    text,
};

// Classifies the built-in tag for fast switch-based dispatch (replaces strcmp
// chains in jsonWriteProps / jsonSerializeNode / isLeafContainerTag). Set once
// at node creation. `dynamic` is for user components (tag_is_dynamic), `comment`
// for [null,{}] comment nodes, `other` for anything not needing special dispatch
// (em, strong, blockquote, headings, p, hr, ...).
const TagKind = enum {
    dynamic,
    comment,
    other,
    pre,
    a,
    img,
    wikilink,
    template,
    alert,
    ol,
    ul,
    li,
    th,
    td,
    code,
    math,
    math_display,
    html_block,
    frontmatter,
    footnote_section,
    footnote_def,
    footnote_ref,
};

// Detail variants. The C version uses a union; since every dispatch checks the
// tag (and tag_is_dynamic first), a flat struct produces identical output while
// avoiding union type-confusion entirely. Dynamic components only ever touch the
// `component` fields, matching the C contract that they use detail.component
// exclusively.
// Every string below is a **sentinel-terminated slice**, never a bare `[*:0]`
// pointer: the length is the exact byte count the arena buffer holds, and the
// NUL terminator is retained only for the few C-shaped consumers (snprintf-free
// props parser, libyaml). Recomputing the length with strlen() silently
// truncated any value carrying an embedded NUL — a NUL is legal document
// content, so `[[a<NUL>b]]` used to serialize as `"target":"a"` while its own
// text child rendered the full string.
const Detail = struct {
    // ol
    ol_is_tight: bool = false,
    ol_start: c_uint = 0,
    ol_delimiter: u8 = 0,
    // ul
    ul_is_tight: bool = false,
    // li
    li_is_task: bool = false,
    li_task_mark: u8 = 0,
    // code
    code_info: ?[:0]u8 = null,
    code_lang: ?[:0]u8 = null,
    code_fence_char: u8 = 0,
    code_filename: ?[:0]u8 = null,
    code_meta: ?[:0]u8 = null,
    code_highlights: ?[]c_uint = null,
    // table
    table_col_count: c_uint = 0,
    // td
    td_align: c_int = 0,
    // a
    a_href: ?[:0]u8 = null,
    a_title: ?[:0]u8 = null,
    // img
    img_src: ?[:0]u8 = null,
    img_title: ?[:0]u8 = null,
    // wikilink
    wikilink_target: ?[:0]u8 = null,
    // component
    component_raw_props: ?[:0]u8 = null,
    component_title: ?[:0]u8 = null,
    // template
    tmpl_name: ?[:0]u8 = null,
    // alert
    alert_type_name: ?[:0]u8 = null,
    // footnote-def / footnote-ref
    footnote_id: c_uint = 0,
    footnote_ref_id: c_uint = 0,
    footnote_ref_count: c_uint = 0,
    footnote_label: ?[:0]u8 = null,
};

const JsonNode = struct {
    kind: JsonNodeKind,
    tag: ?[:0]const u8 = null,
    // Classification of the built-in tag for switch-based dispatch.
    tag_kind: TagKind = .other,

    first_child: ?*JsonNode = null,
    last_child: ?*JsonNode = null,
    next_sibling: ?*JsonNode = null,

    // Text value for text nodes, or literal content for leaf containers.
    text_value: ?[:0]u8 = null,

    detail: Detail = .{},

    // True if the tag is heap-allocated (dynamic component tag).
    tag_is_dynamic: bool = false,

    // Document node only: JSON_MAX_DEPTH was reached, so some nesting was
    // collapsed. Serialized as `"meta":{"maxDepthExceeded":true}`.
    depth_exceeded: bool = false,

    // Raw inline attributes string from trailing {attrs}, or null.
    raw_attrs: ?[:0]u8 = null,
};

const JsonCtx = struct {
    // Arena owns the entire node tree and all node strings. The whole tree has a
    // single lifetime (built during parse, serialized once, freed all at once),
    // so an arena replaces the per-node malloc/free churn.
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator = undefined,
    root: ?*JsonNode = null,
    current: ?*JsonNode = null,
    stack: [JSON_MAX_DEPTH]?*JsonNode = undefined,
    stack_depth: c_int = 0,
    // Number of enter_block/enter_span callbacks that were suppressed because
    // the tree already stands JSON_MAX_DEPTH deep. The matching leave callbacks
    // consume it, so enter/leave stay balanced. `usize`, and one input byte is
    // needed per level, so it cannot overflow.
    suppressed_depth: usize = 0,
    image_nesting: c_int = 0,
    err: c_int = 0,
};

// The active arena allocator. The callbacks receive only a `*JsonCtx` userdata,
// and the helper functions (allocStr, dupNts, jsonAttrToStr, jsonAppendText,
// the text-merge paths) do not get the ctx threaded through; rather than rewrite
// every signature, the current ctx's allocator is stashed here for the duration
// of a single (non-reentrant) md_parse run. md_ast is the only entry point and
// md_parse is synchronous, so this is safe.
threadlocal var g_alloc: std.mem.Allocator = undefined;

// *****************************
// ***  Memory management    ***
// *****************************

// Allocate a NUL-terminated arena buffer holding `n` content bytes, returned as
// a sentinel slice of exactly that length. Returns null on failure.
fn allocStr(n: usize) ?[:0]u8 {
    const m = g_alloc.allocSentinel(u8, n, 0) catch return null;
    return m;
}

fn jsonNodeNew(tag: ?[:0]const u8, kind: JsonNodeKind) ?*JsonNode {
    const node = g_alloc.create(JsonNode) catch return null;
    node.* = .{ .kind = kind, .tag = tag };
    return node;
}

// All node and string memory lives in the arena and is freed wholesale when the
// arena is deinitialized. Per-node freeing is therefore a no-op; the function is
// retained so existing call sites read clearly (and so partial nodes on the OOM
// path are simply abandoned to the arena).
fn jsonNodeFree(node_opt: ?*JsonNode) void {
    _ = node_opt;
}

// U+FFFD REPLACEMENT CHARACTER in UTF-8.
const utf8_replacement_char = [_]u8{ 0xEF, 0xBF, 0xBD };

// Convert an MD_ATTRIBUTE to an arena-allocated, NUL-terminated slice whose
// length is exact. Returns null for an unset (empty) attribute OR on allocation
// failure — matching the C version, whose `text == NULL` test was equivalent:
// md_build_attribute only ever leaves `text` empty when the attribute is unset
// or was built from zero bytes, and never produces a non-empty pointer with a
// zero size.
//
// A `.nullchar` substring is a single U+0000 byte sitting in `attr.text`. It is
// substituted with U+FFFD here, which is what every other renderer's
// render_attribute() does (`render_utf8_codepoint(r, 0x0000, ...)` folds
// codepoint 0 onto the replacement character) and what this renderer's own text
// path does for a `.nullchar` text event. Emitting the raw byte instead left the
// attribute disagreeing with its own text child — `[[a<NUL>b]]` rendered
// `"target":"a\u0000b"` beside the child `"a<U+FFFD>b"` — and, before the
// length became exact, silently truncated the value at the NUL.
fn jsonAttrToStr(attr: *const c.Attribute) ?[:0]u8 {
    const total = attr.text.len;
    if (total == 0)
        return null;

    // Count the NUL substrings first: each grows the value by 2 bytes.
    var extra: usize = 0;
    var i: usize = 0;
    while (i < attr.substr_types.len and attr.substr_offsets[i] < total) : (i += 1) {
        if (attr.substr_types[i] == c.TextType.nullchar)
            extra += utf8_replacement_char.len - 1;
    }

    const buf = allocStr(total + extra) orelse return null;
    if (extra == 0) {
        // Overwhelmingly the common case: no substitution, one copy.
        @memcpy(buf[0..total], attr.text);
        return buf;
    }

    var w: usize = 0;
    var copied: usize = 0;
    i = 0;
    while (i < attr.substr_types.len and attr.substr_offsets[i] < total) : (i += 1) {
        const off: usize = attr.substr_offsets[i];
        const end: usize = attr.substr_offsets[i + 1];
        if (attr.substr_types[i] == c.TextType.nullchar) {
            @memcpy(buf[w..][0..utf8_replacement_char.len], &utf8_replacement_char);
            w += utf8_replacement_char.len;
        } else {
            @memcpy(buf[w..][0 .. end - off], attr.text[off..end]);
            w += end - off;
        }
        copied = end;
    }
    // The substring table is contiguous and ends at `total`, but the walk is
    // bounded rather than terminator-driven; copy any tail it did not cover.
    if (copied < total) {
        @memcpy(buf[w..][0 .. total - copied], attr.text[copied..total]);
        w += total - copied;
    }
    if (w < buf.len)
        buf[w] = 0;
    return buf[0..w :0];
}

// Duplicate `src` into a NUL-terminated arena slice of the same length.
fn dupNts(src: []const u8) ?[:0]u8 {
    const buf = allocStr(src.len) orelse return null;
    @memcpy(buf[0..src.len], src);
    return buf;
}

// ***********************************
// ***  AST tree building helpers  ***
// ***********************************

fn jsonAppendChild(ctx: *JsonCtx, child: *JsonNode) void {
    if (ctx.current == null) {
        ctx.err = 1;
        jsonNodeFree(child);
        return;
    }
    const cur = ctx.current.?;
    if (cur.first_child == null) {
        cur.first_child = child;
        cur.last_child = child;
    } else {
        cur.last_child.?.next_sibling = child;
        cur.last_child = child;
    }
}

// Depth guard for the enter callbacks. Once the tree stands JSON_MAX_DEPTH
// deep, the incoming block/span is NOT turned into a node at all: the callback
// returns 0 immediately, the suppression is counted so the matching leave stays
// balanced, and any text inside the suppressed subtree lands in the deepest
// node that was kept. That is the same shape as the existing image_nesting
// suppression a few lines below (spans inside an image are dropped and their
// text accumulated into the alt attribute), and it keeps the serializer's
// recursion bounded by JSON_MAX_DEPTH for any input. (Exactly one level more,
// in fact: jsonText() appends `["br",{}]` and `[null,{},"comment"]` element
// nodes without pushing. Both are leaves, so they add a single frame, never a
// chain.)
//
// This replaces setting `ctx.err`, which made md_ast() return -1 and emit
// ZERO bytes for the whole document -- a single deep blockquote or list
// anywhere in a file killed the entire render (through the JS bindings: a
// thrown "md4x: render failed" / "Markdown parsing failed"), while every other
// renderer emitted the document happily. Losing the shape of what is already a
// pathological nesting level beats losing the document.
//
// The collapse is reported rather than silent: the document node's flag is
// serialized as `"meta":{"maxDepthExceeded":true}`, using the existing (and
// otherwise always-empty) top-level `meta` bag of the ComarkTree contract, so
// the tuple/props shape every consumer walks is untouched.
fn jsonAtMaxDepth(ctx: *JsonCtx) bool {
    if (ctx.stack_depth < @as(c_int, @intCast(JSON_MAX_DEPTH)))
        return false;
    ctx.suppressed_depth += 1;
    if (ctx.root) |root|
        root.depth_exceeded = true;
    return true;
}

// Consumed by the leave callbacks, which must skip everything they would
// otherwise do to the node the suppressed enter never created -- popping the
// stack included, since nothing was pushed.
fn jsonLeaveSuppressed(ctx: *JsonCtx) bool {
    if (ctx.suppressed_depth == 0)
        return false;
    ctx.suppressed_depth -= 1;
    return true;
}

fn jsonPush(ctx: *JsonCtx, node: *JsonNode) void {
    // Unreachable in practice: every caller has already returned via
    // jsonAtMaxDepth(). Kept as a defensive guard (AGENTS.md: `unreachable` is
    // UB in the shipping ReleaseFast build). It counts the suppression rather
    // than just declining to push, so that a future caller that forgets the
    // check leaves the stack balanced (jsonLeaveSuppressed consumes it) instead
    // of letting the matching leave pop this node's parent.
    if (ctx.stack_depth >= @as(c_int, @intCast(JSON_MAX_DEPTH))) {
        ctx.suppressed_depth += 1;
        return;
    }
    ctx.stack[@intCast(ctx.stack_depth)] = ctx.current;
    ctx.stack_depth += 1;
    ctx.current = node;
}

fn jsonPop(ctx: *JsonCtx) void {
    if (ctx.stack_depth > 0) {
        ctx.stack_depth -= 1;
        ctx.current = ctx.stack[@intCast(ctx.stack_depth)];
    }
}

// Append text to a node's text_value buffer. Returns 0 on success, -1 on OOM.
fn jsonAppendText(node: *JsonNode, src: []const u8) c_int {
    if (node.text_value == null) {
        node.text_value = dupNts(src) orelse return -1;
    } else {
        node.text_value = appendToStr(node.text_value.?, src) orelse return -1;
    }
    return 0;
}

// Grow a NUL-terminated arena slice by `src`, returning the new slice (the old
// buffer is either reused in place or abandoned to the arena). Null on OOM.
fn appendToStr(old: [:0]u8, src: []const u8) ?[:0]u8 {
    const merged = g_alloc.realloc(old[0 .. old.len + 1], old.len + src.len + 1) catch return null;
    @memcpy(merged[old.len .. old.len + src.len], src);
    merged[old.len + src.len] = 0;
    return merged[0 .. old.len + src.len :0];
}

// *************************************
// ***  HTML comment helpers          ***
// *************************************

// Check if a string is an HTML comment (<!-- ... -->), possibly with
// surrounding whitespace. On match, returns the comment body (between <!-- and
// -->) as a subslice of `text`; null otherwise.
fn jsonIsHtmlComment(text: []const u8) ?[]const u8 {
    var p: usize = 0;
    const end: usize = text.len;

    // Skip leading whitespace.
    while (p < end and (text[p] == ' ' or text[p] == '\t' or text[p] == '\n' or text[p] == '\r'))
        p += 1;

    // Must start with <!--
    if (end - p < 7) // at minimum <!-- -->
        return null;
    if (text[p] != '<' or text[p + 1] != '!' or text[p + 2] != '-' or text[p + 3] != '-')
        return null;

    // Find --> from the end, skipping trailing whitespace.
    var q: usize = end;
    while (q > p and (text[q - 1] == ' ' or text[q - 1] == '\t' or text[q - 1] == '\n' or text[q - 1] == '\r'))
        q -= 1;

    if (q - p < 7)
        return null;
    if (text[q - 1] != '>' or text[q - 2] != '-' or text[q - 3] != '-')
        return null;

    return text[p + 4 .. q - 3]; // between <!-- and -->
}

// ***********************************
// ***  md_parse() callbacks       ***
// ***********************************

const heading_tags = [_][:0]const u8{ "h0", "h1", "h2", "h3", "h4", "h5", "h6" };

fn jsonEnterBlock(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));

    // Too deep to nest any further: drop the block and let its content collapse
    // into the deepest node kept (see jsonAtMaxDepth).
    if (jsonAtMaxDepth(ctx))
        return 0;

    const block_type = std.meta.activeTag(detail.*);
    var node: ?*JsonNode = null;
    var tag: ?[:0]const u8 = null;

    switch (detail.*) {
        .doc => tag = null,
        .quote => tag = "blockquote",
        .ul => tag = "ul",
        .ol => tag = "ol",
        .li => tag = "li",
        .hr => tag = "hr",
        .h => |*d| {
            tag = if (d.level >= 1 and d.level <= 6) heading_tags[d.level] else "h1";
        },
        .code => tag = "pre",
        .html => tag = "html_block",
        .p => tag = "p",
        .table => tag = "table",
        .thead => tag = "thead",
        .tbody => tag = "tbody",
        .tr => tag = "tr",
        .th => tag = "th",
        .td => tag = "td",
        .frontmatter => tag = "frontmatter",
        .component => tag = null, // handled below
        .template => tag = null, // handled below
        .alert => tag = "alert",
        // Comark shape rather than upstream's <section class="footnotes"><ol>:
        // an MDC consumer wants the semantic nodes, and renderToHtml still
        // produces the <section>/<ol>/<li> markup from the same SAX stream.
        .footnote_def_section => tag = "footnotes",
        .footnote_def => tag = "footnote",
    }

    // Dispatch on the detail union, so a dynamic component whose name
    // collides with a built-in tag still takes the component path (see the
    // tag_is_dynamic-first rule in AGENTS.md).
    switch (detail.*) {
        .doc => node = jsonNodeNew(null, .document),
        .alert => |*d| {
            node = jsonNodeNew("alert", .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.detail.alert_type_name = jsonAttrToStr(&d.type_name);
        },
        .component => |*d| {
            tag = jsonAttrToStr(&d.tag_name);
            if (tag == null) {
                ctx.err = 1;
                return -1;
            }
            node = jsonNodeNew(tag, .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.tag_is_dynamic = true;
            if (d.raw_props.len > 0) {
                const dup = dupNts(d.raw_props);
                if (dup == null) {
                    ctx.err = 1;
                    return -1;
                }
                node.?.detail.component_raw_props = dup;
            }
            if (d.title.len > 0) {
                const dup = dupNts(d.title);
                if (dup == null) {
                    jsonNodeFree(node);
                    ctx.err = 1;
                    return -1;
                }
                node.?.detail.component_title = dup;
            }
        },
        .template => |*d| {
            const name_str = jsonAttrToStr(&d.name);
            node = jsonNodeNew("template", .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.detail.tmpl_name = name_str;
        },
        else => node = jsonNodeNew(tag, .element),
    }
    if (node == null) {
        ctx.err = 1;
        return -1;
    }
    const n = node.?;

    // Classify the tag once for fast dispatch later (dynamic components win).
    if (n.tag_is_dynamic) {
        n.tag_kind = .dynamic;
    } else switch (block_type) {
        .ul => n.tag_kind = .ul,
        .ol => n.tag_kind = .ol,
        .li => n.tag_kind = .li,
        .h => n.tag_kind = .other,
        .code => n.tag_kind = .pre,
        .html => n.tag_kind = .html_block,
        .th => n.tag_kind = .th,
        .td => n.tag_kind = .td,
        .frontmatter => n.tag_kind = .frontmatter,
        .template => n.tag_kind = .template,
        .alert => n.tag_kind = .alert,
        .footnote_def_section => n.tag_kind = .footnote_section,
        .footnote_def => n.tag_kind = .footnote_def,
        else => n.tag_kind = .other,
    }

    // Copy type-specific detail data.
    switch (detail.*) {
        .ul => |*d| {
            n.detail.ul_is_tight = d.is_tight;
        },
        .ol => |*d| {
            n.detail.ol_is_tight = d.is_tight;
            n.detail.ol_start = d.start;
            n.detail.ol_delimiter = @bitCast(d.mark_delimiter);
        },
        .li => |*d| {
            n.detail.li_is_task = d.is_task;
            n.detail.li_task_mark = @bitCast(d.task_mark);
        },
        .code => |*d| {
            n.detail.code_info = jsonAttrToStr(&d.info);
            n.detail.code_lang = jsonAttrToStr(&d.lang);
            n.detail.code_fence_char = @bitCast(d.fence_char);
            n.detail.code_filename = jsonAttrToStr(&d.filename);
            if (d.meta.len > 0) {
                // Note: C ignores OOM here (best-effort) — match that.
                if (dupNts(d.meta)) |dup|
                    n.detail.code_meta = dup;
            }
            if (d.highlights.len > 0) {
                const m = g_alloc.alloc(c_uint, d.highlights.len) catch null;
                if (m) |arr| {
                    @memcpy(arr, d.highlights);
                    n.detail.code_highlights = arr;
                }
            }
        },
        .table => |*d| {
            n.detail.table_col_count = d.col_count;
        },
        .th, .td => |*d| {
            n.detail.td_align = @intCast(@intFromEnum(d.@"align"));
        },
        .footnote_def => |*d| {
            n.detail.footnote_id = d.id;
            n.detail.footnote_ref_count = d.ref_count;
            n.detail.footnote_label = jsonAttrToStr(&d.label);
        },
        else => {},
    }

    if (ctx.current != null) {
        jsonAppendChild(ctx, n);
    } else if (ctx.root == null) {
        ctx.root = n;
    } else {
        // Unbalanced callbacks caused stack underflow — attach to root
        // to avoid leaking the subtree.
        ctx.current = ctx.root;
        jsonAppendChild(ctx, n);
    }

    jsonPush(ctx, n);
    return if (ctx.err != 0) -1 else 0;
}

fn jsonLeaveBlock(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));

    // The matching enter was depth-suppressed: no node exists, so there is
    // nothing to convert and nothing to pop. Must come before the comment
    // conversion below, which would otherwise inspect an unrelated node.
    if (jsonLeaveSuppressed(ctx))
        return 0;

    // Convert html_block comments to [null, {}, "body"] nodes.
    if (detail.* == .html and ctx.current != null and ctx.current.?.text_value != null) {
        const cur = ctx.current.?;
        if (jsonIsHtmlComment(cur.text_value.?)) |body| {
            // Replace tag with null (comment node).
            cur.tag = null;
            // Replace text_value with just the comment body. The old buffer is
            // abandoned to the arena (freed wholesale at deinit).
            if (dupNts(body)) |new_text| {
                cur.tag_kind = .comment;
                cur.text_value = new_text;
            }
        }
    }

    jsonPop(ctx);
    return 0;
}

fn jsonEnterSpan(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));
    const span_type = std.meta.activeTag(detail.*);
    var node: ?*JsonNode = null;
    var tag: ?[:0]const u8 = null;

    // Inside an image: suppress nested spans, just accumulate alt text.
    // Checked before the depth guard, and in the same order in jsonLeaveSpan,
    // so a span is only ever counted by one of the two suppressions.
    if (ctx.image_nesting > 0) {
        if (detail.* == .img)
            ctx.image_nesting += 1;
        return 0;
    }

    // Too deep to nest any further (see jsonAtMaxDepth).
    if (jsonAtMaxDepth(ctx))
        return 0;

    // The dynamic-component arm is resolved from the union tag *before* any
    // built-in tag handling (AGENTS.md's tag_is_dynamic-first rule), so a
    // component named e.g. "code" still takes the component path.
    if (detail.* == .component) {
        const d = &detail.component;
        tag = jsonAttrToStr(&d.tag_name);
        if (tag == null) {
            ctx.err = 1;
            return -1;
        }
        node = jsonNodeNew(tag, .element);
        if (node == null) {
            ctx.err = 1;
            return -1;
        }
        node.?.tag_is_dynamic = true;
        node.?.tag_kind = .dynamic;
        if (d.raw_props.len > 0) {
            const dup = dupNts(d.raw_props);
            if (dup == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.detail.component_raw_props = dup;
        }
    } else {
        switch (detail.*) {
            .em => tag = "em",
            .strong => tag = "strong",
            .a => tag = "a",
            .img => tag = "img",
            .code => tag = "code",
            .del => tag = "del",
            .mark => tag = "mark",
            .latexmath => tag = "math",
            .latexmath_display => tag = "math-display",
            .wikilink => tag = "wikilink",
            .u => tag = "u",
            .span => tag = "span",
            .footnote_ref => tag = "footnote-ref",
            // `.component` is resolved above; the arm only exists to keep the
            // switch exhaustive without an `unreachable` (AGENTS.md: prefer a
            // defensive guard, since `unreachable` is UB in ReleaseFast).
            .component => tag = "unknown",
        }

        node = jsonNodeNew(tag, .element);
        if (node == null) {
            ctx.err = 1;
            return -1;
        }
        const n = node.?;

        n.tag_kind = switch (span_type) {
            .a => .a,
            .img => .img,
            .code => .code,
            .latexmath => .math,
            .latexmath_display => .math_display,
            .wikilink => .wikilink,
            .footnote_ref => .footnote_ref,
            else => .other,
        };

        switch (detail.*) {
            .a => |*d| {
                n.detail.a_href = jsonAttrToStr(&d.href);
                n.detail.a_title = jsonAttrToStr(&d.title);
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs)) |dup|
                        n.raw_attrs = dup;
                }
            },
            .img => |*d| {
                n.detail.img_src = jsonAttrToStr(&d.src);
                n.detail.img_title = jsonAttrToStr(&d.title);
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs)) |dup|
                        n.raw_attrs = dup;
                }
                ctx.image_nesting = 1;
            },
            .wikilink => |*d| {
                n.detail.wikilink_target = jsonAttrToStr(&d.target);
            },
            .span => |*d| {
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs)) |dup|
                        n.raw_attrs = dup;
                }
            },
            .em, .strong, .code, .del, .u, .mark => |*d| {
                // These spans may carry trailing {attrs}; an empty raw_attrs
                // means there were none.
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs)) |dup|
                        n.raw_attrs = dup;
                }
            },
            .latexmath, .latexmath_display => {},
            .footnote_ref => |*d| {
                n.detail.footnote_id = d.id;
                n.detail.footnote_ref_id = d.ref_id;
                n.detail.footnote_label = jsonAttrToStr(&d.label);
            },
            .component => {}, // resolved above
        }
    }

    jsonAppendChild(ctx, node.?);
    jsonPush(ctx, node.?);
    return if (ctx.err != 0) -1 else 0;
}

fn jsonLeaveSpan(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));

    if (ctx.image_nesting > 0) {
        if (detail.* == .img)
            ctx.image_nesting -= 1;
        if (ctx.image_nesting > 0)
            return 0;
        // Leaving the outermost image span: text_value has the accumulated alt text.
    }

    // The matching enter was depth-suppressed (see jsonLeaveBlock).
    if (jsonLeaveSuppressed(ctx))
        return 0;

    jsonPop(ctx);
    return 0;
}

fn jsonText(text_type: c.TextType, text: []const c.MD_CHAR, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));
    var value: ?[:0]u8 = null;

    // Guard against unbalanced callbacks causing NULL current.
    if (ctx.current == null) {
        if (ctx.root != null)
            ctx.current = ctx.root
        else
            return 0;
    }
    const cur = ctx.current.?;

    // Inside an image: accumulate text as alt attribute.
    if (ctx.image_nesting > 0) {
        const src: []const u8 = switch (text_type) {
            .softbr => " ",
            .nullchar => &utf8_replacement_char,
            else => text,
        };
        if (jsonAppendText(cur, src) != 0) {
            ctx.err = 1;
            return -1;
        }
        return 0;
    }

    // Leaf container nodes: accumulate text as literal on the parent node.
    // Dynamic components (tag_is_dynamic) must never match here, even if their
    // name collides with a built-in tag (e.g. ::pre, ::code).
    if (!cur.tag_is_dynamic and cur.tag != null and isLeafContainer(cur.tag_kind)) {
        const src: []const u8 = if (text_type == c.TextType.nullchar) &utf8_replacement_char else text;
        if (jsonAppendText(cur, src) != 0) {
            ctx.err = 1;
            return -1;
        }
        return 0;
    }

    switch (text_type) {
        .br => {
            // Linebreak → ["br", {}] element node.
            const node = jsonNodeNew("br", .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            jsonAppendChild(ctx, node.?);
            return 0;
        },

        .softbr => {
            // Softbreak → "\n" text.
            value = dupNts("\n") orelse {
                ctx.err = 1;
                return -1;
            };
        },

        .nullchar => {
            value = dupNts(&utf8_replacement_char) orelse {
                ctx.err = 1;
                return -1;
            };
        },

        .html => {
            // Inline HTML: check for comment <!-- ... -->
            if (jsonIsHtmlComment(text)) |cbody| {
                // Emit [null, {}, "comment body"] element.
                const cnode = jsonNodeNew(null, .element);
                if (cnode == null) {
                    ctx.err = 1;
                    return -1;
                }
                cnode.?.tag_kind = .comment;
                // Unconditionally, even for an empty body: a comment node is
                // `[null,{},"body"]` in every other case, and the block-level
                // path (jsonLeaveBlock) already emits `[null,{},""]` for
                // `<!---->`. Guarding on `cbody.len > 0` here made the inline
                // spelling of the same comment `[null,{}]` instead, so a
                // consumer reading `node[2]` got `""` from one and `undefined`
                // from the other. The three-element shape is the documented one
                // (docs/js-bindings.md) and the one that keeps the body slot
                // present for every comment.
                const dup = dupNts(cbody);
                if (dup == null) {
                    jsonNodeFree(cnode);
                    ctx.err = 1;
                    return -1;
                }
                cnode.?.text_value = dup;
                jsonAppendChild(ctx, cnode.?);
                return 0;
            }
            // Non-comment inline HTML: fall through to default text handling.
            value = dupNts(text) orelse {
                ctx.err = 1;
                return -1;
            };
        },

        else => {
            // Normal text, entity, code, latexmath.
            value = dupNts(text) orelse {
                ctx.err = 1;
                return -1;
            };
        },
    }

    // Merge consecutive text nodes.
    const prev_opt = cur.last_child;
    if (prev_opt != null and prev_opt.?.kind == .text and prev_opt.?.text_value != null and value != null) {
        const prev = prev_opt.?;
        prev.text_value = appendToStr(prev.text_value.?, value.?) orelse {
            ctx.err = 1;
            return -1;
        };
        // `value` is abandoned to the arena.
        return 0;
    }

    const node = jsonNodeNew(null, .text);
    if (node == null) {
        // `value` is abandoned to the arena.
        ctx.err = 1;
        return -1;
    }
    node.?.text_value = value;

    jsonAppendChild(ctx, node.?);
    return 0;
}

fn isLeafContainer(kind: TagKind) bool {
    return switch (kind) {
        .pre, .html_block, .code, .frontmatter, .math, .math_display => true,
        else => false,
    };
}

fn jsonDebugLog(msg: []const u8, userdata: ?*anyopaque) void {
    _ = userdata;
    diag.logMessage(msg);
}

fn jsonAlignStr(align_v: c_int) ?[:0]const u8 {
    return switch (align_v) {
        @intFromEnum(c.Align.left) => "left",
        @intFromEnum(c.Align.center) => "center",
        @intFromEnum(c.Align.right) => "right",
        else => null,
    };
}

// True when a parsed prop string yields nothing for jsonWriteParsedProps() to
// emit. A non-empty raw string is NOT enough: `{ }`, `{=}`, `{.}` and `{#}` all
// parse to zero props, so a caller that emits the separating comma up front
// would leave a trailing comma inside the props object (invalid JSON). Every
// call site must consult this BEFORE writing the separator.
fn parsedPropsAreEmpty(parsed: *const ParsedProps) bool {
    return parsed.n_props == 0 and parsed.id == null and parsed.class_len == 0;
}

// Write already-parsed component props. Takes the parse result rather than the
// raw string so a caller can decide whether anything will be written (see
// parsedPropsAreEmpty) without parsing twice — ParsedProps is ~1.5 KB and
// md_parse_props() zeroes all of it on entry, so the second parse was
// measurable on attribute-heavy documents.
// Returns number of props written.
fn jsonWriteParsedProps(w: *JsonWriter, parsed: *const ParsedProps) c_int {
    var n_written: c_int = 0;

    // Write #id.
    if (parsed.id != null and parsed.id_size > 0) {
        if (n_written > 0) jsonWrite(w, ",", 1);
        jsonWriteStr(w, "\"id\":");
        jsonWriteString(w, parsed.id.?, parsed.id_size);
        n_written += 1;
    }

    // Write regular props.
    var i: c_int = 0;
    while (i < parsed.n_props) : (i += 1) {
        const p = &parsed.props[@intCast(i)];

        if (n_written > 0) jsonWrite(w, ",", 1);

        switch (p.type) {
            .string => {
                jsonWrite(w, "\"", 1);
                jsonWriteEscaped(w, p.key, p.key_size);
                jsonWriteStr(w, "\":");
                jsonWriteString(w, p.value.?, p.value_size);
                n_written += 1;
            },
            .boolean => {
                jsonWriteStr(w, "\":");
                jsonWriteEscaped(w, p.key, p.key_size);
                jsonWriteStr(w, "\":\"true\"");
                n_written += 1;
            },
            .bind => {
                jsonWrite(w, "\":", 2);
                jsonWriteEscaped(w, p.key, p.key_size);
                jsonWriteStr(w, "\":");
                // The bind value is emitted as a JSON-escaped *string*, never
                // spliced in raw: a raw splice produces invalid JSON for any
                // non-JSON value and lets an author inject arbitrary sibling
                // keys into the props object. See docs/comark-ast.md
                // ("Object/Array Properties") and docs/js-bindings.md.
                jsonWriteString(w, p.value.?, p.value_size);
                n_written += 1;
            },
        }
    }

    // Write merged class.
    if (parsed.class_len > 0) {
        if (n_written > 0) jsonWrite(w, ",", 1);
        jsonWriteStr(w, "\"class\":");
        jsonWriteString(w, &parsed.class_buf, parsed.class_len);
        n_written += 1;
    }

    return n_written;
}

// Write `s` as a quoted, JSON-escaped string using its **exact** length. Every
// string in the node tree is a sentinel slice so this can never fall back to
// strlen(): a NUL is legal document content (the parser reports it as
// `TextType.nullchar`), and recomputing the length truncated the value there.
// `json_write_escaped` renders any control byte, U+0000 included, as `\u00xx`,
// so the raw-byte strings (component props/title, code `meta`, inline `{attrs}`)
// stay valid JSON and round-trip through JSON.parse().
fn jsonWriteSlice(w: *JsonWriter, s: []const u8) void {
    jsonWriteString(w, s.ptr, @intCast(s.len));
}

// Write the props object for an element node.
fn jsonWriteProps(w: *JsonWriter, node: *const JsonNode) void {
    var has_prop: c_int = 0;

    jsonWrite(w, "{", 1);

    // Dynamic components (tag_is_dynamic) use detail.component fields, so must
    // be checked first to avoid misinterpreting detail when a component name
    // collides with a static tag (e.g. ::alert{...}).
    if (node.tag_is_dynamic) {
        // Component frontmatter: if first child is a frontmatter node, merge its YAML as props.
        if (node.first_child != null and node.first_child.?.kind == .element and
            node.first_child.?.tag != null and !node.first_child.?.tag_is_dynamic and
            node.first_child.?.tag_kind == .frontmatter and
            node.first_child.?.text_value != null and node.first_child.?.text_value.?.len > 0)
        {
            const fm = node.first_child.?.text_value.?;
            has_prop = @intFromBool(jsonWriteYamlProps(w, fm.ptr, @intCast(fm.len)) > 0);
        }
        // Component title (e.g. :::danger STOP → "title":"STOP").
        if (node.detail.component_title) |title| {
            if (title.len > 0) {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"title\":");
                jsonWriteSlice(w, title);
                has_prop = 1;
            }
        }
        // Component: parse raw props string. A non-empty raw string can still
        // yield zero props (`{ }`, `{=}`, `{.}`, `{#}`), so the separating comma
        // is emitted only once the parse says something will follow it.
        if (node.detail.component_raw_props) |raw| {
            if (raw.len > 0) {
                // Declared inside the branch: ParsedProps is ~1.5 KB and Debug /
                // ReleaseSafe fill `undefined` with 0xaa, so hoisting it would cost
                // that memset on every element node, prop string or not.
                var parsed: ParsedProps = undefined;
                mdParseProps(raw.ptr, @intCast(raw.len), &parsed);
                if (!parsedPropsAreEmpty(&parsed)) {
                    if (has_prop != 0) jsonWrite(w, ",", 1);
                    _ = jsonWriteParsedProps(w, &parsed);
                    has_prop = 1;
                }
            }
        }
    } else switch (node.tag_kind) {
        .ol => {
            if (node.detail.ol_start != 1) {
                var buf: [32]u8 = undefined;
                _ = sys.snprintf(&buf, buf.len, "\"start\":%u", node.detail.ol_start);
                jsonWriteStrZ(w, @ptrCast(&buf));
                has_prop = 1;
            }
        },
        .li => {
            if (node.detail.li_is_task) {
                jsonWriteStr(w, "\"task\":true,\"checked\":");
                jsonWriteStr(w, if (node.detail.li_task_mark == 'x' or node.detail.li_task_mark == 'X') "true" else "false");
                has_prop = 1;
            }
        },
        .pre => {
            if (nonEmpty(node.detail.code_lang)) |lang| {
                jsonWriteStr(w, "\"language\":");
                jsonWriteSlice(w, lang);
                has_prop = 1;
            }
            if (nonEmpty(node.detail.code_filename)) |filename| {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"filename\":");
                jsonWriteSlice(w, filename);
                has_prop = 1;
            }
            if (node.detail.code_highlights) |highlights| {
                if (highlights.len > 0) {
                    var buf: [16]u8 = undefined;
                    if (has_prop != 0) jsonWrite(w, ",", 1);
                    jsonWriteStr(w, "\"highlights\":[");
                    for (highlights, 0..) |hl, hi| {
                        if (hi > 0) jsonWrite(w, ",", 1);
                        _ = sys.snprintf(&buf, buf.len, "%u", hl);
                        jsonWriteStrZ(w, @ptrCast(&buf));
                    }
                    jsonWrite(w, "]", 1);
                    has_prop = 1;
                }
            }
            if (nonEmpty(node.detail.code_meta)) |meta| {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"meta\":");
                jsonWriteSlice(w, meta);
                has_prop = 1;
            }
        },
        .th, .td => {
            const align_str = jsonAlignStr(node.detail.td_align);
            if (align_str) |a| {
                jsonWriteStr(w, "\"align\":\"");
                jsonWriteStr(w, a);
                jsonWrite(w, "\"", 1);
                has_prop = 1;
            }
        },
        .a => {
            if (node.detail.a_href) |href| {
                jsonWriteStr(w, "\"href\":");
                jsonWriteSlice(w, href);
                has_prop = 1;
            }
            if (nonEmpty(node.detail.a_title)) |title| {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"title\":");
                jsonWriteSlice(w, title);
                has_prop = 1;
            }
        },
        .img => {
            if (node.detail.img_src) |src| {
                jsonWriteStr(w, "\"src\":");
                jsonWriteSlice(w, src);
                has_prop = 1;
            }
            if (node.text_value) |alt| {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"alt\":");
                jsonWriteSlice(w, alt);
                has_prop = 1;
            }
            if (nonEmpty(node.detail.img_title)) |title| {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"title\":");
                jsonWriteSlice(w, title);
                has_prop = 1;
            }
        },
        .wikilink => {
            if (node.detail.wikilink_target) |target| {
                jsonWriteStr(w, "\"target\":");
                jsonWriteSlice(w, target);
                has_prop = 1;
            }
        },
        .template => {
            if (node.detail.tmpl_name) |name| {
                jsonWriteStr(w, "\"name\":");
                jsonWriteSlice(w, name);
                has_prop = 1;
            }
        },
        .alert => {
            if (node.detail.alert_type_name) |type_name| {
                jsonWriteStr(w, "\"type\":");
                jsonWriteSlice(w, type_name);
                has_prop = 1;
            }
        },
        .frontmatter => {
            if (node.text_value) |fm| {
                if (fm.len > 0)
                    has_prop = @intFromBool(jsonWriteYamlProps(w, fm.ptr, @intCast(fm.len)) > 0);
            }
        },
        .footnote_def => {
            var buf: [32]u8 = undefined;
            _ = sys.snprintf(&buf, buf.len, "\"id\":%u", node.detail.footnote_id);
            jsonWriteStrZ(w, @ptrCast(&buf));
            if (node.detail.footnote_label) |label| {
                jsonWriteStr(w, ",\"label\":");
                jsonWriteSlice(w, label);
            }
            _ = sys.snprintf(&buf, buf.len, ",\"refCount\":%u", node.detail.footnote_ref_count);
            jsonWriteStrZ(w, @ptrCast(&buf));
            has_prop = 1;
        },
        .footnote_ref => {
            var buf: [32]u8 = undefined;
            _ = sys.snprintf(&buf, buf.len, "\"id\":%u", node.detail.footnote_id);
            jsonWriteStrZ(w, @ptrCast(&buf));
            _ = sys.snprintf(&buf, buf.len, ",\"refId\":%u", node.detail.footnote_ref_id);
            jsonWriteStrZ(w, @ptrCast(&buf));
            if (node.detail.footnote_label) |label| {
                jsonWriteStr(w, ",\"label\":");
                jsonWriteSlice(w, label);
            }
            has_prop = 1;
        },
        else => {},
    }

    // Merge inline attributes from trailing {attrs} syntax. Same rule as above:
    // parse once, and only then decide whether a separator is due.
    if (node.raw_attrs) |raw| {
        if (raw.len > 0) {
            var parsed: ParsedProps = undefined;
            mdParseProps(raw.ptr, @intCast(raw.len), &parsed);
            if (!parsedPropsAreEmpty(&parsed)) {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                _ = jsonWriteParsedProps(w, &parsed);
                has_prop = 1;
            }
        }
    }

    // (C had a `(void) has_prop;` here; has_prop is read above, so nothing to do.)
    jsonWrite(w, "}", 1);
}

// Unwrap an optional string, folding the empty string onto "absent". These
// props were previously guarded by `s[0] != 0`, i.e. "non-empty as a C string";
// with exact lengths the same intent is `len > 0`.
fn nonEmpty(s: ?[:0]u8) ?[:0]u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

fn jsonSerializeNode(w: *JsonWriter, node: *const JsonNode) void {
    switch (node.kind) {
        .document => {
            var fm_node: ?*const JsonNode = null;

            // Find frontmatter node (if any).
            var child = node.first_child;
            while (child) |ch| : (child = ch.next_sibling) {
                if (ch.kind == .element and ch.tag != null and
                    !ch.tag_is_dynamic and ch.tag_kind == .frontmatter)
                {
                    fm_node = ch;
                    break;
                }
            }

            // Emit nodes (excluding frontmatter).
            jsonWriteStr(w, "{\"nodes\":[");
            var first: c_int = 1;
            child = node.first_child;
            while (child) |ch| : (child = ch.next_sibling) {
                if (ch == fm_node) continue;
                if (first == 0) jsonWrite(w, ",", 1);
                jsonSerializeNode(w, ch);
                first = 0;
            }

            // Emit frontmatter field.
            jsonWriteStr(w, "],\"frontmatter\":{");
            if (fm_node) |fm| {
                if (fm.text_value) |text| {
                    if (text.len > 0)
                        _ = jsonWriteYamlProps(w, text.ptr, @intCast(text.len));
                }
            }

            // `meta` is the ComarkTree's top-level extension bag
            // (`Record<string, unknown>`, always emitted, empty until now). The
            // one thing the renderer has to report about itself goes here:
            // nesting past JSON_MAX_DEPTH was collapsed, so this tree is
            // shallower than the source. Emitted only in that case, so ordinary
            // output stays byte-for-byte what it was.
            jsonWriteStr(w, "},\"meta\":{");
            if (node.depth_exceeded)
                jsonWriteStr(w, "\"maxDepthExceeded\":true");
            jsonWriteStr(w, "}}");
        },

        .text => {
            jsonWriteSlice(w, node.text_value.?);
        },

        .element => {
            // Comment nodes: [null, {}, "body"]
            if (node.tag == null) {
                jsonWriteStr(w, "[null,{}");
                if (node.text_value) |text| {
                    jsonWrite(w, ",", 1);
                    jsonWriteSlice(w, text);
                }
                jsonWrite(w, "]", 1);
                return;
            }

            jsonWriteStr(w, "[\"");
            jsonWriteStr(w, node.tag.?);
            jsonWriteStr(w, "\",");

            // Write props.
            jsonWriteProps(w, node);

            // Special handling for built-in tags.
            // Dynamic components always use the regular container path.
            if (!node.tag_is_dynamic and node.tag_kind == .pre) {
                jsonWriteStr(w, ",[\"code\",{");
                if (nonEmpty(node.detail.code_lang)) |lang| {
                    jsonWriteStr(w, "\"class\":\"");
                    // Do not repeat the prefix if the info string already carries it.
                    if (!std.mem.startsWith(u8, lang, "language-"))
                        jsonWriteStr(w, "language-");
                    jsonWriteEscaped(w, lang.ptr, @intCast(lang.len));
                    jsonWrite(w, "\"", 1);
                }
                jsonWriteStr(w, "},");
                if (node.text_value) |text|
                    jsonWriteSlice(w, text)
                else
                    jsonWriteStr(w, "\"\"");
                jsonWrite(w, "]", 1);
            }
            // html_block and frontmatter: emit literal as text child.
            else if (!node.tag_is_dynamic and node.text_value != null and
                (node.tag_kind == .html_block or node.tag_kind == .frontmatter))
            {
                jsonWrite(w, ",", 1);
                jsonWriteSlice(w, node.text_value.?);
            }
            // Inline code, math, math-display: emit literal as text child.
            else if (!node.tag_is_dynamic and node.text_value != null and
                (node.tag_kind == .code or node.tag_kind == .math or node.tag_kind == .math_display))
            {
                jsonWrite(w, ",", 1);
                jsonWriteSlice(w, node.text_value.?);
            }
            // img: void element, no children (alt is in props).
            else if (!node.tag_is_dynamic and node.tag_kind == .img) {
                // No children emitted.
            }
            // Regular container: emit children.
            else {
                // For dynamic components, skip frontmatter first child (merged into props).
                var skip_fm: ?*const JsonNode = null;
                if (node.tag_is_dynamic and node.first_child != null and
                    node.first_child.?.kind == .element and node.first_child.?.tag != null and
                    !node.first_child.?.tag_is_dynamic and node.first_child.?.tag_kind == .frontmatter)
                {
                    skip_fm = node.first_child;
                }
                var child = node.first_child;
                while (child) |ch| : (child = ch.next_sibling) {
                    if (ch == skip_fm) continue;
                    jsonWrite(w, ",", 1);
                    jsonSerializeNode(w, ch);
                }
            }

            jsonWrite(w, "]", 1);
        },
    }
}

// **************************************
// ***  Heal-before-render wrapper    ***
// **************************************

const MD4X_HEAL_BUF = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn md4xHealBufAppend(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) void {
    const buf: *MD4X_HEAL_BUF = @ptrCast(@alignCast(userdata.?));
    if (buf.err != 0) return;
    if (buf.size + size > buf.cap) {
        const new_cap: c_uint = buf.cap + buf.cap / 2 + size + 256;
        if (buf.data) |old| {
            const p = c_allocator.realloc(old[0..buf.cap], new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        } else {
            const p = c_allocator.alloc(u8, new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        }
        buf.cap = new_cap;
    }
    @memcpy(buf.data.?[buf.size .. buf.size + size], @as([*]const u8, @ptrCast(text))[0..size]);
    buf.size += size;
}

fn md4xHealInput(input: [*c]const c.MD_CHAR, input_size: c.MD_SIZE, buf: *MD4X_HEAL_BUF) c_int {
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
    buf.err = 0;
    const ret = heal.md_heal(@ptrCast(input), input_size, md4xHealBufAppend, buf);
    if (buf.err != 0) return -1;
    return ret;
}

fn healBufFree(buf: *MD4X_HEAL_BUF) void {
    if (buf.data) |d| {
        c_allocator.free(d[0..buf.cap]);
    }
}

// **************************************
// ***  Public API                    ***
// **************************************

pub fn md_ast(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int {
    var input_ptr = input;
    var size = input_size;

    // Heal-before-render: run md_heal first, then render the healed output.
    if (renderer_flags & MD_AST_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4xHealInput(input, input_size, &hbuf) != 0) {
            healBufFree(&hbuf);
            return -1;
        }
        const ret = md_ast(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_AST_FLAG_HEAL);
        healBufFree(&hbuf);
        return ret;
    }

    const parser: c.Parser = .{
        .flags = parser_flags,
        .enter_block = jsonEnterBlock,
        .leave_block = jsonLeaveBlock,
        .enter_span = jsonEnterSpan,
        .leave_span = jsonLeaveSpan,
        .text = jsonText,
        .debug_log = if (renderer_flags & MD_AST_FLAG_DEBUG != 0) jsonDebugLog else null,
    };

    var ctx: JsonCtx = .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator) };
    defer ctx.arena.deinit();
    ctx.alloc = ctx.arena.allocator();
    g_alloc = ctx.alloc;

    // Skip UTF-8 BOM.
    if (@sizeOf(c.MD_CHAR) == 1) {
        if (renderer_flags & MD_AST_FLAG_SKIP_UTF8_BOM != 0) {
            if (size >= 3 and @as(u8, @bitCast(input_ptr[0])) == 0xEF and
                @as(u8, @bitCast(input_ptr[1])) == 0xBB and @as(u8, @bitCast(input_ptr[2])) == 0xBF)
            {
                input_ptr += 3;
                size -= 3;
            }
        }
    }

    const ret = md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&ctx));

    if (ret != 0 or ctx.err != 0) {
        // Arena (via defer) frees the whole partial tree at once.
        return -1;
    }

    // Serialize the AST to JSON via the output callback.
    var writer: JsonWriter = undefined;
    writer.process_output = process_output;
    writer.userdata = userdata;
    if (ctx.root) |root| {
        jsonSerializeNode(&writer, root);
    }
    jsonWrite(&writer, "\n", 1);

    // Arena (via defer) frees the whole tree at once.
    return 0;
}
