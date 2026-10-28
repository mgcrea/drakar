#!/usr/bin/env node
// The cases `scripts/license-check.swift` runs through the real verifier.
//
// Emits JSON on stdout and nothing else, so `make license-check` can pipe it
// straight in. Every key here is minted for the check and thrown away; none is
// ever issued to anyone.
//
// The signing key is the real one, from `.env`, because that is the point:
// verifying a key signed by a throwaway keypair would prove the two languages
// agree about an algorithm while saying nothing about whether the public half
// compiled into the app matches the private half sitting on this machine. That
// mismatch is the one that refuses every key ever sold.
//
//   node --env-file-if-exists=.env scripts/license-check.mjs

import {
  KEY_PREFIX,
  mint,
  parse,
  PLACEHOLDER_KEY,
  PUBLIC_KEY,
  publicKeyOf,
} from "./lib/license.mjs";

const privateKey = process.env.LICENSE_SIGNING_KEY;
if (!privateKey) {
  console.error("FATAL: set LICENSE_SIGNING_KEY in .env (see scripts/mint-license.mjs --keygen)");
  process.exit(2);
}

// DIVERGES from armada: Drakar has no real key until Phase 2, so the compiled one is the
// placeholder and nothing could verify against it. LICENSE_PUBLIC_KEY stands in for it,
// here and in license-check.swift, so a throwaway keypair proves the two languages agree.
// That says nothing about whether .env matches the build, which is this check's point
// once a real key exists, so the stand-in is refused as soon as one does. Set it on the
// command line: license-check.swift reads the environment, not .env.
const override = process.env.LICENSE_PUBLIC_KEY;
if (override && PUBLIC_KEY !== PLACEHOLDER_KEY) {
  console.error("FATAL: LICENSE_PUBLIC_KEY stands in only for the placeholder, and");
  console.error("scripts/lib/license.mjs has a real PUBLIC_KEY. Unset it and check against that.");
  process.exit(2);
}
const expected = override || PUBLIC_KEY;
if (override) {
  // stderr: stdout is the JSON license-check.swift reads.
  console.error("note: checking against LICENSE_PUBLIC_KEY, not the compiled placeholder");
}
if (publicKeyOf(privateKey) !== expected) {
  const name = override ? "LICENSE_PUBLIC_KEY" : "PUBLIC_KEY in scripts/lib/license.mjs";
  console.error(`FATAL: LICENSE_SIGNING_KEY does not match ${name}.`);
  console.error("Every key signed with it would be refused by the app. Fix before issuing any.");
  process.exit(2);
}

const genuine = mint({ email: "buyer@example.com", major: 1, privateKey });

/** Re-encode claims without re-signing — what forging a key actually looks like. */
const tamper = (key, changes) => {
  const { claims, signature } = parse(key);
  const payload = Buffer.from(JSON.stringify({ ...claims, ...changes })).toString("base64url");
  return `${KEY_PREFIX}.${payload}.${signature}`;
};

console.log(
  JSON.stringify([
    { label: "a genuine key", key: genuine, major: 1, expect: true },
    {
      label: "the same key with whitespace around it",
      key: `\n  ${genuine}  \n`,
      major: 1,
      expect: true,
    },
    {
      // ~200 characters with no spaces, which a mail client hard-wraps; the
      // breaks come back with the paste, inside the payload and signature.
      label: "the same key wrapped across lines by a mail client",
      key: genuine.match(/.{1,76}/g).join("\r\n "),
      major: 1,
      expect: true,
    },
    {
      label: "a forged email",
      key: tamper(genuine, { email: "thief@example.com" }),
      major: 1,
      expect: false,
      reason: "signature does not match",
    },
    {
      label: "a forged major",
      key: tamper(genuine, { major: 2 }),
      major: 1,
      expect: false,
      reason: "signature does not match",
    },
    {
      label: "a key for another major",
      key: mint({ email: "buyer@example.com", major: 2, privateKey }),
      major: 1,
      expect: false,
      reason: "key covers 2.x, this build is 1.x",
    },
    {
      label: "an unknown prefix",
      key: genuine.replace(/^drk1\./, "drk2."),
      major: 1,
      expect: false,
      reason: "unknown key format 'drk2'",
    },
    { label: "an empty key", key: "", major: 1, expect: false, reason: "no licence key" },
  ]),
);
