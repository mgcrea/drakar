// The HMAC the tests sign webhooks with.
//
// WebCrypto rather than node:crypto, so the same file runs in both vitest
// projects and needs no Node type roots. Deliberately NOT the one in
// src/stripe.ts, which is not even exported: a test that signs with the
// primitive under test passes even when both sides are wrong in the same way.
// test/stripe.test.ts checks this copy against the Worker, and the Worker
// against a vector produced outside this repo.

export const hmacHex = async (secret: string, message: string): Promise<string> => {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(mac)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
};
