// Two projects, because the two halves of the suite need different runtimes.
//
// `test/*.test.ts` runs in Node: the licence test imports the Node minter from
// scripts/lib and asserts the Worker produces the same bytes, which is only a
// meaningful claim if the Node side really runs in Node. `test/worker/` runs
// inside workerd through @cloudflare/vitest-pool-workers, with a real D1 and the
// bindings from wrangler.jsonc, because the handlers in src/index.ts are the
// code that decides whether a paying customer gets a key.
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => ({
  test: {
    projects: [
      { test: { name: "node", include: ["test/*.test.ts"] } },
      {
        plugins: [
          cloudflareTest({
            wrangler: { configPath: "./wrangler.jsonc" },
            miniflare: {
              bindings: {
                TEST_MIGRATIONS: await readD1Migrations("./migrations"),
                // Not a real secret and never a real key: `index.test.ts` mints
                // a keypair per run and puts the private half on `env`.
                STRIPE_WEBHOOK_SECRET: "whsec_test",
                LICENSE_SIGNING_KEY: "",
                // The product guard, pinned to the price the fixtures pay.
                // wrangler.jsonc carries Drakar's live price id (empty until one
                // exists, which closes the Worker), and inheriting it would tie
                // every fulfilment test to a value that changes whenever the
                // price does. Set here rather than per test so the
                // whole suite runs with the guard ON, and a session at another
                // price, or no price, is the exception a test states explicitly.
                EXPECTED_PRICE_ID: "price_test",
              },
            },
          }),
        ],
        test: {
          name: "worker",
          include: ["test/worker/*.test.ts"],
          setupFiles: ["./test/worker/setup.ts"],
        },
      },
    ],
  },
}));
