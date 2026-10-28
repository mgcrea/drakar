// Tests for when `make revocations` reads each licence database.
//
// The test Worker signs with the production key, so that a test purchase
// proves the shipped app accepts it. That makes every key it mints a real one,
// and the generator revokes all of them, but only once the database exists,
// which is when wrangler.jsonc gains its id. Before that there is nothing to
// read, and reading anyway would fail every run.
//
// DIVERGES from armada, whose assertions run against the wrangler.jsonc the
// Worker deploys from: Drakar's two databases have no ids until Phase 2 creates
// them, and apps/api may not be here at all yet. So they run against a fixture
// shaped like that file, and the committed file, once there is one, is checked
// to have the same two bindings, so the fixture cannot drift from it unnoticed.

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { databaseConfigured, testDatabaseConfigured } from "./revocations.mjs";

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const committedPath = join(root, "apps/api/wrangler.jsonc");

const FIXTURE = `{
  "name": "drakar-api",
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "drakar-licenses",
      // Created in Phase 2 with \`wrangler d1 create drakar-licenses\`.
      "migrations_dir": "./migrations"
    }
  ],
  "env": {
    "test": {
      "d1_databases": [
        {
          "binding": "DB",
          "database_name": "drakar-licenses-test",
          "migrations_dir": "./migrations"
        }
      ]
    }
  }
}
`;

/** `wrangler` with `id` written into the binding for `name`. */
const withId = (wrangler, name, id = "00000000-0000-0000-0000-000000000000") => {
  const next = wrangler.replace(
    new RegExp(`("database_name":\\s*"${name}",)`),
    `$1\n          "database_id": "${id}",`,
  );
  assert.notEqual(next, wrangler, `no ${name} binding to give an id`);
  return next;
};

describe("testDatabaseConfigured", () => {
  it("is false while the test database has no id", () => {
    assert.equal(testDatabaseConfigured(FIXTURE), false);
  });

  it("is true once the test database's binding carries an id", () => {
    assert.equal(testDatabaseConfigured(withId(FIXTURE, "drakar-licenses-test")), true);
  });

  it("is not fooled by the production database's id", () => {
    assert.equal(testDatabaseConfigured(withId(FIXTURE, "drakar-licenses")), false);
  });

  it("is not fooled by an empty id", () => {
    assert.equal(testDatabaseConfigured(withId(FIXTURE, "drakar-licenses-test", "")), false);
  });
});

describe("databaseConfigured for production", () => {
  it("is false while the production database has no id", () => {
    assert.equal(databaseConfigured(FIXTURE, "drakar-licenses"), false);
  });

  it("is true once its binding carries an id", () => {
    assert.equal(databaseConfigured(withId(FIXTURE, "drakar-licenses"), "drakar-licenses"), true);
  });

  it("is not fooled by the test database's id", () => {
    const configured = withId(FIXTURE, "drakar-licenses-test");
    assert.equal(databaseConfigured(configured, "drakar-licenses"), false);
  });

  it("is false when there is no wrangler.jsonc to read", () => {
    assert.equal(databaseConfigured("", "drakar-licenses"), false);
  });
});

describe("the committed wrangler.jsonc", () => {
  const skip = !existsSync(committedPath) && "no apps/api/wrangler.jsonc yet";

  it("binds both databases by the names the generator reads", { skip }, () => {
    const committed = readFileSync(committedPath, "utf8");
    for (const name of ["drakar-licenses", "drakar-licenses-test"]) {
      const configured = databaseConfigured(committed, name) ? committed : withId(committed, name);
      assert.equal(databaseConfigured(configured, name), true, `${name} is not bound`);
    }
  });
});
