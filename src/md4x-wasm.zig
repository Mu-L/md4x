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
// Zig port of src/md4x-wasm.c — byte-for-byte identical behavior.

const std = @import("std");

// The md4x ABI surface (MD_* types/flags, parser + renderer entry points,
// entity) now lives in the Zig-native abi module; libc comes from std.c.
const c = @import("abi");
// Parser + renderers live in this artifact's module graph (Phase 4a).
const lib = @import("lib.zig");
const diag = @import("renderers/md4x-diag.zig");

// Panic handler for the safety-checked wasm builds (`zig build wasm-safe`,
// `-Doptimize=Debug`). ReleaseFast has no live panic path, but as soon as the
// safety checks are on, std's default handler is reachable, and it reports
// through `std.debug`'s stderr writer + stack-trace machinery, which pulls ~25
// extra WASI imports (`clock_res_get`, `path_open`, `fd_prestat_get`, …) into
// the module. `packages/md4x/lib/wasm/common.mjs` stubs only the six the
// ReleaseFast build needs, so the safe binary would fail to instantiate with a
// `LinkError` instead of being the debugging aid it exists to be — the same
// hazard documented in `renderers/md4x-diag.zig`.
//
// So: report the message through the renderers' libc-stdio stderr (fd 2, i.e.
// `fd_write`, which the loader already provides) and `@trap()`. In JS the trap
// surfaces as a `RuntimeError: unreachable`; `wasm-safe` is built unstripped,
// so its stack frames carry Zig function names.
fn wasmPanic(msg: []const u8, _: ?usize) noreturn {
    diag.logMessage(msg);
    @trap();
}
pub const panic = std.debug.FullPanic(wasmPanic);

// We manage the result/output buffer memory with libc malloc/realloc/free so
// that the JS-side md4x_free(md4x_result_ptr()) (which frees the result buffer)
// is compatible. This mirrors the original C code exactly, including the
// realloc(NULL, n) / realloc(p, n) growth semantics.

// Stub main for wasi libc (we are a library, not a program)
export fn main() callconv(.c) c_int {
    return 0;
}

// Result storage (global — WASM is single-threaded)
var g_result_data: ?[*]u8 = null;
var g_result_size: c_uint = 0;

// Growable output buffer
const md4x_buf = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn buf_append(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) void {
    const buf: *md4x_buf = @ptrCast(@alignCast(userdata.?));
    if (buf.err != 0) return;
    if (buf.size + size > buf.cap) {
        const new_cap: c_uint = buf.cap + buf.cap / 2 + size + 256;
        const p: ?*anyopaque = std.c.realloc(buf.data, new_cap);
        if (p == null) {
            buf.err = 1;
            return;
        }
        buf.data = @ptrCast(p);
        buf.cap = new_cap;
    }
    if (size > 0) {
        @memcpy(buf.data.?[buf.size .. buf.size + size], @as([*]const u8, @ptrCast(text))[0..size]);
    }
    buf.size += size;
}

// --- Memory management exports ---

export fn md4x_alloc(size: c_uint) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

export fn md4x_free(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

// --- Result accessors ---

export fn md4x_result_ptr() callconv(.c) c_uint {
    return @intCast(@intFromPtr(g_result_data));
}

export fn md4x_result_size() callconv(.c) c_uint {
    return g_result_size;
}

// --- Syntax highlighting hook ---
//
// `md4x_to_html_hl` / `md4x_to_ansi_hl` render with a highlighter installed (see
// src/renderers/md4x-highlight.zig): the renderer stops at every fenced or
// indented code block and asks the host what to emit for it. The host is JS, so
// the call leaves the module through an import — the module therefore does not
// instantiate without it, and `packages/md4x/lib/wasm/common.mjs` supplies it
// unconditionally, highlighting or not.
//
// Every argument is a linear-memory address plus a length, so nothing crosses
// the boundary but integers. The reply is one address:
//
//   0 — decline; the renderer emits its own default rendering for the block.
//   p — a buffer holding a u32 little-endian byte length followed by that many
//       UTF-8 bytes. It stays JS-owned: the renderer copies the bytes out
//       immediately, so the loader reuses one buffer for every block instead of
//       allocating and freeing per code block, and `release` is a no-op.
//
// Length-prefixing is what keeps this to a single import call: a wasm function
// returns one value, and returning an i64 pair would drag BigInt conversion
// into the hot path.
extern "env" fn md4x_highlight(
    code_ptr: u32,
    code_len: u32,
    lang_ptr: u32,
    lang_len: u32,
    filename_ptr: u32,
    filename_len: u32,
    highlights_ptr: u32,
    highlights_len: u32,
    prefix_ptr: u32,
    prefix_len: u32,
) u32;

fn js_highlight(ctx: ?*anyopaque, req: *const lib.highlight.Request) ?[]const u8 {
    _ = ctx;
    const ret = md4x_highlight(
        @intCast(@intFromPtr(req.code.ptr)),
        @intCast(req.code.len),
        @intCast(@intFromPtr(req.lang.ptr)),
        @intCast(req.lang.len),
        @intCast(@intFromPtr(req.filename.ptr)),
        @intCast(req.filename.len),
        @intCast(@intFromPtr(req.highlights.ptr)),
        @intCast(req.highlights.len),
        @intCast(@intFromPtr(req.prefix.ptr)),
        @intCast(req.prefix.len),
    );
    if (ret == 0) return null;
    const base: [*]const u8 = @ptrFromInt(ret);
    const len = std.mem.readInt(u32, base[0..4], .little);
    return base[4..][0..len];
}

fn js_highlight_release(ctx: ?*anyopaque, text: []const u8) void {
    _ = ctx;
    _ = text;
    // The reply buffer belongs to the JS loader, which reuses it — see above.
}

const js_highlighter: lib.highlight.Highlighter = .{
    .highlight = js_highlight,
    .release = js_highlight_release,
};

// --- Renderer wrappers ---

const md4x_render_fn = *const fn (
    [*c]const c.MD_CHAR,
    c.MD_SIZE,
    *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void,
    ?*anyopaque,
    c_uint,
) c_int;

fn render(fn_ptr: md4x_render_fn, input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = fn_ptr(input, input_size, buf_append, &buf, renderer_flags);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    // Caller (JS) frees previous g_result_data via md4x_free(md4x_result_ptr()).
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}

export fn md4x_to_html(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_html, input, input_size, renderer_flags);
}

export fn md4x_to_html_hl(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const opts: lib.MD_HTML_OPTS = .{ .highlighter = &js_highlighter };
    const ret = lib.md_html_ex(input, input_size, buf_append, &buf, renderer_flags, &opts);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}

export fn md4x_to_ast(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_ast, input, input_size, renderer_flags);
}

export fn md4x_to_ansi(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_ansi, input, input_size, renderer_flags);
}

export fn md4x_to_ansi_hl(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const opts: lib.MD_ANSI_OPTS = .{ .highlighter = &js_highlighter };
    const ret = lib.md_ansi_ex(input, input_size, buf_append, &buf, renderer_flags, &opts);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}

export fn md4x_to_meta(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_meta, input, input_size, renderer_flags);
}

export fn md4x_to_text(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_text, input, input_size, renderer_flags);
}

export fn md4x_to_markdown(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_markdown, input, input_size, renderer_flags);
}

export fn md4x_yaml_to_json(input: [*c]const u8, input_size: c_uint) callconv(.c) c_int {
    return render(lib.md_yaml, input, input_size, 0);
}

export fn md4x_heal(input: [*c]const u8, input_size: c_uint) callconv(.c) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = lib.md_heal(input, input_size, buf_append, &buf);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    // Caller (JS) frees previous g_result_data via md4x_free(md4x_result_ptr()).
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}
