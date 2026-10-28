#!/usr/bin/env node
// Check a dotenv file, then hand it to `wrangler secret bulk`.
//
// The push itself is wrangler's: `secret bulk` takes a KEY=VALUE file directly
// and applies the whole set in a single request, which is both fewer round trips
// and less to go wrong halfway than a loop of `secret put`. This script exists
// for the things it does not do.
//
// The first is refusing an incomplete set. `.prod.vars` carries the live webhook
// signing secret, which Stripe shows exactly once at creation — so the realistic
// mistake is running this before it has been pasted in, pushing an empty string,
// and getting a Worker that rejects every real payment with a 400 that reads like
// a signature bug. The values also have to be the same Stripe mode: a live
// webhook secret with a test API key fulfils and silently records no price.
//
// "Empty" means empty the way wrangler reads the file, not the way a quick split
// on `=` does. `KEY=""` is two quote characters to a naive reader and an empty
// secret to wrangler, so the file is parsed here with the same rules wrangler
// applies (see `parseSecrets`).
//
// `.dev.vars` needs none of this — wrangler reads it automatically for local dev
// and it never reaches the deployed Worker.
//
// The second is refusing to push anything but `.prod.vars` at the production
// Worker. `.test.vars.example` documents a rehearsal against a test-mode
// deployment, but wrangler applies secrets to the default environment unless
// told otherwise — so following those instructions without `--env test` would
// replace the LIVE webhook signing secret with a test-mode one, and every real
// payment would then be refused as an invalid signature with nothing anywhere
// saying why. Bastion learned that one.
//
// Bastion's guard looks for test-mode markers in the values, and that cannot
// see the secret that matters: a test-mode endpoint's `whsec_` is as featureless
// as a live one, and only an API key says `sk_test_`, when the file has one at
// all. So the file NAME is the guard here, and the markers are a second opinion.
//
// Everything that decides is exported, and the push runs only when this file is
// the entry point, so push-worker-secrets.test.mjs can put each rule through its
// paces without any case being able to reach wrangler.
//
//   node scripts/push-worker-secrets.mjs .prod.vars
//   node scripts/push-worker-secrets.mjs .test.vars --env test

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** The one file that may go to the default environment without an `--env`. */
export const PRODUCTION_FILE = ".prod.vars";

/**
 * The file and the target environment, or `{ error }` saying why not.
 *
 * `--env=name` is read as well as `--env name`, and any other option is
 * refused. Nothing but `--env` is forwarded to wrangler, so a spelling this did
 * not recognise used to be dropped on the floor, and the push went to the
 * production Worker.
 */
export const parseArgs = (args) => {
  let file = null;
  let targetEnv = null;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (argument === "--env" || argument.startsWith("--env=")) {
      const name = argument === "--env" ? args[++index] : argument.slice("--env=".length);
      if (!name || name.startsWith("-")) return { error: "--env needs a name, e.g. --env test" };
      targetEnv = name;
    } else if (argument.startsWith("-")) {
      return { error: `unknown option ${argument}` };
    } else if (file === null) {
      file = argument;
    } else {
      return { error: `one dotenv file at a time, got ${file} and ${argument}` };
    }
  }
  if (!file) return { error: "name a dotenv file, e.g. .prod.vars" };
  return { file, targetEnv };
};

// dotenv 16.3.1's line pattern, verbatim. wrangler bundles that copy into
// wrangler-dist/cli.js and calls its `parse` for a file that is not JSON.
const DOTENV_LINE =
  /(?:^|^)\s*(?:export\s+)?([\w.-]+)(?:\s*=\s*?|:\s+?)(\s*'(?:\\'|[^'])*'|\s*"(?:\\"|[^"])*"|\s*`(?:\\`|[^`])*`|[^#\r\n]+)?\s*(?:#.*)?(?:$|$)/gm;

/**
 * dotenv's `parse`, as wrangler runs it: CRLF folded, `export ` and inline
 * comments dropped, one pair of matching quotes stripped, `\n` and `\r`
 * expanded inside double quotes only, and a later duplicate winning.
 */
export const parseDotenv = (source) => {
  const values = {};
  const text = String(source).replace(/\r\n?/gm, "\n");
  for (const match of text.matchAll(DOTENV_LINE)) {
    let value = (match[2] || "").trim();
    const quote = value[0];
    value = value.replace(/^(['"`])([\s\S]*)\1$/gm, "$2");
    if (quote === '"') value = value.replace(/\\n/g, "\n").replace(/\\r/g, "\r");
    values[match[1]] = value;
  }
  return values;
};

/**
 * The name/value pairs `wrangler secret bulk` would push, or `{ error }`.
 *
 * The same two steps wrangler takes (`parseBulkInputToObject` in wrangler 4):
 * the file as strict JSON first, and dotenv only if that fails. A JSON object
 * pushes its string values and skips its nulls; anything else in one is refused
 * here, as wrangler refuses it.
 */
export const parseSecrets = (source) => {
  const text = String(source);
  let document;
  try {
    document = JSON.parse(text);
  } catch {
    return { entries: Object.entries(parseDotenv(text)) };
  }
  if (document === null || typeof document !== "object" || Array.isArray(document)) {
    return { error: "is JSON, but not an object of string values" };
  }
  const entries = Object.entries(document).filter(([, value]) => value != null);
  const odd = entries.find(([, value]) => typeof value !== "string");
  if (odd) return { error: `is JSON, and ${odd[0]} is not a string` };
  return { entries };
};

/**
 * Which Stripe mode a value says it belongs to, or `null` when it does not say.
 *
 * API keys say (`sk_test_`, `rk_live_`, ...). A webhook signing secret does not,
 * so it is `null` rather than being counted as live, which made every genuine
 * test-mode set look like a mix. `whsec_test` is only ever a placeholder, and
 * reads as test.
 */
export const stripeMode = (value) => {
  if (value.includes("_test_") || value.startsWith("whsec_test")) return "test";
  if (value.includes("_live_")) return "live";
  return null;
};

/**
 * Every reason to refuse this push, and every reason to warn about it.
 *
 * Each message is a list of lines. Any error means exit 2 before wrangler is
 * spawned.
 */
export const checkSecrets = ({ file, targetEnv, entries }) => {
  const errors = [];
  const warnings = [];

  if (entries.length === 0) {
    errors.push([`${file} defines no KEY=VALUE pairs`]);
    return { errors, warnings };
  }

  const blank = entries.filter(([, value]) => value.trim() === "").map(([name]) => name);
  if (blank.length > 0) {
    errors.push([
      `${blank.join(", ")} ${blank.length === 1 ? "is" : "are"} empty in ${file}.`,
      "A half-applied secret set fails in ways that read as a code bug.",
      "A secret meant to stay unset should have no line at all.",
    ]);
  }

  // Not a warning. `wrangler secret bulk` with no `--env` writes to the DEFAULT
  // environment, which is the Worker taking real money at api.drakar.mgcrea.io.
  // Anything but the production file going there is a mistake, and a test-mode
  // webhook secret in it refuses every genuine payment with a failure that
  // surfaces as a signature error rather than as anything pointing back here.
  const production = basename(file) === PRODUCTION_FILE;
  if (!targetEnv && !production) {
    errors.push([
      `no --env was given, and ${file} is not ${PRODUCTION_FILE}.`,
      `Without --env these go to the production Worker, and only ${PRODUCTION_FILE} may.`,
      "A test-mode webhook secret there would refuse every real payment as an",
      "invalid signature. Did you mean:",
      `  node scripts/push-worker-secrets.mjs ${file} --env test`,
    ]);
  }

  // The markers, as a second opinion. Blind to a webhook secret, but an API key
  // that says test is still worth refusing on its way to production, and a mix
  // or a live key heading elsewhere is worth a loud line.
  const modes = new Set(
    entries
      .filter(([name]) => name.startsWith("STRIPE_"))
      .map(([, value]) => stripeMode(value))
      .filter(Boolean),
  );
  if (modes.size > 1) {
    warnings.push([`${file} mixes test and live Stripe credentials.`]);
  }
  if (!targetEnv && production && modes.has("test")) {
    errors.push([
      `${file} carries TEST-mode Stripe credentials and no --env was given.`,
      "Without --env these go to the production Worker, which would then refuse",
      "every real payment as an invalid signature. Did you mean:",
      `  node scripts/push-worker-secrets.mjs ${file} --env test`,
    ]);
  }
  if (targetEnv && modes.has("live")) {
    warnings.push([
      `${file} carries LIVE-mode Stripe credentials, going to the "${targetEnv}" environment.`,
    ]);
  }
  if (targetEnv && production) {
    warnings.push([`${file} is the production file, going to the "${targetEnv}" environment.`]);
  }

  return { errors, warnings };
};

const API = join(dirname(fileURLToPath(import.meta.url)), "..", "apps/api");

const print = (label, lines) => {
  lines.forEach((line, index) => console.error(index === 0 ? `${label}: ${line}` : line));
};

const main = (args) => {
  const parsed = parseArgs(args);
  if (parsed.error) {
    console.error(`FATAL: ${parsed.error}`);
    return 2;
  }
  const { file, targetEnv } = parsed;
  const path = resolve(API, file);

  let source;
  try {
    source = readFileSync(path, "utf8");
  } catch (error) {
    console.error(`FATAL: cannot read ${path}: ${String(error?.message ?? error)}`);
    return 2;
  }
  const secrets = parseSecrets(source);
  if (secrets.error) {
    console.error(`FATAL: ${file} ${secrets.error}`);
    return 2;
  }

  const { errors, warnings } = checkSecrets({ file, targetEnv, entries: secrets.entries });
  for (const lines of warnings) print("WARNING", lines);
  if (errors.length > 0) {
    for (const lines of errors) print("FATAL", lines);
    return 2;
  }

  const target = targetEnv ? `the "${targetEnv}" environment` : "the production Worker";
  const names = secrets.entries.map(([name]) => name).join(", ");
  console.log(`pushing ${names} from ${file} to ${target}`);
  try {
    execFileSync(
      "pnpm",
      ["exec", "wrangler", "secret", "bulk", file, ...(targetEnv ? ["--env", targetEnv] : [])],
      { cwd: API, stdio: "inherit" },
    );
  } catch (error) {
    // Every other failure in this script is a sentence. A raw Node stack trace
    // over a wrangler error that already printed its own is noise on top of the
    // useful part.
    console.error(`FATAL: wrangler did not apply the secrets (${String(error?.message ?? error)})`);
    return 1;
  }
  return 0;
};

if (import.meta.main) process.exit(main(process.argv.slice(2)));
