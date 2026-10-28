// The row a licence minted by hand leaves in D1.
//
// Dependency-free, like everything else under scripts/lib.
//
// **Without it, a hand-minted key can never be revoked.** `make revocations`
// reads revoked rows from D1 and nothing else, and a refund finds its licence by
// payment intent in the same table, so a key that never had a row stays valid
// in every build, refunded or not. The Worker's comments send a refused or
// replayed sale here to be minted by hand, which is exactly the key a refund
// then most needs to reach.

const ULID = /^[0-9A-HJKMNP-TV-Z]{26}$/;
// A real Checkout Session id, or the `manual:` one a comp is filed under, which
// `findBySession` can never be asked for.
const SESSION = /^(cs_(test|live)_[A-Za-z0-9]+|manual:[0-9A-HJKMNP-TV-Z]{26})$/;
const PAYMENT_INTENT = /^pi_[A-Za-z0-9]+$/;

// A SQL string literal. `wrangler d1 execute --command` takes text, not bound
// parameters; every value is either checked against a pattern above or quoted here.
const text = (value) => `'${String(value).replaceAll("'", "''")}'`;

/**
 * The statements that record a minted licence, as one string for
 * `wrangler d1 execute --command`.
 *
 * A comp or replacement is filed under `manual:<id>` with no payment intent, so no
 * refund can reach it; revoke one with an UPDATE on its id. A replayed sale gives
 * its real session and payment intent, so its refund revokes it as the Worker's
 * own would. And when that refund arrived before the key did, it is waiting in
 * `early_revocations`, which only the Worker's fulfil reads: the second statement
 * applies it, as fulfil does.
 */
export const recordSQL = ({
  id,
  email,
  major,
  key,
  issuedAt,
  sessionId = `manual:${id}`,
  paymentIntent = "",
  amountPaid = 0,
  currency = "",
  livemode = 1,
}) => {
  if (!ULID.test(id)) throw new Error(`not a licence id: ${id}`);
  if (!SESSION.test(sessionId)) throw new Error(`not a checkout session id: ${sessionId}`);
  if (paymentIntent && !PAYMENT_INTENT.test(paymentIntent)) {
    throw new Error(`not a payment intent id: ${paymentIntent}`);
  }
  if (!Number.isInteger(major) || !Number.isInteger(amountPaid)) {
    throw new Error("major and amountPaid are whole numbers");
  }
  const insert =
    "INSERT INTO licenses (id, email, major, key, stripe_session_id, payment_intent, " +
    "amount_paid, currency, issued_at, livemode) VALUES (" +
    [
      text(id),
      text(email),
      major,
      text(key),
      text(sessionId),
      text(paymentIntent),
      amountPaid,
      text(currency),
      text(issuedAt),
      livemode ? 1 : 0,
    ].join(", ") +
    ");";
  if (!paymentIntent) return insert;
  const early = `FROM early_revocations WHERE payment_intent = ${text(paymentIntent)}`;
  return (
    `${insert} UPDATE licenses SET revoked_at = (SELECT revoked_at ${early}), ` +
    `revoked_reason = (SELECT reason ${early}) ` +
    `WHERE id = ${text(id)} AND revoked_at IS NULL AND EXISTS (SELECT 1 ${early});`
  );
};
