// Tests for when `generate-revocations.mjs --check` may pass without looking.
//
// Only the tokenless branch is exercised, and only as a process: every case
// here exits before wrangler is spawned, so none of them reaches D1 or needs a
// credential. What the rest of the script does against a real database is
// what CI's "Revocations drift" step is for.
//
// The rule under test is the one a release depends on. Without a token the
// check skips, passing, so a pull request from a fork does not fail over a
// check it structurally cannot run. On a release tag that same skip would pass
// a notarized build carrying whatever list happens to be committed, refunded
// keys included, the day the secret is renamed or rotated.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "generate-revocations.mjs");

/** The script with `--check`, no Cloudflare token, and `GITHUB_REF` set to `ref`. */
const tokenless = (ref) => {
  const env = { ...process.env, GITHUB_REF: ref };
  delete env.CLOUDFLARE_API_TOKEN;
  return spawnSync(process.execPath, [SCRIPT, "--check"], { env, encoding: "utf8" });
};

describe("generate-revocations --check without a token", () => {
  it("skips, passing, on a branch or a pull request", () => {
    for (const ref of ["refs/heads/main", "refs/pull/7/merge"]) {
      const run = tokenless(ref);
      assert.equal(run.status, 0, run.stderr);
      assert.match(run.stdout, /skipped: no CLOUDFLARE_API_TOKEN/);
    }
  });

  it("fails on a release tag, where release-app depends on it", () => {
    const run = tokenless("refs/tags/app-v1.2.3");
    assert.equal(run.status, 1);
    assert.match(run.stderr, /no CLOUDFLARE_API_TOKEN on a release tag/);
  });
});
