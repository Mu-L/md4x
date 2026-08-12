# Performance-Critical Invariants

## Byte scans go through `src/scan.zig`

The four hot "walk forward to the next interesting byte" loops — `md_analyze_line`'s line-end scan,
`md_text_with_null_replacement`'s NUL split, `render_html_escaped`'s escape scan,
`json_write_escaped`'s escape scan — are all `scan.indexOfAnyPos(bytes, lt, …)`, which takes a
**comptime** byte set plus an optional "below this byte" threshold. A **single-byte** needle uses
`std.mem.indexOfScalarPos` instead — std vectorizes that case itself; `scan.zig` exists for the
multi-byte sets `std.mem.indexOfAnyPos` can only walk scalar-wise. Do not hand-roll a fifth one.

**Every vector body must stay gated on `std.simd.suggestVectorLength`.** It returns **null** on
`wasm32` without `simd128`, and a bare `@Vector(16, u8)` loop there does **not** fall back to scalar —
LLVM scalarizes it into 16 unconditional compares and the early exit is lost. Never write an ungated
vector loop, and never assume `@Vector` degrades gracefully.

**The scalar path is a table lookup, unrolled by 4** — both deliberate, and not merely a
`< vector_len` tail: wherever `suggestVectorLength` is null it is the _entire_ scan. Spelling a 4-byte
set as four sequential compares measured ~10% slower on WASM `renderToHtml` than the `ESCAPE_MAP`
lookup (the cost grows with set size, which is backwards), and dropping the unroll cost several more
percent under JavaScriptCore. Keep both.

## `simd128` is enabled on the WASM target

Set in `build.zig`'s `addWasm`; it is what turns those vector bodies into real `v128`. Measured
per-process, best-of, 565 KB input: Node +4-5%, Bun +12-22% across `renderToHtml` / `renderToAST` /
`renderToText`. It sets a runtime floor (Chrome 91+, Firefox 89+, Safari 16.4+, Node 16.4+), so treat
it as a support decision, not a tuning knob.

## Only NUL-free-safe libc calls belong in the parser

Think twice before calling any `<string.h>` function from the parser at all. Neither wasi-libc nor
Zig's bundled musl ships `strcspn.c`/`strspn.c`/`strstr.c`, so Zig's fallbacks (`lib/c/string.zig`)
get linked — and each one `std.mem.span()`s its argument first, i.e. runs `strlen()`. The parser's
buffers are **not NUL-terminated**, so that reads past the end of the document until it meets a zero
byte. `strcspn()` once backed the line-end scan and made the parse O(lines × bytes) wherever libc did
not supply it: ~1.8× on `md_parse` for wasm, **over 500×** on a 32 KB/800-line document for
`linux-*-musl`. `scan.indexOfAnyPos` replaced it because it is **bounds-driven rather than
NUL-driven** — it cannot over-read, needs no `doc_ends_with_newline` precondition, and is fast on
every target rather than only on glibc. Do not reintroduce it.

The parser's remaining libc externs (`memcmp`, `memmove`, `qsort`, `bsearch`) all take an explicit
length and are fine.

## Benchmarking the WASM build

The instance is a module-level singleton in `packages/md4x/lib/wasm/common.mjs` and `init()`
early-returns on `_hasInstance()`. `default.mjs` only re-exports from `common.mjs`, so importing
`default.mjs?v=1` / `?v=2` to A/B two binaries in one process silently benchmarks **one binary
twice** — `init({wasm})` on the second is a no-op, and an output-parity assertion between the two
"variants" passes vacuously. Benchmark one binary per process, or cache-bust `common.mjs` itself and
assert distinct `Memory` objects.

## WASM vs NAPI

WASM is built `ReleaseFast` like NAPI but is consistently slower (~3× on `renderToHtml`, ~2× on
`parseAST` for the medium fixture) due to the runtime plus copying input/output across the JS↔WASM
boundary on every call. Renderer-side allocation optimizations help the native path more, since
wasm's linear-memory allocator has a different cost profile than the system `malloc`. Prefer NAPI
where throughput matters; WASM is the portable fallback.

```sh
bun packages/md4x/bench/index.mjs     # mitata; compares napi/wasm/md4w/markdown-it
```
