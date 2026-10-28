// `env` as the worker tests see it: the Worker's own, plus the migrations the
// config hands in for `setup.ts` to apply. `Cloudflare.Env` is the interface the
// generated worker-configuration.d.ts already extends, so this merges into it.
declare namespace Cloudflare {
  interface Env {
    TEST_MIGRATIONS: import("@cloudflare/vitest-pool-workers").D1Migration[];
  }
}
