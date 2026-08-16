export type ComarkTree = {
  nodes: ComarkNode[];
  frontmatter: Record<string, unknown>;
  /**
   * Open bag. `headings` is always present — building a table of contents from
   * a tree needs no second parse through {@link parseMeta}.
   *
   * `maxDepthExceeded: true` means the document nested deeper than the AST
   * renderer's 1024-level cap: the content past it is preserved but flattened
   * into the deepest node that fit, so the tree is shallower than the source.
   */
  meta: Record<string, unknown> & {
    headings: ComarkHeading[];
    /** Frontmatter `title`, else the first heading's text. */
    title?: string;
    maxDepthExceeded?: true;
  };
};

export type ComarkNode = ComarkElement | ComarkText;

/**
 * Text content, with HTML entities already resolved (`A &amp; B` -> `A & B`).
 * Escape it as you would any other string when rendering. Literal content —
 * code spans, fenced code, math, raw `html` nodes — keeps its source bytes.
 */
export type ComarkText = string;

export type ComarkElement = [
  tag: string | null,
  props: ComarkElementAttributes,
  ...children: ComarkNode[],
];

export type ComarkElementAttributes = {
  [key: string]: unknown;
};

export type ComarkHeading = {
  level: number;
  /** Rendered text: entities resolved, raw HTML tags excluded. */
  text: string;
  /**
   * GitHub-compatible anchor slug, de-duplicated within the document — two
   * `## Same` headings get `same` and `same-1`. The same string the heading
   * node carries as its `id` prop.
   */
  id: string;
};

export type ComarkMeta = {
  frontmatter: Record<string, unknown>;
  headings: ComarkHeading[];
  /** Frontmatter `title`, else the first heading's text. */
  title?: string;
};

export interface RenderOptions {
  /** Heal incomplete/streaming Markdown before rendering. */
  heal?: boolean;
}

export interface AnsiOptions extends RenderOptions {
  /**
   * Highlighter for fenced code blocks, called during the render — see
   * {@link AnsiCodeBlockHighlighter}.
   */
  highlighter?: AnsiCodeBlockHighlighter;
  /** Show link URLs after link text (e.g. `text (url)`). Default: false (links are clickable via OSC 8). */
  showUrls?: boolean;
  /** Show frontmatter content as dim text. Default: false (frontmatter is suppressed). */
  showFrontmatter?: boolean;
}

export interface HtmlOptions extends RenderOptions {
  /** Generate a full HTML document with `<!DOCTYPE html>`, `<head>`, and `<body>`. */
  full?: boolean;

  /**
   * Add an `id="..."` anchor to every heading: a GitHub-compatible slug of the
   * heading text, de-duplicated within the document, and the same id
   * {@link ComarkHeading} carries — so a table of contents built from
   * `parseMeta` links to the headings this output emits. An explicit `{#id}`
   * on the heading wins over the generated one.
   *
   * Default: false, so the output stays CommonMark-exact.
   */
  headingIds?: boolean;

  /**
   * Highlighter for fenced code blocks, called during the render — see
   * {@link CodeBlockHighlighter}.
   */
  highlighter?: CodeBlockHighlighter;
}

export interface CodeBlock {
  /** Language identifier (empty string if none) */
  lang: string;
  /** Filename from `[filename]` syntax */
  filename?: string;
  /** Highlighted line numbers from `{1-3,5}` syntax */
  highlights?: number[];
}

/**
 * Called once per fenced or indented code block, **synchronously, during the
 * render** — the renderer emits what it returns in place of its own
 * `<pre><code>…</code></pre>`, so there is nothing to splice and no offsets to
 * track. Returning `undefined` keeps the default rendering for that block.
 *
 * Because it runs inside the renderer it cannot be `async`: a returned Promise
 * throws a `TypeError` rather than being stringified into the output.
 */
export type CodeBlockHighlighter = (
  /** Raw code content (HTML entities unescaped) */
  code: string,
  /** Code block metadata (lang, filename, highlights) */
  block: CodeBlock,
) => string | undefined;

export interface AnsiCodeBlock {
  /** Language identifier (empty string if none) */
  lang: string;
  /** Filename from `[filename]` syntax */
  filename?: string;
  /** Highlighted line numbers from `{1-3,5}` syntax */
  highlights?: number[];
  /**
   * Line indent the renderer puts in front of every code line (includes ANSI
   * escapes for the colored bars of a blockquote or alert). Informational: the
   * renderer re-applies it to the returned lines, so a highlighter neither
   * receives it in `code` nor has to emit it.
   */
  prefix?: string;
}

/** {@link CodeBlockHighlighter} for `renderToAnsi`. Returns terminal escapes. */
export type AnsiCodeBlockHighlighter = (
  /** Raw code content (indentation stripped, terminal control bytes neutralized) */
  code: string,
  /** Code block metadata (lang, filename, highlights, prefix) */
  block: AnsiCodeBlock,
) => string | undefined;
