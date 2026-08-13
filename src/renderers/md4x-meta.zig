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
// Zig port of src/renderers/md4x-meta.c — byte-for-byte identical behavior.

const std = @import("std");

// MD_* types now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); only genuinely
// external C headers stay in a @cImport, bound as `sys`.
const c = @import("abi");
// Sibling units are imported directly (one Zig module per artifact), not
// resolved through link-time C-ABI symbols. `abi` holds types only.
const md4x = @import("../md4x.zig");
const heal = @import("md4x-heal.zig");
// Heading text + GitHub-compatible slugging, shared with the AST renderer so
// the two never disagree about a heading's id.
const slug = @import("md4x-slug.zig");
const sys = @cImport({
    @cInclude("stdio.h");
});
const diag = @import("md4x-diag.zig");

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-meta.h). Heal flag value is shared (0x0100).
const MD_META_FLAG_DEBUG: c_uint = 0x0001;
const MD_META_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_META_FLAG_HEAL: c_uint = 0x0100;

// Non-optional — see the note on `md4x-json.zig`'s ProcessOutputFn.
const ProcessOutputFn = *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

// *****************************
// ***  Internal data types  ***
// *****************************

// `text` and `id` are arena slices; `id` is also a key in the slugger's
// occurrence table, so neither is freed individually.
const META_HEADING = struct {
    level: c_uint,
    text: []const u8,
    id: []const u8,
};

const META_CTX = struct {
    // Frontmatter raw text.
    fm_text: ?[*]u8 = null,
    fm_size: c.MD_SIZE = 0,
    fm_cap: c.MD_SIZE = 0,
    in_frontmatter: bool = false,

    // Heading list + the strings it points at. One arena for the lot: they all
    // live exactly as long as the render, and slugs are additionally referenced
    // by the slugger's hash table.
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator = undefined,
    headings: std.ArrayListUnmanaged(META_HEADING) = .empty,
    slugger: slug.Slugger = .{},

    // Current heading accumulator.
    in_heading: bool = false,
    heading_level: c_uint = 0,
    heading_text: slug.TextBuf = .empty,

    // Component nesting depth (to ignore component frontmatter).
    comp_depth: c_int = 0,

    err: c_int = 0,
};

// **********************************
// ***  Text accumulation helpers ***
// **********************************

// Mirrors the C realloc-based growable buffer. `buf` may be NULL initially
// (realloc(NULL, ...) == malloc). The current capacity is tracked separately so
// the Zig allocator can free/realloc the correct slice length.
fn meta_buf_append(
    buf: *?[*]u8,
    size: *c.MD_SIZE,
    cap: *c.MD_SIZE,
    text: [*]const u8,
    text_size: c.MD_SIZE,
) c_int {
    if (size.* + text_size > cap.*) {
        const new_cap: c.MD_SIZE = cap.* + cap.* / 2 + text_size + 64;
        if (buf.*) |old| {
            const p = c_allocator.realloc(old[0..cap.*], new_cap) catch return -1;
            buf.* = p.ptr;
        } else {
            const p = c_allocator.alloc(u8, new_cap) catch return -1;
            buf.* = p.ptr;
        }
        cap.* = new_cap;
    }
    @memcpy(buf.*.?[size.* .. size.* + text_size], text[0..text_size]);
    size.* += text_size;
    return 0;
}

// **********************************
// ***  md_parse() callbacks       ***
// **********************************

fn meta_enter_block(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *META_CTX = @ptrCast(@alignCast(userdata.?));

    switch (detail.*) {
        .component => ctx.comp_depth += 1,
        // Only capture document-level frontmatter, not component frontmatter.
        .frontmatter => if (ctx.comp_depth == 0) {
            ctx.in_frontmatter = true;
        },
        .h => |*d| {
            ctx.in_heading = true;
            ctx.heading_level = d.level;
            ctx.heading_text.clearRetainingCapacity();
        },
        else => {},
    }

    return 0;
}

fn meta_leave_block(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *META_CTX = @ptrCast(@alignCast(userdata.?));
    const block_type = std.meta.activeTag(detail.*);

    if (block_type == c.BlockType.component) {
        ctx.comp_depth -= 1;
    } else if (block_type == c.BlockType.frontmatter) {
        ctx.in_frontmatter = false;
    } else if (block_type == c.BlockType.h) {
        // Store the completed heading, with the GitHub-compatible id consumers
        // used to have to derive (and de-duplicate) themselves.
        ctx.in_heading = false;
        const store = struct {
            fn run(cx: *META_CTX) !void {
                const text = try cx.alloc.dupe(u8, cx.heading_text.items);
                const id = try cx.slugger.slug(cx.alloc, text);
                try cx.headings.append(cx.alloc, .{
                    .level = cx.heading_level,
                    .text = text,
                    .id = id,
                });
            }
        };
        store.run(ctx) catch {
            ctx.err = 1;
            return -1;
        };
    }

    return 0;
}

fn meta_enter_span(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    _ = detail;
    _ = userdata;
    return 0;
}

fn meta_leave_span(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    _ = detail;
    _ = userdata;
    return 0;
}

fn meta_text(text_type: c.TextType, text_slice: []const c.MD_CHAR, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *META_CTX = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = text_slice.ptr;
    const size: c.MD_SIZE = @intCast(text_slice.len);

    if (ctx.in_frontmatter) {
        if (meta_buf_append(&ctx.fm_text, &ctx.fm_size, &ctx.fm_cap, text, size) != 0) {
            ctx.err = 1;
            return -1;
        }
        return 0;
    }

    if (ctx.in_heading) {
        slug.appendText(&ctx.heading_text, ctx.alloc, text_type, text_slice) catch {
            ctx.err = 1;
            return -1;
        };
    }

    return 0;
}

fn meta_debug_log(msg: []const u8, userdata: ?*anyopaque) void {
    _ = userdata;
    diag.logMessage(msg);
}

// **************************************
// ***  JSON output                   ***
// **************************************
//
// The streaming JSON writer and the libyaml-backed YAML-to-JSON conversion live
// in the shared md4x-json.zig module (previously reimplemented inline here).
// Local aliases preserve the original call-site names used below. Note that the
// meta renderer's `json_write_str` historically took a NUL-terminated pointer,
// which maps to the shared module's `json_write_strz`.

const json = @import("md4x-json.zig");

const JSON_WRITER = json.JsonWriter;
const json_write = json.json_write;
const json_write_str = json.json_write_strz;
const json_write_string = json.json_write_string;
const json_write_yaml_props = json.json_write_yaml_props;

// Frontmatter lives under its own key rather than being spread across the top
// level beside `headings`.
//
// The flat shape silently DESTROYED data: a document whose frontmatter declared
// a `headings:` key had it overwritten by the parsed heading list, since both
// were emitted as siblings and the later one wins through JSON.parse. It also
// left no way to ask for "just the frontmatter" -- consumers parsing a plain
// YAML file through this renderer had to strip `headings` back off afterwards.
fn meta_serialize(w: *JSON_WRITER, ctx: *META_CTX) void {
    json_write_str(w, "{\"frontmatter\":{");
    if (ctx.fm_text != null and ctx.fm_size > 0) {
        _ = json_write_yaml_props(w, ctx.fm_text.?, ctx.fm_size);
    }

    json_write_str(w, "},\"headings\":[");
    for (ctx.headings.items, 0..) |h, i| {
        var buf: [16]u8 = undefined;

        if (i > 0) json_write(w, ",", 1);

        json_write_str(w, "{\"level\":");
        _ = sys.snprintf(&buf, buf.len, "%u", h.level);
        json_write_str(w, @ptrCast(&buf));

        json_write_str(w, ",\"text\":");
        json_write_string(w, h.text.ptr, @intCast(h.text.len));

        json_write_str(w, ",\"id\":");
        json_write_string(w, h.id.ptr, @intCast(h.id.len));

        json_write(w, "}", 1);
    }

    json_write_str(w, "]}\n");
}

fn meta_free(ctx: *META_CTX) void {
    if (ctx.fm_text) |p| c_allocator.free(p[0..ctx.fm_cap]);
    // Heading text, slugs and the slugger's table all live in the arena.
    ctx.arena.deinit();
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

fn md4x_heal_buf_append(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) void {
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

fn md4x_heal_input(input: [*c]const c.MD_CHAR, input_size: c.MD_SIZE, buf: *MD4X_HEAL_BUF) c_int {
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
    buf.err = 0;
    const ret = heal.md_heal(@ptrCast(input), input_size, md4x_heal_buf_append, buf);
    if (buf.err != 0) return -1;
    return ret;
}

fn heal_buf_free(buf: *MD4X_HEAL_BUF) void {
    if (buf.data) |d| c_allocator.free(d[0..buf.cap]);
}

// **************************************
// ***  Public API                    ***
// **************************************

pub fn md_meta(
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
    if (renderer_flags & MD_META_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_meta(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_META_FLAG_HEAL);
        heal_buf_free(&hbuf);
        return ret;
    }

    const parser: c.Parser = .{
        .flags = parser_flags,
        .enter_block = meta_enter_block,
        .leave_block = meta_leave_block,
        .enter_span = meta_enter_span,
        .leave_span = meta_leave_span,
        .text = meta_text,
        .debug_log = if (renderer_flags & MD_META_FLAG_DEBUG != 0) meta_debug_log else null,
    };

    var ctx: META_CTX = .{ .arena = std.heap.ArenaAllocator.init(c_allocator) };
    ctx.alloc = ctx.arena.allocator();

    // Skip UTF-8 BOM. (MD4X_USE_ASCII is never defined for this build.)
    if (renderer_flags & MD_META_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xEF, 0xBB, 0xBF };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    const ret = md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&ctx));

    if (ret != 0 or ctx.err != 0) {
        meta_free(&ctx);
        return -1;
    }

    // Serialize metadata to JSON via the output callback. The writer coalesces
    // its writes, so it must be built as a whole value (a field-by-field fill of
    // an `undefined` left `len` uninitialized) and flushed before returning.
    var writer: JSON_WRITER = .{ .process_output = process_output, .userdata = userdata };
    meta_serialize(&writer, &ctx);
    json.json_flush(&writer);

    meta_free(&ctx);
    return 0;
}
