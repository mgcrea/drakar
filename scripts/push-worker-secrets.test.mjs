// Tests for the guard rails on `push-worker-secrets.mjs`.
//
// The decisions are imported and called rather than run through the script, so
// no case here can reach `wrangler secret bulk`: a test that got as far as the
// push would be a test that writes secrets to the Worker taking real money,
// which is exactly the accident the script exists to prevent. The few that do
// run it as a process are refusals, which exit before wrangler is spawned.
//
// The rule that matters most is the file name. A test-mode webhook secret has
// no marker in it, so a `.test.vars` whose only Stripe value was that secret
// passed the old marker check and went to production without `--env`.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import {
  checkSecrets,
  parseArgs,
  parseDotenv,
  parseSecrets,
  stripeMode,
} from "./push-worker-secrets.mjs";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "push-worker-secrets.mjs");

/** A test-mode set as the dashboard hands it over: nothing in it says "test". */
const TEST_SET = [
  ["LICENSE_SIGNING_KEY", "MC4CAQAwBQYDK2VwBCIEIexample"],
  ["STRIPE_WEBHOOK_SECRET", "whsec_Q2xhdWRlIHdhcyBoZXJl"],
];

const text = (messages) => messages.map((lines) => lines.join("\n")).join("\n\n");

describe("parseArgs", () => {
  it("reads the file and --env in either order and either spelling", () => {
    const expected = { file: ".test.vars", targetEnv: "test" };
    assert.deepEqual(parseArgs([".test.vars", "--env", "test"]), expected);
    assert.deepEqual(parseArgs(["--env", "test", ".test.vars"]), expected);
    assert.deepEqual(parseArgs(["--env=test", ".test.vars"]), expected);
    assert.deepEqual(parseArgs([".prod.vars"]), { file: ".prod.vars", targetEnv: null });
  });

  it("refuses --env with no name after it", () => {
    assert.match(parseArgs([".test.vars", "--env"]).error, /--env needs a name/);
    assert.match(parseArgs([".test.vars", "--env="]).error, /--env needs a name/);
    assert.match(parseArgs(["--env", "--x", ".test.vars"]).error, /--env needs a name/);
  });

  // An option this did not forward used to vanish, so `--environment test`
  // pushed to production with no complaint.
  it("refuses an option it would not forward to wrangler", () => {
    assert.match(parseArgs([".test.vars", "--environment", "test"]).error, /unknown option/);
  });

  it("refuses no file, or two", () => {
    assert.match(parseArgs(["--env", "test"]).error, /name a dotenv file/);
    assert.match(parseArgs([".prod.vars", ".test.vars"]).error, /one dotenv file at a time/);
  });
});

describe("parseDotenv, read the way wrangler reads it", () => {
  const cases = [
    ["a bare value", "KEY=value", { KEY: "value" }],
    ["an empty pair of double quotes, which is an empty secret", 'KEY=""', { KEY: "" }],
    ["an empty pair of single quotes", "KEY=''", { KEY: "" }],
    ["single quotes around a space", "KEY='a b'", { KEY: "a b" }],
    ["backticks", "KEY=`a b`", { KEY: "a b" }],
    ["an inline comment", "KEY=value # note", { KEY: "value" }],
    ["a # inside quotes", 'KEY="a#b"', { KEY: "a#b" }],
    ["\\n inside double quotes, expanded", 'KEY="a\\nb"', { KEY: "a\nb" }],
    ["\\n inside single quotes, left alone", "KEY='a\\nb'", { KEY: "a\\nb" }],
    ["an export prefix", "export KEY=value", { KEY: "value" }],
    ["spaces around the equals sign", "KEY = value ", { KEY: "value" }],
    ["CRLF line endings", "A=1\r\nB=2\r\n", { A: "1", B: "2" }],
    ["a commented-out line", "# KEY=value\nOTHER=1", { OTHER: "1" }],
    ["an empty value followed by another line", "KEY=\nOTHER=1", { KEY: "", OTHER: "1" }],
    ["a later duplicate, which wins", "KEY=1\nKEY=2", { KEY: "2" }],
    ["a lowercase name", "key=value", { key: "value" }],
  ];
  for (const [label, source, expected] of cases) {
    it(label, () => {
      assert.deepEqual(parseDotenv(source), expected);
    });
  }
});

describe("parseSecrets", () => {
  it("reads dotenv when the file is not JSON", () => {
    assert.deepEqual(parseSecrets("A=1\nB='2'\n"), {
      entries: [
        ["A", "1"],
        ["B", "2"],
      ],
    });
  });

  it("reads a JSON object first, skipping nulls, as wrangler does", () => {
    assert.deepEqual(parseSecrets('{"A":"1","B":null}'), { entries: [["A", "1"]] });
  });

  it("refuses JSON that wrangler would refuse", () => {
    assert.match(parseSecrets('{"A":1}').error, /A is not a string/);
    assert.match(parseSecrets("42").error, /not an object/);
  });
});

describe("stripeMode", () => {
  it("reads API keys and nothing else", () => {
    assert.equal(stripeMode("sk_test_abc"), "test");
    assert.equal(stripeMode("rk_live_abc"), "live");
    assert.equal(stripeMode("whsec_test"), "test");
    // The case the old check got wrong: this says nothing about its mode.
    assert.equal(stripeMode("whsec_Q2xhdWRlIHdhcyBoZXJl"), null);
  });
});

describe("checkSecrets", () => {
  it("refuses any file but .prod.vars when no --env is given, markers or not", () => {
    for (const file of [".test.vars", "apps/api/.test.vars", "prod.vars", ".prod.vars.bak"]) {
      const { errors } = checkSecrets({ file, targetEnv: null, entries: TEST_SET });
      assert.equal(errors.length, 1, file);
      assert.match(text(errors), /no --env was given/);
      // The message has to name the fix, not just the problem.
      assert.match(text(errors), /--env test/);
    }
  });

  it("lets .prod.vars go to production, wherever it lives", () => {
    for (const file of [".prod.vars", "apps/api/.prod.vars", "/tmp/x/.prod.vars"]) {
      const { errors, warnings } = checkSecrets({
        file,
        targetEnv: null,
        entries: [...TEST_SET, ["STRIPE_SECRET_KEY", "sk_live_abc"]],
      });
      assert.deepEqual(errors, [], file);
      assert.deepEqual(warnings, [], file);
    }
  });

  it("still refuses .prod.vars carrying a test-mode API key", () => {
    const { errors } = checkSecrets({
      file: ".prod.vars",
      targetEnv: null,
      entries: [...TEST_SET, ["STRIPE_SECRET_KEY", "sk_test_abc"]],
    });
    assert.match(text(errors), /TEST-mode Stripe credentials and no --env/);
  });

  // A real test-mode set is an API key that says test beside a webhook secret
  // that says nothing. The old check counted the silent one as live and warned
  // about a mix on every genuine rehearsal.
  it("pushes a real test-mode set to --env test without calling it a mix", () => {
    const { errors, warnings } = checkSecrets({
      file: ".test.vars",
      targetEnv: "test",
      entries: [...TEST_SET, ["STRIPE_SECRET_KEY", "sk_test_abc"]],
    });
    assert.deepEqual(errors, []);
    assert.deepEqual(warnings, []);
  });

  it("warns about a mix, a live key heading to a named environment, and the production file", () => {
    const { warnings } = checkSecrets({
      file: ".prod.vars",
      targetEnv: "test",
      entries: [
        ["STRIPE_WEBHOOK_SECRET", "whsec_test"],
        ["STRIPE_SECRET_KEY", "sk_live_abc"],
      ],
    });
    assert.match(text(warnings), /mixes test and live/);
    assert.match(text(warnings), /LIVE-mode Stripe credentials, going to the "test"/);
    assert.match(text(warnings), /is the production file/);
  });

  it("refuses an empty value, including one that is only quotes", () => {
    const { entries } = parseSecrets('LICENSE_SIGNING_KEY=""\nSTRIPE_WEBHOOK_SECRET=whsec_x\n');
    const { errors } = checkSecrets({ file: ".prod.vars", targetEnv: null, entries });
    assert.match(text(errors), /LICENSE_SIGNING_KEY is empty in \.prod\.vars/);
  });

  it("refuses a file that defines nothing", () => {
    const { entries } = parseSecrets("# just a comment\n");
    const { errors } = checkSecrets({ file: ".prod.vars", targetEnv: null, entries });
    assert.match(text(errors), /defines no KEY=VALUE pairs/);
  });
});

describe("the script, as a process", () => {
  const work = mkdtempSync(join(tmpdir(), "drakar-secrets-"));
  after(() => rmSync(work, { recursive: true, force: true }));

  /** Refusals only: every case below must exit before wrangler is spawned. */
  const refuse = (args) => {
    try {
      execFileSync(process.execPath, [SCRIPT, ...args], { encoding: "utf8", stdio: "pipe" });
    } catch (error) {
      return { code: error.status, output: String(error.stderr ?? "") };
    }
    assert.fail("the script did not refuse, and would have reached wrangler");
  };

  it("exits 2 for a test set with no --env", () => {
    const file = join(work, ".test.vars");
    writeFileSync(file, TEST_SET.map(([name, value]) => `${name}=${value}`).join("\n"));
    const { code, output } = refuse([file]);
    assert.equal(code, 2);
    assert.match(output, /FATAL: no --env was given/);
  });

  it("exits 2 for --env with no name", () => {
    const { code, output } = refuse([join(work, ".test.vars"), "--env"]);
    assert.equal(code, 2);
    assert.match(output, /--env needs a name/);
  });

  it("exits 2 for a file that is not there", () => {
    const { code, output } = refuse([join(work, "absent", ".prod.vars")]);
    assert.equal(code, 2);
    assert.match(output, /cannot read/);
  });
});
