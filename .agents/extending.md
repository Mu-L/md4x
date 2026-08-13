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

`scripts/build-entity-map.ts` fetches <https://html.spec.whatwg.org/entities.json> and emits the C
`ENTITY_MAP[]`. `scripts/_gen-entity-zig.py` converted that to `src/entity.zig` — but its input,
`src/entity.c`, was deleted with the C ABI, so it can no longer be re-run and is kept only as the
record of how the file was produced.
