// Licence keys: mint, parse, verify.
//
// The app cannot phone home. scripts/audit-network.sh asserts Drakar makes no
// connection of its own beyond the opt-in update check in Updates.swift — so a
// key has to prove itself from nothing but the bytes it carries and a public key
// compiled into the binary. That rules out every activation server and leaves
// exactly one shape: sign a payload here, verify it there, never ask anyone.
//
// Ed25519 rather than RSA or an HMAC. An HMAC would put the minting key inside
// the app, where anyone could read it and issue their own. RSA is four times the
// bytes for no gain. What is left is a 64-byte signature, which is still long
// enough that a key is pasted or dropped and never typed — LicensePane is
// designed for that rather than surprised by it.
//
// None of this is a tamper defence and none of it should become one. The gate it
// feeds is a few readable lines in AgentSession (canSend, canQueue) and the
// source is public, so hardening this is unenforceable by construction against
// the audience it sells to. What this buys is a key that cannot be forged or
// altered — not a program that cannot be modified.
//
// Dependency-free (node builtins only). Armada's, copied: the format is identical
// to armada's, bastion's and cupertino's but for the prefix, and deliberately so:
// the Worker in apps/api implements the same bytes against WebCrypto, which is
// why the signature covers the ENCODED payload rather than the parsed object.
// JSON key order and whitespace then stop being anybody's problem, in any
// language.

import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  randomBytes,
  sign,
  verify,
} from "node:crypto";

/** Namespaces the format. Bumping it is how a v2 key stays distinguishable. */
export const KEY_PREFIX = "drk1";

/**
 * The public half of the signing key, in base64url.
 *
 * Lives here AND in apps/apple/Drakar/Licence/License.swift, because the app
 * cannot import from this file. Two copies of one constant is a drift risk with a
 * nasty failure — every paid key refused at once — so license.test.mjs reads the
 * Swift file and asserts the two agree, rather than trusting whoever edits one to
 * remember the other.
 *
 * Not a secret — it only ever verifies. The private half lives in `.env` and
 * nowhere else in this repository, and is the one thing in this scheme that must
 * never leak and must never be lost: leaking it lets anyone issue keys, losing it
 * means no new keys can be issued for this major version ever again.
 *
 * Drakar's own, minted 2026-10-29. Until then it was PLACEHOLDER_KEY below, which
 * verify-license.mjs refuses to ask about and license-check.mjs replaces with
 * LICENSE_PUBLIC_KEY; both checks stay, should the placeholder ever come back.
 */
export const PUBLIC_KEY = "CiSKGTcP0umEgb3-gozFMH0OODaQW2Towt_jnLlBLnk";

/** What PUBLIC_KEY and LicenseKey.publicKey said before the real key, refused wherever read. */
export const PLACEHOLDER_KEY = "PLACEHOLDER-SET-IN-PHASE-2";

/** Crockford base32, the ULID alphabet: no I, L, O or U, so it survives dictation. */
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const toBase64Url = (buffer) => Buffer.from(buffer).toString("base64url");
const fromBase64Url = (text) => Buffer.from(text, "base64url");

const privateKeyFrom = (privateKeyBase64) =>
  createPrivateKey({
    format: "der",
    key: Buffer.from(privateKeyBase64, "base64"),
    type: "pkcs8",
  });

const publicKeyFrom = (publicKeyBase64Url) =>
  createPublicKey({
    format: "jwk",
    key: { crv: "Ed25519", kty: "OKP", x: publicKeyBase64Url },
  });

/**
 * A ULID: 10 characters of millisecond timestamp, 16 of randomness.
 *
 * Sortable by issue time, which is what makes Revocations.swift readable rather
 * than a bag of opaque strings. 256 divides by 32, so a byte modulo the alphabet
 * is unbiased and needs no rejection loop.
 */
export const ulid = (now = Date.now()) => {
  let time = "";
  for (let remaining = now, i = 0; i < 10; i++) {
    time = CROCKFORD[remaining % 32] + time;
    remaining = Math.floor(remaining / 32);
  }
  let random = "";
  for (const byte of randomBytes(16)) random += CROCKFORD[byte % 32];
  return time + random;
};

/**
 * A fresh signing keypair.
 *
 * `privateKey` is PKCS#8 DER in base64 — one opaque string to paste into `.env`,
 * and the only thing that must never leak. `publicKey` is the raw 32 bytes in
 * base64url, because that is what CryptoKit's
 * `Curve25519.Signing.PublicKey(rawRepresentation:)` takes and what gets compiled
 * into the app.
 */
export const generateKeypair = () => {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  return {
    privateKey: privateKey.export({ format: "der", type: "pkcs8" }).toString("base64"),
    publicKey: publicKey.export({ format: "jwk" }).x,
  };
};

/** The public half of a private key, in the same form `generateKeypair` returns. */
export const publicKeyOf = (privateKeyBase64) =>
  createPublicKey(privateKeyFrom(privateKeyBase64)).export({ format: "jwk" }).x;

/**
 * Sign claims into a key string.
 *
 * `major` is the app major version the key unlocks: a key for 1 opens every 1.x
 * and nothing numbered 2, which is the whole of the per-major model in one
 * integer — see AppInfo.major, which is what the app compares against. `id` is
 * the revocation handle and the only field a refund needs.
 */
export const mint = ({
  email,
  id = ulid(),
  issuedAt = new Date().toISOString(),
  major,
  privateKey,
}) => {
  const payload = toBase64Url(JSON.stringify({ id, email, major, issuedAt }));
  const signature = toBase64Url(sign(null, Buffer.from(payload), privateKeyFrom(privateKey)));
  return `${KEY_PREFIX}.${payload}.${signature}`;
};

/** Split a key into its parts without judging them. Throws on anything malformed. */
export const parse = (key) => {
  // Every whitespace character, not just the ends: a mail client hard-wraps a
  // key this long, and the breaks come back inside the payload and signature.
  const parts = String(key ?? "")
    .replace(/\s+/g, "")
    .split(".");
  if (parts.length !== 3) throw new Error("expected three dot-separated parts");
  const [prefix, payload, signature] = parts;
  if (prefix !== KEY_PREFIX) throw new Error(`unknown key format '${prefix}'`);
  if (!payload || !signature) throw new Error("empty payload or signature");
  return { claims: JSON.parse(fromBase64Url(payload).toString("utf8")), payload, signature };
};

/**
 * Is this key genuine, current, and for this version?
 *
 * Returns a reason instead of throwing, because every caller wants to say WHY a
 * key was refused: the CLI prints it, the app shows it, and a support reply is
 * mostly that one sentence. The Swift twin in
 * apps/apple/Drakar/Licence/License.swift makes the same four checks in the same
 * order.
 */
export const verifyKey = (key, { major, publicKey, revoked = [] }) => {
  let parsed;
  try {
    parsed = parse(key);
  } catch (error) {
    return { ok: false, reason: String(error?.message ?? error) };
  }

  const { claims, payload, signature } = parsed;
  const genuine = verify(
    null,
    Buffer.from(payload),
    publicKeyFrom(publicKey),
    fromBase64Url(signature),
  );
  if (!genuine) return { claims, ok: false, reason: "signature does not match" };
  if (revoked.includes(claims.id)) {
    return { claims, ok: false, reason: `licence ${claims.id} was revoked` };
  }
  if (major !== undefined && claims.major !== major) {
    return { claims, ok: false, reason: `key covers ${claims.major}.x, this build is ${major}.x` };
  }
  return { claims, ok: true, reason: "" };
};
