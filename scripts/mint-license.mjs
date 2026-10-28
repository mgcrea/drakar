#!/usr/bin/env node
// Mint a licence key, or generate the keypair that signs them.
//
// The manual lane. Sales are fulfilled by the Worker in apps/api, which signs the
// same bytes with WebCrypto; this is for everything with no payment attached — a
// comped licence, a replacement for someone who lost theirs, and the keys
// `make license-check` feeds the Swift verifier. Rare enough not to deserve a UI,
// frequent enough to deserve a command.
//
// The signing key is read from the environment rather than a flag on purpose:
// flags land in shell history and in `ps`, and this one is the only secret in
// the whole scheme. Losing it means no new keys can ever be issued for that
// major version; leaking it means anyone can issue their own.
//
// Every key minted here is recorded in the licence database, as the Worker
// records the keys it mints: `make revocations` reads revocations from there and
// nowhere else, so a key with no row could never be revoked. A replayed sale
// passes its own session and payment intent, so its refund reaches it.
// `--no-record` is for a key that must never be valid anywhere, `--local` writes
// to the local D1 that `pnpm -C apps/api migrate:local` sets up.
//
//   node scripts/mint-license.mjs --keygen
//   LICENSE_SIGNING_KEY=… node scripts/mint-license.mjs --email=a@b.c --major=1
//   LICENSE_SIGNING_KEY=… node scripts/mint-license.mjs --email=a@b.c --out=./a.license
//   LICENSE_SIGNING_KEY=… node scripts/mint-license.mjs --email=a@b.c \
//     --session=cs_live_… --payment-intent=pi_…

import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { recordSQL } from "./lib/license-record.mjs";
import { generateKeypair, mint, parse, publicKeyOf } from "./lib/license.mjs";

const API = join(dirname(fileURLToPath(import.meta.url)), "../apps/api");

const argv = process.argv.slice(2);
const has = (flag) => argv.includes(flag);
const valueOf = (name, fallback) =>
  argv.find((argument) => argument.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const json = has("--json");

if (has("--keygen")) {
  const keys = generateKeypair();
  if (json) {
    console.log(JSON.stringify(keys, null, 2));
    process.exit(0);
  }
  const L = [];
  L.push("KEYPAIR");
  L.push("  Generated once per major version. Generate it offline and back the");
  L.push("  private half up somewhere that is not this machine.");
  L.push("");
  L.push("  LICENSE_SIGNING_KEY — secret, never commit, never pass as a flag:");
  L.push(`    ${keys.privateKey}`);
  L.push("");
  L.push("  public key — paste into BOTH, they are asserted equal by the tests:");
  L.push("    scripts/lib/license.mjs                   PUBLIC_KEY");
  L.push("    apps/apple/Drakar/Licence/License.swift   publicKey");
  L.push(`    ${keys.publicKey}`);
  console.log(L.join("\n"));
  process.exit(0);
}

const privateKey = process.env.LICENSE_SIGNING_KEY;
if (!privateKey) {
  console.error("FATAL: set LICENSE_SIGNING_KEY (see --keygen)");
  process.exit(2);
}

// Trimmed and lowercased the way the Worker stores a buyer's address. The email
// is inside the signed payload, so a key minted here for "Buyer@Example.com "
// and the key the Worker minted for the same person differ byte for byte, and a
// replacement minted by hand would not match the row `/license/resend` looks
// up. Done here rather than in lib/license.mjs, whose output is asserted
// byte-identical to the Worker's for the same input.
const email = valueOf("email", "").trim().toLowerCase();
if (!email.includes("@")) {
  console.error("FATAL: --email=<address> is required, and must look like one");
  process.exit(2);
}

const major = Number(valueOf("major", "1"));
if (!Number.isInteger(major) || major < 1) {
  console.error(`FATAL: --major must be a positive integer, got '${major}'`);
  process.exit(2);
}

const key = mint({ email, major, privateKey });
const { claims } = parse(key);

// Recorded before it is shown or written: a key that reached somebody without a
// row is the one this exists to prevent, so a failed write ends here.
const recorded = !has("--no-record");
if (recorded) {
  const sessionId = valueOf("session", undefined);
  const paymentIntent = valueOf("payment-intent", "");
  let sql;
  try {
    sql = recordSQL({ ...claims, key, sessionId, paymentIntent });
  } catch (error) {
    console.error(`FATAL: ${error.message}`);
    process.exit(2);
  }
  try {
    execFileSync(
      "pnpm",
      [
        "exec",
        "wrangler",
        "d1",
        "execute",
        "drakar-licenses",
        has("--local") ? "--local" : "--remote",
        "--command",
        sql,
      ],
      { cwd: API, stdio: ["ignore", "ignore", "pipe"] },
    );
  } catch (error) {
    console.error(
      `FATAL: could not record licence ${claims.id}, so it was not issued: ${String(error?.stderr ?? error?.message ?? error)}`,
    );
    process.exit(2);
  }
}

const out = valueOf("out", "");
// 0600, not the default umask. The file holds somebody's licence key, and every
// other secret this repo writes is already careful about it — the Makefile
// chmods dev.json to 600 and sets `umask 077` before writing the Sparkle key.
// This one landed world-readable.
if (out) writeFileSync(out, `${key}\n`, { mode: 0o600 });

if (json) {
  console.log(JSON.stringify({ claims, key, publicKey: publicKeyOf(privateKey) }, null, 2));
  process.exit(0);
}

const L = [];
L.push("LICENCE");
L.push(`  id      : ${claims.id}`);
L.push(`  email   : ${claims.email}`);
L.push(`  major   : ${claims.major}.x`);
L.push(`  issued  : ${claims.issuedAt}`);
L.push(`  recorded: ${recorded ? (has("--local") ? "local D1" : "D1") : "no (--no-record)"}`);
L.push("");
L.push("KEY");
L.push(`  ${key}`);
if (out) {
  L.push("");
  L.push(`  written to ${out}`);
}
console.log(L.join("\n"));
