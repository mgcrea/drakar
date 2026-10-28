// The `Env` interface is NOT here. `wrangler types` derives it from the bindings
// and vars in wrangler.jsonc — and from the key names in .dev.vars for the
// secrets — into worker-configuration.d.ts, where it is ambient and needs no
// import. Hand-maintaining it meant a second place to forget a binding.
//
// The secret NAMES come from a vars file, and a bare `wrangler types` reads the
// gitignored .dev.vars: on a machine without one it silently drops them from
// `Env`, and typecheck then fails on every `env.LICENSE_SIGNING_KEY`. So `pnpm
// types` passes `--env-file=.dev.vars.example`, which names the same secrets and
// is committed, and CI runs `wrangler types --check` against that same file, so
// the committed worker-configuration.d.ts cannot drift from wrangler.jsonc.

export interface LicenseRow {
  id: string;
  email: string;
  key: string;
  issued_at: string;
  last_sent_at: string | null;
  revoked_at: string | null;
  revoked_reason: string | null;
}
