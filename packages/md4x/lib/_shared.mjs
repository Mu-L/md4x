const decoder = new TextDecoder();

function parseCodeMeta(bytes, extraFields) {
  const nullIdx = bytes.indexOf(0);
  if (nullIdx === -1) {
    return { output: decoder.decode(bytes), codeBlocks: [] };
  }
  const outBytes = bytes.subarray(0, nullIdx);
  const metaBytes = bytes.subarray(nullIdx + 1);
  const output = decoder.decode(outBytes);
  const meta = JSON.parse(decoder.decode(metaBytes));
  const codeBlocks = meta.map((m) => {
    const start = decoder.decode(outBytes.subarray(0, m.s)).length;
    const end = decoder.decode(outBytes.subarray(0, m.e)).length;
    const block = { start, end, lang: m.l || "" };
    if (m.f) block.filename = m.f;
    if (m.h) block.highlights = m.h;
    if (extraFields) extraFields(block, m);
    return block;
  });
  return { output, codeBlocks };
}

export function parseHtmlMeta(bytes) {
  const { output, codeBlocks } = parseCodeMeta(bytes);
  return { html: output, codeBlocks };
}

export function parseHtmlWithHighlighting(bytes, highlighter) {
  const { html, codeBlocks } = parseHtmlMeta(bytes);
  if (codeBlocks.length === 0) return html;
  let out = "";
  let pos = 0;
  for (const block of codeBlocks) {
    const code = unescapeHtml(html.slice(block.start, block.end));
    const highlighted = highlighter(code, block);
    if (highlighted === undefined) {
      out += html.slice(pos, block.end);
    } else {
      // Calculate <pre><code...> prefix length to replace the full wrapper
      const preLen = block.lang
        ? '<pre><code class="language-'.length + block.lang.length + '">'.length
        : "<pre><code>".length;
      out += html.slice(pos, block.start - preLen);
      out += highlighted;
      pos = block.end + "</code></pre>\n".length;
      continue;
    }
    pos = block.end;
  }
  out += html.slice(pos);
  return out;
}

function unescapeHtml(str) {
  if (!str.includes("&")) return str;
  return str
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"');
}

const DIM = "\x1b[2m";
const DIM_OFF = "\x1b[22m";

export function parseAnsiMeta(bytes) {
  const { output, codeBlocks } = parseCodeMeta(bytes, (block, m) => {
    if (m.i) block.prefix = m.i;
  });
  return { ansi: output, codeBlocks };
}

export function parseAnsiWithHighlighting(bytes, highlighter) {
  const { ansi, codeBlocks } = parseAnsiMeta(bytes);
  if (codeBlocks.length === 0) return ansi;
  let out = "";
  let pos = 0;
  for (const block of codeBlocks) {
    const region = ansi.slice(block.start, block.end);
    const prefix = block.prefix || "  ";
    // Strip DIM wrapper and extract raw code by removing prefix from each line
    let inner = region;
    if (inner.startsWith(DIM)) inner = inner.slice(DIM.length);
    if (inner.endsWith(DIM_OFF)) inner = inner.slice(0, -DIM_OFF.length);
    const code = inner
      .split("\n")
      .filter((l) => l.length > 0)
      .map((l) => (l.startsWith(prefix) ? l.slice(prefix.length) : l))
      .join("\n");
    const highlighted = highlighter(code, block);
    if (highlighted === undefined) {
      out += ansi.slice(pos, block.end);
    } else {
      out += ansi.slice(pos, block.start);
      // Wrap each line with the indent prefix
      const lines = highlighted.split("\n");
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].length > 0) {
          out += prefix + lines[i];
        }
        if (i < lines.length - 1) {
          out += "\n";
        }
      }
      // Ensure trailing newline
      if (!highlighted.endsWith("\n")) out += "\n";
      pos = block.end;
      continue;
    }
    pos = block.end;
  }
  out += ansi.slice(pos);
  return out;
}
