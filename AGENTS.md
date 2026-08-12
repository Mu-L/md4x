# MD4X

> Markdown parser library (Zig port of [mity/md4c](https://github.com/mity/md4c))

## Guides

| Area                                               | Read when                                                         |
| -------------------------------------------------- | ----------------------------------------------------------------- |
| [.agents/build.md](.agents/build.md)               | Building, targets, module graph rules                             |
| [.agents/testing.md](.agents/testing.md)           | Running tests, fuzzing, the parser invariants only unit tests pin |
| [.agents/conventions.md](.agents/conventions.md)   | Touching parser or renderer internals                             |
| [.agents/safety.md](.agents/safety.md)             | Reviewing changes — bug classes and the audit checklist           |
| [.agents/performance.md](.agents/performance.md)   | Byte scans, SIMD, libc, benchmarking                              |
| [.agents/extending.md](.agents/extending.md)       | Adding a block/span type, a renderer, or regenerating tables      |
| [docs/parser-api.md](docs/parser-api.md)           | SAX callback table, detail types, parser flags                    |
| [docs/renderers.md](docs/renderers.md)             | Renderer entry points and their flags                             |
| [docs/js-bindings.md](docs/js-bindings.md)         | WASM / standalone / NAPI targets and the JS package API           |
| [docs/markdown-syntax.md](docs/markdown-syntax.md) | Supported syntax and extensions                                   |

## Quick start

```sh
zig build                       # all artifacts (ReleaseFast); CLI at zig-out/bin/md4x
bun scripts/run-tests.ts        # full test suite
bash scripts/diff-corpus.sh     # output-parity gate — must diff-clean after any internal change
bun fmt
```

## Project Structure

```
src/
  lib.zig             # Library root: parser + entity + all renderers in ONE module
  md4x.zig            # Parser root (md_parse) + parser unit tests
  abi.zig             # Shared types/enums/flags, detail unions, Parser (types only, leaf)
  parser/
    types.zig         # MD_CTX + internal structs, enums
    util.zig          # char/UTF-8/unicode helpers, buffers, entity recognizers, attributes
    refdefs.zig       # ref-def dictionary + link/autolink/wiki recognizers
    inlines.zig       # inline mark engine (emphasis mod-3) + span/text emission
    blocks.zig        # line classification + container/block analysis
    process.zig       # block-content processing + md_process_doc
  scan.zig            # Vectorized byte scan shared by parser + renderers
  unicode_tables.zig  # Generated: case folding, punct, whitespace
  entity.zig          # Generated: HTML entity lookup table
  md4x-wasm.zig       # WASM exports (alloc/free + renderer wrappers)
  md4x-napi.zig       # Node.js NAPI addon
  fuzz.zig            # Zig-native coverage-instrumented fuzz harness
  renderers/
    md4x-props.zig    # Shared component property parser
    md4x-json.zig     # Shared JSON writer + YAML-to-JSON helpers
    md4x-{html,ast,ansi,meta,text,markdown}.zig
    md4x-heal.zig     # Markdown heal/completion utility (no parser dependency)
  cli/
    md4x-cli.zig      # CLI driver (html, text, json, ansi, markdown, heal)
    md4x.1            # Man page
packages/md4x/        # npm package — build/ (wasm + .node), lib/, test/, bench/
test/
  spec.txt            # CommonMark 0.31.2
  spec-*.txt          # Per-extension suites
  regressions.txt     # Bug regression tests
  coverage.txt        # Code coverage tests
  run-testsuite.py    # Individual suite runner
  pathological-tests.py, prog.py, normalize.py
  fuzzers/            # seed-corpus/ + corpus/
scripts/
  run-tests.ts        # Main test runner
  diff-corpus.sh      # Output-parity harness (sha256 of all 6 formats over the corpus)
  build-standalone.ts # Bundles lib/standalone.mjs (rolldown, gzip+Z85 inlined wasm)
  _gen-*.py           # Zig table generators (unicode, entities)
  build-*.ts          # Legacy C table generators
  unicode/            # Unicode data files
website/              # Docs + playground (Vite + Vue) — pages/, components/, samples/
build.zig, build.zig.zon
.github/workflows/    # Build + test (Linux/Windows, debug/release, coverage)
```
