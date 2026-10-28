// Tests for the row a hand-minted licence leaves in D1.
//
// Run against the Worker's own migrations in an in-memory SQLite, so a column
// added there that this forgets fails here rather than on the remote database.
//
// DIVERGES from armada: skipped while there is no apps/api/migrations to run them
// against. Drakar's Worker arrives after this file does; once its migrations are
// here, every case runs.

import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { describe, it } from "node:test";

import { recordSQL } from "./license-record.mjs";

const MIGRATIONS = join(import.meta.dirname, "../../apps/api/migrations");

const database = () => {
  const db = new DatabaseSync(":memory:");
  for (const name of readdirSync(MIGRATIONS)
    .filter((n) => n.endsWith(".sql"))
    .toSorted()) {
    db.exec(readFileSync(join(MIGRATIONS, name), "utf8"));
  }
  return db;
};

const licence = {
  id: "01K7ZZZZZZZZZZZZZZZZZZZZZZ",
  email: "o'brien@example.com",
  major: 1,
  key: "drk1.payload.signature",
  issuedAt: "2026-10-18T09:00:00.000Z",
};

// What generate-revocations.mjs reads.
const revokedIds = (db) =>
  db
    .prepare("SELECT id FROM licenses WHERE revoked_at IS NOT NULL ORDER BY id")
    .all()
    .map((r) => r.id);

const skip = !existsSync(MIGRATIONS) && "no apps/api/migrations yet";

describe("recordSQL", { skip }, () => {
  it("records a comp under a session no checkout can match", () => {
    const db = database();
    db.exec(recordSQL(licence));
    const row = db.prepare("SELECT * FROM licenses").get();
    assert.equal(row.id, licence.id);
    assert.equal(row.email, licence.email, "a quote in the address survives");
    assert.equal(row.stripe_session_id, `manual:${licence.id}`);
    assert.equal(row.payment_intent, "");
    assert.equal(row.revoked_at, null);
  });

  it("records a replayed sale so its refund revokes it", () => {
    const db = database();
    db.exec(recordSQL({ ...licence, sessionId: "cs_test_a1", paymentIntent: "pi_123" }));
    // What the Worker's revoke() does on a full refund.
    db.prepare(
      "UPDATE licenses SET revoked_at = ?, revoked_reason = 'refunded' WHERE payment_intent = ?",
    ).run("2026-10-19T00:00:00.000Z", "pi_123");
    assert.deepEqual(revokedIds(db), [licence.id]);
  });

  it("records it already revoked when the refund came first", () => {
    const db = database();
    db.prepare(
      "INSERT INTO early_revocations (payment_intent, reason, revoked_at) VALUES (?, ?, ?)",
    ).run("pi_123", "refunded", "2026-10-17T00:00:00.000Z");
    db.exec(recordSQL({ ...licence, sessionId: "cs_test_a1", paymentIntent: "pi_123" }));
    const row = db.prepare("SELECT revoked_at, revoked_reason FROM licenses").get();
    assert.equal(row.revoked_at, "2026-10-17T00:00:00.000Z");
    assert.equal(row.revoked_reason, "refunded");
  });

  it("refuses a second key for a session that already has one", () => {
    const db = database();
    db.exec(recordSQL({ ...licence, sessionId: "cs_test_a1" }));
    assert.throws(() =>
      db.exec(recordSQL({ ...licence, id: "01K7YYYYYYYYYYYYYYYYYYYYYY", sessionId: "cs_test_a1" })),
    );
  });
});

// Needs no database, so it runs whether or not the migrations are here.
describe("recordSQL's input checks", () => {
  it("refuses an id, session or payment intent that is not the shape it claims", () => {
    assert.throws(() => recordSQL({ ...licence, sessionId: "cs_x'; DROP TABLE licenses; --" }));
    assert.throws(() => recordSQL({ ...licence, paymentIntent: "ch_123" }));
    assert.throws(() => recordSQL({ ...licence, id: "not a ulid" }));
  });
});
