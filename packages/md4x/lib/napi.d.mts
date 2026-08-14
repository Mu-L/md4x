import type {
  ComarkTree,
  ComarkMeta,
  HtmlOptions,
  AnsiOptions,
  RenderOptions,
  CodeBlockHighlighter,
  AnsiCodeBlockHighlighter,
} from "./types.mjs";

export type {
  ComarkTree,
  ComarkNode,
  ComarkElement,
  ComarkText,
  ComarkElementAttributes,
  ComarkHeading,
  ComarkMeta,
  HtmlOptions,
  AnsiOptions,
  RenderOptions,
} from "./types.mjs";

export type * from "./types.mjs";

export interface NAPIBinding {
  renderToHtml(
    input: string,
    flags?: number,
    highlighter?: CodeBlockHighlighter,
  ): string;
  renderToAST(input: string, flags?: number): string;
  renderToAnsi(
    input: string,
    flags?: number,
    highlighter?: AnsiCodeBlockHighlighter,
  ): string;
  renderToMeta(input: string, flags?: number): string;
  renderToText(input: string, flags?: number): string;
  renderToMarkdown(input: string, flags?: number): string;
  heal(input: string): string;
}

export interface InitOptions {
  binding?: NAPIBinding;
}

export declare function init(opts?: InitOptions): Promise<void>;
export declare function renderToHtml(input: string, opts?: HtmlOptions): string;
export declare function renderToAST(
  input: string,
  opts?: RenderOptions,
): string;
export declare function parseAST(
  input: string,
  opts?: RenderOptions,
): ComarkTree;
export declare function renderToAnsi(input: string, opts?: AnsiOptions): string;
export declare function renderToMeta(
  input: string,
  opts?: RenderOptions,
): string;
export declare function parseMeta(
  input: string,
  opts?: RenderOptions,
): ComarkMeta;
export declare function renderToText(
  input: string,
  opts?: RenderOptions,
): string;
export declare function renderToMarkdown(
  input: string,
  opts?: RenderOptions,
): string;
/**
 * Parse a standalone YAML document (not Markdown frontmatter) to a JS value.
 * Any root node is accepted — mapping, sequence or bare scalar — and an empty
 * document yields `null`.
 */
export declare function parseYAML(input: string): unknown;

/** {@link parseYAML} without the `JSON.parse`. */
export declare function yamlToJson(input: string): string;

export declare function heal(input: string): string;
