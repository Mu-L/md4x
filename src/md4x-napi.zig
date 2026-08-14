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
// Zig port of src/md4x-napi.c — byte-for-byte identical behavior.

const std = @import("std");

// node_api.h stays a @cImport (external); the md4x ABI surface (MD_* types/
// flags + parser/renderer entry points) now comes from the Zig abi module.
const c = @cImport({
    @cInclude("node_api.h");
});
const abi = @import("abi");
// Parser + renderers live in this artifact's module graph (Phase 4a).
const lib = @import("lib.zig");

const c_allocator = std.heap.c_allocator;

// Growable output buffer
const napi_buf = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn napi_buf_append(text: [*c]const abi.MD_CHAR, size: abi.MD_SIZE, userdata: ?*anyopaque) void {
    const buf: *napi_buf = @ptrCast(@alignCast(userdata.?));
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

// The renderers take an MD_SIZE (u32) length. V8 caps strings well below that,
// so this never fires today, but the alternative to checking is an out-of-range
// `@intCast(input_size)` -- a panic in a safe build and illegal behavior in the
// shipping ReleaseFast addon. Throws and returns true when the input is refused.
fn napi_reject_oversized_input(env: c.napi_env, input_size: usize) bool {
    if (input_size <= std.math.maxInt(abi.MD_SIZE)) return false;
    _ = c.napi_throw_error(env, null, "Input too large");
    return true;
}

// Generic renderer wrapper
const md4x_render_fn = *const fn (
    [*c]const abi.MD_CHAR,
    abi.MD_SIZE,
    *const fn ([*c]const abi.MD_CHAR, abi.MD_SIZE, ?*anyopaque) void,
    ?*anyopaque,
    c_uint,
    c_uint,
) c_int;

fn render_impl(env: c.napi_env, info: c.napi_callback_info, fn_ptr: md4x_render_fn) c.napi_value {
    var argc: usize = 2;
    var argv: [2]c.napi_value = undefined;
    var renderer_flags: c_uint = 0;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    // Get input string length, then read
    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    if (napi_reject_oversized_input(env, input_size)) return null;
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    // Get optional renderer flags (second arg)
    if (argc >= 2) {
        var flags: u32 = undefined;
        if (c.napi_get_value_uint32(env, argv[1], &flags) == c.napi_ok) {
            renderer_flags = flags;
        }
    }

    // Render with all extensions enabled
    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = fn_ptr(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf, abi.MD_DIALECT_ALL, renderer_flags);
    std.c.free(input);

    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown parsing failed");
        return null;
    }

    var result: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, if (buf.data) |d| @ptrCast(d) else "", buf.size, &result);
    std.c.free(buf.data);
    return result;
}

// --- Exported functions ---

// --- Syntax highlighting hook ---
//
// `renderToHtml` / `renderToAnsi` take an optional third argument: a function
// called once per fenced or indented code block, synchronously, from inside the
// render (see src/renderers/md4x-highlight.zig). It gets `(code, block)` and
// returns the replacement output, or undefined to keep the default rendering.
//
// The call happens with the renderer mid-block, so it must never unwind through
// it: a JS exception leaves a pending exception on the env instead, `failed`
// latches, and every remaining block silently keeps its default rendering. The
// wrapper hands the exception back to Node once the render has returned and its
// buffers are freed -- unwinding out of the callback would leak them.
const NapiHighlighter = struct {
    env: c.napi_env,
    callback: c.napi_value,
    recv: c.napi_value,
    failed: bool = false,
    // Reply staging. The renderer copies the bytes out before it calls
    // `release`, so one buffer can serve every block: `scratch` takes the
    // common case with no allocation at all, and `owned` is the heap fallback
    // for a reply that does not fit.
    //
    // `napi_get_value_string_utf8` is called ONCE per reply. The documented
    // two-call idiom (NULL to measure, then to copy) walks the string twice --
    // and V8 has to flatten a highlighter's freshly concatenated output before
    // either walk. Sizing optimistically instead means the second call only
    // happens for replies over SCRATCH bytes.
    scratch: [16 * 1024]u8 = undefined,
    owned: ?[]u8 = null,

    fn fail(self: *NapiHighlighter) ?[]const u8 {
        self.failed = true;
        return null;
    }
};

fn napi_set_str(env: c.napi_env, obj: c.napi_value, comptime name: [:0]const u8, value: []const u8) bool {
    var val: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, if (value.len > 0) @ptrCast(value.ptr) else "", value.len, &val) != c.napi_ok)
        return false;
    return c.napi_set_named_property(env, obj, name.ptr, val) == c.napi_ok;
}

fn napi_highlight(ctx: ?*anyopaque, req: *const lib.highlight.Request) ?[]const u8 {
    const h: *NapiHighlighter = @ptrCast(@alignCast(ctx.?));
    if (h.failed) return null;
    const env = h.env;

    var code_val: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, if (req.code.len > 0) @ptrCast(req.code.ptr) else "", req.code.len, &code_val) != c.napi_ok)
        return h.fail();

    // The block descriptor. `lang` is always present (empty string for a fence
    // with no info string); the rest only when the document carries them, so
    // `"filename" in block` keeps meaning something.
    var block: c.napi_value = undefined;
    if (c.napi_create_object(env, &block) != c.napi_ok) return h.fail();
    if (!napi_set_str(env, block, "lang", req.lang)) return h.fail();
    if (req.filename.len > 0 and !napi_set_str(env, block, "filename", req.filename)) return h.fail();
    if (req.prefix.len > 0 and !napi_set_str(env, block, "prefix", req.prefix)) return h.fail();
    if (req.highlights.len > 0) {
        var arr: c.napi_value = undefined;
        if (c.napi_create_array_with_length(env, req.highlights.len, &arr) != c.napi_ok) return h.fail();
        for (req.highlights, 0..) |line, i| {
            var num: c.napi_value = undefined;
            if (c.napi_create_uint32(env, line, &num) != c.napi_ok) return h.fail();
            if (c.napi_set_element(env, arr, @intCast(i), num) != c.napi_ok) return h.fail();
        }
        if (c.napi_set_named_property(env, block, "highlights", arr) != c.napi_ok) return h.fail();
    }

    var argv = [_]c.napi_value{ code_val, block };
    var result: c.napi_value = undefined;
    if (c.napi_call_function(env, h.recv, h.callback, argv.len, &argv, &result) != c.napi_ok)
        return h.fail();

    var vtype: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, result, &vtype) != c.napi_ok) return h.fail();
    if (vtype == c.napi_undefined or vtype == c.napi_null) return null;
    if (vtype != c.napi_string) {
        // A Promise lands here: highlighting runs inside the render, so it
        // cannot be awaited. Say so rather than emitting "[object Promise]".
        _ = c.napi_throw_type_error(env, null, "md4x: highlighter must return a string or undefined (it runs synchronously)");
        return h.fail();
    }

    var len: usize = undefined;
    if (c.napi_get_value_string_utf8(env, result, &h.scratch, h.scratch.len, &len) != c.napi_ok)
        return h.fail();
    // A reply that exactly fills the scratch buffer is indistinguishable from
    // one that was truncated to fit, so both take the measure-then-copy path.
    if (len < h.scratch.len - 1)
        return h.scratch[0..len];

    if (c.napi_get_value_string_utf8(env, result, null, 0, &len) != c.napi_ok) return h.fail();
    const buf = c_allocator.alloc(u8, len + 1) catch {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return h.fail();
    };
    if (c.napi_get_value_string_utf8(env, result, buf.ptr, len + 1, &len) != c.napi_ok) {
        c_allocator.free(buf);
        return h.fail();
    }
    h.owned = buf;
    return buf[0..len];
}

fn napi_highlight_release(ctx: ?*anyopaque, text: []const u8) void {
    _ = text;
    const h: *NapiHighlighter = @ptrCast(@alignCast(ctx.?));
    if (h.owned) |buf| {
        c_allocator.free(buf);
        h.owned = null;
    }
}

// --- Renderers that accept a highlighter ---

const RenderKind = enum { html, ansi };

fn render_highlightable(env: c.napi_env, info: c.napi_callback_info, comptime kind: RenderKind) c.napi_value {
    var argc: usize = 3;
    var argv: [3]c.napi_value = undefined;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    if (napi_reject_oversized_input(env, input_size)) return null;
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    var renderer_flags: c_uint = 0;
    if (argc >= 2) {
        var flags: u32 = undefined;
        if (c.napi_get_value_uint32(env, argv[1], &flags) == c.napi_ok)
            renderer_flags = flags;
    }

    var hl_state: NapiHighlighter = undefined;
    var highlighter: lib.highlight.Highlighter = undefined;
    var has_highlighter = false;
    if (argc >= 3) {
        var vtype: c.napi_valuetype = undefined;
        if (c.napi_typeof(env, argv[2], &vtype) == c.napi_ok and vtype == c.napi_function) {
            var recv: c.napi_value = undefined;
            _ = c.napi_get_undefined(env, &recv);
            hl_state = .{ .env = env, .callback = argv[2], .recv = recv };
            highlighter = .{ .ctx = &hl_state, .highlight = napi_highlight, .release = napi_highlight_release };
            has_highlighter = true;
        }
    }
    const hook: ?*const lib.highlight.Highlighter = if (has_highlighter) &highlighter else null;

    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = switch (kind) {
        .html => blk: {
            const opts: lib.MD_HTML_OPTS = .{ .highlighter = hook };
            break :blk lib.md_html_ex(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf, abi.MD_DIALECT_ALL, renderer_flags, &opts);
        },
        .ansi => blk: {
            const opts: lib.MD_ANSI_OPTS = .{ .highlighter = hook };
            break :blk lib.md_ansi_ex(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf, abi.MD_DIALECT_ALL, renderer_flags, &opts);
        },
    };
    std.c.free(input);

    // The highlighter's exception is already pending on the env; returning null
    // rethrows it in JS, and throwing our own on top would replace it. Only if
    // nothing is pending (a napi call that failed without throwing) does this
    // need an error of its own -- returning null with no exception would hand
    // the caller `undefined` instead of a failure.
    if (has_highlighter and hl_state.failed) {
        std.c.free(buf.data);
        var pending: bool = false;
        _ = c.napi_is_exception_pending(env, &pending);
        if (!pending)
            _ = c.napi_throw_error(env, null, "md4x: highlighter failed");
        return null;
    }

    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown parsing failed");
        return null;
    }

    var result: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, if (buf.data) |d| @ptrCast(d) else "", buf.size, &result);
    std.c.free(buf.data);
    return result;
}

fn md4x_napi_to_html(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_highlightable(env, info, .html);
}

fn md4x_napi_to_ansi(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_highlightable(env, info, .ansi);
}

fn md4x_napi_to_ast(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, lib.md_ast);
}

fn md4x_napi_to_meta(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, lib.md_meta);
}

fn md4x_napi_to_text(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, lib.md_text);
}

fn md4x_napi_to_markdown(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, lib.md_markdown);
}

fn md4x_napi_yaml_to_json(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, lib.md_yaml);
}

fn md4x_napi_heal(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    if (napi_reject_oversized_input(env, input_size)) return null;
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = lib.md_heal(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf);
    std.c.free(input);

    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown heal failed");
        return null;
    }

    var result: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, if (buf.data) |d| @ptrCast(d) else "", buf.size, &result);
    std.c.free(buf.data);
    return result;
}

// --- Module initialization ---

fn descriptor(name: [*c]const u8, method: c.napi_callback) c.napi_property_descriptor {
    return .{
        .utf8name = name,
        .name = null,
        .method = method,
        .getter = null,
        .setter = null,
        .value = null,
        .attributes = c.napi_default,
        .data = null,
    };
}

fn init(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    const props = [_]c.napi_property_descriptor{
        descriptor("renderToHtml", md4x_napi_to_html),
        descriptor("renderToAST", md4x_napi_to_ast),
        descriptor("renderToAnsi", md4x_napi_to_ansi),
        descriptor("renderToMeta", md4x_napi_to_meta),
        descriptor("renderToText", md4x_napi_to_text),
        descriptor("renderToMarkdown", md4x_napi_to_markdown),
        descriptor("yamlToJson", md4x_napi_yaml_to_json),
        descriptor("heal", md4x_napi_heal),
    };
    _ = c.napi_define_properties(env, exports, props.len, &props);
    return exports;
}

// Symbol-based module registration (expansion of the NAPI_MODULE / NAPI_MODULE_INIT
// macros for a non-wasm target with NAPI_VERSION 8):
//   - node_api_module_get_api_version_v1 returns NAPI_VERSION
//   - napi_register_module_v1 invokes the init function

export fn node_api_module_get_api_version_v1() callconv(.c) i32 {
    return c.NAPI_VERSION;
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    return init(env, exports);
}
