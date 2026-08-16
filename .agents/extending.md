# Extending MD4X

## Adding a block or span type

1. Add the enum member to `BlockType`/`SpanType` **at the end** (ordinals are frozen), the detail
   struct to `src/abi.zig`, the matching arm to `BlockDetail`/`SpanDetail` (same name, same position),
   and a field for it to the flat `Detail` struct in `src/renderers/md4x-ast.zig`.
2. Build the node in `jsonEnterBlock`/`jsonEnterSpan`. Every renderer's `switch (detail.*)` is
   exhaustive, so the compiler lists the sites needing an arm.
3. Serialize props in `jsonWriteProps` — **after** the `tag_is_dynamic` check (see
   [safety.md](safety.md)).
4. If it needs special child rendering, handle it in `jsonSerializeNode`.
5. Update all six renderers (HTML, AST, ANSI, meta, text, markdown) and the CLI.
6. Add a test suite in `test/spec-*.txt` and register it in `scripts/run-tests.ts`.
7. Add JS binding tests in `packages/md4x/test/_suite.mjs`.
8. Rebuild WASM (`zig build wasm`) and run `bun vitest run packages/md4x/test/wasm.test.mjs`.

## Adding a renderer

Add it to `src/lib.zig`, not to `build.zig` — see [build.md](build.md).

## Generated tables

`src/unicode_tables.zig` (case folding, punctuation, whitespace) and `src/entity.zig` (HTML entities)
are generated. Regenerate only when updating Unicode compliance (currently Unicode 18.0) or the
WHATWG entity data. Never hand-edit either file.

### `src/unicode_tables.zig`

Two stages. The TypeScript generators read `scripts/unicode/*.txt` and emit C arrays using md4c's
`R()`/`S()` range-encoding macros; `_gen-tables-zig.py` then expands those macros through `zig cc`
and writes the Zig module. It takes a **C source file** as input, not the `.txt` data:

```sh
{ bun scripts/build-whitespace-map.ts    # WHITESPACE_MAP  <- DerivedGeneralCategory.txt (Zs)
  bun scripts/build-punct-map.ts         # PUNCT_MAP       <- DerivedGeneralCategory.txt (P*, S*)
  bun scripts/build-folding-map.ts       # FOLD_MAP_1/2/3  <- CaseFolding.txt (status C, F)
} > /tmp/tables.c
python3 scripts/_gen-tables-zig.py /tmp/tables.c    # run from the repo root; needs `zig cc` on PATH
```

`_gen-tables-zig.py` writes the hardcoded relative path `src/unicode_tables.zig`. Its 12-values-
per-line output is deliberately not `zig fmt`-conformant — do not reformat it, or the next
regeneration diffs spuriously.

Data files come from md4c's `scripts/unicode/` (they are kept byte-identical to upstream's, so the
tables can be cross-checked against md4c's own by running `_gen-tables-zig.py` on `src/md4c.c`).

Unicode updates are near-invisible to the suites: no CommonMark or extension example uses an
affected code point, so `scripts/diff-corpus.sh` stays clean whether the regeneration is right or
wrong. `test/coverage.txt` carries the only guards — flanking cases against newly-punctuation code
points and reference-label cases against new case foldings. Extend them when bumping Unicode.

### `src/entity.zig`

Two stages, both re-runnable — the second reads the first's stdout, not the deleted `src/entity.c`:

```sh
bun scripts/build-entity-map.ts > /tmp/entity-map.c   # <- html.spec.whatwg.org/entities.json
python3 scripts/_gen-entity-zig.py /tmp/entity-map.c  # run from the repo root
```

The emitted table is one blob of `[hdr][name][UTF-8 value]` records plus a u16 index of every 16th
record's offset, **not** an array of `{ name: [*:0]const u8, codepoints: [2]c_uint }`. The struct
form cost 46 KB of the wasm data section and 105 KB of the NAPI addon, the latter because each
`name` pointer needs an `R_X86_64_RELATIVE` relocation — 54 KB of `.rela.dyn` for 2125 records. Keep
it pointer-free. Like `unicode_tables.zig` the file is deliberately not `zig fmt`-conformant (fmt
collapses the blob onto one line); `bun fmt` is prettier-only and leaves both alone.

`hdr` packs the name length into 5 bits and the value length into 3, so a name longer than 31 bytes
or a value longer than 8 is a format change — the generator refuses rather than truncating. The
generated tests walk every record and assert the blob is sorted and the checkpoints land on record
boundaries; nothing else pins that, since the `.txt` suites reach a dozen of the 2125 names.
