/**
 * GitHub Markdown parity harness.
 *
 * md4x has one dialect, and GitHub is what it is measured against (see
 * `.agents/github-parity.md`). This script renders a corpus through both md4x
 * and GitHub's Markdown API, strips GitHub's presentation layer, compares, and
 * classifies whatever is left.
 *
 *   bun scripts/gh-parity.ts            # compare against the committed baseline
 *   bun scripts/gh-parity.ts --update   # re-record the baseline
 *   bun scripts/gh-parity.ts --suite=spec-alerts.txt   # one suite only
 *   bun scripts/gh-parity.ts --verbose  # print every divergence's HTML
 *
 * Needs a GitHub token: `gh auth token` is used if present, else $GITHUB_TOKEN.
 * Responses are cached under node_modules/.cache/gh-parity/ (gitignored), keyed
 * by a hash of the input, so re-runs after an md4x change cost no API calls.
 *
 * The baseline records a *cause* per divergence, not just a count. Most of them
 * are things md4x deliberately does not chase -- GitHub's HTML sanitizer, its
 * autolink scheme allowlist, its older Unicode tables -- so a raw score would be
 * meaningless. What matters is the `unclassified` bucket: those are the ones
 * nobody has explained yet.
 */

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const selfPath = dirname(fileURLToPath(import.meta.url));
const projectDir = resolve(selfPath, "..");
const testDir = join(projectDir, "test");
const cacheDir = join(projectDir, "node_modules/.cache/gh-parity");
const baselinePath = join(testDir, "gh-parity.baseline.json");

/**
 * The corpus. spec.txt is the CommonMark core; the rest are the extensions md4x
 * shares with GitHub.
 *
 * Suites for md4x-only syntax (components, attributes, latex,
 * frontmatter) are absent on purpose: GitHub renders their inputs as literal
 * text, so every case would be a known divergence and would tell us nothing.
 */
const SUITES = [
  "spec.txt",
  "spec-gfm.txt",
  "spec-tables.txt",
  "spec-tasklists.txt",
  "spec-footnotes.txt",
  "spec-alerts.txt",
  "spec-strikethrough.txt",
  "spec-permissive-autolinks.txt",
];

/**
 * GitHub exposes two renderers through one API and neither is a superset of the
 * other, so every case is measured against both and counts as parity if it
 * matches either.
 *
 *   mode=markdown  document renderer. Soft breaks stay soft. Renders tables,
 *                  strikethrough and footnotes (with clean, unsalted ids), but
 *                  leaves `- [x]` and `> [!NOTE]` as literal text.
 *   mode=gfm       comment renderer. Renders task lists and alerts -- the only
 *                  mode that does -- but hard-wraps every soft break into a
 *                  <br>, salts footnote ids with a per-document hash, and wraps
 *                  tables in <markdown-accessiblity-table>.
 *
 * Choosing one mode for the whole corpus is the trap here. `gfm` looks like the
 * more GFM-ish name and quietly turns every soft break in the CommonMark core
 * into a hard one; `markdown` silently scores every task list and alert as a
 * divergence. Per-suite selection does not work either, because the suites are
 * mixed -- spec-gfm.txt alone covers tables, task lists and autolinks.
 */
const MODES = ["markdown", "gfm"] as const;
type Mode = (typeof MODES)[number];

type Case = { suite: string; n: number; md: string };
type Verdict = { suite: string; n: number; cause: string };

/**
 * Split a suite file into cases.
 *
 * The three delimiters -- opening fence, the `.` separator, closing fence -- are
 * matched against the *trimmed* line, because `test/run-testsuite.py` trims
 * before matching and a suite may indent a whole example to sit inside a list
 * item (`test/spec-permissive-autolinks.txt` does, for the `john__doe@` case).
 * Matching at column 0 skipped that example entirely, so the harness measured
 * 791 cases over a 792-case corpus. Trimming only the delimiters and not the
 * body keeps the case's Markdown byte-identical to what the Python runner feeds
 * the CLI -- the leading indent is part of the input under test.
 */
function parseSuite(suite: string): Case[] {
  const text = readFileSync(join(testDir, suite), "utf8");
  const cases: Case[] = [];
  let state = 0;
  let md: string[] = [];
  for (const line of text.split("\n")) {
    const marker = line.trim();
    if (state === 0 && /^`{32} example/.test(marker)) {
      state = 1;
      md = [];
    } else if (state === 1 && marker === ".") {
      state = 2;
    } else if (state === 2 && /^`{32}$/.test(marker)) {
      cases.push({
        suite,
        n: cases.length + 1,
        // The spec files write tabs as U+2192 so they survive editing.
        md: md.length ? md.join("\n").replaceAll("→", "\t") + "\n" : "",
      });
      state = 0;
    } else if (state === 1) {
      md.push(line);
    }
  }
  return cases;
}

// --- GitHub ---------------------------------------------------------------

function githubToken(): string {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
  try {
    return execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();
  } catch {
    throw new Error(
      "gh-parity needs a GitHub token: run `gh auth login` or set $GITHUB_TOKEN",
    );
  }
}

async function renderGitHub(
  token: string,
  md: string,
  mode: Mode,
): Promise<string> {
  const key = createHash("sha256").update(`${mode}\0${md}`).digest("hex");
  const cached = join(cacheDir, `${key}.html`);
  if (existsSync(cached)) return readFileSync(cached, "utf8");

  for (let attempt = 0; ; attempt++) {
    const res = await fetch("https://api.github.com/markdown", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "content-type": "application/json",
      },
      body: JSON.stringify({ text: md, mode }),
    });
    if (res.ok) {
      const html = await res.text();
      mkdirSync(cacheDir, { recursive: true });
      writeFileSync(cached, html);
      return html;
    }
    // Secondary rate limits are the common failure and they clear on their own.
    if ((res.status === 403 || res.status === 429) && attempt < 4) {
      const wait = 20_000 * (attempt + 1);
      console.error(`  rate limited, retrying in ${wait / 1000}s`);
      await new Promise((r) => setTimeout(r, wait));
      continue;
    }
    throw new Error(`GitHub API ${res.status}: ${await res.text()}`);
  }
}

/**
 * Strip GitHub's presentation layer, which sits downstream of its Markdown
 * parser and has nothing to say about parity: heading anchor wrappers, the
 * `notranslate` class, syntax-highlight markup, the `<a>` that wraps every
 * image, `rel="nofollow"`. What survives is comparable to md4x's output.
 */
function destyle(html: string, mode: Mode): string {
  const base = html
    .replace(
      /<div class="markdown-heading">(<h[1-6]) class="heading-element">(.*?)<\/h([1-6])><a id="user-content-[^"]*" class="anchor"[^>]*>.*?<\/a><\/div>/gs,
      "$1>$2</h$3>",
    )
    .replace(
      /<div class="highlight highlight-[^"]*"><pre[^>]*>(.*?)<\/pre><\/div>/gs,
      "<pre><code>$1</code></pre>",
    )
    .replace(/<span class="pl-[^"]*">(.*?)<\/span>/gs, "$1")
    .replace(
      /<a target="_blank" rel="noopener noreferrer" href="[^"]*">(<img .*?>)<\/a>/gs,
      "$1",
    )
    .replaceAll(' style="max-width: 100%;"', "")
    .replace(/\s*class="notranslate"/g, "")
    .replace(/\s*rel="nofollow"/g, "")
    .replace(/\s*rel="noopener noreferrer"/g, "")
    .replace(/\s*target="_blank"/g, "")
    // Camo: GitHub proxies every external image through its own host and keeps
    // the original in data-canonical-src. Put the original back.
    .replace(
      /<a href="https:\/\/camo\.githubusercontent\.com\/[^"]*">(<img [^>]*>)<\/a>/g,
      "$1",
    )
    .replace(
      /<img src="https:\/\/camo\.githubusercontent\.com\/[^"]*"([^>]*?) data-canonical-src="([^"]*)"/g,
      '<img src="$2"$1',
    )
    .replace(/\s*rel="noopener noreferrer nofollow"/g, "")
    // GitHub namespaces every generated anchor to keep user content from
    // colliding with its own chrome. Not a Markdown-level decision.
    .replace(/(id|href)="#?user-content-/g, (m) =>
      m.replace("user-content-", ""),
    )
    .replace(ALERT_OCTICON, "");
  if (mode === "markdown") return base;
  // Comment-mode artifacts, none of which say anything about parity: every soft
  // break becomes a <br>, footnote ids carry a per-document hash so two renders
  // of the same page cannot collide, and tables gain an accessibility shell.
  return base
    .replace(/<br>\n?/g, "\n")
    .replace(/(fn(?:ref)?-\d+)-[0-9a-f]{32}/g, "$1")
    .replace(/<\/?markdown-accessiblity-table>/g, "")
    .replace(/ role="table"/g, "");
}

/**
 * GitHub's alert title row carries an inline octicon SVG -- ~700 bytes of path
 * data that renders as an icon, not as text. md4x emits the same title row
 * without it (icons are the stylesheet's job, see .agents/github-parity.md).
 *
 * Only the SVG is stripped, not the row: both renderers now generate a title,
 * so the label itself is comparable and worth comparing. Blanking the whole row
 * on both sides -- which is what this did while only GitHub emitted one -- would
 * hide a title-casing regression in md4x for good.
 */
const ALERT_OCTICON = /<svg[^>]*class="octicon[^"]*"[^>]*>.*?<\/svg>/gs;

/**
 * Whitespace-insensitive comparison, in the spirit of the CommonMark spec's own
 * normalizer: whitespace between tags and inside text runs carries no meaning in
 * HTML, but inside <pre> every byte does.
 */
function normalize(html: string): string {
  const pres: string[] = [];
  const parked = html.replace(/<pre[\s\S]*?<\/pre>/g, (m) => {
    pres.push(m);
    return ` ${pres.length - 1} `;
  });
  const collapsed = parked.replace(/>\s+</g, "><").replace(/\s+/g, " ").trim();
  return collapsed.replace(/ (\d+) /g, (_, i) => pres[Number(i)]);
}

// --- Classification -------------------------------------------------------

/**
 * Why this case diverges. Ordered most-specific first; `unclassified` is the
 * bucket that matters -- everything else is a decision already taken.
 */
function classify(md: string, ours: string, theirs: string): string {
  const hasRawHtml = RAW_HTML.test(md);

  // md4x extensions GitHub does not have: our output turned syntax into markup
  // that GitHub left as literal text.
  if (/^---\r?\n/.test(md) && /<hr\s*\/?>/.test(theirs) && !/<hr/.test(ours)) {
    return "md4x-extension";
  }
  // The general case: syntax only md4x knows survives verbatim in GitHub's
  // output while ours turned it into markup. `==mark==`, `:component[]`,
  // `{#attrs}`, `$latex$`, `> [!ALERT]` labels GitHub does not define.
  for (const probe of MD4X_ONLY) {
    if (probe.test(md) && probe.test(theirs) && !probe.test(ours)) {
      return "md4x-extension";
    }
  }

  // GitHub re-serializes through an HTML parser, which unescapes &quot; that
  // CommonMark leaves escaped. Tested *before* the sanitizer rules because it
  // is exact whole-document equality: if the two outputs differ only in how a
  // quote is spelled, then nothing was dropped, closed or rebalanced and the
  // sanitizer had no hand in it. Ordering it after let the crude length
  // heuristic below claim `</a href="foo">` once the raw-HTML gate widened.
  if (quoteFolded(ours) === quoteFolded(theirs)) return "entity-escaping";

  // GitHub rebalances and filters raw HTML through a sanitizer before serving
  // it: inserted <tbody>, closed-for-you tags, dropped unknown elements. Gated
  // on the input actually containing raw HTML -- without that gate this rule
  // swallows genuine block-parsing divergences that merely happen to produce a
  // table on one side.
  if (hasRawHtml) {
    if (/<tbody>/.test(theirs) && !/<tbody>/.test(ours)) return "sanitizer";
    if (/<(script|iframe|style|title|textarea)\b/i.test(md)) return "sanitizer";
    // The sanitizer's most visible mode: it deletes whole non-element
    // constructs -- comments, processing instructions, declarations, CDATA --
    // that CommonMark says to pass through verbatim. Recognising the construct
    // itself is what makes this precise: it fires only when the thing survived
    // in md4x's output and is gone from GitHub's, which is the definition of
    // the cause. Without it these landed in `markup-shape` (the deletion moves
    // no visible text) or in `unclassified` (when GitHub's leftovers, e.g.
    // `?&gt;`, made its output the *longer* one and the length rule below
    // missed them).
    for (const probe of SANITIZER_DROPPED) {
      if (probe.test(md) && probe.test(ours) && !probe.test(theirs)) {
        return "sanitizer";
      }
    }
    if (stripTags(ours) === stripTags(theirs)) return "sanitizer";
    // The sanitizer's other mode: it drops what it cannot parse, so GitHub's
    // output carries strictly less text than ours.
    if (text(theirs).length < text(ours).length) return "sanitizer";
  }

  // The two renderers disagree about what is an autolink. Measured by taking
  // the anchors only one side produced back out: if unlinking them makes the
  // documents identical, the *only* difference is that one side linkified and
  // the other did not.
  //
  // Comparing unlinked documents rather than `text(ours) === text(theirs)`
  // matters -- `text()` turns every tag into a space, so a link that abuts
  // punctuation ("…ftp://foo.bar.baz." vs "…ftp://foo.bar.baz .") read as a
  // text difference and kept two of these in `unclassified`.
  const ourLinks = hrefs(ours);
  const theirLinks = hrefs(theirs);
  const extraOurs = [...ourLinks].filter((h) => !theirLinks.has(h));
  const extraTheirs = [...theirLinks].filter((h) => !ourLinks.has(h));

  // GitHub only linkifies a fixed set of URL schemes; md4x follows CommonMark,
  // which allows any scheme. Compared as href *sets* rather than by "GitHub
  // produced no link at all": a document usually mixes an `ftp://` autolink
  // GitHub declines with `http://` ones it accepts, and the old whole-document
  // guard scored exactly those as `markup-shape` / `unclassified`.
  if (
    extraOurs.length > 0 &&
    extraTheirs.length === 0 &&
    extraOurs.every((h) => !/^(https?:|mailto:)/.test(h)) &&
    allAutolinks(ours, extraOurs) &&
    normalize(unlink(ours, extraOurs)) === normalize(theirs)
  ) {
    return "scheme-allowlist";
  }

  // The residue: same scheme, different opinion about the surrounding
  // characters. md4x inherits md4c's rules for what may sit next to and inside
  // a permissive autolink -- `test/spec-permissive-autolinks.txt` pins them --
  // and GitHub's are not the same set. Distinct from `scheme-allowlist`, where
  // GitHub understands the link perfectly well and declines the scheme.
  if (
    extraOurs.length > 0 !== extraTheirs.length > 0 &&
    allAutolinks(ours, extraOurs) &&
    allAutolinks(theirs, extraTheirs) &&
    normalize(unlink(ours, extraOurs)) ===
      normalize(unlink(theirs, extraTheirs))
  ) {
    return "autolink-rules";
  }

  // GitHub percent-encodes hrefs its own way.
  if (unquote(ours) === unquote(theirs)) return "url-encoding";

  // Same words, different wrapper: both rendered the construct, but with
  // different elements, classes or ARIA attributes. This is the actionable
  // extension-parity bucket -- alerts, task lists, footnote scaffolding.
  if (text(ours) === text(theirs)) return "markup-shape";

  // GitHub runs an older cmark-gfm whose Unicode punctuation tables predate
  // CommonMark 0.31, which stopped classifying currency symbols as punctuation.
  if (
    /<\/?(em|strong)>/.test(ours + theirs) &&
    stripTags(ours).replace(/[*_]/g, "") ===
      stripTags(theirs).replace(/[*_]/g, "")
  ) {
    return "unicode-punct";
  }

  return "unclassified";
}

/* Does the input carry raw HTML at all? The sanitizer rules are gated on this,
   so it has to span the whole CommonMark raw-HTML surface and not just open
   tags: a stray `</div>`, a comment, `<!DOCTYPE>`, `<?php ?>` and `<![CDATA[]]>`
   are all raw HTML md4x passes through and GitHub filters. Matching only
   `<tag` left every one of them outside the gate. */
const RAW_HTML = /<(?:\/?[a-z][\w-]*[\s/>]|!--|!\[CDATA\[|![a-z]|\?)/i;

/* Raw-HTML constructs GitHub's sanitizer deletes outright rather than escaping
   or rebalancing. Each is matched against the input, md4x's output and
   GitHub's -- see the loop in `classify`. */
const SANITIZER_DROPPED = [
  /<!--/, // comments, including the malformed `<!-->` forms
  /<!\[CDATA\[/,
  /<![a-z]/i, // declarations: <!DOCTYPE html>, <!ELEMENT …>
  /<\?/, // processing instructions
];

/* Every `href` an output links to. Used as a set so a scheme GitHub declines to
   linkify can be told from a link it rendered differently. */
const hrefs = (s: string) =>
  new Set([...s.matchAll(/<a href="([^"]*)"/g)].map((m) => m[1]));

/* Unwrap the anchors pointing at `targets`, leaving their link text in place.
   Turns "one side linkified this and the other did not" into a comparison the
   rest of the document can be checked against. */
const unlink = (s: string, targets: string[]) => {
  const set = new Set(targets);
  return s.replace(
    /<a href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g,
    (whole, href, inner) => (set.has(href) ? inner : whole),
  );
};

/* Is every anchor to one of `targets` an *autolink* -- a bare URL or e-mail
   that the renderer linkified to itself? The autolink rules only explain a
   divergence when that is what the extra anchors are. Without this guard the
   rule also claimed `spec-tables.txt#12`, where the extra href is GitHub's
   camo image proxy wrapping an `<img>` -- a hosting artifact the destyler could
   not fully undo, and nothing to do with autolink syntax. */
const allAutolinks = (s: string, targets: string[]) => {
  const set = new Set(targets);
  const bare = (v: string) => v.replace(/^(?:mailto:|https?:\/\/)/, "");
  for (const [, href, inner] of s.matchAll(
    /<a href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g,
  )) {
    if (!set.has(href)) continue;
    // An anchor wrapping markup (an image, emphasis) is not a bare URL run.
    if (/</.test(inner)) return false;
    if (bare(href) !== bare(inner.trim())) return false;
  }
  return true;
};

/* Both outputs with `&quot;` folded back to a bare quote. */
const quoteFolded = (s: string) => s.replaceAll("&quot;", '"');

/* Syntax no other renderer claims. Used to tell "md4x has an extension here"
   apart from "md4x and GitHub disagree about CommonMark". */
const MD4X_ONLY = [
  /==[^=\n]+==/,
  /:{1,3}[a-z][\w-]*[[{]/i,
  /\{[#.][\w-]+\}/,
  /\$[^$\n]+\$/,
];

/* How far apart two renderings are, measured on visible text rather than markup.
   Markup length is the wrong ruler: GitHub's alert wrapper carries a ~700-byte
   inline octicon that contributes no text, so scoring by bytes made the mode
   that left `[!NOTE]` unparsed look like the closer match every time. Text
   distance instead rewards the mode that actually consumed the syntax, because
   an unparsed construct leaves its markers behind in the text. */
const distance = (a: string, b: string) =>
  Math.abs(text(a).length - text(b).length) +
  (normalize(a) === normalize(b) ? 0 : 1);

const stripTags = (s: string) => s.replace(/<[^>]*>/g, "").trim();
/* Visible words only: tags gone, entities folded, whitespace collapsed. Two
   outputs that agree here differ in markup, not in what the document says. */
const text = (s: string) =>
  // Tags become a space, not nothing: block tags are a word boundary, and the
  // two renderers disagree about newlines between them (GitHub writes
  // `</p><p>`, md4x `</p>\n<p>`). Deleting them outright glued "Note" to the
  // sentence after it and scored identical text as a divergence.
  s
    .replace(/<[^>]*>/g, " ")
    .replace(/&#8617;|&#x21a9;|\u21a9/gi, "")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
const unquote = (s: string) =>
  s.replace(/(href|src)="[^"]*"/g, "$1=").replace(/%[0-9A-Fa-f]{2}/g, "");

// --- Main -----------------------------------------------------------------

const args = process.argv.slice(2);
const update = args.includes("--update");
const verbose = args.includes("--verbose");
const only = args
  .find((a) => a.startsWith("--suite="))
  ?.slice("--suite=".length);

const { renderToHtml } = await import("../packages/md4x/lib/napi.mjs");
const token = githubToken();

const suiteNames = only ? [only] : SUITES;
const cases = suiteNames.flatMap(parseSuite);
console.log(`${cases.length} cases across ${suiteNames.length} suites\n`);

const verdicts: Verdict[] = [];
let done = 0;
for (const c of cases) {
  const ours = renderToHtml(c.md);
  const rendered: Record<Mode, string> = {} as Record<Mode, string>;
  for (const mode of MODES) {
    rendered[mode] = destyle(await renderGitHub(token, c.md, mode), mode);
  }
  if (MODES.some((m) => normalize(ours) === normalize(rendered[m]))) continue;
  // Report against whichever mode is closest, so the cause reflects the
  // renderer that actually understood the syntax rather than the one that left
  // it as literal text.
  const mode = MODES.reduce((a, b) =>
    distance(ours, rendered[a]) <= distance(ours, rendered[b]) ? a : b,
  );
  const theirs = rendered[mode];
  const cause = classify(c.md, ours, theirs);
  verdicts.push({ suite: c.suite, n: c.n, cause });
  if (verbose) {
    console.log(`--- ${c.suite}#${c.n}  [${cause}] (vs mode=${mode})`);
    console.log(`  in    ${JSON.stringify(c.md)}`);
    console.log(`  md4x  ${JSON.stringify(ours)}`);
    console.log(`  gh    ${JSON.stringify(theirs)}`);
  }
  if (++done % 100 === 0) console.error(`  ${done}/${cases.length}`);
}

// Per-suite totals, and per-cause totals across everything.
const bySuite: Record<string, { cases: number; diverge: number }> = {};
for (const c of cases) {
  bySuite[c.suite] ??= { cases: 0, diverge: 0 };
  bySuite[c.suite].cases++;
}
for (const v of verdicts) bySuite[v.suite].diverge++;

const byCause: Record<string, number> = {};
for (const v of verdicts) byCause[v.cause] = (byCause[v.cause] ?? 0) + 1;

console.log("\nparity by suite:");
for (const [suite, { cases: n, diverge }] of Object.entries(bySuite)) {
  console.log(`  ${(n - diverge + "/" + n).padStart(9)}  ${suite}`);
}
console.log("\ndivergences by cause:");
for (const [cause, n] of Object.entries(byCause).sort((a, b) => b[1] - a[1])) {
  console.log(`  ${String(n).padStart(4)}  ${cause}`);
}

const report = {
  note: "Regenerate with `bun scripts/gh-parity.ts --update`. See .agents/github-parity.md.",
  suites: bySuite,
  causes: byCause,
  divergences: verdicts,
};

if (update) {
  writeFileSync(baselinePath, JSON.stringify(report, null, 2) + "\n");
  console.log(`\nbaseline written: ${baselinePath}`);
} else if (existsSync(baselinePath)) {
  const before = readFileSync(baselinePath, "utf8");
  const after = JSON.stringify(report, null, 2) + "\n";
  if (before === after) {
    console.log("\nbaseline unchanged");
  } else {
    console.error(
      "\nparity changed against the baseline. Review the diff, then re-record:\n" +
        "  bun scripts/gh-parity.ts --update",
    );
    const b = JSON.parse(before) as typeof report;
    for (const [cause, n] of Object.entries(byCause)) {
      const was = b.causes[cause] ?? 0;
      if (was !== n) console.error(`  ${cause}: ${was} -> ${n}`);
    }
    for (const cause of Object.keys(b.causes)) {
      if (!(cause in byCause))
        console.error(`  ${cause}: ${b.causes[cause]} -> 0`);
    }
    process.exit(1);
  }
} else {
  console.log("\nno baseline yet; run with --update to record one");
}
