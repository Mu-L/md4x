# Build

External dependency: [libyaml](https://github.com/yaml/libyaml) 0.2.5 (frontmatter YAML for the
AST/meta renderers), fetched automatically via `build.zig.zon`. It is the **only C** compiled into
any artifact. The remaining `@cImport`s are genuinely external headers: `node_api.h`, `stdio.h`,
`string.h`, `yaml.h`.

```sh
zig build                             # all artifacts (default optimize: ReleaseFast)
zig build -Doptimize=Debug
zig build && zig-out/bin/md4x --help
```

`zig build install` ships only `zig-out/bin/md4x`. There are no static libraries or headers to
install — those were part of the dropped C ABI. The wasm/napi artifacts install straight into
`packages/md4x/build/`.

The project can also be consumed as a Zig package dependency via `build.zig.zon`.

## Comptime feature switches

Feature flags that must fold away at comptime — a runtime flag would still link the payload in —
go through the shared `build_config` options module (`b.addOptions()` in `build.zig`), created
**once** and imported by every artifact, same one-instance rule as `abi`.

| Switch                | Default | Effect                                                                       |
| --------------------- | ------- | ---------------------------------------------------------------------------- |
| `-Demoji=true`        | `false` | Links `src/emoji.zig` (1913 shortcodes) in, so `:wave:` renders as the emoji |
| `-Dwasm-symbols=true` | `false` | Keeps the name section in the WASM/NAPI artifacts (analysis only, see below) |

Emoji is **off in every shipped artifact**: the table costs ~26 KB gzipped on the standalone bundle
(~24% of it). With the default the recognizer folds away entirely — `src/emoji.zig` is never
referenced and a shortcode reaches the output verbatim, which is what `spec-markdown.txt`'s
`## Emojis` section pins. `-Demoji=true` is supported but **not exercised by CI**; flipping it
changes rendered output, so `scripts/diff-corpus.sh` is expected to differ across the two.

Reach the switch through the JS artifacts with
`bun scripts/js-artifacts.ts build -Demoji=true` (anything after `build` is forwarded to each
`zig build` step).

`-Dwasm-symbols` is not a feature switch — it only flips `strip`, so codegen is unchanged. It exists
so `scripts/wasm-size.ts` can attribute code bytes to Zig functions; that script passes it itself and
installs to a throwaway `--prefix`, leaving `packages/md4x/build/` alone. No shipped build sets it.

## Targets

| Target             | Command                               | Output                                |
| ------------------ | ------------------------------------- | ------------------------------------- |
| CLI                | `zig build`                           | `zig-out/bin/md4x`                    |
| WASM               | `zig build wasm` (ReleaseFast)        | `packages/md4x/build/md4x.wasm`       |
| WASM (small)       | `zig build wasm-small` (ReleaseSmall) | `packages/md4x/build/md4x-small.wasm` |
| WASM (safe)        | `zig build wasm-safe` (ReleaseSafe)   | `packages/md4x/build/md4x-safe.wasm`  |
| NAPI (9 platforms) | `zig build napi-all -Dnapi-include=…` | `packages/md4x/build/md4x.*.node`     |

`md4x-small.wasm` is inlined into the `md4x/standalone` bundle and excluded from the npm tarball
(`!build/md4x-small.wasm` in `files`). See [js-bindings.md](../docs/js-bindings.md) for the full
NAPI target list and the standalone build pipeline.

`md4x-safe.wasm` is a debugging aid, not a shipped artifact: nothing loads it, `build:js` does not
build it, and it is excluded from the tarball too. Reach for it when a WASM run misbehaves —
ReleaseFast turns an out-of-bounds index or a bad `@intCast` into silent linear-memory corruption,
while ReleaseSafe traps at the offending instruction. Point a reproducer at it with
`init({ wasm: await readFile("packages/md4x/build/md4x-safe.wasm") })`.

## Module graph

**One Zig module graph per artifact.** `src/lib.zig` is the library root: it imports the parser, the
entity table, and every renderer, and re-exports their entry points. Each artifact root pulls it in —
`src/md4x-wasm.zig`, `src/md4x-napi.zig` and `src/fuzz.zig` via a relative `@import("lib.zig")`;
`src/cli/md4x-cli.zig` via the named `md4x` module, because a module may not `@import` outside its
own directory. Units therefore call each other by **direct Zig call**: no per-unit static libraries,
no link-time symbol resolution between them.

**To add a renderer, add it to `src/lib.zig`** — not to `build.zig`.

Two rules the build graph enforces the hard way:

- The `abi` module must be created **once** and shared by every module in an artifact. A second
  `createModule` on `src/abi.zig` fails with _"file exists in modules 'abi' and 'abi0'"_.
- `src/abi.zig` must stay a **pure leaf** — types only, no imports, no function declarations.
  Anything that makes `abi` import the parser or a renderer creates a cycle. Entry-point
  declarations belong in `src/lib.zig`.

The WASM JS loader (`packages/md4x/lib/wasm/common.mjs`) provides no-op `args_`/`environ_` WASI
import stubs that Zig's `wasm32-wasi` startup references, **plus `env.md4x_highlight`** — the
syntax-highlight hook the HTML/ANSI renderers call per code block. That one is a hard import: a
loader that instantiates the module without passing `_imports` fails with a `LinkError`, whether or
not anything highlights.

## Regenerating JS artifacts

`packages/md4x/build/*` and `packages/md4x/lib/standalone.mjs` are gitignored and must be rebuilt
after source changes. One command covers everything the JS suites load — wasm, ReleaseSmall wasm, the
**host** NAPI target, and the standalone bundle:

```sh
bun run build:js
```

You are not expected to remember: vitest refuses to start when any of them is older than `src/`, and
names the file plus the command. See
[testing.md](testing.md#the-js-suites-cannot-run-against-a-stale-or-foreign-artifact). Individually:

```sh
zig build wasm && bunx vitest run packages/md4x/test/wasm.test.mjs
bun run build:standalone && bunx vitest run packages/md4x/test/standalone.test.mjs
```
