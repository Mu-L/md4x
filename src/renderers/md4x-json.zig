// SPDX-License-Identifier: MIT
//
// Shared JSON writer + YAML-to-JSON helpers for the md4x renderers.
//
// This is the Zig counterpart of the (orphaned) header-only md4x-json.h. The C
// header's helpers are `static`, so @cImport translates them as unresolved
// external references (which the WASM linker cannot satisfy). The streaming JSON
// writer and the libyaml-backed YAML-to-JSON conversion are therefore ported to
// Zig here and shared by the AST and meta renderers. Behavior is kept
// byte-for-byte identical to the C source, including YAML 1.1 type coercion.
//
// Imported (not @cImport'd into a clashing symbol) by each renderer lib: Zig
// compiles its own internal copy per importing artifact, so there is no
// exported-symbol collision and no build.zig change is required.

const std = @import("std");
const scan = @import("../scan.zig");

// MD_* types now come from the Zig-native abi module (replacing md4x.h);
// genuinely external C headers (if any) stay in a @cImport bound as `sys`.
const c = @import("abi");
// stdio.h is gone with the last `snprintf` (the `\u00xx` escape is open-coded
// below); only libyaml is genuinely external now.
const sys = @cImport({
    @cInclude("yaml.h");
});

// Non-optional, like the five required SAX callbacks: every sink here is called
// unconditionally, so a null one was a null-function-pointer call (a panic in
// Debug/ReleaseSafe, UB in the shipping ReleaseFast). Making it non-optional
// turns "forgot the sink" into a compile error instead. `md_heal` already took
// a non-optional `*const fn`; this is the rest of the subsystem catching up.
pub const ProcessOutputFn = *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

// Streaming JSON writer (mirrors the C JSON_WRITER struct).
//
// Writes are COALESCED through `buf` rather than handed to `process_output` one
// at a time. JSON is punctuation-dense — the AST serializer spends most of its
// calls on a single `,`, `"`, `[` or `{` — and every one of those used to cost
// an indirect call into the sink plus, in each of the three sinks, a capacity
// check and a `memcpy` of one or two bytes. Over a 1 MB document that was
// ~13% of the render in the CLI's `ArrayList.appendSlice` sink alone, before
// counting the `memcpy` calls it made.
//
// The sink is only reached once per full buffer (or once per large string, see
// below), so it sees a handful of big appends instead of ~90 000 tiny ones.
//
// **Every entry point that builds a JsonWriter must `json_flush` it before
// returning**, or the tail of the document is silently dropped. There is no
// deinit to hang it off — the struct is a plain value with no allocation.
pub const JsonWriter = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    buf: [8192]u8 = undefined,
    len: usize = 0,
};

// Strings at least this long skip the buffer and go straight to the sink: the
// copy into `buf` would cost as much as the sink's own copy, and a long run of
// them (a big code block, a raw HTML block) would otherwise flush every time.
const passthrough_threshold: usize = 1024;

pub fn json_flush(w: *JsonWriter) void {
    if (w.len > 0) {
        w.process_output(@ptrCast(&w.buf), @intCast(w.len), w.userdata);
        w.len = 0;
    }
}

pub fn json_write(w: *JsonWriter, data: [*]const u8, size: c.MD_SIZE) void {
    const n: usize = size;
    if (n >= passthrough_threshold) {
        // Ordering matters: whatever is buffered precedes this string.
        json_flush(w);
        w.process_output(@ptrCast(data), size, w.userdata);
        return;
    }
    if (w.len + n > w.buf.len)
        json_flush(w);
    @memcpy(w.buf[w.len..][0..n], data[0..n]);
    w.len += n;
}

// Write a sentinel-terminated string slice (length known at the type level).
pub fn json_write_str(w: *JsonWriter, str: [:0]const u8) void {
    json_write(w, str.ptr, @intCast(str.len));
}

// Write a NUL-terminated string pointer (length computed via strlen).
pub fn json_write_strz(w: *JsonWriter, str: [*:0]const u8) void {
    json_write(w, str, @intCast(std.mem.len(str)));
}

// Find the next offset >= `start` needing a JSON escape — `"`, `\`, or any
// control character below 0x20 — or `size` if there is none. Exactly the set
// the switch below produces a `replacement` for; everything else is copied
// through verbatim in one run.
fn next_json_esc(str: [*]const u8, start: c.MD_OFFSET, size: c.MD_SIZE) c.MD_OFFSET {
    return @intCast(scan.indexOfAnyPos("\"\\", 0x20, str, start, size));
}

pub fn json_write_escaped(w: *JsonWriter, str: [*]const u8, size: c.MD_SIZE) void {
    var i: c.MD_OFFSET = 0;
    var beg: c.MD_OFFSET = 0;
    var esc: [8]u8 = undefined;

    // Skipping to the next escape rather than testing every byte is the single
    // biggest win in the AST renderer: this function was ~18% of a `--format=json`
    // render, and nearly every byte of a document needs no escaping at all.
    while (true) {
        i = next_json_esc(str, i, size);
        if (i >= size) break;
        const ch: u8 = str[i];
        var replacement: ?[*]const u8 = null;
        var esc_len: c_int = 0;

        switch (ch) {
            '"' => replacement = "\\\"",
            '\\' => replacement = "\\\\",
            0x08 => replacement = "\\b",
            0x0C => replacement = "\\f",
            '\n' => replacement = "\\n",
            '\r' => replacement = "\\r",
            '\t' => replacement = "\\t",
            else => {
                if (ch < 0x20) {
                    // `snprintf("\\u%04x")` open-coded: the value is always a
                    // single byte, so the two low nibbles are the whole number
                    // and the high two digits are constant.
                    const hex = "0123456789abcdef";
                    esc[0] = '\\';
                    esc[1] = 'u';
                    esc[2] = '0';
                    esc[3] = '0';
                    esc[4] = hex[ch >> 4];
                    esc[5] = hex[ch & 0x0f];
                    replacement = &esc;
                    esc_len = 6;
                }
            },
        }

        if (replacement) |rep| {
            if (i > beg)
                json_write(w, str + beg, i - beg);
            if (esc_len == 0)
                esc_len = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(rep))));
            json_write(w, rep, @intCast(esc_len));
            beg = i + 1;
        }
        i += 1;
    }

    if (i > beg)
        json_write(w, str + beg, i - beg);
}

pub fn json_write_string(w: *JsonWriter, str: [*]const u8, size: c.MD_SIZE) void {
    json_write(w, "\"", 1);
    json_write_escaped(w, str, size);
    json_write(w, "\"", 1);
}

// ---- YAML-to-JSON (md4x-json.h: json_write_yaml_*) ----

// Helper: check if a string matches a literal (case-insensitive, known length).
fn yaml_streq_ci(s: [*]const u8, len: c.MD_SIZE, lit: []const u8) bool {
    if (len != lit.len)
        return false;
    var i: c.MD_SIZE = 0;
    while (i < len) : (i += 1) {
        var ch = s[i];
        if (ch >= 'A' and ch <= 'Z')
            ch += 32;
        if (ch != lit[i])
            return false;
    }
    return true;
}

// Helper: check if a value string looks like a JSON number.
fn yaml_is_number(s: [*]const u8, len: c.MD_SIZE) bool {
    var i: c.MD_SIZE = 0;
    var has_digit = false;
    var has_dot = false;

    if (len == 0)
        return false;

    // Optional leading sign.
    if (s[0] == '-' or s[0] == '+') {
        i += 1;
        if (i >= len)
            return false;
    }

    while (i < len) : (i += 1) {
        if (s[i] >= '0' and s[i] <= '9') {
            has_digit = true;
        } else if (s[i] == '.' and !has_dot) {
            has_dot = true;
        } else {
            return false;
        }
    }
    return has_digit;
}

// Write a YAML scalar as a typed JSON value (YAML 1.1 resolution for plain scalars).
fn json_write_yaml_scalar(w: *JsonWriter, event: *const sys.yaml_event_t) void {
    const val: [*]const u8 = @ptrCast(event.data.scalar.value);
    const len: c.MD_SIZE = @intCast(event.data.scalar.length);
    const style = event.data.scalar.style;

    // Quoted scalars are always strings.
    if (style == sys.YAML_SINGLE_QUOTED_SCALAR_STYLE or style == sys.YAML_DOUBLE_QUOTED_SCALAR_STYLE) {
        json_write_string(w, val, len);
        return;
    }

    // Plain scalars: apply type coercion.
    if (len == 0) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "null") or (len == 1 and val[0] == '~')) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "true") or yaml_streq_ci(val, len, "yes") or yaml_streq_ci(val, len, "on")) {
        json_write_str(w, "true");
        return;
    }
    if (yaml_streq_ci(val, len, "false") or yaml_streq_ci(val, len, "no") or yaml_streq_ci(val, len, "off")) {
        json_write_str(w, "false");
        return;
    }
    if (yaml_is_number(val, len)) {
        json_write(w, val, len);
        return;
    }

    // Default: string (also covers literal/folded block scalars).
    json_write_string(w, val, len);
}

// ---- Malformed-YAML contract ----
//
// `JsonWriter` streams straight through `process_output`: bytes handed to the
// sink cannot be retracted, and libyaml reports a syntax error only once it has
// already emitted the events preceding it. So a mid-mapping error is repaired
// *forward*, never rolled back. Every function below upholds one invariant:
//
//   **on return — success or error — the JSON it emitted is balanced.**
//
// Concretely: a container it opened is always closed, and a position that
// syntactically demands a value always receives one (`null` when nothing could
// be parsed). What is kept is therefore the prefix libyaml did parse, plus an
// explicit `null` for the key whose value it did not. Dropping the failing key
// instead would make a truncated document indistinguishable from one where the
// author simply omitted the field.

// Write a YAML mapping as JSON object key-value pairs (without outer braces).
// Assumes MAPPING_START consumed. Returns 0 on success, -1 on error; `n_written`
// is incremented once per pair actually emitted (including a pair whose value
// had to be repaired to `null`, since its key bytes are already on the wire).
fn json_write_yaml_mapping(w: *JsonWriter, yp: *sys.yaml_parser_t, n_written: *c_int) c_int {
    var event: sys.yaml_event_t = undefined;

    while (true) {
        if (sys.yaml_parser_parse(yp, &event) == 0)
            return -1;

        if (event.type == sys.YAML_MAPPING_END_EVENT) {
            sys.yaml_event_delete(&event);
            break;
        }

        if (event.type != sys.YAML_SCALAR_EVENT) {
            // A non-scalar key (a complex `? key` mapping, or a stray
            // structural event). No byte of this pair has been written yet —
            // not even the separating comma — so stopping here already leaves
            // the object well-formed.
            sys.yaml_event_delete(&event);
            return -1;
        }

        if (n_written.* > 0)
            json_write(w, ",", 1);

        // Write key.
        json_write(w, "\"", 1);
        json_write_escaped(w, @ptrCast(event.data.scalar.value), @intCast(event.data.scalar.length));
        json_write_str(w, "\":");
        sys.yaml_event_delete(&event);

        // Write value (recursive). Past this point the key is committed, so the
        // pair counts as written whatever happens: `json_write_yaml_value`
        // guarantees it emitted *some* value at this position.
        const ret = json_write_yaml_value(w, yp);
        n_written.* += 1;
        if (ret < 0)
            return -1;
    }
    return 0;
}

// Write a YAML sequence as a JSON array.
// Assumes SEQUENCE_START consumed. Returns 0 on success, -1 on error.
fn json_write_yaml_sequence(w: *JsonWriter, yp: *sys.yaml_parser_t) c_int {
    var event: sys.yaml_event_t = undefined;
    var n: c_int = 0;
    var ret: c_int = 0;

    json_write(w, "[", 1);

    while (true) {
        if (sys.yaml_parser_parse(yp, &event) == 0) {
            // Nothing is pending here: the comma is written only after an event
            // has been parsed successfully, so the array closes cleanly on the
            // elements seen so far.
            ret = -1;
            break;
        }

        if (event.type == sys.YAML_SEQUENCE_END_EVENT) {
            sys.yaml_event_delete(&event);
            break;
        }

        if (n > 0)
            json_write(w, ",", 1);

        if (json_write_yaml_event(w, yp, &event) < 0) {
            ret = -1;
            break;
        }

        n += 1;
    }

    json_write(w, "]", 1);
    return ret;
}

// Write the value denoted by an already-parsed `event` as JSON. Takes ownership
// of `event` and deletes it. Returns 0 on success, -1 on error; the output is
// balanced either way (see the malformed-YAML contract above).
fn json_write_yaml_event(w: *JsonWriter, yp: *sys.yaml_parser_t, event: *sys.yaml_event_t) c_int {
    if (event.type == sys.YAML_SCALAR_EVENT) {
        json_write_yaml_scalar(w, event);
        sys.yaml_event_delete(event);
        return 0;
    }
    if (event.type == sys.YAML_MAPPING_START_EVENT) {
        sys.yaml_event_delete(event);
        json_write(w, "{", 1);
        var n: c_int = 0;
        const ret = json_write_yaml_mapping(w, yp, &n);
        json_write(w, "}", 1);
        return ret;
    }
    if (event.type == sys.YAML_SEQUENCE_START_EVENT) {
        sys.yaml_event_delete(event);
        return json_write_yaml_sequence(w, yp);
    }
    if (event.type == sys.YAML_ALIAS_EVENT) {
        // libyaml's parser does not compose, so anchors are never resolved; an
        // alias is a defined `null` rather than an error.
        sys.yaml_event_delete(event);
        json_write_str(w, "null");
        return 0;
    }

    // Anything else is a structural event where a value was expected. The
    // position still needs one.
    sys.yaml_event_delete(event);
    json_write_str(w, "null");
    return -1;
}

// Write the next YAML value (scalar, mapping, or sequence) as JSON.
// Returns 0 on success, -1 on error; a value is always emitted.
fn json_write_yaml_value(w: *JsonWriter, yp: *sys.yaml_parser_t) c_int {
    var event: sys.yaml_event_t = undefined;

    if (sys.yaml_parser_parse(yp, &event) == 0) {
        json_write_str(w, "null");
        return -1;
    }

    return json_write_yaml_event(w, yp, &event);
}

// Write parsed YAML frontmatter as JSON props using libyaml.
// Returns the number of top-level props actually written to the output. A
// malformed document still reports what it emitted (never 0 after writing
// bytes) — callers use the count to decide whether a separating comma is
// needed before whatever they append next.
pub fn json_write_yaml_props(w: *JsonWriter, text: [*]const u8, size: c.MD_SIZE) c_int {
    var yp: sys.yaml_parser_t = undefined;
    var event: sys.yaml_event_t = undefined;
    var n_written: c_int = 0;

    if (sys.yaml_parser_initialize(&yp) == 0)
        return 0;

    sys.yaml_parser_set_input_string(&yp, @ptrCast(text), size);

    // Consume STREAM_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != sys.YAML_STREAM_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    sys.yaml_event_delete(&event);

    // Consume DOCUMENT_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != sys.YAML_DOCUMENT_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    sys.yaml_event_delete(&event);

    // Expect top-level MAPPING_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != sys.YAML_MAPPING_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    sys.yaml_event_delete(&event);

    // A mid-mapping error is already repaired in the output stream, so the
    // status is not actionable here; `n_written` is what matters.
    _ = json_write_yaml_mapping(w, &yp, &n_written);

    sys.yaml_parser_delete(&yp);
    return n_written;
}

// ---- Standalone YAML entry point ----

/// Convert a YAML document to JSON.
///
/// libyaml is already linked for frontmatter, and consumers had no way to reach
/// it: parsing a plain `.yml` file meant wrapping it in `---` fences, running it
/// through the *markdown* meta renderer, and stripping the heading list back off
/// the result.
///
/// Unlike `json_write_yaml_props`, this accepts any root node — a sequence or a
/// bare scalar as readily as a mapping — and a stream with no document at all
/// converts to `null`, YAML's own reading of an empty file. It takes the
/// renderer signature (both trailing flag words unused) so it drops straight
/// into the existing wasm/napi wrappers.
pub fn md_yaml(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int {
    _ = parser_flags;
    _ = renderer_flags;

    var w: JsonWriter = .{ .process_output = process_output, .userdata = userdata };
    var yp: sys.yaml_parser_t = undefined;
    var event: sys.yaml_event_t = undefined;

    if (sys.yaml_parser_initialize(&yp) == 0)
        return -1;
    defer sys.yaml_parser_delete(&yp);
    // Every `return` below is a success path that has already written output.
    defer json_flush(&w);

    sys.yaml_parser_set_input_string(&yp, @ptrCast(input), input_size);

    // Walk to the root node of the first document. Anything other than the
    // expected event -- including a syntax error and including a stream that
    // ends immediately -- means there is no value to convert.
    for ([_]c_uint{ sys.YAML_STREAM_START_EVENT, sys.YAML_DOCUMENT_START_EVENT }) |expected| {
        if (sys.yaml_parser_parse(&yp, &event) == 0) {
            json_write_str(&w, "null\n");
            return 0;
        }
        const actual = event.type;
        sys.yaml_event_delete(&event);
        if (actual != expected) {
            json_write_str(&w, "null\n");
            return 0;
        }
    }

    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        json_write_str(&w, "null\n");
        return 0;
    }
    // Emits a balanced value whatever the outcome (see the malformed-YAML
    // contract above), so a truncated document still yields parseable JSON.
    _ = json_write_yaml_event(&w, &yp, &event);
    json_write_str(&w, "\n");
    return 0;
}
