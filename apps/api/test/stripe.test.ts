// Everything a forged webhook could try.
//
// This endpoint mints licences from an unauthenticated POST, so the signature
// check is the only thing between a stranger and free keys. It is also hand-
// written rather than taken from the Stripe SDK, which means the usual comfort
// of "the library handles it" does not apply and each rule needs its own row.

import { afterEach, describe, expect, it, vi } from "vitest";

import { priceIdFor, verifySignature } from "../src/stripe";
import { hmacHex } from "./hmac";

const SECRET = "whsec_test_0123456789";
const BODY = JSON.stringify({ id: "evt_1", type: "checkout.session.completed" });
const NOW = 1_800_000_000_000;

const sign = async (body: string, secret: string, atMs: number): Promise<string> => {
  const t = Math.floor(atMs / 1000);
  return `t=${t},v1=${await hmacHex(secret, `${t}.${body}`)}`;
};

describe("verifySignature", () => {
  it("matches an HMAC computed outside this file", async () => {
    // Everything else here signs with the same primitive it verifies with, which
    // would pass even if both sides were wrong in the same way. This vector was
    // produced independently and pins the scheme to real HMAC-SHA256 over
    // `<timestamp>.<body>`.
    const header =
      "t=1800000000,v1=faa576380036361b78ae4433782fa5440b4f26d5b735d272cfe3c9873e3d3af7";
    expect(await verifySignature(BODY, header, SECRET, NOW)).toEqual({ ok: true });
  });

  it("accepts a genuine signature", async () => {
    const result = await verifySignature(BODY, await sign(BODY, SECRET, NOW), SECRET, NOW);
    expect(result).toEqual({ ok: true });
  });

  it("accepts when several v1 signatures are present and one matches", async () => {
    const header = `${await sign(BODY, SECRET, NOW)},v1=${"0".repeat(64)}`;
    expect((await verifySignature(BODY, header, SECRET, NOW)).ok).toBe(true);
  });

  const refusals: [string, () => Promise<string | null> | string | null, string][] = [
    ["a missing header", () => null, "no Stripe-Signature header"],
    [
      "a header with no timestamp",
      () => `v1=${"0".repeat(64)}`,
      "no timestamp in the signature header",
    ],
    ["a header with no v1", () => "t=1800000000", "no v1 signature in the header"],
    ["a non-numeric timestamp", () => `t=soon,v1=${"0".repeat(64)}`, "timestamp is not a number"],
    ["a wrong signature", () => sign(BODY, "whsec_wrong", NOW), "no signature matches"],
    [
      "a v0 signature only",
      async () => (await sign(BODY, SECRET, NOW)).replace("v1=", "v0="),
      "no v1 signature in the header",
    ],
  ];

  for (const [label, header, reason] of refusals) {
    it(`refuses ${label}`, async () => {
      const result = await verifySignature(BODY, await header(), SECRET, NOW);
      expect(result.ok).toBe(false);
      expect(result.ok === false && result.reason).toBe(reason);
    });
  }

  it("allows a timestamp a little ahead of the clock, and refuses one well ahead", async () => {
    // Stripe's own libraries take the absolute difference, which lets a captured
    // header stay valid for five minutes after the clock it was stamped with.
    // A minute of skew is generous for two hosts on NTP; five is a replay.
    const slightlyAhead = await sign(BODY, SECRET, NOW + 30_000);
    expect((await verifySignature(BODY, slightlyAhead, SECRET, NOW)).ok).toBe(true);
    const wellAhead = await sign(BODY, SECRET, NOW + 240_000);
    const result = await verifySignature(BODY, wellAhead, SECRET, NOW);
    expect(result.ok === false && result.reason).toMatch(/in the future/);
  });

  it("refuses a replayed signature outside the tolerance", async () => {
    const result = await verifySignature(
      BODY,
      await sign(BODY, SECRET, NOW - 400_000),
      SECRET,
      NOW,
    );
    expect(result.ok).toBe(false);
    expect(result.ok === false && result.reason).toMatch(/tolerance is 300s/);
  });

  // WebCrypto throws on a zero-length HMAC key. Unguarded, an unset secret
  // escaped as an exception and the webhook answered a bare 500.
  it("refuses rather than throws when no secret is configured", async () => {
    const result = await verifySignature(BODY, await sign(BODY, SECRET, NOW), "", NOW);
    expect(result).toEqual({ ok: false, reason: "no webhook secret configured" });
  });

  it("refuses a body edited after signing", async () => {
    const header = await sign(BODY, SECRET, NOW);
    const tampered = BODY.replace("evt_1", "evt_2");
    expect((await verifySignature(tampered, header, SECRET, NOW)).ok).toBe(false);
  });
});

describe("priceIdFor", () => {
  // The fallback that decides whether a sale with no `price_id` metadata is
  // Drakar's. Every failure has to come back as "", which the guard reads as
  // "not ours", rather than as a throw, which would be a bare 500 and a
  // three-day retry loop over a network blip.
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("reads the price of the session's first line item", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(Response.json({ data: [{ price: { id: "price_123" } }] }));
    expect(await priceIdFor("cs_test_1", "sk_test_x")).toBe("price_123");
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0] ?? [];
    expect(String(url)).toBe(
      "https://api.stripe.com/v1/checkout/sessions/cs_test_1/line_items?limit=1",
    );
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer sk_test_x");
  });

  it("answers empty when Stripe answers anything but 2xx", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("no", { status: 401 }));
    expect(await priceIdFor("cs_test_1", "sk_test_x")).toBe("");
  });

  it("answers empty when the call itself throws", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("network is down"));
    expect(await priceIdFor("cs_test_1", "sk_test_x")).toBe("");
  });

  it("answers empty when the session has no line items", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ data: [] }));
    expect(await priceIdFor("cs_test_1", "sk_test_x")).toBe("");
  });
});
