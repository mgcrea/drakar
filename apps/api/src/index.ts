// Turning a Stripe payment into a licence key.
//
// Its own Worker rather than a route on the marketing site, for three reasons
// that all point the same way: the site is static assets whose `_redirects` file
// serves the permanent /appcast.xml URL every shipped binary is built against,
// and putting a script in front of that risks shadowing it; the site's tsconfig
// is Astro-shaped and this is workerd-shaped; and the signing key has no
// business living on the Worker that serves public HTML.
//
// Everything here is allowed to touch the network. The APP is the thing that
// cannot (scripts/audit-network.sh fails the build over any connection beyond
// the opt-in update check), and nothing in this directory ships inside it.
//
// Armada's Worker, copied with its names changed and no change in behaviour.
// Armada adapted bastion's with one deliberate divergence, kept here: an
// unconfigured product guard fails closed. See `handleWebhook`.

import { sendLicense, type Sent } from "./email";
import type { LicenseRow } from "./env";
import { mint, SigningKeyError, type Minted } from "./license";
import { notFoundPage, pendingPage, revokedPage, sentPage, thanksPage } from "./pages";
import {
  charge,
  checkoutSession,
  dispute,
  eventEnvelope,
  isFullyRefunded,
  resendRequest,
  type StripeEvent,
} from "./schema";
import { priceIdFor, verifySignature } from "./stripe";

/** Long enough to swallow a Stripe redelivery, short enough to be useful. */
const SEND_COOLDOWN_MS = 5 * 60 * 1000;

/**
 * How old an event claim with no `handled_at` must be before another delivery
 * may take it over. Longer than any handler runs, short of Stripe's first few
 * retries.
 */
const ABANDONED_CLAIM_MS = 5 * 60 * 1000;

/** A resend body is an address. Anything larger is not one. */
const MAX_BODY_BYTES = 4096;

/**
 * A Stripe event is a few kilobytes; a checkout session with metadata is well
 * under sixty-four. The HMAC has to run over the whole body, so the body is
 * bounded before it is buffered rather than after.
 */
const MAX_WEBHOOK_BYTES = 256 * 1024;

/** How long `/thanks` keeps showing the key against a session id. */
const THANKS_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

/** The event types that end in a mint. Everything the price guard stands in front of. */
const FULFILMENT_EVENTS = new Set([
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
]);

/** Which field moved, in one line, for the log. */
const explain = (error: { issues: { path: PropertyKey[]; message: string }[] }): string =>
  error.issues.map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`).join("; ");

const html = (body: string, status = 200): Response =>
  new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      // `/thanks` puts a licence key in a page body. Without this a proxy or a
      // browser disk cache may keep it, addressed by a `session_id` that never
      // expires on Stripe's side and that lands in history and in `Referer`.
      // The seven-day window bounds what the origin will serve, not what
      // something else has already stored.
      "cache-control": "private, no-store",
    },
  });

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

/**
 * A secret this Worker needs is missing or unusable.
 *
 * 500, so Stripe keeps retrying, and the retry that lands after the secret is
 * fixed is the fulfilment. The body names the secret and never quotes it: it
 * shows up beside the event in the Stripe dashboard, which is where someone
 * looks first, and a bare 500 there used to say nothing at all.
 */
const misconfigured = (what: string): Response => {
  console.error(`webhook: not configured, ${what}`);
  return new Response(`not configured: ${what}`, { status: 500 });
};

/**
 * A verified delivery this Worker will never be able to act on.
 *
 * 200, not 400. Stripe retries every non-2xx answer for three days whatever
 * its code, so a 4xx does not say "stop", it says "later", and no number of
 * retries makes a session grow the field it lacks. The body is what shows up
 * next to the event in the Stripe dashboard and the log line is what shows up
 * in Workers Logs; between them someone can see what arrived.
 *
 * A 200 is recorded in `stripe_events` like any other, so once the code is
 * fixed a "Resend" from the dashboard answers "duplicate". Replaying one means
 * deleting its row first, which sends it through `fulfil` like any sale, or
 * minting by hand with scripts/mint-license.mjs and its `--session` and
 * `--payment-intent`, so the licence is recorded where a refund can revoke it.
 */
const unprocessable = (what: string, event?: StripeEvent): Response => {
  const which = event ? ` ${event.id} (${event.type})` : "";
  console.error(`webhook: cannot handle${which}, ${what}`);
  return new Response(`unprocessable: ${what}`, { status: 200 });
};

/**
 * Why this deployment may not fulfil, as the answer to give Stripe, or `null`
 * when it may. Two failures, answered differently on purpose.
 *
 * No price is a deployment that has not been told which sales are its own.
 * Only the test environment may run without one, and it has to say so by
 * name: a missing or misspelt ENVIRONMENT reads as production, so a mistake in
 * wrangler.jsonc closes the Worker rather than opening it. That one answers
 * 200; `handleWebhook` says why.
 *
 * No signing key is a deployment that cannot mint at all, and that one answers
 * 500 through `misconfigured`, so the sale is fulfilled by Stripe's retry once
 * the secret is set. Every app's checkouts reach this Worker, so theirs are
 * retried too, and answer "not this product" when they come back. Only
 * presence is checked here; a key that is set but will not import is found by
 * `mint`, the first thing to read it, and answered the same way. A
 * CURRENT_MAJOR the app could not read is refused through `misconfigured` too.
 */
const fulfilmentRefusal = (env: Env, event: StripeEvent): Response | null => {
  if (env.ENVIRONMENT !== "test" && !env.EXPECTED_PRICE_ID) {
    console.error(`webhook: not fulfilling ${event.id}, EXPECTED_PRICE_ID is empty`);
    return new Response("fulfilment not configured: EXPECTED_PRICE_ID is empty", { status: 200 });
  }
  if (!env.LICENSE_SIGNING_KEY) return misconfigured("LICENSE_SIGNING_KEY is not set");
  // A var rather than a secret, refused the same way for the same reason:
  // `fulfil` read it with `Number(...) || 1`, which minted "1.5" as a major
  // the app, decoding it as an Int, refuses as "payload is not a licence", and
  // quietly turned "2 beta" or "0" into 1. Unset is fine; that is the 1 every
  // key so far was minted with. Widened, because the generated Env pins the
  // literal in wrangler.jsonc, which is exactly the assumption being checked.
  const major: string | undefined = env.CURRENT_MAJOR;
  if (major && !/^[1-9][0-9]*$/.test(major.trim())) {
    return misconfigured("CURRENT_MAJOR is not a whole number of 1 or more");
  }
  return null;
};

/**
 * Read a body, or give up once it exceeds `cap`. `null` means it did.
 *
 * Reading the stream rather than trusting `Content-Length`: the header is the
 * sender's claim, and a chunked body carries none. Cancelling the reader is
 * what stops the rest from being received at all.
 */
const readCapped = async (request: Request, cap: number): Promise<string | null> => {
  if (Number(request.headers.get("content-length") ?? "0") > cap) return null;
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > cap) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(joined);
};

/** The connecting address, which Cloudflare sets and a client cannot. */
const clientAddress = (request: Request): string =>
  request.headers.get("cf-connecting-ip") ?? "unknown";

/**
 * Whether `key` has had its share of a public route for the minute.
 *
 * Keys are prefixed with what they count (`ip:`, `email:`), so two kinds of
 * limit can share one binding without one's counter spilling into the other.
 * A missing binding (a wrangler that has not got one, a test that stubbed it
 * out) means no limit rather than a crash: a fulfilment must never fail on a
 * limiter.
 */
const overLimit = async (limiter: RateLimit | undefined, key: string): Promise<boolean> => {
  if (!limiter) return false;
  try {
    const outcome = await limiter.limit({ key });
    return !outcome.success;
  } catch {
    return false;
  }
};

/**
 * Take the right to mail this licence, or learn that it is not ours to take.
 *
 * One conditional UPDATE rather than read, decide, send, then write. That
 * sequence let two deliveries arriving together (a Stripe retry crossing a
 * dashboard "Resend", or `completed` crossing `async_payment_succeeded`) both
 * read an old `last_sent_at`, both send, and both stamp it. D1 applies one
 * statement at a time, so exactly one claim changes the row and the other is
 * told the key has gone. ISO timestamps from `toISOString` sort as text.
 *
 * `revoked_at IS NULL` sits in the same statement for the same reason: a refund
 * that lands between reading the row and sending must not let the dead key out.
 *
 * Returns the stamp it wrote, which `releaseSend` needs, or `null`.
 */
const claimSend = async (env: Env, id: string): Promise<string | null> => {
  const now = Date.now();
  const stamp = new Date(now).toISOString();
  const cutoff = new Date(now - SEND_COOLDOWN_MS).toISOString();
  const result = await env.DB.prepare(
    "UPDATE licenses SET last_sent_at = ?" +
      " WHERE id = ? AND revoked_at IS NULL AND (last_sent_at IS NULL OR last_sent_at < ?)",
  )
    .bind(stamp, id, cutoff)
    .run();
  return (result.meta.changes ?? 0) === 1 ? stamp : null;
};

/**
 * Hand a claim back after a send that failed, so the retry is not refused as
 * "already sent" for the next five minutes. Only while the stamp is still the
 * one this claim wrote: a later claim that has taken the row since keeps it.
 */
const releaseSend = async (
  env: Env,
  id: string,
  stamp: string,
  previous: string | null,
): Promise<void> => {
  await env.DB.prepare("UPDATE licenses SET last_sent_at = ? WHERE id = ? AND last_sent_at = ?")
    .bind(previous, id, stamp)
    .run();
};

/** Claim, send, and give the claim back if the send failed. `null` means not claimed. */
const deliver = async (env: Env, row: LicenseRow): Promise<Sent | null> => {
  const stamp = await claimSend(env, row.id);
  if (!stamp) return null;
  const sent = await sendLicense(env, row.email, row.key);
  if (!sent.ok) await releaseSend(env, row.id, stamp, row.last_sent_at);
  return sent;
};

/** Every column of a `LicenseRow`, for each query read with `.first<LicenseRow>()`. */
const LICENSE_COLUMNS = "id, email, key, issued_at, last_sent_at, revoked_at, revoked_reason";

const findBySession = (env: Env, sessionId: string): Promise<LicenseRow | null> =>
  env.DB.prepare(`SELECT ${LICENSE_COLUMNS} FROM licenses WHERE stripe_session_id = ?`)
    .bind(sessionId)
    .first<LicenseRow>();

/**
 * The only route that matters.
 *
 * Idempotent by way of the unique constraint on `stripe_session_id`, because
 * Stripe redelivers for days and a redelivery must not mean a second licence.
 * A failed email returns 500 on purpose: Stripe then retries, the row is found
 * rather than inserted the second time, and the send is attempted again, which
 * is exactly the behaviour wanted when the alternative is a customer who paid
 * and got nothing.
 *
 * `handleWebhook` has already refused the event if no price is configured, but
 * the guard below does not rely on that: with an empty EXPECTED_PRICE_ID outside
 * the test environment, no session's price can match it, so nothing is minted.
 */
const fulfil = async (event: StripeEvent, env: Env): Promise<Response> => {
  const parsed = checkoutSession.safeParse(event.data.object);
  if (!parsed.success) {
    // The message is what says which field Stripe moved.
    return unprocessable(`session: ${explain(parsed.error)}`, event);
  }
  const session = parsed.data;
  // `no_payment_required` is a 100%-off promotion code: nothing to pay, and
  // still a sale. It used to fall in with "not paid yet" and be dropped with a
  // 200, so the code's holder got no key and nothing said why.
  if (session.payment_status !== "paid" && session.payment_status !== "no_payment_required") {
    console.log(`fulfil: ${session.id} is ${session.payment_status}, nothing minted yet`);
    return new Response("not paid yet", { status: 200 });
  }
  const email = session.customer_details?.email?.trim().toLowerCase();
  if (!email) return unprocessable("no email on the session, nothing minted", event);

  let row = await findBySession(env, session.id);
  if (!row) {
    // The Payment Link copies its metadata onto every session it creates, so the
    // price arrives inside the webhook that is already signed and already being
    // parsed. Preferring it removes a network call from the one path that must
    // not fail. The API call survives as a fallback for a session created some
    // other way: a future Checkout Session integration, or a link made by hand.
    const priceId =
      session.metadata?.price_id ||
      (env.STRIPE_SECRET_KEY ? await priceIdFor(session.id, env.STRIPE_SECRET_KEY) : "");

    // Whether this sale is ours at all. Resolved BEFORE the mint, so another
    // product's sale never reaches the signing key.
    //
    // Every app sells through ONE Stripe account, and Stripe delivers every
    // event of a subscribed type to every endpoint subscribed to it, so this
    // Worker sees every other app's checkouts too. An allowlist of OUR price,
    // never a blocklist of theirs: another product is then a Worker nobody has
    // to remember to tell about.
    //
    // DIVERGES from bastion: a session whose price could not be resolved is
    // refused here, where bastion lets it through. Bastion's reasoning is that
    // refusing would refund a real sale to protect a column, which holds while
    // the guard is a reporting nicety. Here it is the only thing standing
    // between another app's buyer and a drk1 key, and an unresolvable price is
    // exactly what a sale made through someone else's hand-made link looks
    // like. The cost is stated rather than hidden: Drakar's Payment Link MUST
    // carry `price_id` in its metadata (or STRIPE_SECRET_KEY must be set), and
    // a Stripe API timeout on the fallback path refuses a genuine sale, which is
    // then found in Workers Logs by the error below and replayed: delete its
    // `stripe_events` row and resend it, or mint by hand with
    // scripts/mint-license.mjs, passing the sale's session and payment intent.
    //
    // Outside the test environment the guard is always on. In it, an empty
    // EXPECTED_PRICE_ID means unguarded, so a test-mode link can be rehearsed
    // before its price id is pinned.
    const guarded = env.ENVIRONMENT !== "test" || Boolean(env.EXPECTED_PRICE_ID);
    if (guarded && (!priceId || priceId !== env.EXPECTED_PRICE_ID)) {
      // 200, not 4xx: the event is valid and simply belongs to another product.
      // A 4xx would have Stripe retrying it for three days.
      if (priceId) {
        console.log(`fulfil: ignoring ${session.id}, price ${priceId} is not ours`);
      } else {
        // An error, not the log line every other app's sale writes: this is the one that
        // can be a genuine Drakar sale refused (a Payment Link missing `price_id`, or the
        // fallback lookup failing), and the comment above says it is found in the logs.
        console.error(`fulfil: price unresolved for ${session.id}, refused as not ours`);
      }
      return new Response("not this product", { status: 200 });
    }

    // Already known to be a whole number of 1 or more, or unset.
    const major = Number(env.CURRENT_MAJOR) || 1;
    let minted: Minted;
    try {
      minted = await mint({ email, major, privateKey: env.LICENSE_SIGNING_KEY });
    } catch (error) {
      // Set, but not a key: `fulfilmentRefusal` can only see that it is set.
      // Answered like a missing one, because fixing the secret is what
      // fulfils this sale, and Stripe's retry is what brings it back.
      if (error instanceof SigningKeyError) return misconfigured(error.message);
      throw error;
    }
    await env.DB.prepare(
      `INSERT INTO licenses
         (id, email, major, key, stripe_session_id, payment_intent, price_id, amount_paid,
          currency, issued_at, livemode)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (stripe_session_id) DO NOTHING`,
    )
      .bind(
        minted.id,
        email,
        major,
        minted.key,
        session.id,
        session.payment_intent ?? "",
        priceId,
        session.amount_total ?? 0,
        session.currency ?? "eur",
        minted.issuedAt,
        event.livemode ? 1 : 0,
      )
      .run();
    // Re-read rather than trusting the insert: on a race the row that won is the
    // one to send, and sending a key that is not in the table would be worse
    // than any duplicate.
    row = await findBySession(env, session.id);
  }
  if (!row) {
    console.error(`fulfil: no row after insert for session ${session.id}`);
    return new Response("could not record the licence", { status: 500 });
  }

  // Refunded or disputed before it got here. Recorded all the same, so a won
  // dispute can restore it and the resend route can deliver it then, but
  // recorded revoked, so the check below does not mail it.
  if (!row.revoked_at && session.payment_intent) {
    const early = await env.DB.prepare(
      "SELECT reason, revoked_at FROM early_revocations WHERE payment_intent = ?",
    )
      .bind(session.payment_intent)
      .first<{ reason: string; revoked_at: string }>();
    if (early) {
      await env.DB.prepare(
        "UPDATE licenses SET revoked_at = ?, revoked_reason = ? WHERE id = ? AND revoked_at IS NULL",
      )
        .bind(early.revoked_at, early.reason, row.id)
        .run();
      row = { ...row, revoked_at: early.revoked_at, revoked_reason: early.reason };
    }
  }

  // A revoked licence is not re-sent, for the same reason `resendTo` will not
  // send one: the money has been given back. Without this, a redelivery
  // arriving after the cooldown, or a "Resend" click on the event in the Stripe
  // dashboard, would mail the dead key again under a covering note promising a
  // full refund.
  if (row.revoked_at) {
    return new Response("revoked, not re-sent", { status: 200 });
  }
  const sent = await deliver(env, row);
  if (!sent) return new Response("already sent", { status: 200 });
  if (!sent.ok) {
    console.error(`fulfil: email failed for licence ${row.id}: ${sent.reason}`);
    return new Response(`email: ${sent.reason}`, { status: 500 });
  }
  return new Response("ok", { status: 200 });
};

/**
 * Mark a licence revoked, by the payment that bought it.
 *
 * Guarded on `revoked_at IS NULL` so a redelivered event does not keep moving
 * the timestamp forward: the date is meant to be when it was revoked, not when
 * Stripe last mentioned it.
 *
 * Nothing here reaches the app. Revocation is baked into a build by
 * `make revocations`, so this only records the fact; the refunded key keeps
 * working until the next release. That is the trade the offline check makes, and
 * it has to be said out loud rather than left to be discovered. Armada's EULA
 * says it (§6 and §7(a)) and its site serves that text at /terms; Drakar has
 * neither yet, and whatever terms it publishes before its first sale must say
 * the same.
 */
const revoke = async (env: Env, paymentIntent: string | null | undefined, why: string) => {
  if (!paymentIntent) {
    // 200, not 500. Retrying will never make a payment intent appear, and a
    // three-day retry loop buries the problem; this body shows up in the event
    // log on the Stripe dashboard, where someone will see it.
    return new Response(`${why}: no payment intent on the event, nothing revoked`, { status: 200 });
  }
  const now = new Date().toISOString();
  const result = await env.DB.prepare(
    "UPDATE licenses SET revoked_at = ?, revoked_reason = ?" +
      " WHERE payment_intent = ? AND revoked_at IS NULL",
  )
    .bind(now, why, paymentIntent)
    .run();
  const changes = result.meta.changes ?? 0;
  if (changes > 0) return new Response(`${why}: revoked ${changes}`, { status: 200 });

  // Nothing to revoke: either already revoked, or the licence does not exist
  // YET. Fulfilment answers 500 until the key is mailed, and a buyer refunded
  // inside that window used to get a working key from the retry. Written down
  // so `fulfil` records that licence revoked. A payment that already has a
  // licence is the first case, and needs nothing more.
  const known = await env.DB.prepare("SELECT 1 FROM licenses WHERE payment_intent = ?")
    .bind(paymentIntent)
    .first();
  if (known) return new Response(`${why}: revoked 0`, { status: 200 });
  await env.DB.prepare(
    "INSERT INTO early_revocations (payment_intent, reason, revoked_at) VALUES (?, ?, ?)" +
      " ON CONFLICT (payment_intent) DO NOTHING",
  )
    .bind(paymentIntent, why, now)
    .run();
  return new Response(`${why}: recorded before the licence existed`, { status: 200 });
};

/**
 * `charge.refunded` also fires for a PARTIAL refund, which is the trap. Handing
 * back two euros of a fifteen euro licence is a goodwill gesture; treating it as
 * a revocation would take the product away from someone who still owns it.
 */
const refunded = async (event: StripeEvent, env: Env): Promise<Response> => {
  const parsed = charge.safeParse(event.data.object);
  if (!parsed.success) return unprocessable(`charge: ${explain(parsed.error)}`, event);
  if (!isFullyRefunded(parsed.data)) {
    return new Response("partial refund: licence left alone", { status: 200 });
  }
  return revoke(env, parsed.data.payment_intent, "refunded");
};

const disputed = async (event: StripeEvent, env: Env): Promise<Response> => {
  const parsed = dispute.safeParse(event.data.object);
  if (!parsed.success) return unprocessable(`dispute: ${explain(parsed.error)}`, event);
  // An inquiry is the bank asking a question, not a chargeback. It arrives as
  // `charge.dispute.created` with a `warning_` status and closes as
  // `warning_closed`, never `won`, so revoking on it left a paying customer
  // revoked for good. If it escalates, Stripe sends a real dispute.
  if (parsed.data.status?.startsWith("warning_")) {
    return new Response(`inquiry (${parsed.data.status}): licence left alone`, { status: 200 });
  }
  return revoke(env, parsed.data.payment_intent, "disputed");
};

/**
 * A dispute that closes in our favour means the claim failed and the customer
 * did pay after all, so the licence comes back. Any other outcome leaves it
 * revoked.
 *
 * In practice this usually costs nothing to honour: disputes take weeks, and
 * unless a release went out in the meantime the revocation was never baked into
 * a build to begin with.
 */
const disputeClosed = async (event: StripeEvent, env: Env): Promise<Response> => {
  const parsed = dispute.safeParse(event.data.object);
  if (!parsed.success) return unprocessable(`dispute: ${explain(parsed.error)}`, event);
  const { payment_intent: paymentIntent, status } = parsed.data;
  if (status !== "won") {
    return new Response(`dispute ${status ?? "closed"}: licence stays revoked`, { status: 200 });
  }
  if (!paymentIntent) {
    return new Response("dispute won: no payment intent, nothing restored", { status: 200 });
  }
  // Only what the DISPUTE took away. `revoke` is guarded on `revoked_at IS
  // NULL`, and without a matching guard here a licence revoked by a refund,
  // whose charge was later disputed and won, would come back, and the next
  // `make revocations` would then drop it from the baked-in list, returning a
  // working key to someone who already had their money back.
  const result = await env.DB.prepare(
    "UPDATE licenses SET revoked_at = NULL, revoked_reason = NULL" +
      " WHERE payment_intent = ? AND revoked_reason = 'disputed'",
  )
    .bind(paymentIntent)
    .run();
  // And the note a dispute that came before the licence left, or a licence
  // fulfilled after this would still be recorded revoked. Same guard: a
  // refund's note stays.
  await env.DB.prepare(
    "DELETE FROM early_revocations WHERE payment_intent = ? AND reason = 'disputed'",
  )
    .bind(paymentIntent)
    .run();
  return new Response(`dispute won: restored ${result.meta.changes ?? 0}`, { status: 200 });
};

/** Give an event's claim back, so Stripe's next delivery of it is handled. */
const releaseEvent = async (env: Env, id: string): Promise<void> => {
  await env.DB.prepare("DELETE FROM stripe_events WHERE id = ?").bind(id).run();
};

/**
 * Verify, then route on the event type.
 *
 * Every subscribed event lands here, not just the ones handled. Deciding that
 * BEFORE insisting on a shape is what keeps an unrelated event type from being
 * reported as a malformed one.
 */
const handleWebhook = async (request: Request, env: Env): Promise<Response> => {
  // Before the signature, because without the secret there is no signature to
  // check: WebCrypto refuses a zero-length HMAC key by throwing, which used to
  // surface as a bare 500 naming nothing. The name of a missing secret is no
  // use to a stranger, and its value is not in reach of this line.
  if (!env.STRIPE_WEBHOOK_SECRET) return misconfigured("STRIPE_WEBHOOK_SECRET is not set");

  const raw = await readCapped(request, MAX_WEBHOOK_BYTES);
  if (raw === null) return new Response("body too large", { status: 413 });
  const verified = await verifySignature(
    raw,
    request.headers.get("stripe-signature"),
    env.STRIPE_WEBHOOK_SECRET,
  );
  if (!verified.ok) {
    // The reason goes to the log and nowhere else. In the body it would tell
    // whoever is forging deliveries which check they got past.
    console.error(`webhook: refused, ${verified.reason}`);
    return new Response("invalid signature", { status: 400 });
  }

  // Past the signature these are Stripe's own bytes, so neither failure can be
  // cured by retrying, and both answer 200 for the reason `unprocessable` gives.
  // Neither is recorded as seen: without an envelope there is no event id.
  let envelope: ReturnType<typeof eventEnvelope.safeParse>;
  try {
    envelope = eventEnvelope.safeParse(JSON.parse(raw));
  } catch {
    return unprocessable("body is not JSON");
  }
  if (!envelope.success) return unprocessable(`not a Stripe event: ${explain(envelope.error)}`);

  const event = envelope.data;

  // DIVERGES from bastion: an empty EXPECTED_PRICE_ID fails closed.
  //
  // Drakar, Armada, Bastion and Cupertino sell through ONE Stripe account, so
  // every checkout event reaches every app's Worker. Bastion reads an empty
  // price as "unguarded", which there meant that deploying the guard changed
  // nothing. Here the same reading would mean that this Worker, deployed before
  // its Stripe price exists, mints drk1 keys for Armada, Bastion and Cupertino
  // buyers and mails them a licence for a product they never bought. So outside
  // the test environment, no price means no fulfilment. Drakar is deployed
  // exactly that way: wrangler.jsonc ships EXPECTED_PRICE_ID empty until a
  // price exists.
  //
  // 200, so Stripe does not retry it for three days. Before the idempotency
  // claim, so an unconfigured Worker never touches D1. And NOT recorded in
  // `stripe_events`, so once the price is set, a "Resend" from the Stripe
  // dashboard still fulfils a sale that was genuinely Drakar's. A missing
  // signing key is refused at the same point, with a 500 instead.
  if (FULFILMENT_EVENTS.has(event.type)) {
    const refusal = fulfilmentRefusal(env, event);
    if (refusal) return refusal;
  }

  // The claim comes BEFORE anything is acted on, and it is the whole check. A
  // SELECT here and an INSERT after handling left a window as long as a
  // fulfilment in which a second delivery of the same event saw no row and
  // handled it again. `ON CONFLICT DO NOTHING` is atomic, so exactly one
  // delivery changes a row and every other one answers "duplicate".
  //
  // The unique constraint on `stripe_session_id` stops a second licence, which
  // is not the same as stopping a second email: past the send cooldown, a
  // redelivery or a "Resend" from the dashboard would mail the key again.
  //
  // Or by taking over a claim that was abandoned: no `handled_at`, and older
  // than any handler runs. That is a Worker killed between the insert and its
  // answer, which could never give its claim back; Stripe's retries used to
  // read as duplicates for days, and the payment could end with no licence.
  // The takeover is the same single statement, so two retries racing for one
  // stale claim still see exactly one `changes`.
  const now = new Date();
  const abandoned = new Date(now.getTime() - ABANDONED_CLAIM_MS).toISOString();
  const claimed = await env.DB.prepare(
    "INSERT INTO stripe_events (id, type, received_at) VALUES (?, ?, ?)" +
      " ON CONFLICT (id) DO UPDATE SET received_at = excluded.received_at" +
      " WHERE stripe_events.handled_at IS NULL AND stripe_events.received_at < ?",
  )
    .bind(event.id, event.type, now.toISOString(), abandoned)
    .run();
  if ((claimed.meta.changes ?? 0) !== 1) return new Response("duplicate", { status: 200 });

  // Given back unless the event was actually handled. A 500 must stay
  // retryable: that is what turns a failed send into a second attempt rather
  // than a customer who paid and got nothing. A throw gives it back too, then
  // carries on into the runtime's own 500. A claim nobody gives back, because
  // the Worker died holding it, is taken over once it is stale, above.
  //
  // One thing this cannot give back, rare enough to leave to the log: a
  // duplicate that arrives while the first delivery is still running answers
  // 200 before that delivery's outcome is known.
  let response: Response;
  try {
    response = await dispatch(event, env);
  } catch (error) {
    await releaseEvent(env, event.id);
    throw error;
  }
  if (response.status >= 300) {
    await releaseEvent(env, event.id);
  } else {
    // What makes the claim permanent: a handled event is a duplicate forever,
    // an unhandled one only until it looks abandoned.
    await env.DB.prepare("UPDATE stripe_events SET handled_at = ? WHERE id = ?")
      .bind(new Date().toISOString(), event.id)
      .run();
  }
  return response;
};

const dispatch = async (event: StripeEvent, env: Env): Promise<Response> => {
  switch (event.type) {
    case "checkout.session.completed":
      return fulfil(event, env);
    // A delayed-notification method (SEPA, Bancontact-to-SEPA, a bank transfer)
    // sends `completed` with `payment_status: "unpaid"` and settles later with
    // this. Unhandled, that second event would fall to `ignored`: the customer
    // charged, no row written, no key minted and nothing recording that it had
    // happened. The switch that enables such methods lives in the Stripe
    // dashboard, not in this repo, so it is handled before anyone flips it.
    case "checkout.session.async_payment_succeeded":
      return fulfil(event, env);
    case "checkout.session.async_payment_failed": {
      // Named, so the line can be traced to a buyer in the Stripe dashboard:
      // the event id alone says which delivery, not whose payment.
      const id = (event.data.object as { id?: unknown } | null)?.id;
      console.error(
        `webhook: async payment failed for session ${String(id ?? "(no id)")}, event ${event.id}`,
      );
      return new Response("async payment failed", { status: 200 });
    }
    case "charge.refunded":
      return refunded(event, env);
    case "charge.dispute.created":
      return disputed(event, env);
    case "charge.dispute.closed":
      return disputeClosed(event, env);
    default:
      return new Response("ignored", { status: 200 });
  }
};

const handleThanks = async (request: Request, url: URL, env: Env): Promise<Response> => {
  const sessionId = url.searchParams.get("session_id");
  if (!sessionId) return html(notFoundPage(env.SITE_URL), 404);
  // The pending page, not an error: to a browser that has just paid, a limit
  // and a slow webhook look the same and deserve the same sentence.
  if (await overLimit(env.THANKS_LIMIT, `ip:${clientAddress(request)}`)) {
    return html(pendingPage(), 429);
  }
  const row = await findBySession(env, sessionId);
  // The redirect can outrun the webhook. That is a wait, not an error.
  if (!row) return html(pendingPage(), 202);
  // Whatever its age. The key stopped being a licence when the money went back.
  if (row.revoked_at) return html(revokedPage());
  if (Date.now() - Date.parse(row.issued_at) > THANKS_WINDOW_MS) return html(sentPage(row.email));
  return html(thanksPage(row.key, row.email));
};

/** The media type, without parameters, case-folded. */
const isJson = (request: Request): boolean =>
  (request.headers.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase() ===
  "application/json";

/**
 * Re-send a key to the address that bought it.
 *
 * A support and command-line route. Nothing in this repo calls it: the site has
 * no form for it, and the email tells a customer to reply instead. It is for
 * `curl` from a support session, where it beats minting a replacement by hand.
 *
 * No CORS, on purpose. It answers no OPTIONS request and sets no
 * Access-Control-Allow-* header, and it refuses any body not labelled
 * `application/json`, which a browser will not send to another origin without
 * a preflight. That preflight lands on the 404 below, so a page elsewhere can
 * neither read this route's answer nor make a visitor's browser call it. A
 * plain form post, which skips the preflight, cannot carry that type and gets
 * 415.
 *
 * Answers identically whether or not the address is a customer, in body AND in
 * time. Anything else makes this an oracle for "did this person buy Drakar",
 * which is a question a stranger should not be able to ask a thousand times a
 * second. The answer is settled before anything is looked up, and the lookup
 * and send run in `waitUntil` after it has gone, so a customer's address
 * costing a D1 read and an email does not make for a slower response.
 */
const handleResend = async (
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> => {
  if (!isJson(request)) return new Response("expected application/json", { status: 415 });

  const answer = json({ ok: true });

  // The limiter first, before the body is even read, and the same answer when
  // it bites: the per-licence cooldown only ever protects a customer's row, so
  // an address that is not a customer would cost a D1 query per request.
  if (await overLimit(env.RESEND_LIMIT, `ip:${clientAddress(request)}`)) return answer;

  let email: string;
  try {
    // Bounded before it is buffered. This route is public and nothing
    // legitimate on it exceeds a few hundred bytes.
    const raw = await readCapped(request, MAX_BODY_BYTES);
    if (raw === null) return answer;
    const parsed = resendRequest.safeParse(JSON.parse(raw));
    if (!parsed.success) return answer;
    email = parsed.data.email;
  } catch {
    return answer;
  }

  ctx.waitUntil(resendTo(env, email));
  return answer;
};

/**
 * The part of a resend whose cost depends on who the address belongs to.
 *
 * The address gets its own count on the limiter, beside the connecting
 * address's. The per-IP limit only bounds one IP, and the per-licence cooldown
 * only protects a customer's row, so without it anyone spreading requests for
 * one address across many IPs would cost a D1 query each.
 *
 * Nothing is waiting on this: the response has already gone. So it never
 * throws, and the log is the only place a failure can land.
 */
const resendTo = async (env: Env, email: string): Promise<void> => {
  try {
    if (await overLimit(env.RESEND_LIMIT, `email:${email}`)) return;
    const row = await env.DB.prepare(
      `SELECT ${LICENSE_COLUMNS} FROM licenses
         WHERE email = ? AND revoked_at IS NULL
         ORDER BY issued_at DESC LIMIT 1`,
    )
      .bind(email)
      .first<LicenseRow>();
    if (!row) return;
    const sent = await deliver(env, row);
    if (sent && !sent.ok)
      console.error(`resend: email failed for licence ${row.id}: ${sent.reason}`);
  } catch (error) {
    console.error(`resend: ${String(error)}`);
  }
};

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;
    switch (route) {
      case "POST /stripe/webhook":
        return handleWebhook(request, env);
      case "GET /thanks":
        return handleThanks(request, url, env);
      case "POST /license/resend":
        return handleResend(request, env, ctx);
      case "GET /health":
        return json({ ok: true });
      default:
        return html(notFoundPage(env.SITE_URL), 404);
    }
  },
} satisfies ExportedHandler<Env>;
