# Releasing

How a Drakar release is cut. Drakar ships Developer ID signed and notarized, as a GitHub release
with a Sparkle appcast beside it. It is not an App Store app and has no store listing. It is
built to be sold with an offline licence key, but nothing is on sale until the owner opens the
store (`LicenceLinks.isSelling` is false): the first release is free.

This is armada's runbook, copied on 2026-10-29, and armada's own is the model wherever the two
read alike. Where Drakar differs it says so.

There is no bump or release script. A release is **one commit, one signed `app-v<version>` tag,
and the `release-app` job in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)**, which
builds, signs, notarizes, verifies, writes the appcast and publishes. `make build-release` on a
laptop is a rehearsal, never how a release ships. The companion that walks through it is the
`cut-a-release` skill in `.claude/skills/`.

Several of the steps below are invisible to CI, so a release that skips them can still go out
green.

## Once, before the first release

This is the one checklist for going public (Phase 2), the first release (Phase 3) and opening
the store (Phase 4). The plan's Phase 2–4 sections and the `cut-a-release` skill point here
rather than repeating it. Every step is the owner's go, and **the order is part of it**: do a
step only once every step above it is done.

### Phase 2: going public

1. **Scan the whole history for secrets.** `brew install gitleaks` (ask first), then
   `gitleaks git --log-opts="--all" -v`. The history was written for a private repository; any
   finding stops this phase, and is not rewritten away quietly.
2. **The owner reads what becomes public.** `git ls-files docs/marketing .claude`, and the
   owner says what stays. A removal is a normal commit; a history rewrite only if the owner asks
   for one.
3. **Create `mgcrea/drakar`, public**, set it as `origin` (GitLab kept, archived or deleted as
   the owner decides) and push `main`. CI runs; with no secrets yet the deploys warn and deploy
   nothing, `revocations` skips, and the licence round trip skips.
4. **The two environments.** `release` admits only `app-v*` tags: `release-app` runs there, so
   a workflow edited on a branch or a pull request cannot read the signing secrets. `production`
   admits `main` **and `app-v*` tags**: the deploys run there from `main`, and so does the
   `revocations` job on a release tag, which `release-app` needs. A `production` limited to
   `main` stops every release at `revocations`. In Settings › Environments, "Selected branches
   and tags", or:

   ```bash
   for env in release production; do
     gh api -X PUT repos/mgcrea/drakar/environments/$env --input - <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
   done
   gh api repos/mgcrea/drakar/environments/release/deployment-branch-policies -f name='app-v*' -f type=tag
   gh api repos/mgcrea/drakar/environments/production/deployment-branch-policies -f name='app-v*' -f type=tag
   gh api repos/mgcrea/drakar/environments/production/deployment-branch-policies -f name=main -f type=branch
   ```

5. **The real keys, in one commit.** Drakar has **its own EdDSA key**, under the keychain
   account `drakar`, not the one armada, bastion and cupertino share: every `generate_keys` and
   `sign_update` call in the Makefile passes `--account drakar`. A leak of the shared key cannot
   update Drakar, and a leak of Drakar's cannot update the others.
   - `apps/apple/Vendor/bin/generate_keys --account drakar` prints the Sparkle public key.
   - `node scripts/mint-license.mjs --keygen` prints the licence pair. The private half goes in
     `.env` (`LICENSE_SIGNING_KEY`), in `apps/api/.prod.vars` and in the owner's password
     manager, never in git. Losing it means no key can be issued for 1.x again.

   Until this commit both public keys are the literal `PLACEHOLDER-SET-IN-PHASE-2`, and
   `make sign` refuses a bundle carrying either, before it signs anything: a tag pushed before
   then fails in **Build, sign and notarize**. The commit changes every one of these:

   | Where                                                                 | What                                                                                                                             |
   | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
   | `apps/apple/Drakar-Info.plist`                                        | `SUPublicEDKey` becomes the Sparkle public key                                                                                   |
   | `apps/apple/Drakar/Licence/License.swift`                             | `publicKey` becomes the licence public key; the declaration stays on one line, since `make sign` reads it                        |
   | `scripts/lib/license.mjs`                                             | `PUBLIC_KEY` becomes the same licence key (a script test compares it with License.swift's). `PLACEHOLDER_KEY` stays: `license-check.mjs` and `verify-license.mjs` compare against it |
   | `DrakarTests/LicenseKeyTests.swift`                                   | delete `publicKeyIsPlaceholderUntilPhase2`                                                                                       |
   | `DrakarTests/UpdatesTests.swift`                                      | rewrite or drop `anUpdaterThatWillNotStartStaysNil`: it runs only while the plist carries the placeholder, which made the refusal real |
   | `DrakarTests/UpdatesTests.swift`                                      | `infoPlistDefaultsArePresentAndFalse` asserts the real key's shape (44 characters of base64, as `PUBLIC_KEY_PATTERN` in `scripts/lib/update-signature.mjs` has it) |
   | `package.json`                                                        | drop the `--test-skip-pattern` from `test:scripts`; the comment above `test-scripts` in the Makefile says why it was there, and goes too |

   Then `git grep -n PLACEHOLDER-SET-IN-PHASE-2` should find only the Makefile's and
   license.mjs's `PLACEHOLDER_KEY`, which go on refusing the placeholder, a comment in
   `ci.yml`, and this runbook. `git grep -n "Phase 2"` finds the comments around each of
   these that say "until Phase 2"; rewrite each in the same commit. `make test-scripts`,
   `make -C apps/apple test-app` and `make license-check` (with `.env` filled in) pass.

6. **The signing secrets.** `release-app` reads seven:

   | Secret                      | What it is                                                                | Where                     |
   | --------------------------- | ------------------------------------------------------------------------- | ------------------------- |
   | `DEVELOPER_ID_P12_BASE64`   | the Developer ID Application certificate and its private key, as a `.p12` | `release` environment     |
   | `DEVELOPER_ID_P12_PASSWORD` | the password that `.p12` was exported with                                | `release` environment     |
   | `KEYCHAIN_PASSWORD`         | any password, for the throwaway keychain the job creates and deletes      | `release` environment     |
   | `AC_KEY_ID`                 | the App Store Connect API key notarytool submits with                     | `release` environment     |
   | `AC_KEY_P8_BASE64`          | that key's `.p8`                                                          | `release` environment     |
   | `SPARKLE_ED_PRIVATE_KEY`    | the EdDSA key the appcast is signed with                                  | `release` environment     |
   | `AC_ISSUER_ID`              | that key's issuer, a team identifier rather than a credential             | the repository            |

   Set the six with `gh secret set NAME -R mgcrea/drakar --env release`. `gh secret list -R
   mgcrea/drakar --env release` must show all six; without `--env release` it lists the
   repository's secrets only, and shows none of them.

   The two `DEVELOPER_ID_*` secrets and `SPARKLE_ED_PRIVATE_KEY` come out of the login keychain
   by hand: the App Store Connect API lists no Developer ID certificate, so nothing can fetch
   the `.p12` for you. For the Sparkle key, run `make sparkle-keys`. It asserts that the
   keychain's `drakar` key is the one whose public half is `SUPublicEDKey`, and only then
   prints the export and `gh secret set … --env release` commands. Run `make sparkle-key-shred`
   afterwards. The key is Drakar's alone, so it belongs in this one repository, never in an
   org-wide secret. `make appcast` checks the same thing again on every release, over the zip
   it signs.

   `LICENSE_SIGNING_KEY`, the licence private half, is a repository secret: it turns on the
   licence round trip in the `app` job, which skips with a warning without it.

7. **D1, and its id committed, before any Cloudflare token exists.** The moment
   `CLOUDFLARE_API_TOKEN` exists, every push to `main` runs `make api-deploy` and the site's
   deploy. So the database comes first:

   ```bash
   export CLOUDFLARE_ACCOUNT_ID=0121e8859874c6fc0d674676e17d9f18   # the Makefile's CF_ACCOUNT_ID
   pnpm -C apps/api exec wrangler d1 create drakar-licenses
   pnpm -C apps/api exec wrangler d1 create drakar-licenses-test
   ```

   Put each `database_id` it prints in `apps/api/wrangler.jsonc` (the production binding at the
   top, the test one under `env.test`), with the comments that say there is none yet, and
   commit and push that before the next step. A binding with no id can find the database by
   name and slip past the migrations check `api-deploy` makes. Then apply the schema:
   `pnpm -C apps/api migrate`.

8. **The Worker's secrets and the first deploy.** `apps/api/.prod.vars` holds
   `LICENSE_SIGNING_KEY` only: a secret meant to stay unset has no line at all, and
   `pnpm -C apps/api secrets:prod` refuses an empty one. `STRIPE_WEBHOOK_SECRET` comes in
   Phase 4. Push them with `pnpm -C apps/api secrets:prod`, then `make deploy`: the Worker
   (refusing on unapplied migrations, then curling `/health`), then the site. Their
   `wrangler.jsonc` routes attach `api.drakar.mgcrea.io` and `drakar.mgcrea.io` as custom
   domains. The Worker refuses every sale while `EXPECTED_PRICE_ID` is empty, which it is
   until Phase 4.

   **The site goes up now, before any release**, and from step 9 on CI redeploys it on every
   push to `main`. Its `/download`, `/checksum` and `/appcast.xml` 302 to a GitHub release that
   does not exist yet. The `X-Robots-Tag: noindex` in `apps/website/public/_headers` is what
   keeps it out of search results until then; it comes out in the first release commit
   (Phase 3), never before.

9. **Only now, `CLOUDFLARE_API_TOKEN`**, in the `production` environment:
   `gh secret set CLOUDFLARE_API_TOKEN -R mgcrea/drakar --env production`. The deploy jobs and
   the `revocations` job read it there; without it the deploys warn and deploy nothing, and
   `revocations` skips, **except on a release tag, where it fails**, and `release-app` needs
   it. So it has to exist before the first tag.
10. **Check from outside** that the links the app ships with resolve (PLAN.md §7.6):

    ```bash
    curl -fsS -o /dev/null -w '%{http_code}\n' https://drakar.mgcrea.io                  # 200
    curl -fsS https://api.drakar.mgcrea.io/health                                    # the Worker
    curl -sI https://drakar.mgcrea.io/appcast.xml | grep -i location                 # a 302 to the releases
    curl -fsS -o /dev/null -w '%{http_code}\n' https://github.com/mgcrea/support/tree/main/drakar   # the tracker
    ```

    `/download` and `/appcast.xml` lead to a GitHub 404 until Phase 3; that is expected.
    `survey.sh` in `fleet-direct-conventions` has no network mode, so these are checked by hand.

### Phase 3: the first release

The version is **1.0.0**. The licence key's `major` is 1 (`CURRENT_MAJOR` in
`apps/api/wrangler.jsonc`) and the app refuses a key for another major, so a first release
numbered 0.x would lock out every key ever sold for 1.x.

The first release commit, beyond what every release commit carries (below), also changes:

- `CHANGELOG.md`: `## [1.0.0] - Unreleased` is dated, and the intro's "none is tagged yet" is
  rewritten to name `app-v1.0.0` as the newest (step 2 below).
- `apps/website/public/_headers`: the `X-Robots-Tag: noindex` line and its comment come out.
  They kept the site out of search results while `/download` led to a GitHub 404. `/download`,
  `/checksum` and `/appcast.xml` start resolving the moment the release exists, because they are
  302s to `releases/latest/download`.

Then [every release](#every-release), tag first. The site's "Free while in beta" stays until the
store opens; so does `isSelling = false`.

### Phase 4: before the store opens

Only when the owner says to open the store.

1. **The owner confirms the refund terms.** The licence email (`apps/api/src/email.ts`) and the
   Worker's `/thanks` page (`apps/api/src/pages.ts`) promise armada's refund: within 30 days, in
   full, for any reason. Armada's EULA says so; Drakar has no terms page, so that sentence is the
   whole of the promise, and so is the trade the offline check makes (a refunded key keeps
   working until the next release). The owner confirms both, adds a terms page if wanted, and
   the email, `/thanks` and any terms say the same thing before the first sale.
2. **Stripe**, live and test: product "Drakar", price $14.99 one-time, a Payment Link with
   `price_id` metadata redirecting to the Worker's `/thanks`, and a webhook endpoint with all six
   events. Its signing secret goes in `apps/api/.prod.vars` as `STRIPE_WEBHOOK_SECRET`, then
   `pnpm -C apps/api secrets:prod`.
3. **`EXPECTED_PRICE_ID`** in `apps/api/wrangler.jsonc`, and the `/buy` 302 in
   `apps/website/public/_redirects`. Pushing `main` deploys both.
4. **`LicenceLinks.isSelling = true`**, the Licence pane's beta copy gone, and the site's "Free
   while in beta" replaced with the price, then a release.

## Every release

### 1. Read what changed

```bash
last=$(git describe --tags --match 'app-v*' --abbrev=0 2>/dev/null)
git log --oneline ${last:+$last..}HEAD
```

Read the diffs, not the subjects, and decide minor or patch. Before the first tag the range is
the whole history.

### 2. Write the version into its copies

CI's `Resolve version from tag` step refuses the tag unless **all of these** agree, and each is a
separate hand edit:

| Where                                         | What                                                                                                                       |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `apps/apple/Drakar.xcodeproj/project.pbxproj` | `MARKETING_VERSION = X.Y.Z;` in **both** build configurations of **both** the `Drakar` and `DrakarHost` targets. CI counts exactly 4 |
| `CHANGELOG.md`                                | the top section titled `## [X.Y.Z] - YYYY-MM-DD`, dated the day the tag is pushed, never `- Unreleased`                    |
| `CHANGELOG.md` intro                          | a sentence containing `` `app-vX.Y.Z` being the newest ``                                                                  |

Armada counts 2 and also checks a version in its site's `config.ts`. Drakar's session host is a
target of its own carrying the version, and Drakar's site carries none.

CI reads the first `## [` heading of any kind, so an `## [Unreleased]` left above the new section
fails the tag, and so does the pending form, `## [X.Y.Z] - Unreleased`, which Drakar's parser
accepts for What's New but which would ship a release with no date. The intro check is a plain
grep for that exact phrase, backticks included; a sentence such as "Releases are tagged
`app-v<version>`, with `app-v1.0.0` being the newest." passes it.

The release job passes `MARKETING_VERSION` from the tag on the xcodebuild command line, so the
pbxproj copies are not what the release reads. They are checked anyway: Xcode reads them when it
builds on its own, and so does `make build`.

The new section opens with its **summary**: one paragraph, `**Title.** Description.`, right
under the `## [X.Y.Z]` heading and above the first `###`. It is the first paragraph of the update
dialog, of What's New and of the GitHub release body. Write it for somebody who has never opened
the app, from the section's own entries.

Then regenerate what is derived from them:

```bash
make changelog      # Changelog.swift, the What's New pane's data
make revocations    # Revocations.swift from the Worker's D1: refunded keys stop at this build
```

Drakar's `make changelog` writes Changelog.swift alone; armada's also renders a release card for
its site, which Drakar's has no page for.

**`make revocations` is not optional.** The app is not allowed to ask anything at runtime, so a
refund or a lost chargeback since the last release is honoured only by a build that re-ran it.
It needs wrangler to be logged in, and fails loudly rather than skipping. Until Phase 2 creates
`drakar-licenses` there is nothing to read, and it says so and keeps the list empty.

It reads D1 and nothing else, so a key exists to it only once it has a row. The Worker records
every key it mints, and so does `scripts/mint-license.mjs` unless told `--no-record`. A comp or a
replacement is filed under `manual:<id>` with no payment intent, so no refund reaches it; revoke
one, or a key posted somewhere public, by its id:

```bash
pnpm -C apps/api exec wrangler d1 execute drakar-licenses --remote --command \
  "UPDATE licenses SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ'), revoked_reason = 'leaked' WHERE id = '<id>'"
```

### 3. Rehearse CI's gate locally

```bash
v=X.Y.Z
grep -c "MARKETING_VERSION = $v;" apps/apple/Drakar.xcodeproj/project.pbxproj   # 4
grep -m 1 '^## \[' CHANGELOG.md                                                  # ## [X.Y.Z] - YYYY-MM-DD
grep -q "\`app-v$v\` being the newest" CHANGELOG.md && echo intro-ok
make changelog-check && make -C apps/apple format-swift-check && make test
node scripts/changelog-notes.mjs "$v" CHANGELOG.md >/dev/null && echo appcast-notes-ok
node scripts/changelog-notes.mjs --markdown "$v" CHANGELOG.md                     # the release body
```

The root `make test` runs the script tests, the licence Worker's suite and DrakarKit's.
`changelog-notes.mjs` is what `make appcast` and the release body both run in CI. It exits
non-zero on a missing section, and on a section with nothing in it once `### Internal` is left
out, which would otherwise stop the release after notarization rather than before it.

The appcast carries those notes **inline**, as the item's `<description>`, never as a
`sparkle:releaseNotesLink`. A link would be a second fetch at update time, and SECURITY.md
promises that a check reads one file. Keep it that way.

Use `/usr/bin/make` for any dry run. It is GNU make 3.81, the version CI runs, and it refuses
things Homebrew's make 4.x forgives.

### 4. Commit, tag, push: the tag first

```bash
git commit -m "chore(release): Drakar X.Y.Z" -- <the files above>
git tag -m "Drakar X.Y.Z" app-vX.Y.Z      # annotated; tag.gpgSign is on, so a bare `git tag` fails
git push origin app-vX.Y.Z
# once release-app has published the release:
git push origin main
```

**The site deploys from `main` and the release from the tag.** On the first release the commit
takes the `noindex` off the site, so pushing `main` first would deploy a site search engines may
index, whose Download button leads to a GitHub 404 for the whole length of the release build, and
for good if that build fails. Pushing the tag first means the release exists before anything
points at it. Nothing is lost while `main` waits: the tag's run builds the tagged commit on its
own, and the branch run is not racing it.

This is the order armada's runbook argues, and the one its `cut-a-release` skill gets backwards.

### 5. Watch the run

`release-app` needs `node`, `app` and `revocations`, so a red one of those shows `release-app` as
**skipped**, not failed. Read which job failed rather than the run summary, and confirm the green
run is for the commit you tagged.

| Failed step                | What it means                                                                                         |
| -------------------------- | ----------------------------------------------------------------------------------------------------- |
| Revocations drift          | `make revocations` was not re-run since a refund, or the token is missing (fatal on a tag)            |
| Resolve version from tag   | a version copy disagrees, or the section is still `- Unreleased`; fix, commit, delete and re-push the tag |
| Import signing certificate | a `DEVELOPER_ID_*` or `KEYCHAIN_PASSWORD` secret is missing or wrong                                  |
| Build, sign and notarize   | a public key is still the placeholder, or notarytool's log names the problem; nothing was uploaded    |
| Verify the artifact        | `make audit-release` or Gatekeeper refused the signed bundle; nothing was uploaded                    |
| Sign the update            | `SPARKLE_ED_PRIVATE_KEY` is missing or is not `SUPublicEDKey`'s other half, or the section is empty   |

### 6. Verify from outside

```bash
gh release view app-vX.Y.Z -R mgcrea/drakar --json assets -q '.assets[].name'
# exactly: Drakar.zip, Drakar.zip.sha256, appcast.xml
curl -sI https://drakar.mgcrea.io/appcast.xml | grep -i location
tmp=$(mktemp -d) && curl -sL -o "$tmp/Drakar.zip" https://drakar.mgcrea.io/download
[ "$(shasum -a 256 "$tmp/Drakar.zip" | cut -d' ' -f1)" = "$(curl -sL https://drakar.mgcrea.io/checksum)" ] && echo checksum-ok
ditto -x -k "$tmp/Drakar.zip" "$tmp" && spctl -a -vvv -t install "$tmp/Drakar.app"
scripts/audit-network.sh --app "$tmp/Drakar.app"   # no entitlements, the hardened runtime, the sweep
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$tmp/Drakar.app/Contents/Info.plist"
apps/apple/Vendor/bin/generate_keys --account drakar -p     # must print the same key
```

Drakar ships no entitlements at all, on the app or the session host; the audit fails on any.
Armada's runbook lists one (the microphone) here instead.

Install it on this Mac with `make install-release` only once you have quit Drakar yourself: the
target refuses while Drakar runs, because quitting it ends live sessions mid-turn.

The update path itself, Sparkle installing X.Y.Z over an older copy, can only be exercised from
the second release onward.

## Traps

- **The Stripe account is shared with armada, bastion and cupertino**, so every app's Worker
  receives every sale. Drakar's refuses anything but its own price, and fails closed when
  `EXPECTED_PRICE_ID` is empty: with that var blank it refuses every sale, Drakar's included.
  That is the state until the store opens; once it does, never deploy `apps/api` with it unset.
- **Late prose lands in the wrong section.** A bullet added after the retitle goes under the new
  version, not under a fresh `[Unreleased]`; add `## [Unreleased]` back after tagging if work
  continues, never before.
- **Never re-sign a stapled bundle.** `make install-release` deliberately does not depend on
  `bundle`: signing again invalidates the stapled ticket.
- **Never `make run` or `make quit` as part of a release.** Both quit the running Drakar, and the
  release is often being cut from a session inside it.
- **GNU coreutils come first on PATH on the author's Mac.** Sort tags with `sort -V`, not a
  string sort, and anything committed must still work with the BSD tools on the runner.
