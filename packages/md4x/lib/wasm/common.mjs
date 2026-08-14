import { applyTitle } from "../_shared.mjs";

// --- internal ---

let _instance;

const decoder = new TextDecoder();
const encoder = new TextEncoder();

// The highlighter of the render currently in flight, and the error it threw (if
// any). WASM is single-threaded and the renderers are synchronous, so one slot
// is enough — but a highlighter may itself render, so `withHighlighter` saves
// and restores rather than assigning.
let _highlighter;
let _highlightError;

// One reusable buffer in linear memory for highlighter replies, grown on
// demand and never freed: the renderer copies each reply out before asking for
// the next block, so allocating per code block would be pure churn. Kept per
// instance so a second `init()` does not hand out a stale address.
let _replyBuffer = { instance: undefined, ptr: 0, size: 0 };

function replyBuffer(exports, size) {
  if (_replyBuffer.instance === _instance && _replyBuffer.size >= size) {
    return _replyBuffer.ptr;
  }
  if (_replyBuffer.instance === _instance && _replyBuffer.ptr) {
    exports.md4x_free(_replyBuffer.ptr);
  }
  const capacity = Math.max(size, 8192);
  const ptr = exports.md4x_alloc(capacity);
  _replyBuffer = ptr
    ? { instance: _instance, ptr, size: capacity }
    : { instance: undefined, ptr: 0, size: 0 };
  return ptr;
}

export function _hasInstance() {
  return !!_instance;
}

export function _setInstance(instance) {
  _instance = instance;
}

export function _getExports() {
  if (!_instance?.exports) {
    throw new Error("md4x: WASM not initialized. Call `await init()` first.", {
      cause: { instance: _instance },
    });
  }
  return _instance.exports;
}

export const _imports = {
  // The syntax-highlight hook. The renderer calls out here once per fenced or
  // indented code block while `_highlighter` is set (see `withHighlighter`);
  // the module imports it unconditionally, so every loader must pass `_imports`
  // whether or not anything highlights.
  //
  // Arguments are (address, length) pairs into linear memory; the reply is 0 to
  // decline the block, or the address of a buffer holding a u32 little-endian
  // length followed by that many UTF-8 bytes. That buffer stays ours and is
  // reused for every block (see `replyBuffer`) — the renderer copies the bytes
  // out before it asks for the next one.
  env: {
    md4x_highlight: (
      codePtr,
      codeLen,
      langPtr,
      langLen,
      filePtr,
      fileLen,
      hlPtr,
      hlLen,
      prefixPtr,
      prefixLen,
    ) => {
      // A highlighter that already threw declines the rest of the document:
      // the error is rethrown once the render returns, so the renderer is
      // never unwound through mid-block.
      if (!_highlighter || _highlightError) return 0;
      const exports = _instance.exports;
      const mem = new Uint8Array(exports.memory.buffer);
      const text = (ptr, len) => decoder.decode(mem.subarray(ptr, ptr + len));

      const code = text(codePtr, codeLen);
      const block = { lang: langLen ? text(langPtr, langLen) : "" };
      if (fileLen) block.filename = text(filePtr, fileLen);
      if (prefixLen) block.prefix = text(prefixPtr, prefixLen);
      if (hlLen) {
        block.highlights = Array.from(
          new Uint32Array(exports.memory.buffer, hlPtr, hlLen),
        );
      }

      let result;
      try {
        result = _highlighter(code, block);
      } catch (error) {
        _highlightError = error;
        return 0;
      }
      if (result === undefined || result === null) return 0;
      if (typeof result !== "string") {
        _highlightError = new TypeError(
          "md4x: highlighter must return a string or undefined (it runs synchronously)",
        );
        return 0;
      }

      const bytes = encoder.encode(result);
      const ptr = replyBuffer(exports, 4 + bytes.length);
      if (!ptr) {
        _highlightError = new Error("md4x: out of memory");
        return 0;
      }
      // The reply buffer may have just been (re)allocated, and growing the
      // memory detaches every view taken before it — including `mem` above.
      const buffer = exports.memory.buffer;
      new DataView(buffer).setUint32(ptr, bytes.length, true);
      new Uint8Array(buffer).set(bytes, ptr + 4);
      return ptr;
    },
  },
  wasi_snapshot_preview1: {
    args_get: () => 0,
    args_sizes_get: () => 0,
    environ_get: () => 0,
    environ_sizes_get: () => 0,
    fd_close: () => 0,
    fd_filestat_get: () => 0,
    fd_pwrite: () => 0,
    fd_read: () => 0,
    fd_seek: () => 0,
    fd_write: () => 0,
    proc_exit: () => {},
    random_get: (buf, len) => {
      const bytes = new Uint8Array(_instance.exports.memory.buffer, buf, len);
      crypto.getRandomValues(bytes);
      return 0;
    },
  },
};

function str(input) {
  if (input == null) return "";
  if (typeof input !== "string")
    throw new TypeError("md4x: input must be a string");
  return input;
}

function render(exports, fn, input, ...extra) {
  const { memory, md4x_alloc, md4x_free, md4x_result_ptr, md4x_result_size } =
    exports;
  const encoded = encoder.encode(str(input));
  const ptr = md4x_alloc(encoded.length);
  new Uint8Array(memory.buffer).set(encoded, ptr);
  const ret = fn(ptr, encoded.length, ...extra);
  md4x_free(ptr);
  if (ret !== 0) {
    throw new Error("md4x: render failed");
  }
  const outPtr = md4x_result_ptr();
  const outSize = md4x_result_size();
  const result = decoder.decode(new Uint8Array(memory.buffer, outPtr, outSize));
  md4x_free(outPtr);
  return result;
}

/* Render through a `*_hl` entry point, with `highlighter` installed for the
   duration. The highlighter runs inside the render (see the `env.md4x_highlight`
   import); anything it throws is held until the renderer has returned and freed
   its buffers, then rethrown here. */
function withHighlighter(exports, fn, input, flags, highlighter) {
  const prevHighlighter = _highlighter;
  const prevError = _highlightError;
  _highlighter = highlighter;
  _highlightError = undefined;
  let out;
  try {
    out = render(exports, fn, input, flags);
  } finally {
    _highlighter = prevHighlighter;
  }
  const error = _highlightError;
  _highlightError = prevError;
  if (error) throw error;
  return out;
}

const HEAL_FLAG = 0x0100;

export function renderToHtml(input, opts) {
  let flags = opts?.full ? 0x0008 : 0;
  if (opts?.heal) flags |= HEAL_FLAG;
  const exports = _getExports();
  if (!opts?.highlighter) {
    return render(exports, exports.md4x_to_html, input, flags);
  }
  return withHighlighter(
    exports,
    exports.md4x_to_html_hl,
    input,
    flags,
    opts.highlighter,
  );
}

export function renderToAST(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_ast, input, flags);
}

export function parseAST(input, opts) {
  const tree = JSON.parse(renderToAST(input, opts));
  applyTitle(tree.meta, tree.frontmatter);
  return tree;
}

export function renderToAnsi(input, opts) {
  let flags = opts?.heal ? HEAL_FLAG : 0;
  if (opts?.showUrls) flags |= 0x0010;
  if (opts?.showFrontmatter) flags |= 0x0020;
  const exports = _getExports();
  if (!opts?.highlighter) {
    return render(exports, exports.md4x_to_ansi, input, flags);
  }
  return withHighlighter(
    exports,
    exports.md4x_to_ansi_hl,
    input,
    flags,
    opts.highlighter,
  );
}

export function renderToMeta(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_meta, input, flags);
}

export function renderToText(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_text, input, flags);
}

export function renderToMarkdown(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_markdown, input, flags);
}

export function parseMeta(input, opts) {
  const meta = JSON.parse(renderToMeta(input, opts));
  applyTitle(meta, meta.frontmatter);
  return meta;
}

export function yamlToJson(input) {
  const exports = _getExports();
  return render(exports, exports.md4x_yaml_to_json, input);
}

export function parseYAML(input) {
  return JSON.parse(yamlToJson(input));
}

export function heal(input) {
  const exports = _getExports();
  return render(exports, exports.md4x_heal, input);
}
