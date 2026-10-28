# Direct distribution

Drakar ships the way armada, bastion and cupertino do: open source under MIT on a public
GitHub repo, signed with the Developer ID, notarized, updated by Sparkle, and sold as a
one-time licence with a 30-minute trial, minted by a Stripe webhook Worker. PLAN.md §5
decided "direct, never the Mac App Store"; this is how.

The fleet's shared rules are `fleet-direct-conventions` (in `~/Projects/claude-skills`),
and **armada is the model** wherever the three differ (PLAN.md §5 already names its
Worker). This document records only what Drakar decides on top of that, and where it
departs from armada.

## Decided

- **Open source, MIT, `github.com/mgcrea/drakar`, public.** Decided by the owner on
  2026-10-28, matching the trio. The GitLab repo stops being `origin`. Anyone can build
  Drakar without paying, as with the other three; the licence check is a few lines in
  the source, and `LicenseKey`'s comment says why that is accepted.
- **The same 30-minute in-memory trial** as the trio, started from a button, ended by
  quitting. Decided by the owner.
- **$14.99, one-time**, Armada's price. Decided by the owner on 2026-10-28 (PLAN.md §7.5).
- **Armada's pipeline, copied**: root-Makefile release targets, a GitHub Actions
  `release-app` job on `app-v*` tags, a one-item appcast, `/appcast.xml` and `/download`
  as 302s to `releases/latest/download`, a zip (no DMG, no Homebrew).

## Goals

1. A tag `app-v1.0.0` produces a signed, notarized, stapled `Drakar.zip`, its checksum and
   a signed appcast on a GitHub release, with provenance attested, and no step done by hand.
2. An installed Drakar finds and installs the next release through Sparkle, only after the
   person said yes to update checks.
3. Drakar can be sold: a key minted on payment, checked offline, revoked on refund at the
   next release.
4. `make audit` keeps PLAN.md §5's checkable claim true, now with Sparkle as its one named
   allowance, and CI runs it on the release artifact.

## Non-goals

- **The marketing site.** `apps/website` here is the skeleton the release path needs:
  the redirects, one plain landing page, privacy, and the pages the Worker links to. A real
  marketing site (armada's has twenty components) is its own project.
- **A capture pipeline (`DemoSeed`).** None exists; when one does, armada's shape applies
  (whole `#if DEBUG`, no demo branch in `LicenseStore`).
- **Homebrew.** Cupertino only, and cupertino needed it for a reason Drakar does not have.
- **Fixing the trio's open drift** (`fleet-direct-conventions` SKILL.md, "Must agree").
  Drakar copies armada's side of each and does not touch the other repos.

## Anti-goals

- **A Drakar that loses someone's work at trial end.** A running turn is never killed.
- **A shipped binary that asks the network anything Drakar did not ask for.** No licence
  call, no revocation fetch, no update check before consent.
- **A refused Drakar with nothing to buy.** While the store is closed nothing is gated
  (below).
- **Anything outward-facing done without the owner's go**: the public push, keys, secrets,
  Cloudflare, Stripe, the first tag.

## The parts

### 1. Release inputs

`CHANGELOG.md` → `Changelog.swift` → a What's New sheet, with the trio's `scripts/lib/changelog.mjs`
(its `HIDDEN_SECTIONS` keeps `### Internal` out of every renderer), `changelog-notes.mjs`,
`generate-changelog.mjs`, and a `changelog-check` gate. Copied from armada; the site's
release cards are left out with the marketing site.

`scripts/verify-update-signature.mjs`, `scripts/lib/update-signature.mjs` and its test are
copied **byte-identical** (the trio keep them that way; `direct.sh` compares hashes).

### 2. Sparkle and the Updates pane

Sparkle 2.9.6 with the trio's `SPARKLE_SHA256`, staged into `apps/apple/Vendor/` with
armada's stamp and tools layout. `Info.plist` gets `SUFeedURL`
(`https://drakar.mgcrea.io/appcast.xml`), `SUPublicEDKey`, and the three update defaults
present and false.

**Drakar's own EdDSA key** (`generate_keys --account drakar`), not the trio's shared one.
PLAN.md §7.4 recommends it and leaves it to the owner. With no copies installed yet, a
separate key costs nothing now, while rotating one later would take two releases. Every
`sign_update` and `generate_keys` call in the Makefile passes `--account drakar`; this is
the first Makefile in the fleet to do so.

An `Updates` pane in Settings (`SettingsPane.updates`), armada's `Updates.swift`:
`UpdateController` stays `nil` until `startIfConsented()`, and
`updater(_:didFinishUpdateCycleFor:error:)` clears "Checking…".

**Drakar-specific: a Sparkle update while sessions run.** The session host
(`docs/session-host.md`) already survives a bundle replacement: the old host keeps running
from its open inode and the new app attaches. Installing an update should therefore defer
to Sparkle's normal "install on quit" path. It must never quit the app on its own while a
turn is running. The plan verifies this against `docs/session-host.md` rather than assuming it.

### 3. Signing, notarization, the appcast

Armada's root-Makefile targets: `bundle`, `sign`, `notarize`, `build-release` (sequential
sub-makes), `appcast`, `checksum`, `install-release`, `sparkle-keys` (refuses when the
keychain key is not the shipped `SUPublicEDKey`), `sparkle-key-shred`, `audit-release`.

`sign` goes inside out without `--deep`. Drakar's order: Sparkle's `Updater.app` →
`Autoupdate` → `Sparkle.framework` → **`Contents/Helpers/DrakarHost`** → the app. Sparkle's
team is asserted after.
No entitlements file (Bastion's precedent, PLAN.md §5), and the audit asserts its absence.

The appcast has every guard in the reference's table: a single 86-character signature,
verified against the built app's key, `xmllint` fatal, the length measured off the zip, and
notes chosen by version.

### 4. The release job

`.github/workflows/ci.yml` from armada's: tests on every push (`make test`, which here is
the DrakarKit suite, the scripts' tests and the Worker's), `format-swift-check`, `make
audit`, `changelog-check`; a `revocations` job (`environment: production`); `release-app`
on `app-v*` (plain `x.y.z` only, macOS 26 SDK asserted, throwaway keychain dropped right
after notarizing, `make audit-release` on the artifact, attestation over zip and
appcast, body from the tag's CHANGELOG section); `api-deploy` and `site-deploy` from
`main`. Every third-party action pinned to a SHA. Secrets named as in the trio.

`docs/releasing.md` and a `.claude/skills/cut-a-release` skill, armada's, with the push
order settled the way `docs/releasing.md` argues (tag before `main`), which armada's own
skill still gets wrong.

### 5. Licence and trial

Armada's `License.swift`, `LicenseStore.swift`, `Trial.swift`, `LicensePane.swift`,
`Revocations.swift`, with prefix **`drk1`** and Drakar's own Ed25519 licence keypair. The
private half lives only in the Worker's secrets and a local `.prod.vars`. A `Licence` pane
in Settings. `scripts/mint-license.mjs`, `verify-license.mjs`, `license-check` (a minted key
verified by the Swift verifier), `generate-revocations.mjs` with `--check`.

**Where the gate goes is Drakar's own decision**, because armada gates by stopping its
watchers and Drakar has no watchers to stop. An `EntitlementMonitor` (armada's name) holds
`Entitlement.current`. Refused means:

- **Reading stays free**: Home, projects, past sessions' transcripts, diffs, the skills
  and MCP inspectors, Settings.
- **Sending work to an agent is gated**: `AgentSession.send`, `Project.newSession`, fan-out
  (`FanOutDraft.start`), and a resume that sends a prompt. The composer shows a card with
  "Start 30-minute trial", "Enter licence" and "Buy" instead of the text field.
- **The IDE bridge's listener is off**, as armada's MCP server is.

**When the trial ends mid-turn**, the running turn finishes. Its permission prompts,
questions and elicitations can still be answered, and Stop still works. Only the next
prompt is refused. Sessions in the host are never terminated by the gate. Those sessions
were started while Drakar was entitled, and the host only runs what the app sent.

**While the store is closed, nothing is gated.** `LicenceLinks.isSelling` is false until the
owner sets a price. While it is false, the monitor answers entitled, the Licence pane says
Drakar is free during the beta, and no Buy button exists. Turning the gate on is the
release that flips `isSelling`. This departs from the trio, which only shipped once they
were already selling.

### 6. The licence Worker

`apps/api` copied from armada's: the `stripe_events` claim with takeover,
`early_revocations`, revocation on refund and lost dispute (an inquiry leaves the licence
alone), the resend route, `/thanks` and the revoked page, `no_payment_required` and the
async pair fulfilled. It keeps armada's **fail-closed** price guard, as PLAN.md §5 already
says. Migrations squashed into one `0001` for a fresh database, and
`drakar-licenses` and `drakar-licenses-test` D1, with `"routes": []` on `env.test`. The
shared Stripe account means this Worker receives the trio's checkouts too, which is why
the guard fails closed.

### 7. The site skeleton

`apps/website` from armada's Astro setup, cut to: one landing page (what Drakar is, the
download button, a GitHub link), `/privacy`, the `_redirects` file (`/appcast.xml`,
`/download`, `/checksum`, `/releases`, and `/buy` only once a payment link exists),
deployed to `drakar.mgcrea.io` through `fleet-ship-conventions`' path. `Support.swift`'s
URLs then resolve; `survey.sh drakar --net` before the first release (PLAN.md §7.6).

### 8. The checkable claim

`scripts/audit-network.sh` gains cupertino's binary sweep: `nm -u` and `otool -L` over every
Mach-O in the bundle, with Sparkle as the one named allowance, plus the no-entitlements
assertion. CI runs `make audit`; `release-app` runs `make audit-release` on the artifact.
PLAN.md §5's sentence stays as written.

### 9. Going public

Before the first push to GitHub:

- A secret scan over the **whole history** (gitleaks or equivalent), since 313+ commits
  were written for a private repo. Anything found is a stop, not a rewrite done quietly.
- A read of what becomes public: `docs/marketing/` competitive briefs, `.claude/`
  contents. The owner says what stays.
- `LICENSE` (MIT, as the trio), `SECURITY.md`, README's distribution line kept.

## Order

1. **In the repo, no outward effect**: parts 1, 2 (with a placeholder key until step 2),
   3, 4, 5, 6, 7 and 8, each its own commit series, tested locally. `make bundle` with the
   Apple Development fallback proves signing end to end before any secret exists.
2. **Going public, each step confirmed by the owner**: the history scan and read; create
   `mgcrea/drakar` and push; generate the Sparkle and licence keys; set the GitHub secrets;
   create the D1 databases, deploy the Worker and the site, point `drakar.mgcrea.io`.
3. **First release, free**: tag `app-v1.0.0` with `isSelling` false.
4. **Selling at $14.99**, when the owner says to open the store: Stripe product, price and payment link with
   `price_id` metadata, webhook endpoint with all six events, `EXPECTED_PRICE_ID`, `/buy`,
   `isSelling` true, a release.

## Still the owner's

- **When the store opens** (step 4), after the free first release.
- **What in `docs/marketing/` and `.claude/` goes public**, at step 2.
- **GitLab afterwards**: kept as a mirror, archived, or deleted.

## Left to the builder

The commit boundaries; how much of armada's `LicensePane` copy changes for a windowed app;
where in each window the composer's locked card sits; whether `Project.newSession` or a
single choke point beneath it is the cleaner gate (one place is better than four, as long
as the four entry points are covered by tests).
