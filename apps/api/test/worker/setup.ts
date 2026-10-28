// Runs before every worker test file, inside workerd.
//
// The schema comes from the same migrations `wrangler d1 migrations apply` runs
// in production, so a column the handlers read but no migration created fails
// here rather than on the first sale.
import { applyD1Migrations, env } from "cloudflare:test";

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
