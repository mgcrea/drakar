// What arrives from outside, and what is allowed through.
//
// Not a security boundary — the webhook is already past an HMAC, and every D1
// query here is parameterised. What this buys is a diagnosable failure. Reading
// `event.data.object` off an unchecked cast throws a TypeError when the shape
// surprises us, which becomes a 500, which becomes Stripe retrying every few
// hours for three days with nothing in the log saying what was wrong. A named
// validation error costs the same line count, says which field moved, and is
// answered 200 with that sentence in the body, because no retry will ever make
// the field appear.
//
// The envelope is separate from the session ON PURPOSE. Stripe delivers every
// event type this endpoint is subscribed to, and a single schema over the whole
// payload would reject `payment_intent.succeeded` and friends as malformed —
// filing "an event we do not care about" in the error log beside a payload
// that really is broken. So: parse the envelope, decide whether it is ours, and
// only then insist on a shape.

import { z } from "zod";

/** Just enough to route on. `object` stays unknown until the type is known. */
export const eventEnvelope = z.object({
  // The per-event idempotency key. `stripe_session_id` stops a second licence
  // and nothing more; this is what stops a second EMAIL for the same event.
  id: z.string(),
  type: z.string(),
  // Recorded on the licence, not enforced here. One signing key and one database
  // serve both Stripe modes, so a test purchase mints a key that really works —
  // which is what makes a rehearsal meaningful, and what makes it worth being
  // able to find those rows afterwards.
  livemode: z.boolean().default(true),
  data: z.object({ object: z.unknown() }),
});

/** A verified, routable event: what every handler in src/index.ts is given. */
export type StripeEvent = z.infer<typeof eventEnvelope>;

/**
 * The fields fulfilment actually reads. Everything is nullish because Stripe
 * omits rather than nulls, and because a missing currency should cost a default
 * rather than a licence.
 */
export const checkoutSession = z.object({
  id: z.string().min(1),
  /** How a later refund or dispute finds its way back to this licence. */
  payment_intent: z.string().nullish(),
  amount_total: z.number().int().nullish(),
  currency: z.string().nullish(),
  /**
   * Required, unlike its neighbours. Everything else here fails soft because
   * a missing currency should cost a default; a missing payment status would
   * cost a licence, since the only safe reading of "unknown" is "not paid" and
   * a session Stripe sends without one is not a shape this knows. The answer
   * says which field moved, and nothing is minted.
   */
  payment_status: z.string(),
  customer_details: z.object({ email: z.string().nullish() }).nullish(),
  /**
   * Copied onto the session from the Payment Link that created it, which is how
   * `price_id` arrives without a second API call. Loose on purpose: metadata is
   * free-form, a link created by hand may carry none, and a missing key is worth
   * a blank column rather than a refused fulfilment.
   */
  metadata: z.record(z.string(), z.string()).nullish(),
});

/**
 * The only unauthenticated body this Worker accepts.
 *
 * Bounded at 320 characters because that is the longest address RFC 5321 admits,
 * and because `includes("@")` would happily pass ten megabytes of it into a
 * query. The address is lowercased here so it matches how the webhook stored it.
 */
export const resendRequest = z.object({
  // Trim and lowercase BEFORE validating, not after. `z.email()` runs against
  // the raw value, so a transform hung on the end would reject exactly the input
  // this is meant to accept — an address pasted out of a mail client with a
  // trailing space. Piping puts the normalisation first, where it belongs.
  email: z.string().trim().toLowerCase().max(320).pipe(z.email()),
});

/**
 * A charge, as `charge.refunded` delivers it.
 *
 * `amount_refunded` matters as much as the event name: Stripe fires
 * `charge.refunded` for a PARTIAL refund too, and handing back part of the price
 * is a goodwill gesture, not a revocation.
 */
export const charge = z.object({
  id: z.string().min(1),
  payment_intent: z.string().nullish(),
  amount: z.number().int().nullish(),
  amount_refunded: z.number().int().nullish(),
});

/** A dispute, as `charge.dispute.created` and `.closed` deliver it. */
export const dispute = z.object({
  id: z.string().min(1),
  payment_intent: z.string().nullish(),
  /** `won`, `lost`, `warning_closed`, … Only `won` restores a licence. */
  status: z.string().nullish(),
});

export type Charge = z.infer<typeof charge>;

/**
 * Was the whole thing given back?
 *
 * A pure function because the partial-refund case is the one that would quietly
 * revoke a paying customer, and that deserves a test rather than a code read.
 */
export const isFullyRefunded = (paid: Charge): boolean => {
  const total = paid.amount ?? 0;
  return total > 0 && (paid.amount_refunded ?? 0) >= total;
};
