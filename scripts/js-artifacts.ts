/**
 * The JS artifacts the vitest suites load — and the guard that keeps them honest.
 *
 * `packages/md4x/build/` (wasm + NAPI addons) and `packages/md4x/lib/standalone.mjs`
 * are gitignored build outputs. `md4x/napi`, `md4x/wasm` and `md4x/standalone`
 * resolve to whatever happens to be sitting there, so a suite can pass against a
 * binary built from an older `src/` and nothing says a word. Two distinct failure
 * modes have bitten this repo:
 *
 *   1. STALE — a fix lands in `src/`, the JS suite/bench runs against yesterday's
 *      `.node`, and the fix looks like it did not work (or a bug looks fixed).
 *   2. SHADOWED — a `node_modules/md4x` (i.e. the *published* package) on the
 *      resolution path. Test files inside `packages/md4x/` are protected by
 *      package self-reference, but any script at the repo root imports the
 *      published tarball instead of this checkout, silently and successfully.
 *
 * `check()` detects both. It is wired in as the vitest `globalSetup` (see
 * `vitest.config.mjs`), so every `vitest run` refuses to start against artifacts
 * that do not match `src/`.
 *
 * `build()` is the fix-it path (`bun run build:js`), also called by
 * `scripts/run-tests.ts` before it invokes vitest.
 *
 * CLI:
 *   bun scripts/js-artifacts.ts check    # report problems, exit 1 if any
 *   bun scripts/js-artifacts.ts build    # (re)build wasm + host NAPI + standalone
 *
 * Anything after `build` is forwarded verbatim to each `zig build` step, so a
 * comptime feature switch reaches the artifacts the JS suites load:
 *
 *   bun scripts/js-artifacts.ts build -Demoji=true
 */
import { execFileSync } from "node:child_process";
import {
  existsSync,
  readdirSync,
  realpathSync,
  statSync,
  utimesSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pkgDir = join(projectDir, "packages", "md4x");
const buildDir = join(pkgDir, "build");

/** The NAPI target for the machine running the tests — the only one they load. */
export function hostNapi(): { name: string; step: string; file: string } {
  // Mirrors the loader's own naming in packages/md4x/lib/napi.mjs.
  const isMusl =
    process.platform === "linux" &&
    !(process as any).report?.getReport?.()?.header?.glibcVersionRuntime;
  const name = `${process.platform}-${process.arch}${isMusl ? "-musl" : ""}`;
  return { name, step: `napi-${name}`, file: `md4x.${name}.node` };
}

type Artifact = {
  /** Repo-relative path, used verbatim in messages. */
  label: string;
  path: string;
  /** Rebuilding just this one. */
  command: string;
  /** Files it must not be older than. */
  inputs: () => string[];
};

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (entry.isFile()) out.push(p);
  }
  return out;
}

/** Everything a `zig build wasm` / `zig build napi-*` output depends on. */
function nativeInputs(): string[] {
  return [
    ...walk(join(projectDir, "src")),
    join(projectDir, "build.zig"),
    join(projectDir, "build.zig.zon"),
  ];
}

export function artifacts(): Artifact[] {
  const napi = hostNapi();
  const smallWasm = join(buildDir, "md4x-small.wasm");
  return [
    {
      label: "packages/md4x/build/md4x.wasm",
      path: join(buildDir, "md4x.wasm"),
      command: "zig build wasm",
      inputs: nativeInputs,
    },
    {
      label: "packages/md4x/build/md4x-small.wasm",
      path: smallWasm,
      command: "zig build wasm-small",
      inputs: nativeInputs,
    },
    {
      label: `packages/md4x/build/${napi.file}`,
      path: join(buildDir, napi.file),
      command: `zig build ${napi.step}`,
      inputs: nativeInputs,
    },
    {
      // Bundled from the ReleaseSmall wasm plus real on-disk JS sources, so it
      // goes stale for reasons the native inputs cannot express.
      label: "packages/md4x/lib/standalone.mjs",
      path: join(pkgDir, "lib", "standalone.mjs"),
      command: "bun run build:standalone",
      inputs: () => [
        smallWasm,
        join(projectDir, "scripts", "build-standalone.ts"),
        join(pkgDir, "lib", "wasm", "common.mjs"),
        join(pkgDir, "lib", "_shared.mjs"),
      ],
    },
  ];
}

function mtime(path: string): number {
  return statSync(path).mtimeMs;
}

function ago(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  if (s < 86_400)
    return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86_400)}d ${Math.floor((s % 86_400) / 3600)}h`;
}

/**
 * A `node_modules/md4x` anywhere on the resolution path that is not this
 * workspace package. Its mere presence is the bug: scripts outside
 * `packages/md4x/` resolve `md4x/napi` to it — successfully — instead of to
 * this checkout.
 */
function shadowProblems(): string[] {
  const problems: string[] = [];
  const real = realpathSync(pkgDir);
  for (const dir of [projectDir, join(projectDir, "packages"), pkgDir]) {
    const candidate = join(dir, "node_modules", "md4x");
    if (!existsSync(candidate)) continue;
    let target: string;
    try {
      target = realpathSync(candidate);
    } catch {
      continue;
    }
    if (target === real) continue;
    problems.push(
      [
        `  ${relative(projectDir, candidate)} -> ${target}`,
        `    A published md4x shadows this checkout on the module resolution path.`,
        `    Test files inside packages/md4x/ self-reference and are unaffected, but`,
        `    any script at the repo root imports THAT package instead of this one.`,
        `    remove it with: rm -rf ${relative(projectDir, candidate)}`,
      ].join("\n"),
    );
  }
  return problems;
}

/** Returns a human-readable problem per stale/missing/shadowed artifact. */
export function check(): string[] {
  const problems = shadowProblems();

  for (const artifact of artifacts()) {
    if (!existsSync(artifact.path)) {
      problems.push(
        [
          `  ${artifact.label}`,
          `    missing`,
          `    build it with: ${artifact.command}`,
        ].join("\n"),
      );
      continue;
    }
    const built = mtime(artifact.path);
    let newest = { path: "", mtime: 0 };
    for (const input of artifact.inputs()) {
      if (!existsSync(input)) continue;
      const m = mtime(input);
      if (m > newest.mtime) newest = { path: input, mtime: m };
    }
    if (newest.mtime > built) {
      problems.push(
        [
          `  ${artifact.label}`,
          `    built ${ago(newest.mtime - built)} BEFORE ${relative(projectDir, newest.path)} was last changed`,
          `    rebuild with: ${artifact.command}`,
        ].join("\n"),
      );
    }
  }
  return problems;
}

export function problemReport(problems: string[]): string {
  return [
    "",
    "md4x: the JS test artifacts do not match this checkout.",
    "",
    ...problems,
    "",
    "  packages/md4x/build/ and lib/standalone.mjs are gitignored build outputs.",
    "  md4x/napi, md4x/wasm and md4x/standalone load them as they are, so running",
    "  the suite now would test something other than the current src/.",
    "",
    "  Fix everything the JS tests need with:",
    "",
    "      bun run build:js",
    "",
    "  (or run the whole gate: bun scripts/run-tests.ts)",
    "",
  ].join("\n");
}

export function assertFresh(): void {
  const problems = check();
  if (problems.length > 0) throw new Error(problemReport(problems));
}

/** vitest `globalSetup` entry point — see vitest.config.mjs. */
export function setup(): void {
  assertFresh();
}

/**
 * Build every artifact the JS tests load: wasm, ReleaseSmall wasm, the host
 * NAPI addon, and the standalone bundle. Deliberately NOT `napi-all` — the
 * suites only ever dlopen the host target, and cross-building the other eight
 * would cost far more than it buys.
 */
export function build(zigArgs: string[] = []): void {
  const napi = hostNapi();
  const steps: [string, string[]][] = [
    ["zig", ["build", "wasm", ...zigArgs]],
    ["zig", ["build", "wasm-small", ...zigArgs]],
    ["zig", ["build", napi.step, ...zigArgs]],
    // Bundles the already-built md4x-small.wasm; it never invokes zig itself.
    ["bun", [join("scripts", "build-standalone.ts")]],
  ];
  for (const [cmd, args] of steps) {
    execFileSync(cmd, args, { cwd: projectDir, stdio: "inherit" });
  }

  // Zig's install step skips the copy when the cached output already matches,
  // leaving the installed file's mtime behind whatever it was. That is correct
  // for Zig (its cache is content-addressed) but it strands the freshness check
  // above, which only has mtimes to go on: a source file touched without a
  // content change would stay "stale" forever. A successful build means the
  // artifact IS current, so stamp it as such.
  const now = new Date();
  for (const artifact of artifacts()) {
    if (existsSync(artifact.path)) utimesSync(artifact.path, now, now);
  }
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (invokedDirectly) {
  const mode = process.argv[2] ?? "check";
  if (mode === "build") {
    build(process.argv.slice(3));
  } else if (mode === "check") {
    const problems = check();
    if (problems.length > 0) {
      console.error(problemReport(problems));
      process.exit(1);
    }
    console.log("md4x: JS artifacts are up to date with src/.");
  } else {
    console.error(`usage: bun scripts/js-artifacts.ts [check|build]`);
    process.exit(2);
  }
}
