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

### The keys are real

Until Phase 2, `SUPublicEDKey` in `apps/apple/Drakar-Info.plist` and `LicenseKey.publicKey` in
`apps/apple/Drakar/Licence/License.swift` are the literal `PLACEHOLDER-SET-IN-PHASE-2`, and
`make sign` refuses a bundle carrying either, before it signs anything. A tag pushed before then
fails in **Build, sign and notarize**.

Drakar has **its own EdDSA key**, under the keychain account `drakar`, not the one armada, bastion
and cupertino share: every `generate_keys` and `sign_update` call in the Makefile passes
`--account drakar`. A leak of the shared key cannot update Drakar, and a leak of Drakar's cannot
update the others.

### The repository secrets

`gh secret list -R mgcrea/drakar` must show all seven that `release-app` reads:

| Secret                      | What it is                                                                |
| --------------------------- | ------------------------------------------------------------------------- |
| `DEVELOPER_ID_P12_BASE64`   | the Developer ID Application certificate and its private key, as a `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the password that `.p12` was exported with                                |
| `KEYCHAIN_PASSWORD`         | any password, for the throwaway keychain the job creates and deletes      |
| `AC_KEY_ID`                 | the App Store Connect API key notarytool submits with                     |
| `AC_ISSUER_ID`              | that key's issuer                                                         |
| `AC_KEY_P8_BASE64`          | that key's `.p8`                                                          |
| `SPARKLE_ED_PRIVATE_KEY`    | the EdDSA key the appcast is signed with                                  |

All but `AC_ISSUER_ID` belong in the `release` environment, whose deployment policy admits only
`app-v*` tags, so a workflow edited on a branch cannot read them.

The two `DEVELOPER_ID_*` secrets and `SPARKLE_ED_PRIVATE_KEY` come out of the login keychain by
hand: the App Store Connect API lists no Developer ID certificate, so nothing can fetch the
`.p12` for you.

For the Sparkle key, run `make sparkle-keys`. It asserts that the keychain's `drakar` key is the
one whose public half is `SUPublicEDKey` in `apps/apple/Drakar-Info.plist`, and only then prints
the export and `gh secret set` commands. Run `make sparkle-key-shred` afterwards. The key is
Drakar's alone, so it belongs in this one repository's secret, never an org-wide one.
`make appcast` checks the same thing again on every release, over the zip it signs.

Two other secrets are not needed to release. `CLOUDFLARE_API_TOKEN`, in the `production`
environment, is what the deploy jobs and the `revocations` job use; without it the deploys warn
and deploy nothing, and `revocations` skips, **except on a release tag, where it fails**, and
`release-app` needs it. So the token has to exist before the first tag. `LICENSE_SIGNING_KEY`
turns on the licence round trip in the `app` job; without it that step warns and skips.

### The version is 1.0.0

The licence key's `major` is 1 (`CURRENT_MAJOR` in `apps/api/wrangler.jsonc`) and the app refuses
a key for another major, so a first release numbered 0.x would lock out every key ever sold for
1.x.

### What flips in the first release commit

- `CHANGELOG.md`: `## [1.0.0] - Unreleased` is dated, and the intro's "none is tagged yet" is
  rewritten to name `app-v1.0.0` as the newest (step 2 below).
- `apps/website/public/_headers`: the `X-Robots-Tag: noindex` line and its comment come out.
  They kept the site out of search results while `/download` led to a GitHub 404. `/download`,
  `/checksum` and `/appcast.xml` start resolving the moment the release exists, because they are
  302s to `releases/latest/download`.

The site's "Free while in beta" stays until the store opens; so does `isSelling = false`.

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
