# JS Bindings

## WASM Target

```sh
zig build wasm                     # packages/md4x/build/md4x.wasm       (ReleaseFast, ~378K)
zig build wasm-small               # packages/md4x/build/md4x-small.wasm (ReleaseSmall, ~285K)
zig build wasm-safe                # packages/md4x/build/md4x-safe.wasm  (ReleaseSafe, unstripped, ~2.2M)
```

Builds a `wasm32-wasi` WASM binary with exported functions. `wasm` is the binary shipped as an asset and loaded by `md4x/wasm` (`ReleaseFast`, `pkg_optimize` in `build.zig`, shared with the NAPI targets); `wasm-small` is the `ReleaseSmall` variant inlined into the `md4x/standalone` bundle (it is excluded from the npm tarball, since it ships inside that module). The WASM module requires minimal WASI imports (`fd_close`, `fd_seek`, `fd_write`, `proc_exit`) which can be stubbed for browser use.

### The safety-checked variant

`md4x-safe.wasm` exists for debugging and is loaded by nothing: `bun run build:js` does not build it, no export maps to it, and it is excluded from the npm tarball. Under `ReleaseFast` an out-of-bounds index, a bad `@intCast` or an integer overflow silently corrupts the linear memory and surfaces (if at all) as wrong output much later; under `ReleaseSafe` each one traps at the offending instruction. So when a WASM run misbehaves, re-run the reproducer against this binary:

```js
import { readFile } from "node:fs/promises";
import { init, renderToHtml } from "md4x/wasm";

await init({ wasm: await readFile("packages/md4x/build/md4x-safe.wasm") });
```

It is byte-for-byte identical in output to `md4x.wasm`, and 9-30% slower depending on input size (see the table below) — fine for a reproducer, which is why the shipped binary stays `ReleaseFast`.

Two properties make it usable from the same loader:

- **Same WASI import surface.** `src/md4x-wasm.zig` installs a `std.debug.FullPanic` handler that reports through the renderers' libc-stdio stderr and then `@trap()`s. Std's default handler would instead report through `std.debug`'s stderr writer and stack-trace machinery, pulling ~25 further WASI imports (`clock_res_get`, `path_open`, `fd_prestat_get`, …) into the module; `lib/wasm/common.mjs` stubs only the handful the ReleaseFast build needs, so the binary would fail to instantiate with a `LinkError`. A panic therefore prints `MD4X: <message>` to stderr and surfaces in JS as `RuntimeError: unreachable`.
- **Unstripped** (`.strip = false` on this variant only), so the trap's wasm stack frames carry Zig function names, and the DWARF sections let a source-level wasm debugger step through `src/`. That is where the ~2.2 MB comes from; the code itself is ~427 KB.

### Profile tradeoffs

All three binaries are the same `wasm32-wasi` + `simd128` module built at a different optimize level, and all three produce **identical output** (hash-compared across `renderToHtml` / `renderToAST` / `renderToText` on both inputs below). They differ only in speed and size:

| Profile                   | Step                   |    Raw | gzip -9 | Instantiate |
| ------------------------- | ---------------------- | -----: | ------: | ----------: |
| `ReleaseFast` (shipped)   | `zig build wasm`       | 378 KB |  126 KB |      1.2 ms |
| `ReleaseSmall` (compact)  | `zig build wasm-small` | 285 KB |  106 KB |      1.0 ms |
| `ReleaseSafe` (debug aid) | `zig build wasm-safe`  | 2.2 MB |  749 KB |      1.9 ms |

Speed, in µs per call and as a ratio to `ReleaseFast`. **Document size changes the answer**, so both ends are listed: a 494 B input (the `medium` bench fixture — one short message, the streaming/chat shape) where per-call fixed costs dominate, and a 623 KB input (the fuzzer seed corpus plus `test/spec.txt` ×3 — the document shape):

| Profile        |  494 B: html |          ast |         text | 623 KB: html |          ast |         text |
| -------------- | -----------: | -----------: | -----------: | -----------: | -----------: | -----------: |
| `ReleaseFast`  | 10.2 (1.00×) | 14.9 (1.00×) | 10.0 (1.00×) | 7395 (1.00×) | 8038 (1.00×) | 6152 (1.00×) |
| `ReleaseSmall` | 11.9 (1.16×) | 20.6 (1.38×) | 11.4 (1.13×) | 7746 (1.05×) | 9433 (1.17×) | 6635 (1.08×) |
| `ReleaseSafe`  | 13.3 (1.30×) | 19.9 (1.34×) | 12.6 (1.25×) | 8066 (1.09×) | 9379 (1.17×) | 6812 (1.11×) |

Bun 1.3 on an i7-10700K, best-of-8 rounds after warm-up; times are per call, so the JS↔WASM copy is in every number. `ReleaseFast` runs the large document at ~86 MB/s of markdown. All three produce identical output hashes on both inputs.

Reading it:

- **The optimize level costs most on small inputs, not large ones.** Per-call setup (allocator, context init, the copy in and out) is branchy code where the checks and the size-optimized codegen land hardest; the large-document path is dominated by `scan.zig`'s vectorized byte scans and memory bandwidth, which barely move. Quoting a single ratio for these builds is misleading — say which input size it is for.
- **`ReleaseSmall` buys 93 KB raw / 20 KB gzipped.** That is the right trade only for `md4x/standalone`, where the binary ships inside the JS bundle as a Z85 string and every byte is download weight; `md4x/wasm` fetches a `.wasm` asset once and keeps the speed.
- **`ReleaseSafe` costs 9-11% on documents and 25-34% on short messages**, so what it is worth depends on the workload it would run. The size column is misleading: 1.8 MB of it is DWARF. Stripped, the safety checks themselves cost only ~50 KB over `ReleaseFast` (427 KB raw / 143 KB gzipped) — the binary is big because it is meant to be debugged, not shipped.
- Instantiate time tracks code size, not optimize level, and stays ~1-2 ms in all three — it is not a reason to pick a profile.

> **Runtime requirement:** all three binaries are built with the **`simd128`** feature (WebAssembly fixed-width SIMD), which `src/scan.zig` uses for its byte scans. That sets a floor of **Chrome 91+, Firefox 89+, Safari 16.4+ (March 2023), Node 16.4+**, and Bun/Deno of any version. Older engines cannot instantiate the module at all — `WebAssembly.instantiate` rejects rather than degrading. It buys +4-5% on Node and +12-22% on Bun across `renderToHtml` / `renderToAST` / `renderToText`; see `build.zig`'s `addWasm` to turn it off if you need to support an older engine.

> **Note on WASM performance:** The WASM target is built `ReleaseFast` (same as NAPI), but it is consistently slower than the native NAPI binding (roughly 3x on `renderToHtml`, 2x on `parseAST` for the medium fixture) due to the WebAssembly runtime plus the cost of copying input/output across the JS↔WASM memory boundary on every call. Renderer-side allocation optimizations (e.g. the AST arena, HTML output buffering) help the native path more than WASM, since wasm's linear-memory allocator has a different cost profile than the system `malloc`. Prefer NAPI where raw throughput matters; WASM is the portable fallback for non-Node environments.

**Exported functions:**

| Function                                   | Description                                                            |
| ------------------------------------------ | ---------------------------------------------------------------------- |
| `md4x_alloc(size) -> ptr`                  | Allocate memory in WASM linear memory                                  |
| `md4x_free(ptr)`                           | Free previously allocated memory                                       |
| `md4x_to_html(ptr, size, flags) -> int`    | Render to HTML (0=ok, -1=error)                                        |
| `md4x_to_html_hl(ptr, size, flags) -> int` | Render to HTML, calling the `env.md4x_highlight` import per code block |
| `md4x_to_ast(ptr, size, flags) -> int`     | Render to JSON AST                                                     |
| `md4x_to_ansi(ptr, size, flags) -> int`    | Render to ANSI                                                         |
| `md4x_to_ansi_hl(ptr, size, flags) -> int` | Render to ANSI, calling the `env.md4x_highlight` import per code block |
| `md4x_to_meta(ptr, size, flags) -> int`    | Render to meta JSON                                                    |
| `md4x_to_text(ptr, size, flags) -> int`    | Render to plain text                                                   |
| `md4x_heal(ptr, size) -> int`              | Heal incomplete streaming markdown                                     |
| `md4x_result_ptr() -> ptr`                 | Get output buffer pointer (after render)                               |
| `md4x_result_size() -> size`               | Get output buffer size (after render)                                  |

**Usage from JS (via `lib/wasm.mjs` wrapper):**

```js
import { init, renderToHtml } from "md4x/wasm";

await init(); // load WASM binary (call once before using render methods)

const html = renderToHtml("# Hello"); // sync after init
```

`init(opts?)` accepts an optional options object with a `wasm` property: `ArrayBuffer`, `Uint8Array`, `WebAssembly.Module`, `Response`, or `Promise<Response>`. When called with no arguments in Node.js, it reads the bundled `.wasm` file from disk. All render methods are **sync** after initialization. All extensions are enabled by default (`MD_DIALECT_ALL`).

## Standalone Target (inlined WASM)

`md4x/standalone` exposes the same WASM API from a **single, minified, dependency-free ES module** (`lib/standalone.mjs`, ~126 KB) with the binary embedded — gzipped, then [Z85](https://rfc.zeromq.org/spec/32/) encoded. No `.wasm` asset to fetch, resolve, or configure a bundler for, and no relative imports to follow. Useful for single-file bundles, edge runtimes, and environments without asset loading.

```js
import { init, renderToHtml } from "md4x/standalone";

await init(); // decodes + inflates + instantiates the inlined binary (no options)

const html = renderToHtml("# Hello");
```

It is also what `md4x` and `md4x/wasm` resolve to under the **`browser`** export condition, so browser bundlers pick it up with no configuration. Everything else (render functions, options, behavior) is identical to `md4x/wasm`: the bundle is built from the same `lib/wasm/common.mjs` source, inlined at build time. `init(opts?)` keeps the same signature — the embedded binary is used unless `opts.wasm` overrides it.

**Encoding pipeline:** `md4x-small.wasm` (ReleaseSmall) → gzip (zlib level 9, build time) → Z85 → JS string literal.

**Inflating at `init()`** takes the fastest available route:

1. `process.getBuiltinModule("node:zlib").gunzipSync()` on Node/Bun/Deno — ~1 ms. This is a plain call, not an import, so bundlers never see a `node:zlib` specifier and the module stays dependency-free.
2. `DecompressionStream("gzip")` otherwise (browsers, workers, older runtimes).

If neither exists, `init()` throws a descriptive error pointing at `md4x/wasm`.

Cold `init()`, measured on this repo's fixture (single run in a fresh process, AMD Ryzen 9 9950X3D):

| Runtime | `DecompressionStream` | `node:zlib` |
| ------- | --------------------: | ----------: |
| Node 24 |                ~28 ms |     ~6.5 ms |
| Bun 1.3 |                ~15 ms |    ~13.5 ms |

The gap is **not** zlib throughput (inflating 96 KB → 294 KB takes ~1 ms either way) — it is first-call setup of the web-streams-to-zlib adapter (~27 ms on Node, ~10 ms on Bun). Bun's win is smaller because loading `node:zlib` itself costs ~7 ms there. Browser figures are not measured here; `DecompressionStream` is native in browsers and does not pay Node's adapter cost.

Streaming the inflate directly into `WebAssembly.instantiateStreaming()` was measured and **did not help**: the payload is already in memory, so there is no download to overlap with, and compilation (~1–4 ms) is too small a fraction of cold init to hide behind decompression.

Z85 encodes 4 bytes as 5 ASCII characters (**+25%** overhead, vs +33% for base64) and its alphabet contains no `"`, `'`, `\` or backtick, so the payload embeds verbatim in a JS string literal with no escaping.

| Payload                                      |        Size |
| -------------------------------------------- | ----------: |
| `md4x.wasm` (ReleaseFast, raw)               |     ~302 KB |
| `md4x-small.wasm` (ReleaseSmall, raw)        |     ~287 KB |
| Z85 of raw                                   |     ~359 KB |
| base64 of gzip                               |     ~126 KB |
| **gzip + Z85 payload**                       | **~118 KB** |
| **`lib/standalone.mjs`** (payload + runtime) | **~126 KB** |

**Build (`scripts/build-standalone.ts`):** [rolldown](https://rolldown.rs/) bundles the entry, with the payload/decoder and the entry module supplied as **virtual modules** — so the ~118 KB Z85 string and the glue code never land in `lib/` as source. Real source (`lib/wasm/common.mjs`, `lib/_shared.mjs`) is bundled in from disk, then everything is minified into one file.

| Module                | Kind    | Contents                                                                  |
| --------------------- | ------- | ------------------------------------------------------------------------- |
| `\0md4x:standalone`   | virtual | Entry — re-exports the renderers, defines `init()` (gunzip + instantiate) |
| `\0md4x:z85`          | virtual | `z85Decode()` + the `WASM_GZIP_Z85` / `GZIP_SIZE` payload constants       |
| `lib/wasm/common.mjs` | on disk | Shared render functions (same source as `md4x/wasm`)                      |
| `lib/_shared.mjs`     | on disk | Shared post-parse helpers (`applyTitle`)                                  |

Output files:

| File                   | Description                                              |
| ---------------------- | -------------------------------------------------------- |
| `lib/standalone.mjs`   | **Generated** — minified single-file bundle (gitignored) |
| `lib/standalone.d.mts` | TypeScript declarations (checked in)                     |

```sh
zig build wasm-small && bun scripts/build-standalone.ts   # or: bun run build:standalone
```

This runs in CI, in the release workflow, and in the package `prepack` script, so `lib/standalone.mjs` is always rebuilt from the freshly built binary before publish.

## NAPI Target (Node.js)

```sh
bunx nypm add node-api-headers
zig build napi-all -Dnapi-include=node_modules/node-api-headers/include  # all 9 platforms
```

Individual platform targets:

```sh
zig build napi-linux-x64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-x64-musl -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-arm64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-arm64-musl -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-arm -Dnapi-include=node_modules/node-api-headers/include
zig build napi-darwin-x64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-darwin-arm64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-win32-x64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-win32-arm64 -Dnapi-include=node_modules/node-api-headers/include
```

`zig build napi-all` outputs platform-specific binaries to `packages/md4x/build/`:

| Output file                  | Platform                |
| ---------------------------- | ----------------------- |
| `md4x.linux-x64.node`        | Linux x86_64 (glibc)    |
| `md4x.linux-x64-musl.node`   | Linux x86_64 (musl)     |
| `md4x.linux-arm64.node`      | Linux aarch64 (glibc)   |
| `md4x.linux-arm64-musl.node` | Linux aarch64 (musl)    |
| `md4x.linux-arm.node`        | Linux ARMv7 (gnueabihf) |
| `md4x.darwin-x64.node`       | macOS x86_64            |
| `md4x.darwin-arm64.node`     | macOS Apple Silicon     |
| `md4x.win32-x64.node`        | Windows x86_64          |
| `md4x.win32-arm64.node`      | Windows ARM64           |

Windows targets use `zig dlltool` to generate import libraries from `node_modules/node-api-headers/def/node_api.def`. The `-Dnapi-def` build option can override the `.def` path.

**Exported functions (C-level, raw strings):**

| Function       | Signature                                 |
| -------------- | ----------------------------------------- |
| `renderToHtml` | `(input: string) => string`               |
| `renderToAST`  | `(input: string) => string` (JSON string) |
| `renderToAnsi` | `(input: string) => string`               |
| `renderToMeta` | `(input: string) => string` (JSON string) |
| `renderToText` | `(input: string) => string`               |
| `heal`         | `(input: string) => string`               |

**Usage (via `lib/napi.mjs` wrapper, which parses JSON):**

```js
import { renderToHtml } from "md4x/napi";

const html = renderToHtml("# Hello");
```

The NAPI API is sync. All extensions are enabled by default (`MD_DIALECT_ALL`). `renderToAST` returns the raw JSON string from the AST renderer. `parseAST` parses it into a `ComarkTree` object.

`init(opts?)` is optional for NAPI — the native binding loads lazily on first render call. It accepts an optional options object with a `binding` property to provide a custom NAPI binding.

The JS loader (`lib/napi.mjs`) auto-detects the platform via `process.platform` and `process.arch`, loading `md4x.{platform}-{arch}.node`.

## JS Package Exports

Configured in `packages/md4x/package.json` via `exports`:

| Subpath           | Conditions (in order)                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `md4x` (bare)     | `node` → `lib/napi.mjs`, `unwasm` → `lib/wasm/unwasm.mjs`, `browser` → `lib/standalone.mjs`, else `lib/wasm/default.mjs` |
| `md4x/wasm`       | `unwasm` → `lib/wasm/unwasm.mjs`, `browser` → `lib/standalone.mjs`, else `lib/wasm/default.mjs`                          |
| `md4x/standalone` | `lib/standalone.mjs` (unconditional)                                                                                     |
| `md4x/napi`       | `lib/napi.mjs`                                                                                                           |

Conditions are matched in declaration order, so: Node.js keeps NAPI for the bare entry; an explicitly-enabled `unwasm` build keeps the unwasm module; browser bundlers (Vite, webpack, Rollup with `browser` on) get the self-contained `lib/standalone.mjs` with no `.wasm` asset to emit; everything else loads `build/md4x.wasm` from disk or over the network.

All extensions (`MD_DIALECT_ALL`) are enabled by default. No parser/renderer flag configuration is exposed to JS consumers.

**JS API functions (unified across NAPI and WASM):**

| Function                      | NAPI                                     | WASM                                     |
| ----------------------------- | ---------------------------------------- | ---------------------------------------- |
| `init(opts?)`                 | `Promise<void>` (optional, lazy loading) | `Promise<void>` (required before render) |
| `renderToHtml(input: string)` | `string`                                 | `string`                                 |
| `renderToAST(input: string)`  | `string`                                 | `string`                                 |
| `parseAST(input: string)`     | `ComarkTree`                             | `ComarkTree`                             |
| `renderToAnsi(input: string)` | `string`                                 | `string`                                 |
| `renderToMeta(input: string)` | `string`                                 | `string`                                 |
| `parseMeta(input: string)`    | `ComarkMeta`                             | `ComarkMeta`                             |
| `renderToText(input: string)` | `string`                                 | `string`                                 |
| `yamlToJson(input: string)`   | `string`                                 | `string`                                 |
| `parseYAML(input: string)`    | `unknown`                                | `unknown`                                |
| `heal(input: string)`         | `string`                                 | `string`                                 |

`renderToAST` returns the raw JSON string from the AST renderer. `parseAST` calls `renderToAST` and parses the result into a `ComarkTree` object. `renderToMeta` returns the raw JSON string from the meta renderer. `parseMeta` calls `renderToMeta` and parses the result. Both then fill in `title` — the frontmatter `title` if the document declares one, else the first heading's text — which is the one piece of policy the renderers cannot express, since it spans two of their outputs. See `lib/types.d.ts` for types.

`parseAST` already reports the document's headings in `tree.meta.headings`, so building a table of contents from a tree does **not** need a second pass through `parseMeta`; use `parseMeta` when the AST itself is not wanted.

`parseYAML` converts a standalone YAML document (not Markdown frontmatter) to a JS value, reaching the libyaml the frontmatter path already links in. Any root node is accepted — mapping, sequence or bare scalar — and an empty document yields `null`. `yamlToJson` is the same thing without the `JSON.parse`.

### Heading anchors

`renderToHtml` emits bare `<hN>` by default, matching CommonMark. Pass `headingIds` for anchors:

```js
renderToHtml("# Hello World"); // <h1>Hello World</h1>
renderToHtml("# Hello World", { headingIds: true }); // <h1 id="hello-world">Hello World</h1>
```

The id is the same GitHub-compatible slug `parseAST` and `parseMeta` publish on every heading, de-duplicated the same way, so a table of contents built from `meta.headings` links to anchors this output actually contains. An explicit `{#custom-id}` block attribute on the heading wins over the generated slug, and a heading with no sluggable text gets no `id` at all. The AST and meta outputs carry the id unconditionally — they are Comark's own format, not CommonMark.

### Code block highlighting

Both `renderToHtml` and `renderToAnsi` accept an optional `highlighter` callback:

````js
import { codeToHtml } from "rangi";

const html = renderToHtml("```js [app.js] {1}\nconst x = 1;\n```", {
  highlighter: (code, block) => {
    // code  = "const x = 1;\n"
    // block = { lang: "js", filename?: "app.js", highlights?: [1], prefix?: "  " }
    return codeToHtml(code, { lang: block.lang });
  },
});
````

The callback runs **inside the renderer**, once per fenced or indented code block, in document order:

- Returning a string replaces the block's entire rendering — `<pre><code …>…</code></pre>` for HTML, the dim region for ANSI. For ANSI the renderer re-indents the returned lines with the block's `prefix` (blockquote bars and list indentation included), so a highlighter emits bare lines.
- Returning `undefined` keeps the default rendering for that block, byte for byte. A highlighter may decline per block (unknown language) without any special-casing.
- `code` is the un-escaped block content, trailing newline included. For ANSI it is control-sanitized first, so a fenced block cannot smuggle escape sequences to the terminal through a highlighter that echoes its input.
- The callback **cannot be async**: it runs mid-render, so a returned Promise throws a `TypeError` rather than being stringified into the output. Anything it throws is rethrown from `renderToHtml`/`renderToAnsi` after the renderer has unwound cleanly; the remaining blocks keep their default rendering.

It is a native hook on both bindings — NAPI calls the JS function directly, WASM through the `env.md4x_highlight` import — not a postprocessing pass over the finished string. Inline code spans (`` `x` ``) are never passed to it.

## TypeScript Types (`lib/types.d.ts`)

The package exports TypeScript types for the Comark AST:

- `ComarkTree` — Root container: `{ nodes: ComarkNode[], frontmatter: Record<string, unknown>, meta: Record<string, unknown> }`. `meta` is an open bag that always carries `headings` (and `title`, via `parseAST`); the renderer additionally sets `maxDepthExceeded: true` there when a document nested deeper than the AST renderer's 1024-level cap and the excess was collapsed (see `docs/renderers.md`)
- `ComarkNode` — Either a `ComarkElement` (tuple array) or `ComarkText` (plain string)
- `ComarkElement` — Tuple: `[tag: string | null, props: ComarkElementAttributes, ...children: ComarkNode[]]`
- `ComarkText` — Plain string representing text content
- `ComarkElementAttributes` — Key-value record: `{ [key: string]: unknown }`
- `ComarkMeta` — Metadata object: `{ frontmatter: Record<string, unknown>, headings: ComarkHeading[], title?: string }`
- `ComarkHeading` — Heading entry: `{ level: number, text: string, id: string }`, where `id` is a GitHub-compatible slug de-duplicated within the document (two `## Same` headings yield `same` and `same-1`) and `text` has entities resolved and raw HTML tags excluded

The website playground includes both Vue and React examples that render this AST format (`website/components/ComarkVueRenderer.vue`, `website/components/ComarkReactRenderer.vue`).

## Comark AST Format

The JSON renderer produces a **Comark AST** — a lightweight, array-based format: `{"nodes":[...],"frontmatter":{...},"meta":{"headings":[...]}}`. Each node is either a plain string (text) or an element tuple `[tag, props, ...children]`. Frontmatter YAML is parsed into the top-level `frontmatter` object (not included in `nodes`). HTML comments are represented as `[null, {}, "comment body"]`.

**Shapes that differ from a naive tree walk of the source:**

- **Raw HTML is a node, never loose text.** `["html", {}, "<b>"]` for an inline run and `["html", { "block": true }, "…"]` for an HTML block — one node per source event, so `<b>` and `</b>` stay separate and a literal `<` in prose stays a plain text character. Without this the two are indistinguishable inside one string.
- **Headings carry an `id`** matching `meta.headings[].id`.
- **A paragraph holding only MDC components is unwrapped.** A component written on its own line (`:pm-x{cmd=foo}`) is emitted at block level; one used mid-sentence keeps its paragraph. Matches `markdown-it-mdc`.
- **A `template` slot body that is exactly one paragraph is unwrapped**, the same way a tight list item renders as `["li", {}, "one"]`. A multi-block body keeps its paragraphs.
- **`> [!NOTE]` reports `{"type":"note"}`**, lowercased so the GFM and `::alert{type=note}` spellings of one node agree.

**Property type conventions in AST output:**

| MDC Syntax              | AST Props                        | Description                 |
| ----------------------- | -------------------------------- | --------------------------- |
| `prop="value"`          | `"prop": "value"`                | String prop                 |
| `bool`                  | `":bool": "true"`                | Boolean (`:` prefix in key) |
| `:count="5"`            | `":count": "5"`                  | Number/bind (`:` prefix)    |
| `:data='{"k":"v"}'`     | `":data": "{\"k\":\"v\"}"`       | JSON passthrough            |
| `#my-id`                | `"id": "my-id"`                  | ID shorthand                |
| `.class-one .class-two` | `"class": "class-one class-two"` | Class shorthand (merged)    |

**Key AST mappings:**

- Code blocks: `["pre", {"language": "js", "filename": "app.js", "highlights": [1,2]}, ["code", {"class": "language-js"}, "..."]]`
- Components: `["component-name", {props}, ...children]`
- Slots: `["template", {"name": "slot-name"}, ...children]`
- Images: `["img", {"src": "url", "alt": "text"}]` (void, no children)
- HTML comments: `[null, {}, " comment text "]` — the body slot is always present, so an empty comment (`<!---->`) is `[null, {}, ""]` whether it appeared as a block or inline

## JS Package Testing

Tests use vitest with a shared test suite (`packages/md4x/test/_suite.mjs`) that validates the NAPI, WASM and standalone bindings against the same assertions:

```sh
bunx vitest run                                     # all three bindings
bunx vitest run packages/md4x/test/napi.test.mjs    # NAPI tests
bunx vitest run packages/md4x/test/wasm.test.mjs    # WASM tests
```

**The suites refuse to run against artifacts that do not match `src/`.** `packages/md4x/build/*` and `lib/standalone.mjs` are gitignored build outputs, so `md4x/napi` / `md4x/wasm` / `md4x/standalone` would otherwise happily load a binary built from older sources — or, for a script outside `packages/md4x/`, a **published** `md4x` from `node_modules`. `scripts/js-artifacts.ts` runs as the vitest `globalSetup` and fails the run with the exact rebuild command; `packages/md4x/test/provenance.test.mjs` additionally pins that each bare specifier resolves back into this checkout. Rebuild with:

```sh
bun run build:js     # wasm + wasm-small + host NAPI + standalone
bun run check:js     # report only
```

`bun scripts/run-tests.ts` runs `build:js` and vitest itself, so the full gate needs no separate step. See [.agents/testing.md](../.agents/testing.md#the-js-suites-cannot-run-against-a-stale-or-foreign-artifact).

## JS Package Benchmarks

Benchmarks use `mitata` and compare against `md4w` and `markdown-it`:

```sh
bun run build:js && bun packages/md4x/bench/index.mjs
```

The bench loads the same gitignored artifacts the suites do, but has no `globalSetup` to guard it — build first, or you may be benchmarking a binary from before your change.

## Workspace Setup

The root `package.json` defines a bun workspace (`"workspaces": ["packages/*"]`) with:

- `node-api-headers` — Required for NAPI builds
- `prettier` — Code formatting
- Package manager: `bun@1.3.9`
