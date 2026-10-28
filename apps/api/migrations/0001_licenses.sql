-- Three tables. They are the whole of what this project knows about anyone.
--
-- Stripe already records who paid, how much and what tax; duplicating that here
-- would mean two systems of record disagreeing eventually. What Stripe does NOT
-- know is which key was issued, and that is the only reason this exists.
--
-- `key` is stored rather than re-derived from the payment on demand. Derivation
-- looks elegant until the payload format changes once, and then no old key can
-- be reproduced and every re-send is subtly wrong.
--
-- `price_id` and `amount_paid` are recorded from the very first sale because the
-- price ladder rises: offering fair upgrade pricing at 2.0 is impossible without
-- knowing what people actually paid, and that number cannot be reconstructed
-- after the fact.
--
-- DIVERGES from armada: one migration, not the four armada's schema arrived in
-- (0001_licenses, 0002_revocation_reason_and_events, 0003_early_revocations,
-- 0004_event_handled_at). Theirs were ALTERs against a database that already
-- held real sales; this one is created fresh, so replaying that history would be
-- inheriting somebody else's accidents. The tables, columns, column order and
-- indexes are the ones armada's four produce together, and 0004's backfill
-- (`handled_at = received_at` for rows from before the column) is dropped,
-- because a fresh table has no such rows. The reasons each later migration gave
-- are kept beside the columns they added.

CREATE TABLE licenses (
  id                TEXT    PRIMARY KEY,
  email             TEXT    NOT NULL,
  major             INTEGER NOT NULL,
  key               TEXT    NOT NULL,
  -- The idempotency key. Stripe redelivers a webhook for days, and a second
  -- delivery must not mean a second licence.
  stripe_session_id TEXT    NOT NULL UNIQUE,
  -- How a refund or a dispute finds its way back to the licence. A charge knows
  -- its payment intent, never the checkout session that created it, so without
  -- this the only route back would be a Stripe API call on the one path that
  -- most needs to keep working when the network does not.
  payment_intent    TEXT    NOT NULL DEFAULT '',
  price_id          TEXT    NOT NULL DEFAULT '',
  amount_paid       INTEGER NOT NULL,
  currency          TEXT    NOT NULL,
  issued_at         TEXT    NOT NULL,
  -- Which Stripe mode minted it. The Worker signs with the real key whatever
  -- mode the event came from, because there is one signing key and one database
  -- — so a test purchase produces a licence that genuinely unlocks the shipped
  -- app. That is what makes a rehearsal meaningful, and a hole if it goes
  -- unrecorded: recorded, those keys can be found and revoked afterwards.
  livemode          INTEGER NOT NULL DEFAULT 1,
  -- Set on refund or chargeback. Read by `make revocations`, which bakes the
  -- list into the next build — revocation lands at build time, never at run
  -- time, because the app does not ask anyone about its licence.
  revoked_at        TEXT,
  -- Rate-limits the resend route without needing a second table.
  last_sent_at      TEXT,
  -- `refunded` or `disputed`, the first reason kept. Last rather than beside
  -- `revoked_at` because that is where armada's ALTER put it, and the column
  -- order is part of what this file reproduces.
  --
  -- It exists because `charge.dispute.closed` with status `won` once un-revoked
  -- a licence unconditionally. A licence revoked by a REFUND, whose charge was
  -- later also disputed and won, was silently restored — and the next `make
  -- revocations` then dropped it from the baked-in list, handing the key back
  -- to someone who had already been paid back. Restoring requires that the
  -- dispute is what took it away.
  revoked_reason    TEXT
);

CREATE INDEX licenses_email ON licenses (email);
CREATE INDEX licenses_payment_intent ON licenses (payment_intent);
CREATE INDEX licenses_livemode ON licenses (livemode) WHERE livemode = 0;

-- One row per Stripe event, claimed before the event is handled.
--
-- `licenses.stripe_session_id` stops a second LICENCE and nothing else. Past the
-- five-minute send cooldown, any redelivery or manual re-send from the dashboard
-- would mail the key again. A delivery claims its event by inserting a row here,
-- and a handler that fails gives the claim back, so a 500 still leaves Stripe
-- free to retry, which is the behaviour fulfilment depends on.
CREATE TABLE stripe_events (
  id          TEXT PRIMARY KEY,
  type        TEXT NOT NULL,
  received_at TEXT NOT NULL,
  -- When the event was actually handled, beside when it was claimed. What could
  -- never be given back is the claim of a Worker that died between the insert
  -- and its answer: Stripe retried, found the row, and was told "duplicate" for
  -- the rest of its retry window, so a payment could end with no licence. A
  -- claim with no `handled_at` that is more than five minutes old was
  -- abandoned, and the next delivery may take it over.
  handled_at  TEXT
);

-- A refund or a dispute that arrives before the licence it revokes.
--
-- Fulfilment answers 500 until the key is mailed, and Stripe retries it for
-- days. A buyer refunded inside that window sent a `charge.refunded` that
-- matched no row: `revoke` changed nothing, answered 200, and the event was
-- recorded as handled. The fulfilment retry then minted and mailed a licence
-- for money already returned, and nothing ever revoked it.
--
-- So a revocation that finds no licence is written down here, by payment
-- intent, and fulfilment checks it: the licence is still recorded, so a won
-- dispute can restore it and the resend route can deliver it then, but it is
-- recorded revoked and not mailed.
--
-- Rows from the other apps' charges land here too, since every app sells
-- through one Stripe account and every Worker hears every refund. They are
-- rare, small and never read except by a payment intent this Worker sold, so
-- they are left alone.
CREATE TABLE early_revocations (
  payment_intent TEXT PRIMARY KEY,
  reason         TEXT NOT NULL,
  revoked_at     TEXT NOT NULL
);
