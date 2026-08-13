import { bench, compact, run, summary } from "mitata";
import * as napi from "../lib/napi.mjs";
import * as wasm from "../lib/wasm/default.mjs";
import * as md4w from "md4w";
import MarkdownIt from "markdown-it";
import { createMarkdownExit } from "markdown-exit";
import * as satteri from "satteri";
import * as oxContent from "@ox-content/napi";
import * as fixtures from "./_fixtures.mjs";

const markdownIt = new MarkdownIt();
const markdownExit = createMarkdownExit();

// ox-content has GFM off by default; the others enable it, so opt in to match.
const oxOpts = { gfm: true };

// Latest published md4x (C version) aliased as `md4x-c`, for old-vs-new
// comparison. Opt-in via `MD4X_C=1` since it only matters while porting.
const napiC = process.env.MD4X_C ? await import("md4x-c/napi") : undefined;
const wasmC = process.env.MD4X_C ? await import("md4x-c/wasm") : undefined;

// Initialize WASM instances
await wasm.init();
await napi.init();
await wasmC?.init();
await napiC?.init();
await md4w.init();

const inputs = {
  // small: fixtures.small,
  medium: fixtures.medium,
  // large: fixtures.large,
};

for (const [name, input] of Object.entries(inputs)) {
  compact(() => {
    summary(() => {
      bench(`md4x.napi (renderToHtml)`, () => napi.renderToHtml(input));
      bench(`md4x.wasm (renderToHtml)`, () => wasm.renderToHtml(input));
      if (napiC) {
        bench(`md4x-c.napi (renderToHtml)`, () => napiC.renderToHtml(input));
        bench(`md4x-c.wasm (renderToHtml)`, () => wasmC.renderToHtml(input));
      }
      bench(`md4w (renderToHtml)`, () => md4w.mdToHtml(input));
      bench(`markdown-it (renderToHtml)`, () => markdownIt.render(input));
      bench(`markdown-exit (renderToHtml)`, () => markdownExit.render(input));
      bench(`satteri (renderToHtml)`, () => satteri.markdownToHtml(input));
      bench(`ox-content (renderToHtml)`, () =>
        oxContent.parseAndRender(input, oxOpts),
      );
      // const bunToHTML = global.Bun.markdown.html;
      // if (bunToHTML) {
      //   bench(`Bun.markdown.html`, () => bunToHTML(input));
      // }
    });

    // summary(() => {
    //   bench(`md4x.napi (ast) (${name})`, () => napi.renderToAST(input));
    //   bench(`md4x.wasm (ast) (${name})`, () => wasm.renderToAST(input));
    // });

    summary(() => {
      bench(`md4x.napi (parseAST) (${name})`, () => napi.parseAST(input));
      bench(`md4x.wasm (parseAST) (${name})`, () => wasm.parseAST(input));
      if (napiC) {
        bench(`md4x-c.napi (parseAST) (${name})`, () => napiC.parseAST(input));
        bench(`md4x-c.wasm (parseAST) (${name})`, () => wasmC.parseAST(input));
      }
      bench(`md4w (parseAST) (${name})`, () => md4w.mdToJSON(input));
      bench(`markdown-it (parseAST) (${name})`, () =>
        markdownIt.parse(input, {}),
      );
      bench(`markdown-exit (parseAST) (${name})`, () =>
        markdownExit.parse(input, {}),
      );
      bench(`satteri (parseAST) (${name})`, () =>
        satteri.markdownToMdast(input),
      );
      // `.ast` is a JSON string; parse it so this matches the others, which all
      // hand back a materialized tree.
      bench(`ox-content (parseAST) (${name})`, () =>
        JSON.parse(oxContent.parse(input, oxOpts).ast),
      );
    });
  });
}

await run();
