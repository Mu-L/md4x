import { applyTitle } from "./_shared.mjs";

// --- internal ---

let binding;

function str(input) {
  if (input == null) return "";
  if (typeof input !== "string")
    throw new TypeError("md4x: input must be a string");
  return input;
}

function getBinding(opts) {
  if (binding) return binding;
  if (opts?.binding) {
    return (binding = opts.binding);
  }
  const { arch, platform } = globalThis.process || {};
  const { createRequire } = globalThis.process?.getBuiltinModule?.("module");
  const isMusl =
    platform === "linux" &&
    !process.report?.getReport?.()?.header?.glibcVersionRuntime;
  return (binding = createRequire(import.meta.url)(
    `../build/md4x.${platform}-${arch}${isMusl ? "-musl" : ""}.node`,
  ));
}

// --- exports ----

export function init(opts) {
  try {
    getBinding(opts);
    return Promise.resolve(binding);
  } catch (err) {
    return Promise.reject(err);
  }
}

const HEAL_FLAG = 0x0100;

/* Skip a leading UTF-8 BOM instead of parsing it as document text. Always on,
   with no option to turn it off: a BOM is an encoding artifact, and leaving it
   in derails the first block — `﻿---` stops looking like a frontmatter
   fence, so the whole frontmatter renders as a setext heading. The CLI has
   always set this; the bindings not setting it was the only flag difference
   between them. The HTML renderer numbers the bit differently from the rest. */
const HTML_BOM_FLAG = 0x0004;
const BOM_FLAG = 0x0002;

export function renderToHtml(input, opts) {
  let flags = HTML_BOM_FLAG | (opts?.full ? 0x0008 : 0);
  if (opts?.headingIds) flags |= 0x0020;
  if (opts?.heal) flags |= HEAL_FLAG;
  // The addon calls `opts.highlighter` synchronously, once per code block, from
  // inside the render — see the hook in src/md4x-napi.zig. A non-function third
  // argument (including undefined) renders without one.
  return getBinding().renderToHtml(str(input), flags, opts?.highlighter);
}

export function renderToAST(input, opts) {
  const flags = BOM_FLAG | (opts?.heal ? HEAL_FLAG : 0);
  return getBinding().renderToAST(str(input), flags);
}

export function parseAST(input, opts) {
  const tree = JSON.parse(renderToAST(input, opts));
  applyTitle(tree.meta, tree.frontmatter);
  return tree;
}

export function renderToAnsi(input, opts) {
  let flags = BOM_FLAG | (opts?.heal ? HEAL_FLAG : 0);
  if (opts?.showUrls) flags |= 0x0010;
  if (opts?.showFrontmatter) flags |= 0x0020;
  return getBinding().renderToAnsi(str(input), flags, opts?.highlighter);
}

export function renderToMeta(input, opts) {
  const flags = BOM_FLAG | (opts?.heal ? HEAL_FLAG : 0);
  return getBinding().renderToMeta(str(input), flags);
}

export function renderToText(input, opts) {
  const flags = BOM_FLAG | (opts?.heal ? HEAL_FLAG : 0);
  return getBinding().renderToText(str(input), flags);
}

export function renderToMarkdown(input, opts) {
  const flags = BOM_FLAG | (opts?.heal ? HEAL_FLAG : 0);
  return getBinding().renderToMarkdown(str(input), flags);
}

export function parseMeta(input, opts) {
  const meta = JSON.parse(renderToMeta(input, opts));
  applyTitle(meta, meta.frontmatter);
  return meta;
}

export function yamlToJson(input) {
  return getBinding().yamlToJson(str(input));
}

export function parseYAML(input) {
  return JSON.parse(yamlToJson(input));
}

export function heal(input) {
  return getBinding().heal(str(input));
}
