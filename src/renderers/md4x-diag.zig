// SPDX-License-Identifier: MIT
//
// Shared debug-sink diagnostics for the md4x renderers.
//
// Every renderer's `MD_*_FLAG_DEBUG` path writes the parser's diagnostic
// messages to stderr in the same one-line format, so the write lives here once
// instead of in six copies.
//
// It is here rather than inline in each renderer because libc's `stderr` has no
// portable shape under translate-c, and only this file has to know that:
//
//   - glibc / musl / wasi-libc: an extern variable, usable as-is.
//   - macOS: a macro over `__stderrp`, which translate-c renders as an inline
//     function — passing it to `fprintf` is a type error.
//   - MinGW: a macro over `__acrt_iob_func(2)`, which translate-c emits as a
//     container-level const initialized by an extern call. That is not
//     comptime-known, so merely *naming* `sys.stderr` fails to compile.
//
// Only the Linux and wasi targets built while the renderers named `sys.stderr`
// directly; the macOS and Windows NAPI targets did not.
//
// The write stays on libc stdio (rather than `std.debug.print`) because the
// WASM build is `wasm32-wasi` against the small WASI import surface that
// `packages/md4x/lib/wasm/common.mjs` stubs; `std`'s stderr writer pulls in
// imports (`clock_res_get`, …) the loader does not provide, and the module then
// fails to instantiate.
//
// Imported (not @cImport'd into a clashing symbol) by each renderer lib: Zig
// compiles its own internal copy per importing artifact, so there is no
// exported-symbol collision and no build.zig change is required.

const builtin = @import("builtin");

const sys = @cImport({
    @cInclude("stdio.h");
});

/// Write one parser diagnostic to stderr. `msg` need not be NUL-terminated.
/// The `fprintf` result is discarded, exactly as the per-renderer calls did.
pub fn logMessage(msg: []const u8) void {
    // Comptime-known switch: only the prong for this target is analyzed, which
    // is what keeps the unusable `sys.stderr` shapes out of the other builds.
    const stream = switch (builtin.os.tag) {
        .windows => sys.__acrt_iob_func(2),
        .macos, .ios, .tvos, .watchos, .visionos => sys.stderr(),
        else => sys.stderr,
    };
    _ = sys.fprintf(stream, "MD4X: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
}
