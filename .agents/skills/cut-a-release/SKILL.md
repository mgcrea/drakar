---
name: cut-a-release
description: Companion for cutting and shipping a Drakar release — the steps that live nowhere else. Use this whenever the user says anything like "let's release 1.0.0", "ship it", "cut a release", "push a release", "tag a version", "what's unreleased?", or asks to write the CHANGELOG for a release. Reach for it even when the ask sounds like a single step ("bump the version", "just tag it") — the steps constrain each other, and several are invisible to CI, so a release that skips them can still go out green. IMPORTANT: Drakar ships Developer ID signed and notarized, as a GitHub release with a Sparkle appcast beside it, and is built to be sold with an offline licence key. It is NOT an App Store app and has no store listing; if a generic App Store or fastlane release skill also looks relevant, it is wrong here.
---

# Cutting a Drakar release

Drakar's release path is armada's, copied on 2026-10-29, which is bastion's step for
step. There is no bump or release script. A release is **one commit, one signed
`app-v<version>` tag, and the `release-app` job in `.github/workflows/ci.yml`**, which
builds, signs, notarizes, verifies, writes the appcast and publishes. `make build-release`
on a laptop is a rehearsal, never how a release ships.

`docs/releasing.md` is the runbook, with the reasons. Read `fleet-direct-conventions` for
why each piece is shaped the way it is. This is only the sequence, and the traps in it.

**Never `make run` or `make quit` at any step.** Both quit the running Drakar, and this
release is quite possibly being cut from a session inside it.

## Before the first release only

`docs/releasing.md`, "Once, before the first release", is the one checklist for going public,
the first release and opening the store, **in the order its steps must run** (the D1
database id committed before `CLOUDFLARE_API_TOKEN` exists, for one). Work through it there;
this is only what must be true before tagging 1.0.0. After 1.0.0 these stay true.

1. **The keys are real.** `SUPublicEDKey` in `apps/apple/Drakar-Info.plist` and
   `LicenseKey.publicKey` in `apps/apple/Drakar/Licence/License.swift` must not be
   `PLACEHOLDER-SET-IN-PHASE-2`; `make sign` refuses a bundle carrying either, so CI would
   fail in Build, sign and notarize. The runbook lists everything else the commit that
   lands them changes.
2. **CI can sign.** `gh secret list -R mgcrea/drakar --env release` must show six:
   `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`,
   `AC_KEY_ID`, `AC_KEY_P8_BASE64`, `SPARKLE_ED_PRIVATE_KEY`. Without `--env release` it
   lists only the repository's secrets, where `AC_ISSUER_ID` (and `LICENSE_SIGNING_KEY`)
   live. `make sparkle-keys` prints the Sparkle export commands; run
   `make sparkle-key-shred` after `gh secret set`.
3. **`CLOUDFLARE_API_TOKEN` is in the `production` environment, and `production` admits
   `app-v*` tags.** The `revocations` job runs there on a release tag, fails on a tag
   without the token, and `release-app` needs it.
4. **The version is 1.0.0.** The licence key's `major` is 1, so a first release numbered
   0.x would lock out every key sold for 1.x.
5. **The first release commit also** dates `## [1.0.0] - Unreleased` (step 2 below),
   rewrites the CHANGELOG intro's "none is tagged yet" to name `app-v1.0.0` as the newest,
   and **removes the `X-Robots-Tag: noindex` line and its comment from
   `apps/website/public/_headers`**: the site has been live since Phase 2, and that line
   kept it out of search results while `/download` led to a GitHub 404. `/download`,
   `/checksum` and `/appcast.xml` start resolving the moment the release exists, because
   they are 302s to `releases/latest/download`. The site's "Free while in beta" and
   `LicenceLinks.isSelling = false` stay until the owner opens the store, after the
   runbook's Phase 4, refund terms first.

## Every release

### 1. Read what changed

```bash
last=$(git describe --tags --match 'app-v*' --abbrev=0 2>/dev/null)
git log --oneline ${last:+$last..}HEAD
```

Read the diffs, not the subjects, and decide minor or patch. Before 1.0.0 there is no
tag and the range is the whole history.

### 2. Write the release into the version copies

CI's `Resolve version from tag` step refuses the tag unless **all of these** agree, and
each is a separate hand edit:

| Where | What |
|---|---|
| `apps/apple/Drakar.xcodeproj/project.pbxproj` | `MARKETING_VERSION = X.Y.Z;` in **both** configurations of **both** `Drakar` and `DrakarHost` (it greps for exactly 4) |
| `CHANGELOG.md` | the top section titled `## [X.Y.Z] - YYYY-MM-DD`, dated the day the tag is pushed; `- Unreleased` is refused |
| `CHANGELOG.md` intro | a sentence containing `` `app-vX.Y.Z` being the newest `` |

**Open the section with its summary**: one paragraph right under `## [X.Y.Z]`, above the
first `###`, `**Title.** A sentence or two.` It is the first paragraph of the update
dialog, of What's New and of the GitHub release body. Write it for somebody who has never
opened the app, from the section's own entries.

Then regenerate what is derived from them, **on the Mac**:

```bash
make changelog          # Changelog.swift (What's New) and the site's release card
make revocations        # Revocations.swift from D1: refunded keys stop at this build
pnpm version:sync       # apps/website/src/config.ts: CI's Website job refuses a drift
```

`make revocations` needs wrangler to be logged in and fails loudly rather than skipping.
A refund that happened since the last release is only honoured by a build that re-ran it.

### 3. Rehearse CI's gate locally

```bash
v=X.Y.Z
grep -c "MARKETING_VERSION = $v;" apps/apple/Drakar.xcodeproj/project.pbxproj   # 4
grep -m 1 '^## \[' CHANGELOG.md                                                  # dated, not Unreleased
grep -q "\`app-v$v\` being the newest" CHANGELOG.md && echo intro-ok
make changelog-check && make -C apps/apple format-swift-check && make test
pnpm version:check && pnpm -C apps/api typecheck
node scripts/changelog-notes.mjs "$v" CHANGELOG.md >/dev/null && echo notes-ok
```

**A local Release build does not prove CI's.** CI builds with its own Xcode (26.6, Swift
6.3.3, on 2026-11-02), older than this Mac's; app-v1.2.0's first run died in a compiler
crash that 6.4 never showed. When `main` has commits no CI run has built, push them to a
scratch branch and `gh workflow run ci.yml --ref <branch>` before tagging: deploys need a
push to `main` and `release-app` a tag, so that run publishes nothing. Its Revocations job
fails at once (the `production` environment admits only `main` and `app-v*`), which means
nothing; Node, Website and App are the ones to read. Delete the branch afterwards.

`changelog-notes.mjs` is what `make appcast` runs in CI. It exits non-zero on a
missing or empty section, which would otherwise stop the release after notarization
rather than before it. The notes go into the appcast inline; never add a
`sparkle:releaseNotesLink`, which would make an update check read a second file.

Use `/usr/bin/make` for any dry run. It is GNU make 3.81, the version CI runs, and it
parses things Homebrew's make 4.x on this Mac forgives.

### 4. Before tagging: not from the Drakar in use

Ask the owner before going further if this release would be installed over, or tested
in, the Drakar they are working in. Nothing in steps 4–6 needs the running app, and
nothing here may quit it: `make install-release` refuses while Drakar runs, and the
person quits it themselves, when no turn is in flight, if they want the new build
installed. Never work around that refusal, and never reach for `make quit`.

### 5. Commit, tag, push: the tag first

```bash
git add apps/website/public/changelog/X.Y.Z.png    # the new release card
git commit -m "chore(release): Drakar X.Y.Z" -- CHANGELOG.md \
  apps/apple/Drakar.xcodeproj/project.pbxproj apps/apple/Drakar/Changelog.swift \
  apps/apple/Drakar/Licence/Revocations.swift apps/website/src/config.ts \
  apps/website/src/data/release-cards.json apps/website/public/changelog/X.Y.Z.png
git tag -m "Drakar X.Y.Z" app-vX.Y.Z      # annotated; tag.gpgSign is on, so a bare `git tag` fails
git push origin app-vX.Y.Z
# once release-app has published the release:
git push origin main
```

Push the **tag first**, and `main` only once the release is public. The site deploys from
`main` and the release from the tag: pushing `main` first deploys a site that points at a
release that does not exist yet (on the first release, a site without its `noindex`, whose
Download button is a GitHub 404), for the whole release build, and for good if it fails.
The tag's run builds the tagged commit on its own, so nothing is lost while `main` waits.
This is the order `docs/releasing.md` argues; armada's own skill still pushes `main` first,
and is the one that is wrong.

### 6. Watch the run

`release-app` needs `node`, `app` and `revocations`, so a red one of those shows
`release-app` as **skipped**, not failed. Read which job failed, not the run summary, and
confirm the green run is for the commit you tagged.

```bash
gh run list -R mgcrea/drakar --branch app-vX.Y.Z -L 1      # a tag's runs list under its name
gh run watch <id> -R mgcrea/drakar --interval 30           # in the background: ~20 min with notarization
gh run view <id> -R mgcrea/drakar --log-failed             # "log not found"? read the job instead:
gh api repos/mgcrea/drakar/actions/jobs/<job-id>/logs
```

| Failed step | What it means |
|---|---|
| Revocations drift | `make revocations` not re-run since a refund, or no token (fatal on a tag) |
| Website › Version | `pnpm version:sync` not run: `apps/website/src/config.ts` disagrees with the pbxproj |
| App › Build | CI's older Swift refused or crashed on code this Mac builds; see step 3 |
| App › Tests (swift) | often a wall-clock budget on a loaded 3-core runner (`took 1.19 s < 1 s`); widen it rather than rerun |
| Resolve version from tag | a version copy disagrees, or the section is still `- Unreleased`; fix, commit, delete and re-push the tag |
| Import signing certificate | a `DEVELOPER_ID_*` or `KEYCHAIN_PASSWORD` secret is missing or wrong |
| Build, sign and notarize | a public key is still the placeholder, or notarytool's log names the problem; nothing was uploaded |
| Verify the artifact | `make audit-release` or Gatekeeper refused the signed bundle; nothing was uploaded |
| Sign the update | `SPARKLE_ED_PRIVATE_KEY` is missing or not `SUPublicEDKey`'s other half, or the CHANGELOG section is empty |

Anything before `release-app` publishes nothing, so the fix is a new commit on top and the
same tag moved to it, once `gh release view app-vX.Y.Z` says there is no release:

```bash
git push origin :refs/tags/app-vX.Y.Z && git tag -d app-vX.Y.Z
git tag -m "Drakar X.Y.Z" app-vX.Y.Z && git push origin app-vX.Y.Z
```

Never move a tag whose release exists: Sparkle copies may already hold that build.

Then push `main` (step 5). Its own run deploys the site and the API whether or not its App
job passes, so a red App there (a timing test) leaves the release and the site alone, but
still fix it.

### 7. Verify from outside

```bash
gh release view app-vX.Y.Z -R mgcrea/drakar --json assets -q '.assets[].name'
# exactly: Drakar.zip, Drakar.zip.sha256, appcast.xml
curl -sI https://drakar.mgcrea.io/appcast.xml | grep -i location
tmp=$(mktemp -d) && curl -sL -o "$tmp/Drakar.zip" https://drakar.mgcrea.io/download
[ "$(shasum -a 256 "$tmp/Drakar.zip" | cut -d' ' -f1)" = "$(curl -sL https://drakar.mgcrea.io/checksum)" ] && echo checksum-ok
ditto -x -k "$tmp/Drakar.zip" "$tmp" && spctl -a -vvv -t install "$tmp/Drakar.app"
scripts/audit-network.sh --app "$tmp/Drakar.app"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$tmp/Drakar.app/Contents/Info.plist"
apps/apple/Vendor/bin/generate_keys --account drakar -p     # must print the same key
```

The update path itself (Sparkle installing X.Y.Z over an older copy) can only be
exercised from the second release onward.

## Traps

- **Never quit the running Drakar.** No `make run`, no `make quit`, no `pkill`; the owner
  quits it when no turn is running.
- **GNU coreutils come first on PATH here.** Sort tags with `sort -V`, not a string sort,
  and anything committed must still work with BSD tools on the runner.
- **Late prose lands in the wrong section.** A bullet added after the retitle goes under
  the new version, not under a fresh `[Unreleased]`; add `## [Unreleased]` back after
  tagging if work continues.
- **Never re-sign a stapled bundle.** `make install-release` deliberately does not depend
  on `bundle`: signing again invalidates the stapled ticket.
- **The Stripe account is shared with armada, bastion and cupertino.** Every app's Worker
  receives every sale. Drakar's refuses anything but its own price and fails closed if
  `EXPECTED_PRICE_ID` is empty. The store has been open since 1.1.0 (2026-10-31): never
  deploy `apps/api` with that var blank.
