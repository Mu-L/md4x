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
are generated. Regenerate only when updating Unicode compliance (currently Unicode 15.1) or the
WHATWG entity data:

| Script                       | Output                                                |
| ---------------------------- | ----------------------------------------------------- |
| `scripts/_gen-tables-zig.py` | `src/unicode_tables.zig` from `scripts/unicode/*.txt` |
| `scripts/_gen-entity-zig.py` | `src/entity.zig` from the WHATWG entity data          |

The TypeScript generators (`build-entity-map.ts`, `build-folding-map.ts`, `build-punct-map.ts`,
`build-whitespace-map.ts`, `_unicode-map.ts`) produce the legacy C tables and are not used by the
current build.
