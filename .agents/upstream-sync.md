# Upstream sync — mity/md4c

md4x is a Zig port of [mity/md4c](https://github.com/mity/md4c). This file is the
**append-only record of which upstream commits have been reviewed and what was decided**.
The machine-readable half — fork point, last-reviewed sha, review date, path filter — lives
in [`upstream-sync.json`](upstream-sync.json); `scripts/upstream-sync.ts` reads it.

Read it before touching upstream code again. Its main job is to stop a future sync from
re-litigating the decisions in [Do not port](#do-not-port), which are the expensive ones:
each cost a full investigation, and several are cases where **md4x is right and upstream is
wrong**.

## Where we are

|                |                                                                          |
| -------------- | ------------------------------------------------------------------------ |
| Upstream       | `https://github.com/mity/md4c.git`, branch `master`                      |
| Fork point     | `481fbfbdf72daab2912380d62bb5f2187d438408` (2024-02-25)                  |
| Last reviewed  | `c4be8625eb11725d604232b028df10c2ddf9b577` (2026-08-06)                  |
| Reviewed on    | 2026-08-13                                                               |
| Range reviewed | 120 commits, 89 of which touch `src/`, `test/`, `md2html/` or `scripts/` |

The fork point never changes. `last_reviewed` advances on **every** completed sweep,
including one that concludes "all no-op" — a sha having been _looked at_ is the durable
fact; whether code was ported is recorded per-commit in the [ledger](#ledger--2026-08-sweep-fork-point--c4be862).

## Running a sync

```sh
bun scripts/upstream-sync.ts              # commits newer than last_reviewed, oldest first
bun scripts/upstream-sync.ts --all        # include README/CHANGELOG/CI/CMake churn
bun scripts/upstream-sync.ts --no-fetch   # offline: report from the local mirror as-is
```

The script clones/fetches upstream into a bare mirror under `$TMPDIR` (override with
`$MD4C_CLONE`); it never writes to this repo and needs no network access to it. Offline with
no mirror it fails, printing the clone command to run; offline with a mirror it warns and
reports from what it has.

Then, for each commit it prints:

1. Classify it (see [Classes](#classes)) and **append a row** to the ledger — never rewrite an
   existing row. A `do-not-port` row must carry its reason.
2. Land what is worth landing. Name the upstream sha in the commit message
   (`Ports md4c <sha>.`), the cross-reference convention `.agents/conventions.md` already asks for.
3. Bump `last_reviewed`, `last_reviewed_date` and `reviewed_on` in `upstream-sync.json`.

Path filter rationale: `src/`, `test/`, `md2html/` (→ md4x's `src/cli/`) and `scripts/`
(upstream's Unicode data lives in `scripts/unicode/`, the source for
`src/unicode_tables.zig`). Over the whole fork range the filter drops 31 of 120 commits — 29
pure README/CHANGELOG/CI/CMake/`.gitignore`/version-bump commits and the 2 merge commits,
whose content appears anyway as the commits they merge. Nothing else upstream ships can reach
md4x: md4x has its own README, versions independently, and shares no CI or build system.

## Classes

| class           | meaning                                                                                      |
| --------------- | -------------------------------------------------------------------------------------------- |
| `ported`        | landed in md4x; the md4x commit is named                                                     |
| `already-fixed` | md4x was already correct, usually by construction of the Zig port                            |
| `do-not-port`   | reviewed and **deliberately declined**; the reason is the point of the row                   |
| `n/a`           | structurally inapplicable (UTF-16 build, C allocator, an extension md4x lacks, build system) |
| `open`          | actionable, reviewed, not yet landed                                                         |

Ledger rows carry a source tag naming the audit report the verdict came from, from the
2026-08 sweep's eight parallel reports: `[mem]` memory-safety, `[inl]` inline-marks,
`[auto]` autolinks, `[blk]` blocks-tables, `[rnd]` renderers, `[ext]` extensions,
`[uni]` unicode-tests, `[misc]` residue + sync process. Those reports were working documents
and are not checked in — this ledger is their durable residue. Where a report's claim was
later corrected by the work that landed, the corrected value is what appears here; see
[Corrections](#corrections-to-the-2026-08-audit).

## Do not port

### `10e96ad` — code spans keep the line-break space

**Never port. Upstream regression; md4x is correct.** Byte-exact over every backtick example
in CommonMark 0.31.2: md4c HEAD fails 5 (12, 335, 337, 479, 640), md4c `10e96ad^` fails 2,
md4x fails 0. It regresses the three examples it claims to fix. The premise ignores that
`md_analyze_line` trims trailing blanks off `line->end` and the loop above re-emits them, so
the new predicate double-counts the line-break separator.

Trap for a future sync: the CommonMark normalizer collapses whitespace runs outside `<pre>`,
so `run-testsuite.py` would stay green while the raw bytes are wrong. Worth reporting upstream.

### `870f967` — drop the `strcspn` line-end scan

**Do not port; do not reintroduce `strcspn`.** Upstream's rationale is purely memory safety:
glibc's `strcspn` can over-read past a non-NUL-terminated buffer. `src/scan.zig`'s
`indexOfAnyPos` is bounds-driven (`off + V <= len`) and cannot over-read on any target, so the
hazard does not exist here. md4x additionally sheds the `doc_ends_with_newline` precondition
and the mid-buffer-NUL rescan, and never paid upstream's scalar-loop performance price.
`.agents/performance.md` and `src/parser/util.zig` already say so.

### `6d168ef` — test harness modernization

**Actively reject.** Its `[no-normalize]` removal would gut `test/spec-markdown.txt`, which
uses that flag **52** times for the round-trip renderer. Its per-case timeout never fires:
`Process(target=q.put(prog.to_html(inp)), …)` evaluates the parse eagerly in the parent, so
the spawned process is a no-op. Its third part — checking each child's exit status —
`scripts/run-tests.ts` already does. Worth reporting upstream.

### `16a8df7` — escape `'` as `&#x27;`

**Declined for now**; revisit only alongside another change that re-baselines corpus output.
Not exploitable in md4x: every emitted attribute is double-quoted and `"` is already escaped
(component prop keys can carry `'` but not `=` or an unescaped `"`). The cost is real — 6 of
28 tracked corpus files change their `html:` hash — while `test/*.txt` needs no edits, since
`normalize.py` decodes `&#x27;` back. This difference is the entire residual diff against
md4c HEAD in the autolink differential (see `00b9516`).

### `1ec0ff4` — remove the footnote special case in `md_disable_marks`

**Do not port.** It is predicated on upstream's `md_resolve_brackets` refactor (`193141e`),
which md4x does not have. md4x reaches the wiki-link case through `md_rollback`, so it needs
the `326fe25` guard in **both** `md_rollback` and `md_disable_marks`; removing it would
reintroduce the #348 bug. The 2026-08 audit initially called this N/A — see
[Corrections](#corrections-to-the-2026-08-audit).

### `193141e` — refactor bracket resolution into `md_resolve_brackets()`

**Out of scope, deliberately.** A pure refactor. md4x keeps the monolithic `md_resolve_links`
and hand-fitted footnotes into it. Taking the split would churn the most delicate function in
the parser for no behavior change — and `1ec0ff4` above depends on it.

### Subscript `~x~` (`0bc75cd`, `625a49e`)

**Skip.** Upstream deliberately steals the single tilde from strikethrough. md4x documents
`~text~` **and** `~~text~~` as strikethrough (`docs/markdown-syntax.md`) and has **no
per-flag opt-out** — CLI, wasm, standalone and NAPI all hardcode `MD_DIALECT_ALL` — so this
would silently change the meaning of every existing `H~2~O` for every consumer. `:sub[2]`
works today via COMPONENTS.

Superscript `^x^` (`0bc75cd`, `1af4605`, `f6ad5af`) collides with nothing and is merely
**deferred** for lack of demand; it is one more globally-on delimiter with no opt-out.

### Spoilers `||x||` (`1e82998`, `84c5d92`, `3a8c180`, `86cee2b`)

**Skip.** `||` stops being a table cell boundary — upstream's own `spec-spoilers.txt`
documents the breakage — and wiki-link `[[a|b]]` delimiters stop resolving, because md4x's
resolver scans for a single-byte `'|'` mark. The output is a non-standard `<x-spoiler>`
element; `:spoiler[text]` already works via COMPONENTS. If ever ported, `84c5d92` (the O(n²)
fix) must come with it.

### Admonitions `!!! type` (`3456667` + `859d9df`, `5f9b246`, `c9e4a7c`, `9e1165f`, `56eec98`, `110011e`, `4f0b252`)

**Do not port; adopt 0 code fixes.** md4x's ALERTS (`> [!NOTE]`) matches upstream on all seven
inputs upstream pinned in `test/regressions.txt`, and accepts custom types upstream cannot.
Every upstream bugfix in the series is an artifact of detecting in `md_process_line`; md4x
detects in `md_analyze_line` from day one — the shape `c9e4a7c` refactored _toward_. This was
a tests-only item, discharged by `26038a5` (`test/spec-alerts.txt` 19 → 42 cases).

### Underline `MD_FLAG_UNDERLINE` / `MD_SPAN_U` — **removed from md4x**

**Do not re-port.** Upstream still ships the flag and the `MD_SPAN_U` span type; md4x deleted
both (see unjs/md4x#18). The flag was in `MD_DIALECT_ALL`, which every md4x entry point
hardcodes — CLI, WASM and NAPI — so `_foo_` emitted `<u>`, `__foo__` emitted `<u><u>` (one
`<u>` per underscore, upstream's own semantics) and `_` emphasis was unreachable. CommonMark
and GFM both treat `*` and `_` as exact synonyms and have no underline syntax at all, so the
default silently broke every document written for either. Since md4x has no CLI toggle for
parser flags and no C ABI consumer, keeping the flag would have meant keeping an
unreachable-and-untestable code path plus its span type across five renderers.

Consequences to remember: `SpanType` ordinals after `wikilink` all shift down by one, and the
AST/JSON renderers no longer emit a `u` node. If a future sync brings a commit touching
`MD_SPAN_U`, it is not applicable here.

## Open — reviewed, actionable, not landed

| upstream             | item                                                                                       | note                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `323995c`, `ed89abe` | `src/cli/md4x.1` documents ~17 options the CLI rejects with exit 1                         | See below. `[misc]`                                                     |
| `f6b445d`, `99d4667` | `--replay-fuzz` is vestigial                                                               | See below. `[misc]`                                                     |
| `ce4636b`            | `MD_CHECK` should abort on any non-zero, not just `< 0`                                    | Decision, not a port. See below. `[mem]`                                |
| `377cc53`, `be7332b` | `2016-2024` → `2016-2026` (4 files); `http://github.com/unjs/md4x` → `https://` (10 files) | Trivial. `[misc]`                                                       |
| `2a0f60d`, `e90921a` | `test/spec-permissive-autolinks.txt` text drift                                            | Cosmetic. See below. `[auto]`                                           |
| `28e2fbd`            | duplicate chars in the URL-escape set (`md4x-html.zig:70`)                                 | Zero output change; the comptime `ESCAPE_MAP` is bit-identical. `[rnd]` |

- **Man page.** Verified: `--ftables`, `--github`, `--fverbatim-entities` all exit 1. md4x
  dropped every dialect/extension flag (hardcodes `MD_DIALECT_ALL`, `src/cli/md4x-cli.zig:84`)
  but kept md4c's page verbatim; it also omits `--heal`, lists 3 of 6 `--format` values, and
  still stamps "February 2026". The fix is a product decision: rewrite the page to describe the
  real CLI (recommended), or implement the flags — which would also change the default from ALL
  to CommonMark.
- **`--replay-fuzz`.** It implements md2html's 8-byte flag prefix, but `src/fuzz.zig` uses a
  fixed `MD_DIALECT_ALL`/`0` and the corpus is plain markdown, so replay silently eats 8 bytes.
  md4x also still does the trailing zero-fill upstream removed ("it can actually hide a bug")
  and overwrites `r_flags`, losing `MD_HTML_FLAG_DEBUG`. Delete the mode, or apply both
  one-line fixes.
- **`ce4636b`.** md4x ported the callback half (`!= 0`) but not the internal propagation half
  (~60 `ret < 0` sites) and **pins the pre-`ce4636b` matrix in tests** (`src/md4x.zig:800-854`).
  Either follow upstream, or document in `docs/parser-api.md` that callbacks must abort with a
  negative code. Doing neither leaves md4x pinned to behavior upstream calls a bug.
- **Spec text drift.** `john.doe@gmail.com` → `example.com` (10 occurrences) and the typos
  `formost` → `foremost`, `username` → `user name`. md4x passes the suite either way. Do **not**
  re-add the per-example `--fpermissive-*` flag blocks or upstream's `MD4C` naming — both
  divergences are intentional.

md4x-only follow-ups the sweep raised, with no upstream counterpart, that did not land:
`.github/workflows/ci.yml` never runs `zig build fuzz-zig`, and `AGENTS.md` claims a
Linux/Windows/coverage CI matrix that does not exist.

## Worth reporting upstream

1. `10e96ad` regresses CommonMark examples 335, 337 and 640.
2. After `589681b` removed the column cap, md4c HEAD truncates the count mod 65536 — a
   65 536-column table emits **zero** `<th>` and drops its content. md4x keeps a 65535 cap for
   exactly this reason.
3. `6d168ef`'s pathological-test timeout never fires.
4. In `d1f8a97`, a segment that consumes nothing still rolls `end` back past its own start,
   killing the whole match (`http://example.com//`, `http://ex.coma._`, `a@ex.com.-`).

## Ledger — 2026-08 sweep (fork point → `c4be862`)

89 rows, oldest first: one per commit in `481fbfb..c4be862` touching `src/`, `test/`,
`md2html/` or `scripts/` — exactly what `bun scripts/upstream-sync.ts` prints for that range,
in the same order. Long reasoning lives in the sections above; these notes are the index.

| sha       | subject                                                        | class                                     | note                                                                                    |
| --------- | -------------------------------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------- |
| `870f967` | md_analyze_line: get rid of strcspn-based optimization         | do-not-port                               | `src/scan.zig` is bounds-driven. `[blk]`                                                |
| `e0dcf62` | md_process_leaf_block: invalid free() in error path            | already-fixed                             | `MD_ATTRIBUTE_BUILD` is `= .{}` everywhere; free is idempotent. `[mem]`                 |
| `fab28e4` | Avoid repeated `language-` in info string                      | ported                                    | → `c108204` (HTML + AST + `lib/_shared.mjs`). `[rnd]` `[uni]`                           |
| `ce25e56` | Fix alignment issue in md_mark_store_ptr()                     | n/a                                       | md4x stores via `[*]u8` `@memcpy`; **do not "modernize"** into a pointer store. `[mem]` |
| `ae85f71` | MD_MARK union → just beg/end                                   | n/a                                       | C-layout refactor; md4x already writes only `beg`+`end`. `[mem]`                        |
| `9b51e26` | Simplify mark pointers more                                    | n/a                                       | Same. `[mem]`                                                                           |
| `bd6a4e3` | Fix md_decode_utf16le_before\_\_() return value                | n/a                                       | UTF-16 only; md4x returns `ch(off - 1)` on every path. `[misc]`                         |
| `380ee2b` | md_is_closing_code_fence: accept trailing tabs                 | ported                                    | → `bb4ee4d`; 6 new cases, the rule's first executable coverage. `[blk]` `[uni]`         |
| `1ccedb3` | fix OFF_MAX redefinition and a potential overflow              | already-fixed                             | `src/md4x.zig:249` widens to `u64` before multiplying. `[mem]`                          |
| `44c90ca` | Disable openers/marks more carefully (#278, #294)              | ported                                    | → `9eed904`, with `c055ef5`; unbalanced SAX spans, not just HTML. `[inl]`               |
| `ff71f00` | md_process_inlines: don't skip back to line start (#271)       | ported                                    | → `a629443` (`off = @max(off, line.beg)`). `[inl]` `[uni]`                              |
| `ce4636b` | MD_CHECK: abort on any non-zero value                          | **open**                                  | Decision needed; see [Open](#open--reviewed-actionable-not-landed). `[mem]`             |
| `3834f11` | permissive autolink: remove always-true condition              | ported                                    | → `00b9516`, subsumed by `d1f8a97`. `[auto]`                                            |
| `5d52d32` | permissive autolink: be a little more permissive               | ported                                    | → `00b9516`, subsumed by `d1f8a97`. `[auto]`                                            |
| `bd8f80e` | const up scheme_map                                            | n/a                                       | Zig's `const scheme_map` is already immutable. `[auto]`                                 |
| `fccb43a` | fix tasklist XHTML render                                      | n/a                                       | md4x has no XHTML mode. `[rnd]`                                                         |
| `8cab795` | build: CMake improvements                                      | n/a                                       | md4x builds with `zig build`. `[misc]`                                                  |
| `87258eb` | build: absolute include/lib dirs in pc file                    | n/a                                       | md4x ships no pkg-config files. `[misc]`                                                |
| `3420ce7` | Update to Unicode 18.0                                         | ported                                    | → `d806f23`; +1003 punct, +76 folds, whitespace unchanged. `[uni]`                      |
| `f24870b` | render_open_code_block: fix buffer overflow                    | n/a                                       | Cannot recur (slice + `startsWith`), but a **constraint** on `fab28e4`. `[rnd]` `[mem]` |
| `c4eebad` | Create initial fuzzer seed corpus                              | n/a                                       | 8-byte flag header; `src/fuzz.zig` takes raw markdown. `[uni]`                          |
| `2a0f60d` | spec-permissive-autolinks.txt: fix a typo                      | **open**                                  | Cosmetic text drift. `[auto]`                                                           |
| `e90921a` | spec-permissive-autolinks.txt: drop gmail.com                  | **open**                                  | Cosmetic text drift (10 occurrences). `[auto]`                                          |
| `1e82998` | Add spoiler span extension (#308)                              | do-not-port                               | Breaks table cells and wiki-link delimiters. `[ext]`                                    |
| `f6b445d` | md2html: minor --replay-fuzz improvements                      | **open**                                  | md4x still does the zero-fill upstream removed. `[misc]`                                |
| `5860a02` | md_collect_marks: add missing parenthesis                      | n/a                                       | The C precedence trap does not exist in Zig. `[inl]`                                    |
| `84c5d92` | Fix O(n²) with --fspoilers and nested brackets (#311)          | n/a                                       | Spoiler-only pass; the skip-resolved jump already exists here. `[inl]`                  |
| `3a8c180` | Tests for links/images inside spoiler spans                    | n/a                                       | Spoilers. `[ext]`                                                                       |
| `86cee2b` | Tests for inline spans inside spoilers                         | n/a                                       | Spoilers. `[ext]`                                                                       |
| `f169318` | Replace ISANYOF\_ with direct char comparison                  | n/a                                       | Coverage-only edit inside the spoiler loop. `[inl]`                                     |
| `f41e674` | md_analyze_link_contents: reuse md_analyze_marks()             | n/a                                       | Refactor; 0 diffs over 8 400 differential inputs. `[inl]`                               |
| `d534ad9` | permissive autolink: accept any opener mark before it          | ported                                    | → `00b9516`; unobservable until a new mark char exists. `[auto]`                        |
| `0bc75cd` | Add superscript and subscript span extensions                  | do-not-port (sub) / deferred (super)      | Single tilde is md4x's strikethrough. `[ext]`                                           |
| `1af4605` | Remove unused caret case in md_opener_stack                    | n/a                                       | No `^` opener stack in md4x. `[misc]`                                                   |
| `625a49e` | Examples for tilde behavior in subscript spans                 | n/a                                       | Subscript. `[misc]`                                                                     |
| `f6ad5af` | Examples for caret behavior in superscript spans               | n/a                                       | Superscript. `[misc]`                                                                   |
| `377cc53` | Update copyright years                                         | **open**                                  | 4 files still say `2016-2024`. `[misc]`                                                 |
| `81b871f` | Fix python SyntaxWarning in test                               | ported                                    | → `26038a5`; the `pathological-tests.py` half was already done. `[uni]`                 |
| `07712a5` | Code cleanup (#314)                                            | n/a                                       | Comment style, include order, `MD_UNUSED`. `[inl]`                                      |
| `ed89abe` | md2html: add option --gfm                                      | **open** (design)                         | md4x's CLI has no dialect option at all. `[misc]`                                       |
| `3456667` | Implement github-style admonitions extension (#316)            | do-not-port                               | md4x ships ALERTS and already matches. `[ext]`                                          |
| `859d9df` | Fix invalid assertion at admonition recognition                | n/a                                       | Admonitions. `[ext]`                                                                    |
| `4f0b252` | md_process_all_blocks: fix stack-use-after-scope               | n/a                                       | md4x's alert attribute build is **function-scoped**; keep it that way. `[mem]`          |
| `d1f8a97` | Refactor the permissive autolink extension code (#319)         | ported                                    | → `00b9516`, the primary port; subsumes 5 earlier commits. `[auto]`                     |
| `5f9b246` | md_process_line: fix admonition handling                       | n/a                                       | Admonitions. `[ext]`                                                                    |
| `6257361` | Fix double-free on second realloc failure                      | already-fixed                             | `realloc_array_a` returns null and leaves the old slice owned. `[mem]`                  |
| `174fe05` | MD_ATTRIBUTE_BUILD: unsigned size types                        | ported                                    | → `76dff08`; counters → `usize`, refused at the opener. `[mem]`                         |
| `28e2fbd` | md_html: remove duplicate chars from strchr()                  | **open** (tidy)                           | Zero output change. `[rnd]`                                                             |
| `5faab7c` | Fix HTML tag length computation in UTF-16 builds               | n/a                                       | `mkTag` uses `name.len`, the correct unit for `u8`. `[misc]`                            |
| `c9e4a7c` | Admonitions: move detection to md_analyze_line()               | n/a                                       | md4x detects there from day one. `[ext]`                                                |
| `192723a` | Fuzz seed corpus: add an admonition sample                     | n/a                                       | Covered by `test/fuzzers/seed-corpus/alerts.md`. `[uni]`                                |
| `671cd93` | fix: V-001 (membuf_append size overflow)                       | ported                                    | → `76dff08`; `md4x-heal.zig`'s `+%` guard was the live bug. `[mem]`                     |
| `53852ac` | Fix multiple bugs (#325)                                       | ported (surrogate) / already-fixed (rest) | → `3583855`; CESU-8 from 4 renderers, raw NUL from meta. `[mem]` `[uni]`                |
| `5012c8f` | Use SZ (not int) for realloc sizes                             | already-fixed / ported (arena)            | → `235d587` for the arena upstream never covered. `[mem]`                               |
| `b8d9ee1` | permissive autolink: allow `~` in the URL path                 | ported                                    | → `00b9516`. `[auto]`                                                                   |
| `9e1165f` | md_analyze_line: fix admonition detection                      | n/a                                       | Admonitions. `[ext]`                                                                    |
| `56eec98` | Admonitions: get rid of MD_LINE_ADMONITIONTAG                  | n/a                                       | md4x sets `line.type = .blank`. `[ext]`                                                 |
| `110011e` | Admonitions: don't turn indented code into admonition          | n/a                                       | md4x's `indent < code_indent_offset` guard already does this. `[ext]`                   |
| `5add6a3` | Several fixes for the Windows UTF-16 build                     | n/a                                       | `sizeof(CHAR)` scalings; the 4 md4x sites were checked byte-correct. `[misc]`           |
| `a8b0d3e` | Add footnote reference support (#315)                          | ported                                    | → `09b10c2`; also fixed a live md4x mis-parse of `[^1]: note`. `[ext]`                  |
| `54bfec0` | Footnotes: text may be split into multiple lines               | ported                                    | → `09b10c2`. `[ext]`                                                                    |
| `915676f` | Separate the label hashtable implementation                    | ported                                    | → `09b10c2` as a comptime-generic `LabelHashTable(Def)`. `[ext]`                        |
| `19dd06f` | Heavily refactor label hashtable                               | ported + `76dff08` (sizing)               | → `09b10c2`; md4x computes `n + n/4`, never forming `n*5`. `[ext]` `[misc]`             |
| `589681b` | Tables: suppress too sparse tables (#346)                      | ported, diverged                          | → `1094346`; cap retuned to 65535, not deleted (16-bit `bits.data`). `[blk]`            |
| `326fe25` | Footnotes: fix assert for a ref inside a wiki-link dest (#348) | ported                                    | → `09b10c2`; md4x needs the guard in `md_rollback` **and** `md_disable_marks`. `[ext]`  |
| `193141e` | Refactor bracket resolution into md_resolve_brackets()         | do-not-port                               | Deliberately out of scope. `[inl]`                                                      |
| `30c1a68` | Brackets: rename some mark flags                               | n/a                                       | md4x's flag values are frozen per `.agents/conventions.md`. `[inl]`                     |
| `59af256` | Brackets: no-impact preparation for image handling             | n/a                                       | md4x collects image openers with `ch == '!'` directly. `[inl]`                          |
| `9fa747c` | Fix code indentation and add missing `_T()`                    | n/a                                       | Re-indentation; `_T()` is identity in UTF-8 builds. `[misc]`                            |
| `99d4667` | md2html: --replay-fuzz enforces debug output                   | **open**                                  | md4x's replay path overwrites `r_flags`, losing DEBUG. `[misc]`                         |
| `1ecb4a4` | md_process_leaf_block: fix sparse table detection              | ported                                    | → `1094346`; only the `589681b`+typo-fix form was landed. `[blk]`                       |
| `a962cdf` | md_resolve_bracket_wikilink: simplify a little                 | n/a                                       | Same predicate, regrouped. `[inl]`                                                      |
| `ff70673` | Brackets: remove extra pass for the bracket extension          | n/a                                       | Footnotes were hand-fitted into `md_resolve_links` instead. `[inl]`                     |
| `1ec0ff4` | md_disable_marks: remove the footnote special case             | do-not-port                               | Would reintroduce the `326fe25` bug here. `[inl]` → corrected                           |
| `fb4d03d` | Regressions: add a testcase from #352                          | ported                                    | → `26038a5`, in its `6ed63d1`-corrected form. `[uni]`                                   |
| `ea20033` | Match cmark version of normalize.py                            | ported                                    | → `26038a5`, byte-identical to md4c HEAD. `[uni]`                                       |
| `be7332b` | Update links to https                                          | **open**                                  | 10 md4x sources still carry `http://github.com/unjs/md4x`. `[misc]`                     |
| `16a8df7` | Add apostrophe to HTML escaping                                | do-not-port (for now)                     | Not exploitable; 6 of 28 corpus hashes would move. `[rnd]`                              |
| `323995c` | Add man page options, clean up md2html --help (#362)           | **open**                                  | `src/cli/md4x.1` is badly stale. `[misc]`                                               |
| `d2a08e5` | Add highlight span extension (#357)                            | ported, diverged                          | → `d59ea4e`; span carries `SpanAttrsDetail` so `==x=={.warn}` composes. `[ext]`         |
| `c055ef5` | md_resolve_brackets: check the `[` is not disabled             | ported                                    | → `9eed904`; no standalone effect, mandatory with `44c90ca`. `[inl]`                    |
| `6ed63d1` | Fix broken testcase related to #352                            | ported                                    | → `26038a5` (the corrected expectation is what was imported). `[misc]`                  |
| `755ce49` | md_is_autolink_uri: scheme must begin with alnum (#369)        | ported                                    | → `47f4485`; **63 of 128** first bytes made bogus links. `[auto]` `[uni]`               |
| `38592ac` | Accept percent sign in auto links                              | ported                                    | → `00b9516`. `[auto]`                                                                   |
| `6d168ef` | Make the tests more like current cmark (#373)                  | do-not-port                               | Would gut `spec-markdown.txt`; its timeout never fires. `[uni]`                         |
| `ecbb091` | md_analyze_table_alignment: bound the dash scan                | ported                                    | → `76dff08`; latent, but `ctx.ch()` is never bounds-checked. `[blk]`                    |
| `10e96ad` | Code spans: keep the line-break space                          | do-not-port                               | **Upstream regression; md4x fails 0 of the affected examples.** `[blk]`                 |
| `65c6c9d` | md_html: escape raw HTML in image alt attribute                | ported                                    | → `c1a1990`; `onerror` became a live attribute. `[rnd]` `[uni]`                         |
| `c4be862` | test/regressions.txt: fix some wording                         | already-fixed                             | Wording only; no example bodies changed. `[uni]`                                        |

**Excluded from the table (31 of 120).** 29 commits touching only README/CHANGELOG/CI/CMake/
`.gitignore`/version: `05c0e7f` `09819bf` `10c0158` `2855917` `2bac75e` `2ed8e52` `313429e`
`347b528` `387b0b9` `3ab40d0` `3eade38` `472c417` `4913b5d` `4e0102e` `63f897e` `66c32f3`
`69a7e96` `795ddff` `7e19948` `8eca73a` `9de89d8` `a1072a0` `a1794a4` `bd61dfb` `bf51db2`
`ca4ef3d` `e60580d` `f232554` `f5f5594`. Plus the 2 merge commits `2347000`
(superscript/subscript) and `a4a5678` (spoilers), whose content is in the table as the commits
they merge. All were reviewed and are no-ops for md4x.

## What landed in this sweep

17 md4x commits. Every one names its upstream sha in the commit message.

| md4x      | upstream                                                          | note                                                                                                   |
| --------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `c1a1990` | `65c6c9d`                                                         | Escape raw HTML inside the image `alt` attribute.                                                      |
| `9eed904` | `44c90ca`, `c055ef5`                                              | Disable marks swallowed by an inline link URL; `md_rollback` call sites left alone.                    |
| `1094346` | `589681b`, `1ecb4a4`                                              | Sparse-table suppression; 642× amplification fixed. First `ctx.log()` reachable on non-error input.    |
| `3583855` | `53852ac` (surrogate half)                                        | Guards patched in place, **not** hoisted: the five encoders are not interchangeable.                   |
| `47f4485` | `755ce49`                                                         | Autolink scheme must begin with an alphanumeric.                                                       |
| `bb4ee4d` | `380ee2b`                                                         | Trailing tabs after a closing code fence.                                                              |
| `a629443` | `ff71f00`                                                         | Don't rewind past bytes a span closer consumed.                                                        |
| `c108204` | `fab28e4` (+ `f24870b` as constraint)                             | Only `class` is de-duplicated; the AST `language` prop stays raw for the JS highlighter.               |
| `235d587` | md4x-only (class of `5012c8f`/`174fe05`)                          | `block_bytes` arena → `usize` + `MAX_BLOCK_BYTES`. Upstream never fixed this site.                     |
| `6b48364` | md4x-only                                                         | Markdown renderer escaping, three tiers derived from the mark collector. Only `markdown:` hashes move. |
| `0fe86b9` | md4x-only                                                         | ANSI/text neutralize document control bytes; unconditional, not gated behind `NO_COLOR`.               |
| `76dff08` | `174fe05`, `671cd93`, `ecbb091`, `19dd06f` (sizing)               | Plus md4x-only: CLI/NAPI oversized-input refusal, `containers.items.len` underflow guard.              |
| `00b9516` | `d1f8a97` ⊃ `3834f11`, `5d52d32`, `d534ad9`, `b8d9ee1`, `38592ac` | Three inputs become _stricter_; upstream followed, all three pinned in `regressions.txt`.              |
| `d59ea4e` | `d2a08e5`                                                         | Highlight `==x==` → `<mark>`, `MD_FLAG_HIGHLIGHT = 0x100000`.                                          |
| `09b10c2` | `a8b0d3e`, `54bfec0`, `326fe25`, `915676f`, `19dd06f`             | `MD_FLAG_FOOTNOTES = 0x200000`, also in `MD_DIALECT_GITHUB`. `1ec0ff4` deliberately not ported.        |
| `d806f23` | `3420ce7`                                                         | Unicode 15.1 → 18.0; pipeline proved reproducible before any data changed.                             |
| `26038a5` | `ea20033`, `81b871f`, `fb4d03d`, `6ed63d1`                        | Test import + `normalize.py` refresh; `spec-alerts.txt` 19 → 42 cases.                                 |

## Corrections to the 2026-08 audit

Recorded because the ledger, not the report, is the durable artifact.

1. **Autolink scheme blast radius.** The audit said `isAscii` produced a bogus link on
   **61 of 127** possible first bytes. Measured while landing `47f4485`: **63 of 128**. Byte
   `0x3C` also changes (`<<oo:bar>` now links the inner `<oo:bar>`), and md4x agrees with md4c
   HEAD on 127 of 128 bytes afterwards.
2. **`block_bytes` arena reachability.** The audit put the overflow at ~358 MB of input. It is
   **~140 MB**: a blank line inside a fenced code block is one input byte but costs a full
   12-byte `MD_VERBATIMLINE` (12×, not 6×). The overflow is the 1.5× growth step at
   1 677 392 853 bytes; in ReleaseFast the optimizer keeps the true size in a 64-bit register
   while the `i32` field stores the negative, so the arena really is allocated and the grow test
   then reads false forever. Widening alone was not enough — `MAX_BLOCK_BYTES` is `maxInt(OFF)`,
   because `MD_CONTAINER.block_byte_off` is an `OFF` through which `md_analyze_line` writes the
   loose-list flag back.
3. **`1ec0ff4`.** `[inl]` classified it N/A ("the special case never existed in md4x") and
   `[ext]` listed it among the footnote commits to port. Both are wrong: md4x reaches the
   wiki-link case through `md_rollback`, needs the `326fe25` guard in two places, and porting
   `1ec0ff4` would reintroduce the bug. Now recorded as do-not-port.
4. **Missing test cases.** The audit found 19 post-fork regression examples missing, 10 of them
   failing. By the time the test import ran, **17 of the 19 had already been imported** by
   earlier commits in this series; only 2 were genuinely missing — upstream's PR-325 hard-break
   case and #352, footnote-gated until `09b10c2` — and both pass.
5. **`[no-normalize]` usage.** The audit counted 8 uses in `test/spec-markdown.txt`; the real
   count is **52**, which strengthens the `6d168ef` rejection.
6. **Autolink differential.** The audit measured 36 diffs over ~6 000 inputs. Re-run at 8 139
   inputs while landing `00b9516`: 522 → 25 diffs, with **all 25 residuals** being the `16a8df7`
   apostrophe difference, reproducible with no link present. Autolink-attributable diffs reach
   zero.
7. **Flag bits as landed.** `MD_FLAG_HIGHLIGHT = 0x100000` (`d59ea4e`),
   `MD_FLAG_FOOTNOTES = 0x200000` (`09b10c2`, also in `MD_DIALECT_GITHUB`). md4x's bit
   assignment diverges from upstream's from `0x10000` up; do not try to re-align — there is no
   shared C ABI.
8. **`language-` de-duplication reach.** The audit named the HTML and AST renderers.
   `packages/md4x/lib/_shared.mjs` also had to change: it reconstructed the `<pre><code …>`
   wrapper length assuming the prefix was always present, and under-trimmed by 9 bytes once the
   prefix became conditional.
9. **Unicode regeneration coverage.** The audit recommended "at least one spec case per class";
   `d806f23` added **8** cases to `coverage.txt` (five punctuation-flanking, three folding).
   Against the pre-regeneration binary that suite is 31 passed / 7 failed; after, 38 / 0.
