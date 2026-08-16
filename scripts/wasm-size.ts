#!/usr/bin/env bun
/**
 * WASM size analyzer — where the bytes in `packages/md4x/build/*.wasm` go.
 *
 *   bun scripts/wasm-size.ts                    # the compact bundle's module (wasm-small)
 *   bun scripts/wasm-size.ts --variant=wasm     # the default ReleaseFast module
 *   bun scripts/wasm-size.ts --top=40 --depth=2 # more functions / deeper rollup
 *   bun scripts/wasm-size.ts --json             # machine-readable, for CI budgets
 *   bun scripts/wasm-size.ts --diff=old.wasm    # per-group/function delta vs another module
 *   bun scripts/wasm-size.ts some.wasm          # any module (names only if it kept a name section)
 *
 * The shipped artifacts are stripped, so with no file argument this rebuilds the
 * variant with `-Dwasm-symbols=true` into a throwaway prefix under
 * `node_modules/.cache/wasm-size/` and reads that. The flag only controls
 * `strip`, not codegen, so every code byte reported is a byte in the stripped
 * artifact too — the sizes are the real ones, just with names attached.
 * `--no-build` skips the rebuild and reads the stripped artifact as-is
 * (`func[N]` instead of names).
 *
 * Anything else starting with `-D` is forwarded to `zig build`, so a comptime
 * feature switch can be measured: `bun scripts/wasm-size.ts -Demoji=true`.
 *
 * Three views, because each answers a different question:
 *
 *   SECTIONS — raw and gzipped, since the compact bundle ships the module
 *     gzip+Z85-inlined (see scripts/build-standalone.ts): a flat generated table
 *     and a page of branchy code cost very differently once compressed.
 *   CODE     — function bodies rolled up the Zig module tree (yaml/, parser/,
 *     renderers/), plus the biggest individual functions and a set of named cost
 *     centers: runtime machinery that is easy to link in by accident and hard to
 *     spot in a flat function list.
 *   DATA     — the generated tables (entity, unicode, emoji) sized from their
 *     source of truth in `src/`, so the number moves when the generator does.
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const projectDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cacheDir = join(projectDir, "node_modules/.cache/wasm-size");

/** The WASM variants build.zig installs, keyed by their `zig build` step. */
const VARIANTS: Record<string, string> = {
  wasm: "md4x.wasm",
  "wasm-small": "md4x-small.wasm",
  "wasm-safe": "md4x-safe.wasm",
};

// --- CLI ---------------------------------------------------------------------

const argv = process.argv.slice(2);
if (argv.includes("-h") || argv.includes("--help")) {
  console.log(
    [
      "Usage: bun scripts/wasm-size.ts [file.wasm] [options] [-D...]",
      "",
      `  --variant=NAME  which build.zig wasm step to analyze (${Object.keys(VARIANTS).join(", ")}); default wasm-small`,
      "  --top=N         how many individual functions to list (default 25)",
      "  --depth=N       rollup depth for the code tree: 1 = top groups only (default 2)",
      "  --diff=FILE     compare against another .wasm and report deltas",
      "  --no-build      do not rebuild with symbols; read the stripped artifact",
      "  --json          emit JSON instead of the tables",
      "  -D...           forwarded to `zig build` (e.g. -Demoji=true)",
    ].join("\n"),
  );
  process.exit(0);
}

const flag = (name: string): string | undefined => {
  const hit = argv.find((a) => a.startsWith(`--${name}=`));
  return hit?.slice(name.length + 3);
};
const variant = flag("variant") ?? "wasm-small";
const top = Number(flag("top") ?? 25);
const depth = Number(flag("depth") ?? 2);
const diffPath = flag("diff");
const asJson = argv.includes("--json");
const noBuild = argv.includes("--no-build");
const zigArgs = argv.filter((a) => a.startsWith("-D"));
const fileArg = argv.find((a) => !a.startsWith("-"));

if (!fileArg && !(variant in VARIANTS)) {
  console.error(
    `wasm-size: unknown variant "${variant}" (expected one of ${Object.keys(VARIANTS).join(", ")})`,
  );
  process.exit(1);
}

// --- Locating the module -----------------------------------------------------

/**
 * Build `variant` with its name section intact.
 *
 * `--prefix` is what keeps this out of the way: build.zig installs the wasm to
 * `../packages/md4x/build/` *relative to the install prefix*, so pointing the
 * prefix at the cache directory redirects the artifact there and leaves the real
 * `packages/md4x/build/` — which the JS suites and the standalone bundle load —
 * untouched. The compilation cache is shared with normal builds, so this costs a
 * link, not a full rebuild.
 */
function buildWithSymbols(step: string): string {
  mkdirSync(cacheDir, { recursive: true });
  const args = [
    "build",
    step,
    "-Dwasm-symbols=true",
    ...zigArgs,
    "--prefix",
    join(cacheDir, "out"),
  ];
  execFileSync("zig", args, {
    cwd: projectDir,
    stdio: ["ignore", "ignore", "inherit"],
  });
  return join(cacheDir, "packages/md4x/build", VARIANTS[step]);
}

function locate(): string {
  if (fileArg) return resolve(fileArg);
  if (!noBuild) return buildWithSymbols(variant);
  const shipped = join(projectDir, "packages/md4x/build", VARIANTS[variant]);
  if (!existsSync(shipped)) {
    console.error(
      `wasm-size: ${relative(projectDir, shipped)} does not exist — run \`zig build ${variant}\` or drop --no-build`,
    );
    process.exit(1);
  }
  return shipped;
}

// --- WASM binary reader ------------------------------------------------------

const SECTION_NAMES = [
  "custom",
  "type",
  "import",
  "function",
  "table",
  "memory",
  "global",
  "export",
  "start",
  "element",
  "code",
  "data",
  "datacount",
  "tag",
];

type Section = { id: number; name: string; size: number; body: Uint8Array };
type Func = { index: number; name: string | undefined; size: number };
type DataSeg = {
  index: number;
  offset: number;
  size: number;
  body: Uint8Array;
};

type Module = {
  path: string;
  /** The file as read. */
  bytes: Uint8Array;
  /**
   * The module with every custom section removed — i.e. the shipped artifact.
   * All sizes are reported against this, so building with `-Dwasm-symbols=true`
   * to get names does not bill the report for a debug build's DWARF. Checked
   * against the stripped `md4x-small.wasm`: identical but for 4 bytes in one of
   * 495 function bodies, so the numbers are the shipped ones.
   */
  shipped: Uint8Array;
  sections: Section[];
  funcs: Func[];
  data: DataSeg[];
  importedFuncs: number;
};

/** Re-emit sections into a module, for the custom-section-free shipping view. */
function reassemble(sections: Section[]): Uint8Array {
  const uleb = (n: number) => {
    const out: number[] = [];
    do {
      let byte = n & 0x7f;
      n >>>= 7;
      if (n) byte |= 0x80;
      out.push(byte);
    } while (n);
    return out;
  };
  const header = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  const framed = sections.map((s) => [s.id, ...uleb(s.size)]);
  const size =
    header.length +
    framed.reduce((n, f) => n + f.length, 0) +
    sections.reduce((n, s) => n + s.body.length, 0);

  const out = new Uint8Array(size);
  let at = 0;
  out.set(header, at);
  at += header.length;
  for (const [i, s] of sections.entries()) {
    out.set(framed[i], at);
    at += framed[i].length;
    out.set(s.body, at);
    at += s.body.length;
  }
  return out;
}

function parseWasm(path: string): Module {
  const bytes = new Uint8Array(readFileSync(path));
  if (
    bytes.length < 8 ||
    bytes[0] !== 0x00 ||
    bytes[1] !== 0x61 ||
    bytes[2] !== 0x73
  ) {
    console.error(`wasm-size: ${path} is not a WebAssembly module`);
    process.exit(1);
  }

  let p = 8;
  const u8 = () => bytes[p++];
  const uleb = () => {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      byte = bytes[p++];
      result |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80);
    return result >>> 0;
  };
  const sleb = () => {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      byte = bytes[p++];
      result |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80);
    if (shift < 32 && byte & 0x40) result |= -(1 << shift);
    return result;
  };
  const str = () => {
    const len = uleb();
    const s = new TextDecoder().decode(bytes.subarray(p, p + len));
    p += len;
    return s;
  };
  /** Skip a `limits` (the shape shared by table and memory types). */
  const limits = () => {
    const flags = u8();
    uleb();
    if (flags & 0x01) uleb();
  };

  const sections: Section[] = [];
  const funcs: Func[] = [];
  const data: DataSeg[] = [];
  const names = new Map<number, string>();
  let importedFuncs = 0;

  while (p < bytes.length) {
    const id = u8();
    const size = uleb();
    const start = p;
    const end = start + size;
    let label = SECTION_NAMES[id] ?? `unknown(${id})`;

    switch (id) {
      case 0: {
        // Custom. The `name` section is what makes every other number legible.
        const custom = str();
        label = `custom:${custom}`;
        if (custom === "name") {
          while (p < end) {
            const sub = u8();
            const subEnd = uleb() + p;
            // 1 = function names. Indices are into the *whole* function index
            // space, so imports come first and code-section body i is index
            // i + importedFuncs.
            if (sub === 1) {
              const count = uleb();
              for (let i = 0; i < count; i++) {
                const index = uleb();
                names.set(index, str());
              }
            }
            p = subEnd;
          }
        }
        break;
      }
      case 2: {
        const count = uleb();
        for (let i = 0; i < count; i++) {
          str(); // module
          str(); // field
          const kind = u8();
          if (kind === 0) {
            uleb();
            importedFuncs++;
          } else if (kind === 1) {
            u8();
            limits();
          } else if (kind === 2) {
            limits();
          } else {
            u8();
            u8();
          }
        }
        break;
      }
      case 10: {
        const count = uleb();
        for (let i = 0; i < count; i++) {
          const bodySize = uleb();
          funcs.push({ index: i, name: undefined, size: bodySize });
          p += bodySize;
        }
        break;
      }
      case 11: {
        const count = uleb();
        for (let i = 0; i < count; i++) {
          const flags = uleb();
          let offset = 0;
          if (flags === 2) uleb(); // explicit memory index
          if (flags === 0 || flags === 2) {
            // Offset init expr: `i32.const N end`, or `global.get N end` for a
            // relocatable segment (then the offset is not statically known).
            const op = u8();
            if (op === 0x41) offset = sleb();
            else if (op === 0x23) {
              uleb();
              offset = -1;
            }
            if (u8() !== 0x0b) {
              console.error(
                "wasm-size: unsupported data segment offset expression",
              );
              process.exit(1);
            }
          }
          const len = uleb();
          data.push({
            index: i,
            offset,
            size: len,
            body: bytes.subarray(p, p + len),
          });
          p += len;
        }
        break;
      }
    }

    p = end;
    sections.push({ id, name: label, size, body: bytes.subarray(start, end) });
  }

  for (const f of funcs) f.name = names.get(f.index + importedFuncs);
  const kept = sections.filter((s) => s.id !== 0);
  const shipped = kept.length === sections.length ? bytes : reassemble(kept);
  return { path, bytes, shipped, sections, funcs, data, importedFuncs };
}

// --- Attribution -------------------------------------------------------------

/**
 * Function name -> `group/subgroup` path, rolled up for the code tree.
 *
 * The Zig module names come through the name section as dotted paths
 * (`renderers.md4x-html.enter_block_callback`), so most of this is
 * re-spelling them into the source layout. The tail entries catch what has no
 * module path at all: musl, compiler-rt, and Zig's own std.
 */
const CODE_GROUPS: { re: RegExp; path: (m: RegExpMatchArray) => string[] }[] = [
  { re: /^renderers\.md4x-([\w-]+)\./, path: (m) => ["renderers", m[1]] },
  { re: /^parser\.(\w+)\./, path: (m) => ["parser", m[1]] },
  // src/md4x.zig is the parser root (md_parse and friends).
  { re: /^md4x\./, path: () => ["parser", "md4x.zig (root)"] },
  { re: /^yaml\.(\w+)\./, path: (m) => ["yaml", m[1]] },
  {
    re: /^(entity|scan|abi|unicode_tables|emoji)\./,
    path: (m) => ["md4x other", m[1]],
  },
  { re: /^md4x-wasm\./, path: () => ["md4x other", "wasm exports"] },
  {
    re: /^(mem|fmt|heap|hash_map|array_list|Io|sort|unicode|debug|math|meta|ascii|simd|start|posix|os|fs|process|Thread|crypto|json|time|builtin)[.$]/,
    path: (m) => ["zig std", m[1]],
  },
  { re: /^(compiler_rt|__)/, path: () => ["runtime", "compiler-rt"] },
  { re: /^c\.(\w+)\./, path: (m) => ["runtime", `libc (${m[1]})`] },
  {
    re: /^(printf_core|v?f?s?n?printf|pop_arg|pad|sn_write|wcrtomb|wctomb|strerror|str\w+|mem\w+|malloc|free|calloc|realloc|qsort\w*|abort|exit|_Exit|_start|writev|dummy|undefined_weak|fwrite|fput[cs]|fflush|__towrite|__stdio_write)/,
    path: () => ["runtime", "libc"],
  },
];

function groupOf(name: string | undefined): string[] {
  if (!name) return ["unnamed (stripped)", ""];
  for (const g of CODE_GROUPS) {
    const m = name.match(g.re);
    if (m) return g.path(m);
  }
  return ["unclassified", name.split(".")[0]];
}

/**
 * Runtime machinery worth calling out by name: each of these is pulled in
 * wholesale by a small number of call sites, so the cost is invisible in a
 * flat function list but removable in one edit.
 */
const COST_CENTERS: { label: string; note: string; re: RegExp }[] = [
  {
    label: "libc printf + 128-bit soft-float",
    note: "linked in by any snprintf/fprintf call site; printf_core's long double path drags the __*tf* set with it",
    // `__multi3` is deliberately NOT in this set: printf_core's long double
    // path does call it, but so does wyhash (`hash_map.StringContext.hash`),
    // which is its only caller here — attributing it to printf claimed 117
    // bytes this call site cannot remove.
    re: /^(printf_core|vfprintf|vsnprintf|snprintf|fprintf|sprintf|pop_arg|pad|sn_write|wcrtomb|wctomb|strerror|c\.math\.frexpl|__(add|sub|mul|div|cmp|unord|extend|trunc|fix|fixuns|float|floatun)\w*tf\w*)$/,
  },
  {
    label: "libc malloc/qsort",
    note: "the allocator and sort the C-shaped paths reach for",
    re: /^(c\.stdlib\.)?(malloc|free|calloc|realloc|qsort(_r)?)$/,
  },
  {
    label: "Zig std formatting",
    note: "std.fmt / std.debug.print reachable from somewhere in the graph",
    re: /^(fmt\.|Io\.Writer\.|debug\.)/,
  },
];

/** The generated tables' `[N]T{...}` literals, as counted from the source. */
type Table = {
  records: number;
  bytes: number;
  /**
   * Bytes the table must contribute to the data section. Without this probe a
   * table that got dead-stripped (or that a comptime switch left out) would
   * still be billed for its source-side size.
   */
  signature: Uint8Array;
};

/** Little-endian u32 array, as the bytes it becomes in the data section. */
const u32le = (values: number[]) =>
  new Uint8Array(
    values.flatMap((v) => [
      v & 0xff,
      (v >>> 8) & 0xff,
      (v >>> 16) & 0xff,
      (v >>> 24) & 0xff,
    ]),
  );

const ascii = (s: string) => new TextEncoder().encode(s);

/**
 * The bytes every `"…"` literal in `src` stands for, concatenated. Zig source
 * is UTF-8, so a literal's own byte length is not its runtime length: a `\xNN`
 * escape is four source bytes and one data byte, and a character written as
 * itself is one source character and up to four data bytes.
 */
function zigLiteralBytes(src: string): Uint8Array {
  const out: number[] = [];
  for (const [, body] of src.matchAll(/"((?:[^"\\]|\\.)*)"/g)) {
    // By code point, not by UTF-16 unit: the table's astral characters (𝔄, …)
    // are surrogate pairs that encode as one 4-byte sequence, not two.
    const chars = [...body];
    for (let i = 0; i < chars.length; i++) {
      if (chars[i] !== "\\") {
        out.push(...new TextEncoder().encode(chars[i]));
      } else if (chars[i + 1] === "x") {
        out.push(parseInt(chars[i + 2] + chars[i + 3], 16));
        i += 3;
      } else {
        out.push(0); // any other escape stands for exactly one byte
        i += 1;
      }
    }
  }
  return new Uint8Array(out);
}

/** Raw byte search. Not a string search: the data section is not text. */
function containsBytes(haystack: Uint8Array, needle: Uint8Array): boolean {
  outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
    for (let j = 0; j < needle.length; j++)
      if (haystack[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
}

/**
 * The generated tables that dominate the data section, sized from the source
 * they are generated into rather than from a guess at the layout — so the
 * number moves when the generator does. Record sizes are wasm32: a
 * `[*:0]const u8` is a 4-byte pointer, a `[]const u8` is pointer + length.
 */
const TABLES: {
  label: string;
  source: string;
  measure: (src: string) => Table | undefined;
}[] = [
  {
    label: "HTML entity table",
    source: "src/entity.zig",
    measure(src) {
      // A record blob plus a u16 checkpoint index — no pointers, so unlike the
      // other tables here this one costs the same in the NAPI addon, where a
      // relocation per record would otherwise dwarf the data it points at.
      const src_blob = src.slice(
        src.indexOf("const blob ="),
        src.indexOf("const index ="),
      );
      const blob = zigLiteralBytes(src_blob);
      const index = src.match(/const index = \[_\]u16\{([^}]*)\}/)?.[1] ?? "";
      const records = Number(src.match(/pub const count = (\d+)/)?.[1] ?? 0);
      if (blob.length === 0 || records === 0) return undefined;
      // The longest stored name, as the byte run least likely to occur by chance.
      const names =
        String.fromCharCode(...blob).match(/[A-Za-z][A-Za-z0-9]+/g) ?? [];
      return {
        records,
        bytes: blob.length + 2 * (index.match(/\d+,/g)?.length ?? 0),
        signature: ascii(
          names.reduce((a, b) => (b.length > a.length ? b : a), ""),
        ),
      };
    },
  },
  {
    label: "Emoji shortcode table (-Demoji=true)",
    source: "src/emoji.zig",
    measure(src) {
      const rows = [...src.matchAll(/\.name = "(.*?)", \.chars = "(.*?)"/g)];
      if (rows.length === 0) return undefined;
      // struct EMOJI { name: []const u8, chars: []const u8 } -> two slices.
      // `chars` are \u{...} escapes in source; count the UTF-8 bytes they mean.
      const utf8 = (s: string) =>
        [...s.matchAll(/\\u\{([0-9a-fA-F]+)\}/g)].reduce(
          (n, m) =>
            n +
            new TextEncoder().encode(String.fromCodePoint(parseInt(m[1], 16)))
              .length,
          0,
        );
      const strings = rows.reduce((n, m) => n + m[1].length + utf8(m[2]), 0);
      return {
        records: rows.length,
        bytes: rows.length * (8 + 8) + strings,
        signature: ascii(
          rows.map((m) => m[1]).reduce((a, b) => (b.length > a.length ? b : a)),
        ),
      };
    },
  },
  {
    label: "Unicode tables (punct/whitespace/fold)",
    source: "src/unicode_tables.zig",
    measure(src) {
      const arrays = [
        ...src.matchAll(/pub const \w+ = \[[^\]]*\]c_uint\{(.*?)\n\};/gs),
      ].map((m) =>
        m[1]
          .split(",")
          .map((x) => x.trim())
          .filter((x) => x.length > 0)
          .map(Number),
      );
      const records = arrays.reduce((n, a) => n + a.length, 0);
      if (records === 0) return undefined;
      return {
        records,
        bytes: records * 4,
        // The first array's contents verbatim — a run of u32s the linker keeps
        // contiguous, so a hit is unambiguous.
        signature: u32le(arrays[0]),
      };
    },
  },
];

// --- Formatting --------------------------------------------------------------

const kb = (n: number) => `${(n / 1024).toFixed(1)} KB`;
const pad = (s: string, n: number) => s.padStart(n);
const padEnd = (s: string, n: number) => s.padEnd(n);
const pct = (n: number, total: number) => `${((n / total) * 100).toFixed(1)}%`;
const gz = (b: Uint8Array) => gzipSync(b, { level: 9 }).length;
const signed = (n: number) => {
  if (n === 0) return "—";
  const magnitude = Math.abs(n) < 1024 ? `${Math.abs(n)} B` : kb(Math.abs(n));
  return `${n > 0 ? "+" : "-"}${magnitude}`;
};

/** Repo-relative when the file is inside the repo, absolute when it is not. */
function label(path: string): string {
  const rel = relative(projectDir, path);
  return rel && !rel.startsWith("..") ? rel : path;
}

function heading(text: string) {
  console.log(`\n\x1b[1m${text}\x1b[0m`);
}

// --- Report ------------------------------------------------------------------

type Node = { size: number; count: number; children: Map<string, Node> };

function tree(funcs: Func[]): Node {
  const root: Node = { size: 0, count: 0, children: new Map() };
  for (const f of funcs) {
    let node = root;
    node.size += f.size;
    node.count++;
    for (const key of groupOf(f.name)) {
      if (!key) continue;
      let child = node.children.get(key);
      if (!child)
        node.children.set(
          key,
          (child = { size: 0, count: 0, children: new Map() }),
        );
      child.size += f.size;
      child.count++;
      node = child;
    }
  }
  return root;
}

function printTree(node: Node, total: number, level = 1, indent = "  ") {
  const sorted = [...node.children].sort((a, b) => b[1].size - a[1].size);
  for (const [name, child] of sorted) {
    console.log(
      `${indent}${padEnd(name, 40 - indent.length)} ${pad(kb(child.size), 9)} ${pad(pct(child.size, total), 6)} ${pad(`${child.count} fn`, 7)}`,
    );
    if (level < depth) printTree(child, total, level + 1, `${indent}  `);
  }
}

function report(mod: Module) {
  const total = mod.shipped.length;
  const code = mod.sections.find((s) => s.id === 10);
  const bodies = mod.funcs.reduce((n, f) => n + f.size, 0);
  const dataBlob = mod.data.reduce((n, d) => n + d.size, 0);
  const custom = mod.sections.filter((s) => s.id === 0);

  console.log(
    `\x1b[1m${label(mod.path)}\x1b[0m — ${kb(total)} raw, ${kb(gz(mod.shipped))} gzipped`,
  );
  if (custom.length) {
    // The symbols build is only how the names got here; its DWARF is not part
    // of anything that ships, so it is excluded from every number above.
    console.log(
      `\x1b[2mstripped view — ${kb(mod.bytes.length - total)} of custom sections (${custom.map((s) => s.name.replace(/^custom:/, "")).join(", ")}) excluded\x1b[0m`,
    );
  }
  if (!mod.funcs.some((f) => f.name)) {
    console.log(
      "(no name section — rerun without --no-build for per-function names)",
    );
  }

  heading("SECTIONS");
  for (const s of [...mod.sections].sort((a, b) => b.size - a.size)) {
    if (s.id === 0) continue;
    if (s.size < 64 && s.id !== 10 && s.id !== 11) continue;
    console.log(
      `  ${padEnd(s.name, 28)} ${pad(kb(s.size), 9)} ${pad(pct(s.size, total), 6)} ${pad(kb(gz(s.body)), 9)} gz`,
    );
  }

  heading(`CODE — ${kb(bodies)} in ${mod.funcs.length} function bodies`);
  printTree(tree(mod.funcs), bodies);
  if (code && code.size > bodies) {
    console.log(
      `  ${padEnd("(section framing)", 40)} ${pad(kb(code.size - bodies), 9)}`,
    );
  }

  heading(`LARGEST FUNCTIONS (top ${top})`);
  for (const f of [...mod.funcs]
    .sort((a, b) => b.size - a.size)
    .slice(0, top)) {
    console.log(
      `  ${pad(kb(f.size), 9)} ${pad(pct(f.size, bodies), 6)}  ${f.name ?? `func[${f.index + mod.importedFuncs}]`}`,
    );
  }

  heading("COST CENTERS");
  for (const c of COST_CENTERS) {
    const hits = mod.funcs.filter((f) => f.name && c.re.test(f.name));
    if (hits.length === 0) continue;
    const size = hits.reduce((n, f) => n + f.size, 0);
    console.log(
      `  ${padEnd(c.label, 40)} ${pad(kb(size), 9)} ${pad(pct(size, bodies), 6)} ${pad(`${hits.length} fn`, 7)}`,
    );
    console.log(`    \x1b[2m${c.note}\x1b[0m`);
  }

  heading(`DATA — ${kb(dataBlob)} in ${mod.data.length} segments`);
  let attributed = 0;
  for (const t of TABLES) {
    const path = join(projectDir, t.source);
    if (!existsSync(path)) continue;
    const measured = t.measure(readFileSync(path, "utf8"));
    if (!measured) continue;
    if (!mod.data.some((d) => containsBytes(d.body, measured.signature))) {
      console.log(
        `  ${padEnd(t.label, 40)} ${pad("absent", 9)} \x1b[2m(not linked in)\x1b[0m`,
      );
      continue;
    }
    attributed += measured.bytes;
    console.log(
      `  ${padEnd(t.label, 40)} ${pad(kb(measured.bytes), 9)} ${pad(pct(measured.bytes, dataBlob), 6)} ${pad(`${measured.records} rec`, 10)} \x1b[2m${t.source}\x1b[0m`,
    );
  }
  const rest = dataBlob - attributed;
  console.log(
    `  ${padEnd("other rodata (literals, error tables)", 40)} ${pad(kb(rest), 9)} ${pad(pct(rest, dataBlob), 6)}`,
  );
  const printable = mod.data.reduce(
    (n, d) =>
      n + d.body.reduce((m, b) => m + (b >= 0x20 && b < 0x7f ? 1 : 0), 0),
    0,
  );
  console.log(
    `  \x1b[2m${pct(printable, dataBlob)} of the data section is printable ASCII\x1b[0m`,
  );
}

function reportDiff(mod: Module, other: Module) {
  heading(`DIFF vs ${label(other.path)}`);
  const delta = mod.shipped.length - other.shipped.length;
  console.log(
    `  total ${kb(other.shipped.length)} -> ${kb(mod.shipped.length)}  (${signed(delta)}, ${signed(gz(mod.shipped) - gz(other.shipped))} gz)`,
  );

  const sectionSizes = (m: Module) =>
    new Map(m.sections.filter((s) => s.id !== 0).map((s) => [s.name, s.size]));
  const nowSec = sectionSizes(mod);
  const beforeSec = sectionSizes(other);
  for (const key of new Set([...nowSec.keys(), ...beforeSec.keys()])) {
    const d = (nowSec.get(key) ?? 0) - (beforeSec.get(key) ?? 0);
    if (d !== 0) console.log(`  ${padEnd(key, 40)} ${pad(signed(d), 10)}`);
  }

  // Attributing a delta to a module needs names on BOTH sides; against a
  // stripped baseline every group would read as newly introduced.
  if (!other.funcs.some((f) => f.name) || !mod.funcs.some((f) => f.name)) {
    console.log(
      "  \x1b[2m(one side has no name section — per-function deltas unavailable)\x1b[0m",
    );
    return;
  }

  const groupSizes = (m: Module) => {
    const acc = new Map<string, number>();
    for (const f of m.funcs) {
      const key = groupOf(f.name).filter(Boolean).slice(0, depth).join("/");
      acc.set(key, (acc.get(key) ?? 0) + f.size);
    }
    return acc;
  };
  const now = groupSizes(mod);
  const before = groupSizes(other);
  const rows = [...new Set([...now.keys(), ...before.keys()])]
    .map((k) => ({ k, d: (now.get(k) ?? 0) - (before.get(k) ?? 0) }))
    .filter((r) => r.d !== 0)
    .sort((a, b) => Math.abs(b.d) - Math.abs(a.d));
  if (rows.length === 0) {
    console.log("  no per-group change");
    return;
  }
  for (const r of rows)
    console.log(`  ${padEnd(r.k, 40)} ${pad(signed(r.d), 10)}`);

  const funcSizes = (m: Module) => {
    const acc = new Map<string, number>();
    for (const f of m.funcs) {
      // Zig numbers each generic instantiation (`__anon_25603`), and the
      // numbering shifts on any unrelated change. Left alone, every one of them
      // shows up as a +N/-N pair of identical size and buries the real delta.
      if (!f.name) continue;
      const key = f.name.replace(/__(anon|struct)_\d+/g, "__$1");
      acc.set(key, (acc.get(key) ?? 0) + f.size);
    }
    return acc;
  };
  const fnNow = funcSizes(mod);
  const fnBefore = funcSizes(other);
  const fnRows = [...new Set([...fnNow.keys(), ...fnBefore.keys()])]
    .map((k) => ({ k, d: (fnNow.get(k) ?? 0) - (fnBefore.get(k) ?? 0) }))
    .filter((r) => r.d !== 0)
    .sort((a, b) => Math.abs(b.d) - Math.abs(a.d))
    .slice(0, top);
  if (fnRows.length) {
    heading(`LARGEST FUNCTION DELTAS (top ${top})`);
    for (const r of fnRows) console.log(`  ${pad(signed(r.d), 10)}  ${r.k}`);
  }
}

function json(mod: Module) {
  const bodies = mod.funcs.reduce((n, f) => n + f.size, 0);
  const flatten = (
    node: Node,
    prefix: string[] = [],
  ): Record<string, number> => {
    const out: Record<string, number> = {};
    for (const [name, child] of node.children) {
      out[[...prefix, name].join("/")] = child.size;
      Object.assign(out, flatten(child, [...prefix, name]));
    }
    return out;
  };
  return {
    file: label(mod.path),
    total: mod.shipped.length,
    gzip: gz(mod.shipped),
    sections: Object.fromEntries(
      mod.sections
        .filter((s) => s.id !== 0)
        .map((s) => [s.name, { size: s.size, gzip: gz(s.body) }]),
    ),
    code: {
      total: bodies,
      functions: mod.funcs.length,
      groups: flatten(tree(mod.funcs)),
    },
    costCenters: Object.fromEntries(
      COST_CENTERS.map((c) => [
        c.label,
        mod.funcs
          .filter((f) => f.name && c.re.test(f.name))
          .reduce((n, f) => n + f.size, 0),
      ]).filter(([, size]) => (size as number) > 0),
    ),
    functions: [...mod.funcs]
      .sort((a, b) => b.size - a.size)
      .slice(0, top)
      .map((f) => ({
        name: f.name ?? `func[${f.index + mod.importedFuncs}]`,
        size: f.size,
      })),
    data: {
      total: mod.data.reduce((n, d) => n + d.size, 0),
      segments: mod.data.map((d) => ({ offset: d.offset, size: d.size })),
    },
  };
}

// --- Main --------------------------------------------------------------------

const mod = parseWasm(locate());

if (asJson) {
  console.log(JSON.stringify(json(mod), null, 2));
} else {
  report(mod);
  if (diffPath) reportDiff(mod, parseWasm(resolve(diffPath)));
  console.log();
}
