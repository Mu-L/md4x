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

## No helper may rescan the document per candidate

`md4x-heal.zig` had three of these: `in_math_block` restarted at offset 0 on every call, and
`in_link_url` / `in_html_tag` walked backward to the previous newline — which looks line-bounded
until the input has no newlines, and then runs back to offset 0. Their callers
(`count_single_asterisks`, `count_single_underscores`) ask once per candidate marker while sweeping
forward, so each pair was O(n²): 240 KB of `'_a '` repeats took **14 s**, and a heal of the 565 KB
bench fixture cost 10.9 **billion** instructions — ~400× an HTML render of the same file.

`in_fenced_code_block` was the fourth, and the worst: `heal_comparison_operators` asks it once per
`- > 5`-shaped list line, so 400 KB of those took **10.3 s** and 1 MB took **68 s**.

The fix pattern, in every direction, is a **resumable cursor**: keep the original state machine
verbatim, promote its loop index to a field, and let the caller drive it from its own forward index
(`MathScanner`, `LineContextScanner`, `FenceScanner`). That is exact rather than approximate **only
while the queried positions never decrease** — say so in the doc comment of any such helper, and
check the call sites really are forward-only. `FenceScanner` adds a second precondition, because
`in_fenced_code_block`'s two `pos`-bounded details are not prefix-pure: a backtick within two bytes
of `pos` is undecidable (the ``` may complete once the region grows) so the cursor stops in front of
it, and the "skip to the end of the fence line" inner loop can be left unfinished, which a
`skipping` flag carries. Both only work if **`text[0..pos]` never changes after being queried** —
which is why the caller had to stop mutating in place, below.

## Nor may a healer splice per insertion

`heal_comparison_operators` also `memmove`d the whole tail one byte right for every backslash it
inserted, so the same input was O(n²) a second time over. It now **appends** to a second `HEAL_BUF`
and hands it to `buf` at the end: `out` is the source prefix with every earlier insertion applied,
`copied` tracks how much of `src` has been flushed, and the buffer is allocated lazily so a document
with no candidate line pays nothing. Flushing up to `gt_pos` **before** querying `FenceScanner` is
what makes `out` byte-identical to what the in-place version's buffer held at that point — that
equality is the entire correctness argument, so do not reorder it.

That rewrite also retires the file's one mid-scan mutator. Every healer now caches
`const text = buf.data.?` and is safe only because each `buf_append` is that healer's **last** use
of the cached pointer — an append followed by another `text[…]` read is a use-after-free. If you add
one, either re-read `buf.data.?` after the append or move the append last.

When touching heal, remember `md_heal()` does **not** use the parser, so none of the parser's
linear-time limits (`docs/parser-api.md`) cover it, and `scripts/diff-corpus.sh`'s corpus is short
enough that a quadratic path stays invisible there. Pin new ones in `test/pathological-tests.py`,
which takes a third tuple element of extra CLI options (`["--format=heal"]`). Prefer **odd** repeat
counts so the marker is genuinely unbalanced and heal exercises its append path.

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
