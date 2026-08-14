/**
 * Fill in `meta.title`: the frontmatter `title` if the document declares one,
 * otherwise the first heading's text.
 *
 * Derived here rather than in the renderer because it spans two of the
 * renderer's outputs — `parseAST` keeps frontmatter in `tree.frontmatter` and
 * headings in `tree.meta`, and they are separate objects in `parseMeta` too.
 * Left absent when there is neither, so `"title" in meta` still means something.
 */
export function applyTitle(meta, frontmatter) {
  if (!meta) return;
  const title = frontmatter?.title ?? meta.headings?.[0]?.text;
  if (title !== undefined) meta.title = title;
}
