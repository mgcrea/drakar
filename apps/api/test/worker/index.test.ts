// The handlers, in workerd, against a real D1.
//
// Every test builds its own `env` on top of the pool's: the real database, a
// stub in place of Email Service that records what it was asked to send, a
// keypair minted for the run, and the webhook secret the signatures below use.
// The table is emptied before each test, so each one seeds what it needs.
import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import worker from "../../src/index";
import { hmacHex } from "../hmac";

const SECRET = "whsec_test";
const SESSION = "cs_test_1";
const INTENT = "pi_test_1";

/**
 * How many 64 KiB chunks the streaming test may pull before the cap has to have
 * bitten. Five cross the 256 KiB cap; the rest is slack for whatever the
 * runtime buffers between the stream and the reader.
 */
const PULL_BOUND = 32;

// The pool shares one D1 across the file, so every test starts from an empty
// table rather than from whatever the previous one left.
beforeEach(async () => {
  await env.DB.prepare("DELETE FROM licenses").run();
  await env.DB.prepare("DELETE FROM stripe_events").run();
  await env.DB.prepare("DELETE FROM early_revocations").run();
});

afterEach(() => {
  vi.restoreAllMocks();
});

// Every event needs its own id, because the Worker refuses to handle the same
// one twice. Stamped rather than hardcoded so each builder call is a distinct
// delivery; a test about redelivery passes an explicit id and overrides this.
let eventSeq = 0;
const stamped = <T extends object>(event: T): T & { id: string } => ({
  id: `evt_test_${++eventSeq}`,
  ...event,
});

let privateKey = "";
beforeAll(async () => {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array(
    (await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer,
  );
  privateKey = btoa(String.fromCharCode(...der));
});

/** One message as the Email Service stub received it, with line 3 read back as the key. */
type Mail = { to: string; key: string; message: EmailMessageBuilder };

const limiter = (success: boolean): RateLimit => ({ limit: async () => ({ success }) });

/**
 * The Worker's env, with the pieces a test controls swapped in.
 *
 * Both limiters are stubs that always allow. The real bindings count per key,
 * every request in this file arrives from the same "unknown" address, and the
 * file sends enough of them that the real ones would start refusing part-way
 * through for a reason no test states. A test about limiting passes its own
 * stub, and the "bindings" block checks the real ones are there.
 */
const testEnv = (overrides: Partial<Env> = {}, sender?: () => Promise<void>) => {
  const sent: Mail[] = [];
  const EMAIL = {
    send: async (message: EmailMessageBuilder) => {
      if (sender) await sender();
      sent.push({ to: String(message.to), key: message.text?.split("\n")[2] ?? "", message });
    },
  } as unknown as SendEmail;
  const built: Env = {
    ...env,
    EMAIL,
    LICENSE_SIGNING_KEY: privateKey,
    STRIPE_WEBHOOK_SECRET: SECRET,
    RESEND_LIMIT: limiter(true),
    THANKS_LIMIT: limiter(true),
    ...overrides,
  };
  return { env: built, sent };
};

/**
 * Overrides carrying a fixture price id. `wrangler types` pins EXPECTED_PRICE_ID
 * to the literals in wrangler.jsonc, the live and test price ids, so any other
 * id, and the empty one of a Worker deployed before its price exists, has to be
 * widened past the generated type.
 */
const priced = (price: string, rest: Partial<Env> = {}): Partial<Env> =>
  ({ ...rest, EXPECTED_PRICE_ID: price }) as unknown as Partial<Env>;

/**
 * One request through the handler, and whatever it left in `waitUntil`. A
 * resend answers before it looks anything up, so a test that checks what was
 * sent has to wait for the context and not just for the response.
 */
const call = async (request: Request, forEnv: Env): Promise<Response> => {
  const context = createExecutionContext();
  const response = await worker.fetch(request, forEnv, context);
  await waitOnExecutionContext(context);
  return response;
};

const webhook = async (
  forEnv: Env,
  event: unknown,
  options: { secret?: string; body?: string } = {},
): Promise<Response> => {
  const body = options.body ?? JSON.stringify(event);
  const t = Math.floor(Date.now() / 1000);
  const header = `t=${t},v1=${await hmacHex(options.secret ?? SECRET, `${t}.${body}`)}`;
  return call(
    new Request("https://api.test/stripe/webhook", {
      method: "POST",
      body,
      headers: { "stripe-signature": header },
    }),
    forEnv,
  );
};

const completed = (session: Record<string, unknown> = {}, livemode = false) =>
  stamped({
    type: "checkout.session.completed",
    livemode,
    data: {
      object: {
        id: SESSION,
        payment_intent: INTENT,
        amount_total: 1499,
        currency: "eur",
        payment_status: "paid",
        customer_details: { email: " Buyer@Example.com " },
        metadata: { price_id: "price_test" },
        ...session,
      },
    },
  });

const chargeEvent = (type: string, charge: Record<string, unknown> = {}) =>
  stamped({
    type,
    data: { object: { id: "ch_1", payment_intent: INTENT, amount: 1499, ...charge } },
  });

const disputeEvent = (type: string, dispute: Record<string, unknown> = {}) =>
  stamped({
    type,
    data: { object: { id: "dp_1", payment_intent: INTENT, ...dispute } },
  });

type Row = {
  email: string;
  key: string;
  price_id: string;
  livemode: number;
  revoked_at: string | null;
  revoked_reason: string | null;
  last_sent_at: string | null;
};

const row = (forEnv: Env): Promise<Row | null> =>
  forEnv.DB.prepare(
    "SELECT email, key, price_id, livemode, revoked_at, revoked_reason, last_sent_at FROM licenses WHERE stripe_session_id = ?",
  )
    .bind(SESSION)
    .first<Row>();

const count = async (forEnv: Env): Promise<number> =>
  (await forEnv.DB.prepare("SELECT COUNT(*) AS n FROM licenses").first<{ n: number }>())?.n ?? -1;

const events = async (forEnv: Env): Promise<number> =>
  (await forEnv.DB.prepare("SELECT COUNT(*) AS n FROM stripe_events").first<{ n: number }>())?.n ??
  -1;

/** The webhook just mailed the key, so the cooldown is live; clear it. */
const cooled = async (forEnv: Env) => {
  await forEnv.DB.prepare("UPDATE licenses SET last_sent_at = NULL").run();
};

/** A paid session through the webhook, so a test can start from a licence. */
const fulfilled = async () => {
  const built = testEnv();
  const response = await webhook(built.env, completed());
  expect(response.status).toBe(200);
  return built;
};

describe("the router", () => {
  it("answers /health", async () => {
    const response = await call(new Request("https://api.test/health"), testEnv().env);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it("404s everything else, as HTML", async () => {
    const response = await call(new Request("https://api.test/nope"), testEnv().env);
    expect(response.status).toBe(404);
    expect(response.headers.get("content-type")).toContain("text/html");
  });

  it("escapes SITE_URL into the 404 page", async () => {
    const built = testEnv({
      SITE_URL: 'https://x.test/"><script>alert(1)</script>',
    } as unknown as Partial<Env>);
    const page = await (await call(new Request("https://api.test/nope"), built.env)).text();
    expect(page).not.toContain("<script>");
    expect(page).toContain('href="https://x.test/&quot;&gt;&lt;script&gt;');
  });
});

describe("the webhook", () => {
  it("refuses a body signed with another secret, and mints nothing", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed(), { secret: "whsec_other" });
    expect(response.status).toBe(400);
    // The reason is logged and not returned: in the body it would tell a forger
    // which check they had got past.
    expect(await response.text()).toBe("invalid signature");
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  it("refuses a body over the cap before reading it", async () => {
    const built = testEnv();
    const body = JSON.stringify({ type: "x", data: { object: { pad: "a".repeat(300 * 1024) } } });
    const response = await webhook(built.env, null, { body });
    expect(response.status).toBe(413);
  });

  // The streaming half of `readCapped`. A chunked body carries no
  // Content-Length, so the check on the header lets it through, and only
  // counting bytes as they arrive stops it. The stream never ends by itself:
  // without the cap this test hangs rather than passes.
  it("refuses a streamed body with no Content-Length once it passes the cap", async () => {
    const built = testEnv();
    let pulled = 0;
    const endless = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled += 1;
        controller.enqueue(new Uint8Array(64 * 1024).fill(0x61));
      },
    });
    const request = new Request("https://api.test/stripe/webhook", {
      method: "POST",
      body: endless,
      headers: { "stripe-signature": "t=1,v1=00" },
    });
    expect(request.headers.get("content-length")).toBeNull();
    const response = await call(request, built.env);
    expect(response.status).toBe(413);
    expect(pulled).toBeLessThan(PULL_BOUND);
    expect(await count(built.env)).toBe(0);
  });

  it("mints, records and mails a key for a paid session", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");

    const stored = await row(built.env);
    expect(stored?.email).toBe("buyer@example.com");
    expect(stored?.price_id).toBe("price_test");
    expect(stored?.livemode).toBe(0);
    expect(stored?.last_sent_at).not.toBeNull();
    expect(stored?.key.startsWith("drk1.")).toBe(true);
    expect(built.sent).toHaveLength(1);
    expect(built.sent[0]?.to).toBe("buyer@example.com");
    expect(built.sent[0]?.key).toBe(stored?.key);
  });

  it("mails the key in the body and as an attachment, from the configured sender", async () => {
    const built = testEnv();
    await webhook(built.env, completed());
    const stored = await row(built.env);
    const message = built.sent[0]?.message;
    expect(message?.to).toBe("buyer@example.com");
    expect(message?.from).toEqual({ email: built.env.LICENSE_FROM_EMAIL, name: "Drakar" });
    // Replies are how a customer asks for a refund or a re-send, so they have
    // to reach a person rather than the sending address.
    expect(message?.replyTo).toEqual({ email: "olivier@mgcrea.io", name: "Olivier Louvignes" });
    expect(message?.subject).toBe("Your Drakar licence key");
    expect(message?.attachments).toHaveLength(1);
    const attachment = message?.attachments?.[0];
    expect(attachment?.disposition).toBe("attachment");
    expect(attachment?.filename).toBe("Drakar.license");
    expect(attachment?.type).toBe("text/plain");
    expect(new TextDecoder().decode(attachment?.content as Uint8Array)).toBe(`${stored?.key}\n`);
  });

  it("treats a redelivery as already done: one row, one mail", async () => {
    const built = testEnv();
    await webhook(built.env, completed());
    const again = await webhook(built.env, completed());
    expect(again.status).toBe(200);
    expect(await again.text()).toBe("already sent");
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  // A 100%-off promotion code: nothing to pay, and still a sale.
  it("mints and mails a key for a session that needed no payment", async () => {
    const built = testEnv();
    const response = await webhook(
      built.env,
      completed({ payment_status: "no_payment_required", amount_total: 0 }),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  it("does nothing for a session that is not paid", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ payment_status: "unpaid" }));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("not paid yet");
    expect(await count(built.env)).toBe(0);
  });

  // 200 rather than 400 for everything below that no retry can fix. Stripe
  // retries every non-2xx for three days; the body is what says what was wrong,
  // and the event is recorded like any other it has finished with.
  it("refuses a session with no payment status rather than guessing", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ payment_status: undefined }));
    expect(response.status).toBe(200);
    expect(await response.text()).toMatch(/^unprocessable: session: payment_status/);
    expect(await count(built.env)).toBe(0);
    expect(await events(built.env)).toBe(1);
  });

  it("refuses a session with no email", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ customer_details: {} }));
    expect(response.status).toBe(200);
    expect(await response.text()).toMatch(/^unprocessable: no email/);
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  it("answers 200 to a signed body that is not JSON, or not an event", async () => {
    const built = testEnv();
    const notJson = await webhook(built.env, null, { body: "{nope" });
    expect(notJson.status).toBe(200);
    expect(await notJson.text()).toBe("unprocessable: body is not JSON");
    const notEvent = await webhook(built.env, null, { body: JSON.stringify({ hello: "world" }) });
    expect(notEvent.status).toBe(200);
    expect(await notEvent.text()).toMatch(/^unprocessable: not a Stripe event/);
    // Nothing to record: without an envelope there is no event id.
    expect(await events(built.env)).toBe(0);
  });

  it("answers 200 to a refund whose charge has no id, and revokes nothing", async () => {
    const built = await fulfilled();
    const response = await webhook(
      built.env,
      chargeEvent("charge.refunded", { id: undefined, amount_refunded: 1499 }),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toMatch(/^unprocessable: charge: id/);
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  it("returns 500 when the mail fails, keeps the row, and sends on the retry", async () => {
    let broken = true;
    const built = testEnv({}, async () => {
      if (broken) throw new Error("E_SENDER_NOT_VERIFIED");
    });
    const first = await webhook(built.env, completed());
    expect(first.status).toBe(500);
    expect(await first.text()).toMatch(/^email:/);
    expect(await count(built.env)).toBe(1);
    expect((await row(built.env))?.last_sent_at).toBeNull();

    broken = false;
    const retry = await webhook(built.env, completed());
    expect(retry.status).toBe(200);
    expect(built.sent).toHaveLength(1);
    expect(await count(built.env)).toBe(1);
  });

  it("ignores an event type it does not handle", async () => {
    const response = await webhook(
      testEnv().env,
      stamped({ type: "payment_intent.succeeded", data: { object: {} } }),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ignored");
  });
});

describe("the product guard", () => {
  // Every app on the Stripe account gets every checkout event, so this Worker
  // sees the other apps' sales. None of them may leave here with a drk1 key.
  it("fulfils a sale at the configured price", async () => {
    const built = testEnv(priced("price_test"));
    const response = await webhook(built.env, completed({ metadata: { price_id: "price_test" } }));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
    expect(await count(built.env)).toBe(1);
    expect((await row(built.env))?.price_id).toBe("price_test");
    expect(built.sent).toHaveLength(1);
  });

  it("ignores a sale at another product's price, and mints nothing", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ metadata: { price_id: "price_other" } }));
    // 200, so Stripe stops. A 4xx would have it retrying a valid event for days.
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("not this product");
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  // DIVERGES from bastion, which fulfils these. An unresolvable price is what a
  // sale through another app's hand-made link looks like, and here the guard is
  // the only thing between that buyer and a drk1 key.
  it("ignores a sale whose price cannot be resolved", async () => {
    const built = testEnv({ STRIPE_SECRET_KEY: "" });
    const response = await webhook(built.env, completed({ metadata: {} }));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("not this product");
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  // DIVERGES from bastion, where an empty price means unguarded. This is the
  // Worker deployed before its Stripe price exists, receiving another app's
  // sale: it must acknowledge, and mint, store and mail nothing.
  it("refuses to fulfil anything when no price is configured", async () => {
    const built = testEnv(priced(""));
    const response = await webhook(built.env, completed({ metadata: { price_id: "price_other" } }));
    expect(response.status).toBe(200);
    expect(await response.text()).toMatch(/^fulfilment not configured/);
    expect(await count(built.env)).toBe(0);
    expect(await events(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  it("refuses the delayed-payment route too when no price is configured", async () => {
    const built = testEnv(priced(""));
    const response = await webhook(built.env, {
      ...completed(),
      type: "checkout.session.async_payment_succeeded",
    });
    expect(await response.text()).toMatch(/^fulfilment not configured/);
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  it("refuses a session with no price at all when no price is configured", async () => {
    const built = testEnv(priced("", { STRIPE_SECRET_KEY: "" }));
    const response = await webhook(built.env, completed({ metadata: {} }));
    expect(await response.text()).toMatch(/^fulfilment not configured/);
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  // Not recorded as handled, so a "Resend" from the Stripe dashboard once the
  // price is set still reaches fulfilment instead of answering "duplicate".
  it("fulfils the same event once the price is configured", async () => {
    const event = { ...completed(), id: "evt_before_the_price" };
    const early = testEnv(priced(""));
    expect(await (await webhook(early.env, event)).text()).toMatch(/^fulfilment not configured/);

    const configured = testEnv(priced("price_test"));
    const later = await webhook(configured.env, event);
    expect(await later.text()).toBe("ok");
    expect(await count(configured.env)).toBe(1);
    expect(configured.sent).toHaveLength(1);
  });

  // Only a deployment that names itself "test" may run unguarded. A missing or
  // misspelt ENVIRONMENT must read as production.
  it("treats a missing ENVIRONMENT as production", async () => {
    const built = testEnv({
      ENVIRONMENT: undefined,
      EXPECTED_PRICE_ID: "",
    } as unknown as Partial<Env>);
    const response = await webhook(built.env, completed());
    expect(await response.text()).toMatch(/^fulfilment not configured/);
    expect(await count(built.env)).toBe(0);
  });

  it("leaves refunds working when no price is configured", async () => {
    const built = await fulfilled();
    const unconfigured = { ...built.env, ...priced("") } as Env;
    const response = await webhook(
      unconfigured,
      chargeEvent("charge.refunded", { amount_refunded: 1499 }),
    );
    expect(await response.text()).toBe("refunded: revoked 1");
  });

  // The rehearsal: a test-mode link sells a test-mode price that is not pinned
  // anywhere, so the test environment alone keeps the unguarded reading.
  it("fulfils any price in the test environment when none is configured", async () => {
    const built = testEnv(priced("", { ENVIRONMENT: "test" }));
    const response = await webhook(built.env, completed({ metadata: { price_id: "price_other" } }));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  // The fallback, for a session with no `price_id` in its metadata: the price is
  // asked of the Stripe API, and what the guard decides depends on the answer.
  it("fulfils a sale the Stripe API says was at our price", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(Response.json({ data: [{ price: { id: "price_test" } }] }));
    const built = testEnv({ STRIPE_SECRET_KEY: "sk_test_x" });
    const response = await webhook(built.env, completed({ metadata: {} }));
    expect(await response.text()).toBe("ok");
    expect((await row(built.env))?.price_id).toBe("price_test");
    expect(String(fetchSpy.mock.calls[0]?.[0])).toContain(
      `/checkout/sessions/${SESSION}/line_items`,
    );
  });

  it("ignores a sale when the Stripe API cannot say what was bought", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("down", { status: 503 }));
    const built = testEnv({ STRIPE_SECRET_KEY: "sk_test_x" });
    const response = await webhook(built.env, completed({ metadata: {} }));
    expect(await response.text()).toBe("not this product");
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  it("logs an unresolved price as an error, apart from another product's sale", async () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("down", { status: 503 }));
    const unresolved = testEnv({ STRIPE_SECRET_KEY: "sk_test_x" });
    await webhook(unresolved.env, completed({ metadata: {} }));
    expect(errors.mock.calls.map(String).join("\n")).toContain("price unresolved");

    errors.mockClear();
    const other = testEnv(priced("price_live"));
    await webhook(other.env, completed({ metadata: { price_id: "price_other" } }));
    expect(errors).not.toHaveBeenCalled();
  });

  it("still guards the test environment once a price is pinned there", async () => {
    const built = testEnv(priced("price_test", { ENVIRONMENT: "test" }));
    const response = await webhook(built.env, completed({ metadata: { price_id: "price_other" } }));
    expect(await response.text()).toBe("not this product");
    expect(await count(built.env)).toBe(0);
  });
});

describe("refunds and disputes", () => {
  it("leaves a licence alone on a partial refund", async () => {
    const built = await fulfilled();
    const response = await webhook(
      built.env,
      chargeEvent("charge.refunded", { amount_refunded: 200 }),
    );
    expect(await response.text()).toContain("partial refund");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  it("revokes on a full refund, once", async () => {
    const built = await fulfilled();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    const when = (await row(built.env))?.revoked_at;
    expect(when).not.toBeNull();
    const again = await webhook(
      built.env,
      chargeEvent("charge.refunded", { amount_refunded: 1499 }),
    );
    expect(await again.text()).toBe("refunded: revoked 0");
    expect((await row(built.env))?.revoked_at).toBe(when);
  });

  it("says so when a refund names no payment intent", async () => {
    const built = await fulfilled();
    const response = await webhook(
      built.env,
      chargeEvent("charge.refunded", { amount_refunded: 1499, payment_intent: null }),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("nothing revoked");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  it("revokes on a dispute and restores it when the dispute is won", async () => {
    const built = await fulfilled();
    await webhook(built.env, disputeEvent("charge.dispute.created"));
    expect((await row(built.env))?.revoked_at).not.toBeNull();
    const lost = await webhook(
      built.env,
      disputeEvent("charge.dispute.closed", { status: "lost" }),
    );
    expect(await lost.text()).toContain("stays revoked");
    expect((await row(built.env))?.revoked_at).not.toBeNull();
    const won = await webhook(built.env, disputeEvent("charge.dispute.closed", { status: "won" }));
    expect(await won.text()).toBe("dispute won: restored 1");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  // `revoke` is guarded on `revoked_at IS NULL`, and the restore needs a
  // matching guard: a refunded licence whose charge was later disputed and won
  // must not come back to life, or the next `make revocations` drops it from
  // the baked-in list.
  it("does not restore a refunded licence when a later dispute is won", async () => {
    const built = await fulfilled();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    const when = (await row(built.env))?.revoked_at;
    expect(when).not.toBeNull();
    expect((await row(built.env))?.revoked_reason).toBe("refunded");

    const won = await webhook(built.env, disputeEvent("charge.dispute.closed", { status: "won" }));
    expect(await won.text()).toBe("dispute won: restored 0");
    expect((await row(built.env))?.revoked_at).toBe(when);
  });

  // Fulfilment answers 500 until the key is mailed, and Stripe retries it for
  // days; a buyer refunded inside that window used to get a working key from
  // the retry, for money already returned, and nothing ever revoked it.
  it("records a refund that arrives before the licence, and mails nothing later", async () => {
    const built = testEnv();
    const early = await webhook(
      built.env,
      chargeEvent("charge.refunded", { amount_refunded: 1499 }),
    );
    expect(early.status).toBe(200);
    expect(await early.text()).toBe("refunded: recorded before the licence existed");

    const late = await webhook(built.env, completed());
    expect(late.status).toBe(200);
    expect(await late.text()).toBe("revoked, not re-sent");
    expect(built.sent).toHaveLength(0);
    const licence = await row(built.env);
    expect(licence?.revoked_at).not.toBeNull();
    expect(licence?.revoked_reason).toBe("refunded");
  });

  // The same window, through the resend route: the licence is recorded, so
  // the address is a customer's, but a revoked one is never sent.
  it("does not resend a licence an early refund revoked", async () => {
    const built = testEnv();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    await webhook(built.env, completed());
    await call(
      new Request("https://api.test/license/resend", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: "buyer@example.com" }),
      }),
      built.env,
    );
    expect(built.sent).toHaveLength(0);
  });

  // The early note has to go too, or a licence fulfilled after the dispute
  // was won would still be recorded revoked.
  it("restores a licence revoked by an early dispute once the dispute is won", async () => {
    const built = testEnv();
    await webhook(built.env, disputeEvent("charge.dispute.created"));
    await webhook(built.env, completed());
    expect((await row(built.env))?.revoked_reason).toBe("disputed");
    expect(built.sent).toHaveLength(0);

    const won = await webhook(built.env, disputeEvent("charge.dispute.closed", { status: "won" }));
    expect(await won.text()).toBe("dispute won: restored 1");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  it("forgets an early dispute that was won before the licence existed", async () => {
    const built = testEnv();
    await webhook(built.env, disputeEvent("charge.dispute.created"));
    await webhook(built.env, disputeEvent("charge.dispute.closed", { status: "won" }));
    const late = await webhook(built.env, completed());
    expect(await late.text()).toBe("ok");
    expect((await row(built.env))?.revoked_at).toBeNull();
    expect(built.sent).toHaveLength(1);
  });

  // An inquiry (`warning_needs_response`) is the bank asking a question, not
  // a chargeback, and it closes as `warning_closed` rather than `won`, so
  // revoking on it left a paying customer revoked for good.
  it("leaves a licence alone on an inquiry", async () => {
    const built = await fulfilled();
    const response = await webhook(
      built.env,
      disputeEvent("charge.dispute.created", { status: "warning_needs_response" }),
    );
    expect(await response.text()).toBe("inquiry (warning_needs_response): licence left alone");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  it("does not re-send a revoked licence", async () => {
    const built = await fulfilled();
    expect(built.sent).toHaveLength(1);
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    await cooled(built.env);

    // A "Resend" of the original event from the Stripe dashboard, past the
    // cooldown, must not mail the dead key again under a note promising a
    // refund that has already been paid.
    const again = await webhook(built.env, completed());
    expect(again.status).toBe(200);
    expect(await again.text()).toBe("revoked, not re-sent");
    expect(built.sent).toHaveLength(1);
  });
});

// Not behaviour tests: claims that wrangler.jsonc says what the code relies on.
// Every other test in this file injects its own limiter stub and its own price,
// so renaming a limiter or flipping the deployment to "test" would leave the
// suite green and the live Worker unlimited or unguarded, with nothing saying so.
describe("bindings", () => {
  it("binds both rate limiters from wrangler.jsonc", () => {
    expect(typeof env.RESEND_LIMIT?.limit).toBe("function");
    expect(typeof env.THANKS_LIMIT?.limit).toBe("function");
  });

  it("declares the default deployment as production", () => {
    expect(env.ENVIRONMENT).toBe("production");
  });
});

describe("event idempotency", () => {
  it("handles the same event id only once", async () => {
    const built = testEnv();
    const event = { ...completed(), id: "evt_fixed" };
    expect((await webhook(built.env, event)).status).toBe(200);
    expect(built.sent).toHaveLength(1);
    await cooled(built.env);

    const second = await webhook(built.env, event);
    expect(second.status).toBe(200);
    expect(await second.text()).toBe("duplicate");
    expect(built.sent).toHaveLength(1);
    expect(await count(built.env)).toBe(1);
  });

  // A Worker that dies between the claim and its answer cannot give the claim
  // back. Stripe's retry then read as a duplicate for days, and the payment
  // could end with no licence at all.
  it("takes over a claim abandoned long enough ago, and only then", async () => {
    const built = testEnv();
    const abandoned = { ...completed(), id: "evt_abandoned" };
    const longAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();
    await built.env.DB.prepare("INSERT INTO stripe_events (id, type, received_at) VALUES (?, ?, ?)")
      .bind(abandoned.id, abandoned.type, longAgo)
      .run();
    const retry = await webhook(built.env, abandoned);
    expect(await retry.text()).toBe("ok");
    expect(built.sent).toHaveLength(1);

    // One still in flight is not abandoned: a slow first attempt and its retry
    // must not both handle the event.
    const inFlight = {
      ...completed({ id: "cs_test_2", payment_intent: "pi_test_2" }),
      id: "evt_busy",
    };
    await built.env.DB.prepare("INSERT INTO stripe_events (id, type, received_at) VALUES (?, ?, ?)")
      .bind(inFlight.id, inFlight.type, new Date().toISOString())
      .run();
    expect(await (await webhook(built.env, inFlight)).text()).toBe("duplicate");
  });

  // A handled event is a duplicate forever, however old its claim.
  it("never takes over an event that was handled", async () => {
    const built = testEnv();
    const event = { ...completed(), id: "evt_old_handled" };
    expect(await (await webhook(built.env, event)).text()).toBe("ok");
    const longAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    await built.env.DB.prepare("UPDATE stripe_events SET received_at = ? WHERE id = ?")
      .bind(longAgo, event.id)
      .run();
    await cooled(built.env);
    expect(await (await webhook(built.env, event)).text()).toBe("duplicate");
    expect(built.sent).toHaveLength(1);
  });

  // The retry path fulfilment depends on: a 500 must stay retryable, so a
  // failed send must NOT record the event as handled.
  it("does not record an event whose handling failed", async () => {
    let broken = true;
    const built = testEnv({}, async () => {
      if (broken) throw new Error("smtp is down");
    });
    const event = { ...completed(), id: "evt_retry" };
    expect((await webhook(built.env, event)).status).toBe(500);
    expect(await events(built.env)).toBe(0);

    broken = false;
    const retry = await webhook(built.env, event);
    expect(retry.status).toBe(200);
    expect(await retry.text()).not.toBe("duplicate");
    expect(built.sent).toHaveLength(1);
  });
});

describe("deliveries that arrive together", () => {
  // A Stripe retry crossing a "Resend" from the dashboard. Reading
  // `stripe_events` first and writing it after handling let both through; the
  // INSERT is now the gate, and only one delivery can win it.
  it("sends one email when the same event arrives twice at once", async () => {
    const built = testEnv();
    const event = { ...completed(), id: "evt_twice" };
    const responses = await Promise.all([webhook(built.env, event), webhook(built.env, event)]);
    expect(responses.map((response) => response.status)).toEqual([200, 200]);
    const bodies = await Promise.all(responses.map((response) => response.text()));
    expect(bodies.toSorted()).toEqual(["duplicate", "ok"]);
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  // Two different events for one session, which the event gate cannot tell are
  // the same sale. The send claim on the licence row is what stops the second
  // email.
  it("sends one email when two events for one session arrive at once", async () => {
    const built = testEnv();
    const responses = await Promise.all([
      webhook(built.env, completed()),
      webhook(built.env, { ...completed(), type: "checkout.session.async_payment_succeeded" }),
    ]);
    const bodies = await Promise.all(responses.map((response) => response.text()));
    expect(bodies.toSorted()).toEqual(["already sent", "ok"]);
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });
});

describe("missing and malformed secrets", () => {
  // 500 on purpose, with the secret named and never quoted: Stripe keeps
  // retrying, and the retry that lands after the secret is fixed is the
  // fulfilment. Nothing is recorded, so that retry is not a "duplicate".
  it("answers 500 naming the signing key when it is not set, then fulfils on the retry", async () => {
    const built = testEnv({ LICENSE_SIGNING_KEY: "" });
    const event = { ...completed(), id: "evt_no_key" };
    const response = await webhook(built.env, event);
    expect(response.status).toBe(500);
    expect(await response.text()).toBe("not configured: LICENSE_SIGNING_KEY is not set");
    expect(await count(built.env)).toBe(0);
    expect(await events(built.env)).toBe(0);
    expect(built.sent).toEqual([]);

    const fixed = testEnv();
    expect(await (await webhook(fixed.env, event)).text()).toBe("ok");
    expect(fixed.sent).toHaveLength(1);
  });

  const malformed: [string, string][] = [
    ["text that is not base64", "not base64 at all!"],
    ["base64 that is not a key", btoa("definitely not a PKCS#8 Ed25519 key")],
  ];
  for (const [label, value] of malformed) {
    it(`answers 500 naming the signing key when it is ${label}`, async () => {
      const built = testEnv({ LICENSE_SIGNING_KEY: value });
      const response = await webhook(built.env, completed());
      expect(response.status).toBe(500);
      const body = await response.text();
      expect(body).toMatch(
        /^not configured: LICENSE_SIGNING_KEY is not a base64 PKCS#8 Ed25519 private key/,
      );
      expect(body).not.toContain(value);
      expect(await count(built.env)).toBe(0);
      expect(await events(built.env)).toBe(0);
    });
  }

  // `Number(...) || 1` minted these as a fractional or unexpected major, and
  // the app decodes `major` as an Int: "payload is not a licence". A var
  // rather than a secret, refused the same way, so the sale is fulfilled by
  // Stripe's retry once wrangler.jsonc is fixed. Cast, because the generated
  // Env types the var as the literal "1", which is exactly the assumption
  // under test.
  const majors: [string, string][] = [
    ["a fractional major", "1.5"],
    ["a major with junk after it", "2 beta"],
    ["a zero major", "0"],
  ];
  for (const [label, value] of majors) {
    it(`answers 500 naming CURRENT_MAJOR when it is ${label}`, async () => {
      const built = testEnv({ CURRENT_MAJOR: value } as unknown as Partial<Env>);
      const response = await webhook(built.env, completed());
      expect(response.status).toBe(500);
      expect(await response.text()).toBe(
        "not configured: CURRENT_MAJOR is not a whole number of 1 or more",
      );
      expect(await count(built.env)).toBe(0);
      expect(await events(built.env)).toBe(0);
    });
  }

  it("still revokes without a signing key, which a refund never needs", async () => {
    const built = await fulfilled();
    const keyless = { ...built.env, LICENSE_SIGNING_KEY: "" };
    const response = await webhook(
      keyless,
      chargeEvent("charge.refunded", { amount_refunded: 1499 }),
    );
    expect(await response.text()).toBe("refunded: revoked 1");
  });

  it("answers 500 naming the webhook secret when it is not set", async () => {
    const built = testEnv({ STRIPE_WEBHOOK_SECRET: "" });
    const response = await webhook(built.env, completed());
    expect(response.status).toBe(500);
    expect(await response.text()).toBe("not configured: STRIPE_WEBHOOK_SECRET is not set");
    expect(await count(built.env)).toBe(0);
  });
});

describe("delayed payment methods", () => {
  // SEPA and friends send `completed` with `payment_status: "unpaid"`, then
  // settle later with this. Falling through to "ignored" would leave a charged
  // customer with no key.
  it("fulfils on async_payment_succeeded", async () => {
    const built = testEnv();
    const pending = await webhook(built.env, completed({ payment_status: "unpaid" }));
    expect(await pending.text()).toBe("not paid yet");
    expect(await count(built.env)).toBe(0);

    const settled = await webhook(built.env, {
      ...completed(),
      type: "checkout.session.async_payment_succeeded",
    });
    expect(settled.status).toBe(200);
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  it("records an async payment failure without minting anything", async () => {
    const built = testEnv();
    const failed = await webhook(built.env, {
      ...completed(),
      type: "checkout.session.async_payment_failed",
    });
    expect(failed.status).toBe(200);
    expect(await count(built.env)).toBe(0);
  });

  // Named, so the log line can be traced to a buyer in the Stripe dashboard.
  it("names the session in the log when an async payment fails", async () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const built = testEnv();
    await webhook(built.env, {
      ...completed(),
      type: "checkout.session.async_payment_failed",
    });
    expect(errors.mock.calls.flat().join("\n")).toContain(SESSION);
  });
});

describe("/thanks", () => {
  const thanks = (forEnv: Env, query = `?session_id=${SESSION}`) =>
    call(new Request(`https://api.test/thanks${query}`), forEnv);

  it("404s without a session id", async () => {
    expect((await thanks(testEnv().env, "")).status).toBe(404);
  });

  it("shows the pending page for a session the webhook has not reached yet", async () => {
    const response = await thanks(testEnv().env);
    expect(response.status).toBe(202);
    expect(await response.text()).toContain("Payment received");
  });

  it("shows the key once the licence exists", async () => {
    const built = await fulfilled();
    const response = await thanks(built.env);
    expect(response.status).toBe(200);
    const page = await response.text();
    expect(page).toContain((await row(built.env))?.key);
    expect(page).toContain("buyer@example.com");
    expect(page).toContain("Drakar ▸ Settings ▸ Licence");
  });

  // The page carries a licence key, addressed by a session id that never
  // expires on Stripe's side and that lands in browser history and in `Referer`.
  // The seven-day window bounds what this origin will serve; it says nothing
  // about what a proxy or a disk cache has already kept.
  it("tells caches not to keep the page with the key on it", async () => {
    const built = await fulfilled();
    const response = await thanks(built.env);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
  });

  it("stops showing the key a week after it was issued", async () => {
    const built = await fulfilled();
    const eightDaysAgo = new Date(Date.now() - 8 * 86_400_000).toISOString();
    await built.env.DB.prepare("UPDATE licenses SET issued_at = ? WHERE stripe_session_id = ?")
      .bind(eightDaysAgo, SESSION)
      .run();
    const response = await thanks(built.env);
    expect(response.status).toBe(200);
    const page = await response.text();
    expect(page).toContain("Already sent");
    expect(page).not.toContain((await row(built.env))?.key);
  });

  it("shows no key for a licence that has been revoked", async () => {
    const built = await fulfilled();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    const response = await thanks(built.env);
    expect(response.status).toBe(200);
    const page = await response.text();
    expect(page).toContain("This licence has been revoked");
    expect(page).not.toContain((await row(built.env))?.key);
    expect(page).not.toContain("Already sent");
  });

  // The address is the one thing on the page that came from the buyer. Stripe
  // does not promise it is well formed, and the Worker only trims and
  // lowercases it.
  it("escapes the address it puts on the page", async () => {
    const built = testEnv();
    const response = await webhook(
      built.env,
      completed({ customer_details: { email: 'x<&"y@example.com' } }),
    );
    expect(await response.text()).toBe("ok");
    const page = await (await thanks(built.env)).text();
    expect(page).toContain("x&lt;&amp;&quot;y@example.com");
    expect(page).not.toContain('x<&"y');
  });

  it("answers the pending page when the address is over its limit", async () => {
    const built = await fulfilled();
    const limited = { ...built.env, THANKS_LIMIT: limiter(false) };
    const response = await thanks(limited);
    expect(response.status).toBe(429);
    expect(await response.text()).not.toContain((await row(built.env))?.key);
  });
});

describe("/license/resend", () => {
  const resend = (forEnv: Env, body: string, headers: Record<string, string> = {}) =>
    call(
      new Request("https://api.test/license/resend", {
        method: "POST",
        body,
        headers: { "content-type": "application/json", ...headers },
      }),
      forEnv,
    );

  it("answers ok and sends nothing for an address that is not a customer", async () => {
    const built = testEnv();
    const response = await resend(built.env, JSON.stringify({ email: "nobody@example.com" }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(built.sent).toEqual([]);
  });

  it("re-sends to a customer, and not again inside the cooldown", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    await resend(built.env, JSON.stringify({ email: "Buyer@Example.com " }));
    expect(built.sent).toHaveLength(2);
    expect(built.sent[1]?.to).toBe("buyer@example.com");
    await resend(built.env, JSON.stringify({ email: "buyer@example.com" }));
    expect(built.sent).toHaveLength(2);
  });

  it("does not re-send a revoked licence", async () => {
    const built = await fulfilled();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    await cooled(built.env);
    await resend(built.env, JSON.stringify({ email: "buyer@example.com" }));
    expect(built.sent).toHaveLength(1);
  });

  it("answers identically, and sends nothing, when the address is over its limit", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    const limited = { ...built.env, RESEND_LIMIT: limiter(false) };
    const response = await resend(limited, JSON.stringify({ email: "buyer@example.com" }));
    expect(await response.json()).toEqual({ ok: true });
    expect(built.sent).toHaveLength(1);
  });

  // What makes a cross-origin browser unable to call this route: a JSON body
  // needs a preflight, the preflight gets a 404, and anything a form can send
  // without one is refused here.
  it("refuses a body not labelled application/json, and sends nothing", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    const body = JSON.stringify({ email: "buyer@example.com" });
    for (const type of ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data"]) {
      const response = await resend(built.env, body, { "content-type": type });
      expect(response.status).toBe(415);
    }
    expect(built.sent).toHaveLength(1);
  });

  it("accepts application/json with parameters and in any case", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    const body = JSON.stringify({ email: "buyer@example.com" });
    const response = await resend(built.env, body, {
      "content-type": "Application/JSON; charset=utf-8",
    });
    expect(response.status).toBe(200);
    expect(built.sent).toHaveLength(2);
  });

  it("does not answer a CORS preflight", async () => {
    const response = await call(
      new Request("https://api.test/license/resend", { method: "OPTIONS" }),
      testEnv().env,
    );
    expect(response.status).toBe(404);
    expect(response.headers.get("access-control-allow-origin")).toBeNull();
  });

  // The per-IP limit only bounds one IP. Requests for one address spread across
  // many IPs are bounded by the address's own count on the same limiter.
  it("sends nothing when the address is over its own limit, whatever the IP", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    const keys: string[] = [];
    const byAddress: RateLimit = {
      limit: async ({ key }) => {
        keys.push(key);
        return { success: !key.startsWith("email:") };
      },
    };
    const response = await resend(
      { ...built.env, RESEND_LIMIT: byAddress },
      JSON.stringify({ email: "Buyer@Example.com" }),
      { "cf-connecting-ip": "203.0.113.7" },
    );
    expect(await response.json()).toEqual({ ok: true });
    expect(keys).toEqual(["ip:203.0.113.7", "email:buyer@example.com"]);
    expect(built.sent).toHaveLength(1);
  });

  // The response must not wait on the lookup or the send, or its timing would
  // say whether the address belongs to a customer.
  it("answers before the lookup and the send have finished", async () => {
    let gate: Promise<void> = Promise.resolve();
    const built = testEnv({}, () => gate);
    expect((await webhook(built.env, completed())).status).toBe(200);
    await cooled(built.env);

    let open: (() => void) | undefined;
    gate = new Promise<void>((resolve) => {
      open = resolve;
    });
    const context = createExecutionContext();
    const response = await worker.fetch(
      new Request("https://api.test/license/resend", {
        method: "POST",
        body: JSON.stringify({ email: "buyer@example.com" }),
        headers: { "content-type": "application/json" },
      }),
      built.env,
      context,
    );
    expect(await response.json()).toEqual({ ok: true });
    expect(built.sent).toHaveLength(1);
    open?.();
    await waitOnExecutionContext(context);
    expect(built.sent).toHaveLength(2);
  });

  it("answers identically to a body that is not JSON, or is too large", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    expect(await (await resend(built.env, "not json")).json()).toEqual({ ok: true });
    const large = JSON.stringify({ email: `${"a".repeat(5000)}@example.com` });
    expect(await (await resend(built.env, large)).json()).toEqual({ ok: true });
    expect(built.sent).toHaveLength(1);
  });
});
