/**
 * The suites import `md4x/napi`, `md4x/wasm` and `md4x/standalone` by bare
 * specifier. Those names also belong to the *published* package, and a
 * `node_modules/md4x` on the resolution path resolves them successfully and
 * silently — one scratch script in this repo has already ended up benchmarking
 * md4x@0.0.26 from bun's install cache while appearing to test local code.
 *
 * What saves the test files today is package self-reference: they live inside
 * `packages/md4x/`, whose package.json is named `md4x` and has `exports`, so the
 * specifier resolves back into this directory before node_modules is consulted.
 * That is a property of the resolver and of package.json — not something the
 * suite states anywhere. These assertions state it: each bare specifier must
 * yield the very same module instance as the local file behind it.
 *
 * The complementary check — that no published md4x is installed on the
 * resolution path at all, which is what bites scripts *outside* this directory —
 * runs in the vitest globalSetup (scripts/js-artifacts.ts).
 */
import { describe, expect, it } from "vitest";

import * as napiSpecifier from "md4x/napi";
import * as napiLocal from "../lib/napi.mjs";
import * as wasmSpecifier from "md4x/wasm";
import * as wasmLocal from "../lib/wasm/default.mjs";
import * as standaloneSpecifier from "md4x/standalone";
import * as standaloneLocal from "../lib/standalone.mjs";

describe("provenance: bare specifiers resolve into this checkout", () => {
  it.each([
    ["md4x/napi", "lib/napi.mjs", napiSpecifier, napiLocal],
    ["md4x/wasm", "lib/wasm/default.mjs", wasmSpecifier, wasmLocal],
    [
      "md4x/standalone",
      "lib/standalone.mjs",
      standaloneSpecifier,
      standaloneLocal,
    ],
  ])("%s is packages/md4x/%s", (specifier, file, viaSpecifier, viaPath) => {
    // Same module instance => same resolved file. A published copy would give a
    // second, distinct instance.
    expect(
      viaSpecifier.renderToHtml,
      `${specifier} did not resolve to packages/md4x/${file} — something (a stray ` +
        `node_modules/md4x, a bundler alias, or a renamed package.json) is ` +
        `shadowing this checkout, and the suite would be testing that instead.`,
    ).toBe(viaPath.renderToHtml);
  });
});
