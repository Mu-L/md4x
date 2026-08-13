#!/usr/bin/env bun
// Lists mity/md4c commits that landed after the sha md4x last reviewed, so a
// sync only has to look at what is genuinely new.
//
//   bun scripts/upstream-sync.ts            # new commits touching code/tests, oldest first
//   bun scripts/upstream-sync.ts --all      # include README/CHANGELOG/CI/CMake churn
//   bun scripts/upstream-sync.ts --no-fetch # use the local mirror as-is (offline)
//
// State lives in `.agents/upstream-sync.json` (fork point + last reviewed sha);
// the per-commit verdicts live in `.agents/upstream-sync.md`. Both are updated by
// hand at the end of a sync — this script only reports, it never writes.
//
// Upstream is fetched into a bare mirror under $TMPDIR (override with $MD4C_CLONE);
// nothing in this repo is touched and no network access to this repo is needed.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const selfPath = dirname(fileURLToPath(import.meta.url));
const projectDir = resolve(selfPath, "..");
const statePath = resolve(projectDir, ".agents/upstream-sync.json");

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  console.log(
    [
      "Usage: bun scripts/upstream-sync.ts [--all] [--no-fetch]",
      "",
      "  --all       do not filter by path (shows README/CHANGELOG/CI commits too)",
      "  --no-fetch  do not contact the network; report from the local mirror",
      "",
      "Env: MD4C_CLONE  path to a md4c clone or mirror (default: $TMPDIR/md4c-upstream.git)",
    ].join("\n"),
  );
  process.exit(0);
}
const showAll = args.includes("--all");
const noFetch = args.includes("--no-fetch");

const state = JSON.parse(readFileSync(statePath, "utf8")) as {
  upstream: string;
  branch: string;
  fork_point: string;
  last_reviewed: string;
  last_reviewed_date: string;
  paths: string[];
};

const clone = process.env.MD4C_CLONE || join(tmpdir(), "md4c-upstream.git");

function git(cwdArgs: string[], quiet = false): string {
  return execFileSync("git", cwdArgs, {
    encoding: "utf8",
    stdio: quiet ? ["ignore", "pipe", "pipe"] : ["ignore", "pipe", "inherit"],
  });
}

function fail(message: string): never {
  console.error(`upstream-sync: ${message}`);
  process.exit(1);
}

// --- 1. Make sure we have a local copy of upstream. ---

const haveClone =
  existsSync(join(clone, "HEAD")) || existsSync(join(clone, ".git"));

if (!haveClone) {
  if (noFetch) {
    fail(
      `no md4c clone at ${clone} and --no-fetch was given.\n` +
        `  Clone one first:  git clone --mirror --filter=blob:none ${state.upstream} ${clone}\n` +
        `  Or point MD4C_CLONE at an existing checkout.`,
    );
  }
  console.error(`Cloning ${state.upstream} into ${clone} ...`);
  try {
    git(["clone", "--mirror", "--filter=blob:none", state.upstream, clone]);
  } catch {
    fail(
      `could not clone ${state.upstream} (offline?).\n` +
        `  Retry when online, or point MD4C_CLONE at an existing md4c clone:\n` +
        `    MD4C_CLONE=/path/to/md4c bun scripts/upstream-sync.ts --no-fetch`,
    );
  }
} else if (noFetch) {
  console.error(`Using ${clone} without fetching (results may be stale).`);
} else {
  try {
    git(["-C", clone, "fetch", "--quiet", "--prune", "origin"], true);
  } catch {
    console.error(
      `warning: could not fetch ${state.upstream} (offline?) — reporting from the\n` +
        `         existing mirror at ${clone}, which may be stale.`,
    );
  }
}

// --- 2. Resolve the two ends of the range. ---

function revParse(rev: string): string | null {
  try {
    return git(
      ["-C", clone, "rev-parse", "--verify", "--quiet", rev],
      true,
    ).trim();
  } catch {
    return null;
  }
}

// A mirror keeps upstream branches under refs/heads/; a normal clone under
// refs/remotes/origin/. Accept either.
const head =
  revParse(`refs/remotes/origin/${state.branch}`) ??
  revParse(`refs/heads/${state.branch}`);
if (!head) {
  fail(`branch '${state.branch}' not found in ${clone}.`);
}
if (!revParse(`${state.last_reviewed}^{commit}`)) {
  fail(
    `last_reviewed sha ${state.last_reviewed.slice(0, 7)} is not in ${clone}.\n` +
      `  If that clone is shallow: git -C ${clone} fetch --unshallow`,
  );
}

// --- 3. Report. ---

function log(paths: string[]): string[] {
  const argv = [
    "-C",
    clone,
    "log",
    "--reverse",
    "--no-merges",
    "--date=short",
    "--format=%h  %ad  %s",
    `${state.last_reviewed}..${head}`,
  ];
  if (paths.length > 0) argv.push("--", ...paths);
  return git(argv, true).split("\n").filter(Boolean);
}

const relevant = log(showAll ? [] : state.paths);
const total = showAll ? relevant.length : log([]).length;

console.log(
  `upstream ${state.upstream}#${state.branch} @ ${head.slice(0, 7)}\n` +
    `last reviewed ${state.last_reviewed.slice(0, 7)} (${state.last_reviewed_date})\n`,
);

if (relevant.length === 0) {
  console.log(
    total === 0
      ? "Up to date — no new upstream commits."
      : `No new commits touching ${state.paths.join(", ")} (${total} README/CHANGELOG/CI-only commits, see --all).`,
  );
  process.exit(0);
}

console.log(relevant.join("\n"));
console.log(
  `\n${relevant.length} commit(s)` +
    (showAll ? "" : ` touching ${state.paths.join(", ")}`) +
    (total > relevant.length
      ? `; ${total - relevant.length} more filtered out (see --all)`
      : "") +
    ".",
);
console.log(
  `\nReview each, then append a row per sha to .agents/upstream-sync.md and bump\n` +
    `last_reviewed / last_reviewed_date / reviewed_on in .agents/upstream-sync.json.\n` +
    `Record the do-not-port decisions too — they are the ones that get re-litigated.`,
);
