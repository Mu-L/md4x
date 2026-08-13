# Testing & Fuzzing

```sh
bun scripts/run-tests.ts                          # everything: zig unit tests + .txt suites + pathological
zig build test                                    # Zig unit tests (ReleaseSafe)
zig build test -Doptimize=Debug                   # + undefined-fill and allocator length validation
python3 test/run-testsuite.py -s test/spec.txt -p zig-out/bin/md4x
python3 test/pathological-tests.py -p zig-out/bin/md4x
```

Suite format: Markdown examples with a `.` separator and expected HTML. The runner pipes input
through `md4x` and compares normalized output.

Suites: `spec.txt`, `spec-tables.txt`, `spec-strikethrough.txt`, `spec-tasklists.txt`,
`spec-wiki-links.txt`, `spec-latex-math.txt`, `spec-permissive-autolinks.txt`,
`spec-hard-soft-breaks.txt`, `spec-underline.txt`, `spec-frontmatter.txt`, `spec-components.txt`,
`spec-attributes.txt`, `spec-alerts.txt`, `spec-highlight.txt`, `spec-footnotes.txt`,
`spec-markdown.txt`,
`regressions.txt`, `coverage.txt`.

Both `bun scripts/run-tests.ts` and `.github/workflows/ci.yml` run the Zig unit tests on every PR.
CI additionally smoke-runs `zig build fuzz-zig` (see [Fuzzing](#fuzzing)); it does **not** run
`scripts/diff-corpus.sh`, which stays a local gate.

## The test artifact is pinned to a safe optimize mode

`build.zig` pins it: `.optimize = if (optimize == .Debug) .Debug else .ReleaseSafe`, independently of
the global `-Doptimize` default of `.ReleaseFast` the shipping artifacts use. Bounds checks,
`@intCast` range checks, overflow checks and `unreachable` panics are what make the OOM sweep's
"never a crash" assertion mean anything — under `ReleaseFast` it degrades to "no hard segfault".
**Do not hand the global `optimize` to the test artifact.** The pin is self-checking: the
`test artifact is built with runtime safety armed` case asserts `std.debug.runtime_safety`.

## Parser invariants the HTML-diff suites cannot express

Covered by Zig unit tests in `src/md4x.zig`:

- **Abort matrix** — for each of the five SAX callbacks, a negative code propagates verbatim and a
  positive one stops emission but returns 0. Plus the **doc-level exception**: `md_process_doc`'s own
  bookends test `!= 0`, not `< 0`, so a callback aborting on the `.doc` block propagates **both**
  signs verbatim (`md_parse` returns `5` for a `+5`, `-7` for a `-7`). That is md4c parity — do not
  "fix" those two `!= 0` tests into `< 0`, and keep the doc-level cases, the only guard either way.
- **OOM sweep** — a `FailingAllocator` walks every internal allocation index over a document
  exercising ref-defs, tables, code metadata, attributes, components and autolinks, asserting each
  run is crash- and leak-free. The document carries a link title with 15 substrings, the only thing
  driving `md_build_attr_append_substr` past its initial capacity of 8 — keep it.
- **Golden SAX event trace** — the full ordered `enter_block`/`leave_block`/`enter_span`/`leave_span`/
  `text` stream over a document covering every block, span and text type, with each detail union
  arm's field values and every `Attribute`'s substring table spelled out. The corpus harness only
  compares each renderer's final bytes, so it can miss a detail-packaging change renderers paper
  over; this compares the raw SAX stream instead. **Treat a trace diff as a stop-the-line
  regression.** The expected value is a _recorded_ baseline: to re-record after a deliberate change,
  temporarily `std.debug.print` `probe.out.items` from the test and say in the commit message what
  changed and why.

## Fuzzing

`src/fuzz.zig` / `zig build fuzz-zig` is the only harness. It `@import`s the parser + renderer
sources directly, so Zig's fuzzer instruments the library and steers by **real coverage of the Zig
internals**. No ASan/UBSan — it relies on Zig runtime safety checks (the artifact is `ReleaseSafe`).

```sh
zig build fuzz-zig                    # smoke-run each harness once (+ parser unit tests)
zig build fuzz-zig --fuzz             # coverage-guided (serves a local web UI)
zig build fuzz-zig --fuzz -- md_html  # a single named test
```

Covers `md_parse` (no-op SAX callbacks), the six renderers, and `md_heal`. Inputs are gated to valid,
NUL-free UTF-8, matching the JS binding surface. libyaml is linked for the html/ast/meta paths but is
not instrumented.

Seed corpus at `test/fuzzers/seed-corpus/` (CommonMark, GFM, LaTeX math, wiki links, frontmatter,
components, attributes, alerts, code block metadata, heal edge cases) is shared with
`scripts/diff-corpus.sh`.

## Verification gate

Run after any internal change:

```sh
bash scripts/diff-corpus.sh    # must diff-clean against the baseline
zig build test
bun scripts/run-tests.ts
zig build fuzz-zig
```
