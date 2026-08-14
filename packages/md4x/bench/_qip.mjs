// qip.dev's markdown-to-html component (https://qip.dev/markdown-to-html).
//
// It ships as a bare .wasm artifact rather than an npm package, so there is
// nothing to put in devDependencies: fetch it once and cache it next to this
// file (bench/.cache is gitignored). If the download fails, `load()` returns
// `undefined` and the caller drops the entry rather than failing the whole run.

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const VERSION = "gfm-commonmark.0.31.2";
const URL = `https://qip.dev/components/text/markdown/${VERSION}.wasm`;

const cacheFile = join(
  dirname(fileURLToPath(import.meta.url)),
  ".cache",
  `${VERSION}.wasm`,
);

async function bytes() {
  if (existsSync(cacheFile)) return readFileSync(cacheFile);
  const res = await fetch(URL);
  if (!res.ok) throw new Error(`GET ${URL} -> ${res.status}`);
  const buf = new Uint8Array(await res.arrayBuffer());
  mkdirSync(dirname(cacheFile), { recursive: true });
  writeFileSync(cacheFile, buf);
  return buf;
}

/**
 * @returns {Promise<((source: string) => string) | undefined>} `renderToHtml`,
 * or `undefined` if the component could not be fetched.
 */
export async function load() {
  let exports;
  try {
    ({
      instance: { exports },
    } = await WebAssembly.instantiate(await bytes(), {}));
  } catch (error) {
    console.warn(`[bench] skipping qip: ${error.message}`);
    return undefined;
  }

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  // The component renders through fixed in/out buffers inside its own memory
  // (2 MiB each) — no allocator, no imports. Copy in, render, copy out.
  return function renderToHtml(source) {
    const { memory, input_ptr, input_utf8_cap, output_ptr, render } = exports;
    const input = encoder.encode(source);
    if (input.length > input_utf8_cap()) {
      throw new RangeError("Markdown input is too large");
    }
    new Uint8Array(memory.buffer, input_ptr(), input.length).set(input);
    const size = render(input.length);
    return decoder.decode(new Uint8Array(memory.buffer, output_ptr(), size));
  };
}
