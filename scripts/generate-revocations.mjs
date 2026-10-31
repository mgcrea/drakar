#!/usr/bin/env node
// Bake the revoked licence IDs into the app.
//
// Revocation lands at BUILD time, not run time, and that is the whole shape of
// it. The app asks nobody anything — scripts/audit-network.sh fails the build
// over any connection beyond the opt-in update check — so there is no list it
// can consult while running. A refunded key therefore keeps working until the
// next release and then stops. That is to be said to the buyer rather than left
// to be discovered. The EULA says it in Section 5(a), which the site renders at
// /terms, as revoke() in apps/api/src/index.ts notes.
//
// Generated-and-committed rather than fetched by CI. Reading D1 from the release
// job would put a network dependency in the path of shipping, so an outage at
// Cloudflare would become an outage in releases — and it would buy nothing,
// since a revocation cannot take effect before the next build either way. CI
// runs `--check` in its own Revocations job to confirm the committed file is
// current, and skips even that when it has no credentials, so forks and pull
// requests are unaffected. A release tag is the exception: there a missing
// token fails, because release-app needs that job.
//
//   node scripts/generate-revocations.mjs            # rewrite the Swift file
//   node scripts/generate-revocations.mjs --check    # fail if it is stale
//   node scripts/generate-revocations.mjs --local    # against the local D1

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { databaseConfigured, testDatabaseConfigured } from "./lib/revocations.mjs";

// `fileURLToPath`, not `.pathname`: the latter leaves a checkout under a path
// with a space percent-encoded, and every path built from it then misses.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TARGET = join(ROOT, "apps/apple/Drakar/Licence/Revocations.swift");
const API = join(ROOT, "apps/api");

const args = process.argv.slice(2);
const check = args.includes("--check");
const local = args.includes("--local");

// The skip is for --check only, and only for CI. A pull request from a fork has
// no secrets and neither does a clean clone; failing there would turn "we cannot
// confirm this" into "the build is broken", which it is not — the committed file
// is what the build uses.
//
// Writing is the opposite case and must never skip. A developer authenticates
// wrangler with `wrangler login`, not a token in the environment, so guarding the
// write path on CLOUDFLARE_API_TOKEN made `make revocations` print "skipped" and
// change nothing — after a refund, silently leaving the refunded key working
// while looking like it had been handled. Let wrangler's own auth decide, and
// let it fail loudly when there is none.
//
// A release tag is not a pull request. release-app needs the job that runs
// this, so a skip there (a secret renamed, rotated, or moved where the job
// cannot read it) would pass a notarized build carrying whatever list happens
// to be committed, refunded keys included. On a tag the missing token is the
// failure.
if (check && !local && !process.env.CLOUDFLARE_API_TOKEN) {
  if (process.env.GITHUB_REF?.startsWith("refs/tags/")) {
    console.error("FATAL: no CLOUDFLARE_API_TOKEN on a release tag, cannot confirm against D1");
    process.exit(1);
  }
  console.log("skipped: no CLOUDFLARE_API_TOKEN, cannot confirm against D1");
  process.exit(0);
}

/**
 * The result rows out of `wrangler d1 execute --json`.
 *
 * The whole of stdout first, since that is what `--json` promises. Some wrangler
 * paths print a banner or a warning around the document, so failing that, try
 * each `[` in turn up to the last `]`. Slicing at the FIRST `[` broke on a
 * banner that contained one, such as a `[wrangler]` prefix. Whatever parses is
 * then checked for the shape read below, so a stray bracketed fragment that
 * happens to be valid JSON is refused rather than read as zero revocations.
 */
const resultsOf = (raw) => {
  const candidates = [raw];
  const end = raw.lastIndexOf("]");
  for (let at = raw.indexOf("["); at !== -1 && at < end; at = raw.indexOf("[", at + 1)) {
    candidates.push(raw.slice(at, end + 1));
  }
  for (const candidate of candidates) {
    let document;
    try {
      document = JSON.parse(candidate);
    } catch {
      continue;
    }
    if (Array.isArray(document) && Array.isArray(document[0]?.results)) {
      return document[0].results;
    }
  }
  throw new Error("no D1 result document in wrangler's output");
};

// `rows` of one D1 database, or exit 2 naming it. `extra` selects the
// wrangler environment the binding lives in.
const read = (database, query, extra = []) => {
  try {
    const raw = execFileSync(
      "pnpm",
      [
        "exec",
        "wrangler",
        "d1",
        "execute",
        database,
        ...extra,
        local ? "--local" : "--remote",
        "--json",
        "--command",
        query,
      ],
      { cwd: API, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    return resultsOf(raw);
  } catch (error) {
    console.error(`FATAL: could not read ${database}: ${String(error?.message ?? error)}`);
    process.exit(2);
  }
};

// DIVERGES from armada, whose production database has existed since its first
// sale: Drakar's had no id in wrangler.jsonc until it was created on 2026-10-29.
// With no database there has been no sale, so there is nothing to revoke and the
// list is empty. That answer is refused below
// if the committed list is not empty: an id gone missing from wrangler.jsonc must
// not quietly bring refunded keys back to life. `--local` reads the local D1,
// which needs no id.
const WRANGLER = join(API, "wrangler.jsonc");
const wrangler = existsSync(WRANGLER) ? readFileSync(WRANGLER, "utf8") : "";
const hasDatabase = local || databaseConfigured(wrangler, "drakar-licenses");
if (!hasDatabase) {
  console.log("no database yet: drakar-licenses has no database_id in apps/api/wrangler.jsonc");
}

const revoked = hasDatabase
  ? read("drakar-licenses", "SELECT id FROM licenses WHERE revoked_at IS NOT NULL ORDER BY id")
  : [];

// Every licence the test environment ever minted, revoked or not. It signs
// with the production key, so that a test purchase proves the shipped app
// accepts it, which makes each of those keys a real one, from a checkout
// anybody holding a test-mode link can complete with card 4242. Revoking all
// of them leaves the rehearsal working in the build under test and in no
// released one. Read only once wrangler.jsonc gives the database an id: before
// that it does not exist, and once it does, failing to read it is fatal like
// any other read here.
const rehearsed = testDatabaseConfigured(wrangler)
  ? read("drakar-licenses-test", "SELECT id FROM licenses ORDER BY id", ["--env", "test"])
  : [];

const ids = [
  ...new Set([...revoked, ...rehearsed].map((row) => row.id).filter(Boolean)),
].toSorted();

// The hand-written doc comment is kept and the declaration regenerated. The
// declaration is matched with or without `nonisolated`: a split on a bare
// `\nenum Revocations` missed the committed spelling, kept the whole file as the
// header, and appended a second declaration that does not compile.
const current = readFileSync(TARGET, "utf8");
const declaration = current.search(/^(?:nonisolated )?enum Revocations\b/m);
if (declaration === -1) {
  console.error("FATAL: no `enum Revocations` declaration in Revocations.swift to regenerate");
  process.exit(1);
}
const header = current.slice(0, declaration);
// `JSON.stringify`, not string interpolation — the same escaper
// `generate-changelog.mjs` uses for every value it writes into Swift. These ids
// come from a DATABASE, which makes this the one string in the release path
// nobody in this repo chose, and a quote or a backslash in one would emit Swift
// that does not compile.
const swiftString = (value) => JSON.stringify(value);
// One id per line, trailing comma included, except when there is only one:
// swift-format's TrailingComma rule reads a one-element literal as a single-line
// one and fails `make format-swift-check` over the comma, which on a release tag
// fails the App job the release needs.
const items = ids.map((id) => `    ${swiftString(id)}`).join(",\n");
const list = ids.length === 0 ? "[]" : `[\n${items}${ids.length > 1 ? "," : ""}\n  ]`;
const next = `${header}nonisolated enum Revocations {\n  static let ids: Set<String> = ${list}\n}\n`;

if (!hasDatabase && current !== next) {
  console.error("FATAL: Revocations.swift lists licences, but drakar-licenses has no");
  console.error("database_id to read them from. Restore it in apps/api/wrangler.jsonc");
  console.error("rather than dropping them.");
  process.exit(1);
}

if (check) {
  if (readFileSync(TARGET, "utf8") === next) {
    console.log(`ok: ${ids.length} revoked licence(s), Revocations.swift is current`);
    process.exit(0);
  }
  console.error("FATAL: Revocations.swift is stale. Run `make revocations` and commit the result.");
  process.exit(1);
}

writeFileSync(TARGET, next);
console.log(
  `wrote ${ids.length} revoked licence(s) to apps/apple/Drakar/Licence/Revocations.swift`,
);
