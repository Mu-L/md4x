export const small =
  "# Hello\n\nA paragraph with **bold** and *italic* text.\n";

export const medium = `# Document Title

A paragraph with **bold**, *italic*, \`code\`, and [a link](https://example.com).

## Section 1

- Item 1
- Item 2
  - Nested item
- Item 3

> Blockquote with **emphasis** inside.

## Section 2

\`\`\`js
function hello() {
  return "world";
}
\`\`\`

| Column A | Column B | Column C |
|----------|:--------:|---------:|
| left     | center   | right    |
| foo      | bar      | baz      |

---

1. First
2. Second
3. Third

Final paragraph with ~~strikethrough~~ and \`inline code\`.
`;

export const large = medium.repeat(50);

// --- YAML ---------------------------------------------------------------
//
// Standalone YAML documents (not Markdown frontmatter). Deliberately limited
// to constructs every parser under bench agrees on: no anchors/aliases (the
// JSON writer rejects them), no timestamps (js-yaml resolves them to `Date`,
// the core schema leaves them strings). Compare outputs before trusting the
// numbers -- a parser that silently drops nodes would otherwise look fast.

export const yamlSmall = `title: Hello
count: 42
draft: true
`;

export const yamlMedium = `name: md4x
version: 0.0.26
description: "Markdown parser library, a Zig port of md4c"
private: false
keywords: [markdown, commonmark, zig, wasm]
engines:
  node: ">=18"
  bun: ">=1.0"
exports:
  ".":
    types: ./lib/types.d.mts
    node: ./lib/napi.mjs
    default: ./lib/wasm/default.mjs
  ./wasm:
    types: ./lib/wasm/index.d.mts
    browser: ./lib/standalone.mjs
targets:
  - name: wasm
    optimize: ReleaseSmall
    flags: [--export-table, --no-entry]
    limits: { memory: 16777216, stack: 1048576 }
  - name: napi
    optimize: ReleaseFast
    flags: []
    limits: { memory: null, stack: 8388608 }
matrix:
  os: [ubuntu-latest, macos-latest, windows-latest]
  optimize: [ReleaseSafe, Debug]
thresholds:
  parse_ns: 12500.5
  render_ns: -1
  regression_pct: 2.5
notes: |
  Block scalars keep their newlines, which exercises the
  chomping and folding paths of the scanner.
summary: >
  Folded scalars join their lines into a single paragraph,
  which is a different code path than the literal form above.
empty_value:
tilde: ~
explicit_null: null
`;

// Unique keys per entry -- repeating a mapping would produce duplicate keys,
// which the parsers disagree about (warn, throw, or last-one-wins).
export const yamlLarge = `entries:\n${Array.from(
  { length: 400 },
  (_, i) => `  - id: item-${i}
    index: ${i}
    enabled: ${i % 2 === 0}
    ratio: ${(i / 400).toFixed(4)}
    label: "Entry number ${i}"
    tags: [alpha, beta, gamma]
    meta:
      owner: team-${i % 8}
      nested:
        depth: 3
        note: plain scalar with spaces
`,
).join("")}`;
