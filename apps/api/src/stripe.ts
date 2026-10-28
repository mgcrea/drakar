// Verifying that a webhook really came from Stripe.
//
// Done by hand rather than with the Stripe SDK, which would pull in
// `nodejs_compat` and a few hundred kilobytes to perform one HMAC. The scheme is
// small and fully specified: the header carries a timestamp and one or more
// signatures, and each is HMAC-SHA256 over `<timestamp>.<raw body>` keyed by the
// endpoint secret, verbatim including its `whsec_` prefix.
//
// Two things here are not optional. The body must be the RAW text, because
// re-serialising the JSON changes bytes Stripe signed. And the timestamp must be
// checked, because a signature with no freshness bound is a replay waiting to
// happen — a captured `checkout.session.completed` could otherwise be posted
// back forever.

export type Verified = { ok: true } | { ok: false; reason: string };

/** Stripe's tolerance for age, and the one everyone uses: five minutes. */
const TOLERANCE_SECONDS = 300;

/**
 * How far into the future a timestamp may sit. Stripe's own libraries take the
 * absolute difference, which quietly doubles the replay window: a captured
 * header stays valid for five minutes AFTER the clock Stripe stamped it with.
 * A future timestamp is clock skew, not a delivery delay, and two hosts on NTP
 * do not disagree by a minute.
 */
const FUTURE_SKEW_SECONDS = 60;

const hmacHex = async (secret: string, message: string): Promise<string> => {
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

/** Length-independent compare, so a mismatch leaks no position information. */
const constantTimeEqual = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
};

export const verifySignature = async (
  rawBody: string,
  header: string | null,
  secret: string,
  now: number = Date.now(),
): Promise<Verified> => {
  // WebCrypto refuses a zero-length HMAC key by throwing, so an unset secret
  // used to escape this function as an exception. `handleWebhook` checks for it
  // first and answers with the secret's name; this keeps the function itself a
  // verdict rather than something its callers have to wrap.
  if (!secret) return { ok: false, reason: "no webhook secret configured" };
  if (!header) return { ok: false, reason: "no Stripe-Signature header" };

  let timestamp = "";
  const candidates: string[] = [];
  for (const piece of header.split(",")) {
    const separator = piece.indexOf("=");
    if (separator < 0) continue;
    const name = piece.slice(0, separator).trim();
    const value = piece.slice(separator + 1).trim();
    if (name === "t") timestamp = value;
    // v0 is the test-mode scheme and is deliberately not accepted.
    if (name === "v1") candidates.push(value);
  }

  if (!timestamp) return { ok: false, reason: "no timestamp in the signature header" };
  if (candidates.length === 0) return { ok: false, reason: "no v1 signature in the header" };

  const seconds = Number(timestamp);
  if (!Number.isFinite(seconds)) return { ok: false, reason: "timestamp is not a number" };
  const age = now / 1000 - seconds;
  if (age > TOLERANCE_SECONDS) {
    return { ok: false, reason: `timestamp is ${Math.round(age)}s old, tolerance is 300s` };
  }
  if (age < -FUTURE_SKEW_SECONDS) {
    return {
      ok: false,
      reason: `timestamp is ${Math.round(-age)}s in the future, tolerance is ${FUTURE_SKEW_SECONDS}s`,
    };
  }

  const expected = await hmacHex(secret, `${timestamp}.${rawBody}`);
  if (!candidates.some((candidate) => constantTimeEqual(candidate, expected))) {
    return { ok: false, reason: "no signature matches" };
  }
  return { ok: true };
};

/**
 * Which price the customer actually paid, for the upgrade maths at 2.0.
 *
 * The FALLBACK path. A session created by our Payment Link carries `price_id` in
 * the metadata Stripe copies onto it, and `fulfil` prefers that — no API key, no
 * second round trip on the one path that must not fail. This covers a session
 * created some other way, and only when a key happens to be configured.
 *
 * `checkout.session.completed` does not carry line items, so this is a second
 * call. It never throws: any failure comes back as an empty string. What an
 * empty price then means is `fulfil`'s decision, and here it refuses the sale
 * (see the price guard there, which diverges from bastion on exactly this).
 */
export const priceIdFor = async (sessionId: string, secretKey: string): Promise<string> => {
  try {
    const response = await fetch(
      `https://api.stripe.com/v1/checkout/sessions/${sessionId}/line_items?limit=1`,
      { headers: { Authorization: `Bearer ${secretKey}` } },
    );
    if (!response.ok) return "";
    const body = (await response.json()) as { data?: { price?: { id?: string } }[] };
    return body.data?.[0]?.price?.id ?? "";
  } catch {
    return "";
  }
};
