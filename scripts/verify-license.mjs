#!/usr/bin/env node
// Check a licence key the way the app will, without launching the app.
//
// The point is that a stranger can run this. When somebody writes in to say
// their key is refused, the useful reply is a reason rather than a shrug, and
// the reason has to come from the same four checks the app makes — format,
// signature, revocation, major — in the same order. License.swift is the twin of
// scripts/lib/license.mjs and this is how you find out which of them is wrong.
//
// It also means a key can be verified before it is sent, which is the cheapest
// possible guard against handing a paying customer a subtly wrong payload.
//
// Exit codes: 0 valid, 1 refused, 2 could not ask the question.
//
//   node scripts/verify-license.mjs drk1.…
//   node scripts/verify-license.mjs --file=./a.license --major=1
//   node scripts/verify-license.mjs --file=./a.license --public-key=…

import { readFileSync } from "node:fs";

import { PLACEHOLDER_KEY, PUBLIC_KEY, verifyKey } from "./lib/license.mjs";

const argv = process.argv.slice(2);
const valueOf = (name, fallback) =>
  argv.find((argument) => argument.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const json = argv.includes("--json");

const file = valueOf("file", "");
const positional = argv.find((argument) => !argument.startsWith("--"));
if (!file && !positional) {
  console.error("FATAL: pass a key as an argument, or --file=<path>");
  process.exit(2);
}

let key;
try {
  key = file ? readFileSync(file, "utf8") : positional;
} catch (error) {
  console.error(`FATAL: cannot read ${file}: ${String(error?.message ?? error)}`);
  process.exit(2);
}

// DIVERGES from armada: the placeholder counts as no key. It is not one, and asking
// the question of it would end in a stack trace from node:crypto rather than this.
const publicKey = valueOf("public-key", "") || process.env.LICENSE_SIGNING_KEY_PUBLIC || PUBLIC_KEY;
if (!publicKey || publicKey === PLACEHOLDER_KEY) {
  console.error("FATAL: no public key. Pass --public-key=, set");
  console.error("LICENSE_SIGNING_KEY_PUBLIC, or fill in PUBLIC_KEY in scripts/lib/license.mjs.");
  process.exit(2);
}

// Revocation is deliberately not consulted here. The list that matters is the
// one compiled into a specific build (apps/apple/Drakar/Licence/Revocations.swift), so
// answering "is this revoked" needs a build to answer it about. Pass --revoked=
// to check against one anyway.
const revoked = valueOf("revoked", "").split(",").filter(Boolean);
const asked = argv.some((argument) => argument.startsWith("--major="));
const major = asked ? Number(valueOf("major", "1")) : undefined;

const result = verifyKey(key, { major, publicKey, revoked });

if (json) {
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.ok ? 0 : 1);
}

const L = [];
L.push(result.ok ? "VALID" : "REFUSED");
if (!result.ok) L.push(`  reason  : ${result.reason}`);
if (result.claims) {
  L.push(`  id      : ${result.claims.id}`);
  L.push(`  email   : ${result.claims.email}`);
  L.push(`  major   : ${result.claims.major}.x`);
  L.push(`  issued  : ${result.claims.issuedAt}`);
}
console.log(L.join("\n"));
process.exit(result.ok ? 0 : 1);
