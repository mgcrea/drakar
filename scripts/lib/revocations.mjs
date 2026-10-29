// What `generate-revocations.mjs` reads besides the production database.
//
// Dependency-free, like everything else under scripts/lib.

/**
 * Whether apps/api/wrangler.jsonc gives the D1 database named `name` an id, which
 * is the point at which it exists and has licences to read.
 *
 * Read from the raw text rather than parsed: the file is JSONC, and the binding is
 * a flat object with no braces inside it, comments included.
 *
 * DIVERGES from armada, which asks this of its test database alone: Drakar's
 * production database had no id either until it was created on 2026-10-29, and the
 * generator asks the same question of both.
 */
export function databaseConfigured(wrangler, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const binding = new RegExp(`\\{[^{}]*"database_name"\\s*:\\s*"${escaped}"[^{}]*\\}`).exec(
    wrangler,
  );
  return binding !== null && /"database_id"\s*:\s*"[^"]+"/.test(binding[0]);
}

/**
 * Whether the test environment's database exists.
 *
 * The test Worker signs with the production key, so a test purchase proves
 * the shipped app accepts it, and every key it mints is a real one. The
 * generator revokes all of them, so none outlives the next build.
 */
export function testDatabaseConfigured(wrangler) {
  return databaseConfigured(wrangler, "drakar-licenses-test");
}
