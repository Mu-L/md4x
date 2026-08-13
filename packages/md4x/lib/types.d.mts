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
   * Custom highlighter function for fenced code blocks. If provided, code blocks
   * are passed through this callback which can return custom ANSI-highlighted output.
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
   * Custom highlighter function for fenced code blocks. If provided, code blocks
   * are passed through this callback which can return custom HTML-highlighted output.
   */
  highlighter?: CodeBlockHighlighter;
}

export interface CodeBlock {
  /** Character offset in HTML string where code content starts (after `<code...>`) */
  start: number;
  /** Character offset in HTML string where code content ends (before `</code>`) */
  end: number;
  /** Language identifier (empty string if none) */
  lang: string;
  /** Filename from `[filename]` syntax */
  filename?: string;
  /** Highlighted line numbers from `{1-3,5}` syntax */
  highlights?: number[];
}

export type CodeBlockHighlighter = (
  /** Raw code content (HTML entities unescaped) */
  code: string,
  /** Code block metadata (lang, filename, highlights, offsets) */
  block: CodeBlock,
) => string | undefined;

export interface HtmlWithCodeBlocks {
  /** The HTML string */
  html: string;
  /** Metadata for each fenced code block in document order */
  codeBlocks: CodeBlock[];
}

export interface AnsiCodeBlock {
  /** Character offset in ANSI string where code block starts (including DIM escape) */
  start: number;
  /** Character offset in ANSI string where code block ends (including DIM_OFF escape) */
  end: number;
  /** Language identifier (empty string if none) */
  lang: string;
  /** Filename from `[filename]` syntax */
  filename?: string;
  /** Highlighted line numbers from `{1-3,5}` syntax */
  highlights?: number[];
  /** Line indent prefix (includes ANSI escapes for colored bars in nested contexts) */
  prefix?: string;
}

export type AnsiCodeBlockHighlighter = (
  /** Raw code content (indentation stripped) */
  code: string,
  /** Code block metadata (lang, filename, highlights, offsets) */
  block: AnsiCodeBlock,
) => string | undefined;
