# Direct Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything Drakar needs inside the repo to ship as a signed, notarized,
Sparkle-updated, licence-sold Developer ID app, copied from armada, with nothing published.

**Architecture:** Armada (`~/Projects/apps/armada`) is the source for every file copied here.
"Copy armada's X" means: copy the file, rename `armada`/`Armada`/`arm1` to
`drakar`/`Drakar`/`drk1`, keep its comments where they still hold and rewrite the ones that
don't, and mark every behavioural departure `DIVERGES from armada:` with the reason. The
licence check lives in one place: `AgentSession.canSend`/`canQueue`. Every prompt passes
through `AgentSession.send`, so that one check covers the composer, Yes/No, skills, fan-out
and debug prompts.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), Sparkle 2.9.6 (vendored), Node ≥ 24 + pnpm
11 for scripts, Cloudflare Workers + D1 (Wrangler, Vitest), Astro, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-28-direct-distribution-design.md`. Fleet rules:
`~/Projects/claude-skills/projects/apps/fleet-direct-conventions/` (SKILL.md and
`references/`). Read both before starting any task.

## Global Constraints

- Bundle id `io.mgcrea.Drakar`, team `75QE9PRT3V`, `MARKETING_VERSION` 1.0.0, build number `git rev-list --count HEAD`.
- Licence prefix `drk1`; `Trial.duration = 30 * 60`; price $14.99 (store copy only, never in code).
- `LicenceLinks.buy = https://drakar.mgcrea.io/buy`, `LicenceLinks.isSelling = false` throughout this plan.
- `SUFeedURL = https://drakar.mgcrea.io/appcast.xml`; enclosure `https://github.com/mgcrea/drakar/releases/download/app-v$version/Drakar.zip`.
- Sparkle `2.9.6`, `SPARKLE_SHA256 := 8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606`; every `generate_keys`/`sign_update` call passes `--account drakar`.
- Placeholder public keys are the literal `PLACEHOLDER-SET-IN-PHASE-2` (Sparkle and licence alike); `sign` refuses to sign a bundle carrying it.
- No entitlements file, `ENABLE_APP_SANDBOX = NO`, hardened runtime on: unchanged, and asserted.
- Never `make run`/`make quit` (they kill the owner's live sessions); build and test only.
- `scripts/verify-update-signature.mjs`, `scripts/lib/update-signature.mjs`, `scripts/lib/update-signature.test.mjs` are byte-identical to armada's.
- Committed scripts and Makefiles stay BSD-portable (CI is macOS with BSD tools; this Mac has GNU ones first on PATH).
- User-facing copy spells it "Licence"; code spells it `License`.
- Nothing in this plan pushes, deploys, creates a key in a keychain, or touches Stripe, GitHub or Cloudflare. Phases 2–4 below are the owner's checklists.

## Review Focus

1. **The trial ends while a turn waits on a permission prompt.** The answer still reaches the agent and Stop still works; only a new prompt is refused (Task 6, `answersPermissionAfterTrialEnds`).
2. **A prompt typed and sent after the trial ended.** It is refused and the draft is kept in the composer, not cleared (Task 6, `refusedSendKeepsDraft`).
3. **A key pasted from a mail client with line breaks and spaces inside it** is accepted (Task 5, `acceptsWrappedKey`).
4. **A release built before Phase 2 replaced the placeholder keys.** `make sign` stops with a message naming the placeholder (Task 4, verification step).
5. **Update checks never answered.** No `SPUUpdater` exists and nothing resolves a name (Task 3, `noUpdaterBeforeConsent`).

---

### Task 1: Node workspace and the changelog pipeline

**Files:**
- Create: `package.json`, `pnpm-workspace.yaml`, `CHANGELOG.md`, `LICENSE`
- Create: `scripts/lib/changelog.mjs`, `scripts/lib/changelog.test.mjs`, `scripts/changelog-notes.mjs`, `scripts/generate-changelog.mjs`
- Create (byte-identical copies): `scripts/verify-update-signature.mjs`, `scripts/lib/update-signature.mjs`, `scripts/lib/update-signature.test.mjs`
- Modify: `Makefile` (root), `.gitignore`

**Interfaces:**
- Produces: `node scripts/changelog-notes.mjs <version> CHANGELOG.md [--markdown]` (exit ≠ 0 on a missing or empty section); `node scripts/generate-changelog.mjs [--check]`, which writes `apps/apple/Drakar/Changelog.swift`; root targets `test-scripts`, `changelog`, `changelog-check`.

- [ ] **Step 1:** Copy armada's `package.json` (name `@mgcrea/drakar`, repository `mgcrea/drakar`, the description from README's first sentence) and `pnpm-workspace.yaml`. Drop `apps/website/scripts` from `test:scripts`. Add `LICENSE`: MIT, copyright 2026 Olivier Louvignes, like armada's. Add `Vendor/`, `sparkle_key.pem`, `*.pem` and `apps/apple/.build/` to `.gitignore` if they are missing.
- [ ] **Step 2:** Copy the three update-signature files byte for byte, plus `scripts/lib/changelog.mjs` and its test. Run `pnpm install && pnpm test:scripts`. Expected: PASS, including `HIDDEN_SECTIONS` keeping `### Internal` out.
- [ ] **Step 3:** Copy `changelog-notes.mjs` and `generate-changelog.mjs`. Drakar's generator writes only `apps/apple/Drakar/Changelog.swift`; armada's site release cards are dropped with a `DIVERGES` note. Write `CHANGELOG.md` in armada's format with one section, `## [1.0.0] - Unreleased`, summarising what Drakar does today (README's paragraph, as bullets under `### Added`).
- [ ] **Step 4:** Add the root targets `test-scripts` (`pnpm test:scripts`), `changelog` and `changelog-check`, and remove the README's "No deploy block yet" comment once Task 8 lands (leave it for now). Run `make changelog && make changelog-check`. Expected: both exit 0. Then add a bullet to `CHANGELOG.md` and run `make changelog-check`. Expected: FAIL naming `Changelog.swift`. Revert the bullet.
- [ ] **Step 5:** Run `shasum -a 256 scripts/verify-update-signature.mjs scripts/lib/update-signature*.mjs ~/Projects/apps/armada/scripts/verify-update-signature.mjs ~/Projects/apps/armada/scripts/lib/update-signature*.mjs`. Expected: pairs match.
- [ ] **Step 6:** Commit: `build: the Node workspace and the changelog pipeline, armada's`.

### Task 2: What's New and AppInfo

**Files:**
- Create: `apps/apple/Drakar/Services/AppInfo.swift` (armada's `AppInfo.swift`), `apps/apple/Drakar/Views/WhatsNewPane.swift` (armada's)
- Modify: `apps/apple/Drakar/Views/SettingsView.swift` (pane enum and switch), `apps/apple/DrakarTests/SettingsPaneTests.swift`

**Interfaces:**
- Consumes: `Changelog` (generated in Task 1).
- Produces: `AppInfo.major: Int` (nonisolated, from `CFBundleShortVersionString`), and `SettingsPane.whatsNew`, which Tasks 3 and 6 slot new panes beside.

- [ ] **Step 1:** In `SettingsPaneTests.keepsPaneIdentifiersStable`, expect `["general", "transcript", "theme", "attention", "whatsNew", "about"]`. Tasks 3 and 6 each insert their pane into this list (final order: `…, "attention", "updates", "licence", "whatsNew", "about"`).
- [ ] **Step 2:** Add `case whatsNew` (title "What's New", symbol `sparkles`) before `.about`, with the unseen badge as armada wires it. Copy `AppInfo.swift`, keeping the members Drakar uses.
- [ ] **Step 3:** Run `make -C apps/apple test-app`. Expected: all pass. Known flakes (`CapabilityProbe`, `AgentSession` opened-elsewhere, `SessionMoves`): rerun any of those alone before treating it as a regression.
- [ ] **Step 4:** Commit: `feat(apple): What's New, from CHANGELOG.md`.

### Task 3: Sparkle and the Updates pane

**Files:**
- Modify: `apps/apple/Makefile` (a `sparkle` target, with `build`, `build-release` and `test-app` depending on it), `apps/apple/Drakar.xcodeproj/project.pbxproj`, `apps/apple/Drakar/Info.plist`, `apps/apple/Drakar/DrakarApp.swift`, `apps/apple/Drakar/Views/SettingsView.swift`, `apps/apple/Drakar/Views/HomeView.swift`
- Create: `apps/apple/Drakar/Services/Updates.swift` (armada's)
- Test: `apps/apple/DrakarTests/UpdatesTests.swift`

**Interfaces:**
- Produces: `UpdateController.shared` with `startIfConsented()`, `checkNow()`, `answer(automatic:)`, `hasAnswered`, and `var isStarted: Bool` (new; true once the `SPUStandardUpdaterController` exists). Also `SettingsPane.updates`, `UpdatesPane` and `UpdateConsentCard`.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("Updates", .serialized) @MainActor struct UpdatesTests {
  @Test func noUpdaterBeforeConsent() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults)
    controller.startIfConsented()
    #expect(!controller.isStarted)
    #expect(!controller.hasAnswered)
  }
  @Test func infoPlistDefaultsArePresentAndFalse() {
    let info = Bundle.main.infoDictionary!
    #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
    #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
    #expect(info["SUScheduledCheckInterval"] as? Int == 86400)
    #expect(info["SUFeedURL"] as? String == "https://drakar.mgcrea.io/appcast.xml")
  }
}
```

- [ ] **Step 2:** Run `make -C apps/apple test-app`. Expected: compile failure (no `UpdateController`).
- [ ] **Step 3:** Copy armada's `sparkle` target and variables into `apps/apple/Makefile`: the stamp and the tools under `Vendor/`, with armada's `DIVERGES` comment kept. Wire `Vendor/Sparkle.framework` into the project as armada's pbxproj does: a file reference with `SOURCE_ROOT`, Frameworks, Embed Frameworks with `CodeSignOnCopy`, and `FRAMEWORK_SEARCH_PATHS = $(SRCROOT)/Vendor` in both configurations. Add `SUFeedURL`, `SUPublicEDKey` (`PLACEHOLDER-SET-IN-PHASE-2`) and the three defaults to `Info.plist`, carrying over the comments armada puts in `Armada-Info.plist`.
- [ ] **Step 4:** Copy `Updates.swift`, with one addition: an `init(defaults: UserDefaults = .standard)` and `isStarted`. Add `case updates` (title "Updates", symbol `arrow.triangle.2.circlepath`) after `.attention`, showing `UpdatesPane`. Call `UpdateController.shared.startIfConsented()` in `applicationDidFinishLaunching`. Show `UpdateConsentCard` at the top of Home while `!hasAnswered`.
- [ ] **Step 5:** Insert `"updates"` after `"attention"` in `keepsPaneIdentifiersStable`. Run `make -C apps/apple sparkle test-app`. Expected: all pass.
- [ ] **Step 6:** Read `docs/session-host.md` on bundle replacement and confirm that Sparkle's "Install and Relaunch" goes through `applicationShouldTerminate`/`applicationWillTerminate`, which hand sessions to the host. Write the finding as a short paragraph in `docs/session-host.md` under "A Sparkle update". If the quit path skips the hand-over, stop and report instead of working around it.
- [ ] **Step 7:** Commit: `feat(apple): Sparkle 2.9.6 and the Updates pane, off until asked`.

### Task 4: The release targets

**Files:**
- Modify: `Makefile` (root)

**Interfaces:**
- Consumes: the `sparkle` target (Task 3) and `changelog-notes.mjs` (Task 1).
- Produces: root targets `bundle`, `sign`, `notarize`, `build-release`, `checksum`, `appcast`, `install-release`, `sparkle-keys`, `sparkle-key-shred`. Outputs go to `apps/apple/.build/`: `Drakar.zip`, `Drakar.zip.sha256` (a bare 64-character digest, as armada writes it) and `appcast.xml`.

- [ ] **Step 1:** Copy armada's root `Makefile` release section (`bundle` through `sparkle-key-shred`, its lines ~230–486). Drop armada's speech framework and its entitlements flag. Sign in this order: `Updater.app` → `Autoupdate` → `Sparkle.framework` → `Contents/Helpers/DrakarHost` → `Drakar.app`. Then add two refusals at the top of `sign`: no `apps/apple/*.entitlements` file may exist, and `SUPublicEDKey` (read with PlistBuddy) and `LicenseKey.publicKey` (grepped from `License.swift`, Task 5) must not equal `PLACEHOLDER-SET-IN-PHASE-2`. Until Task 5 lands, the licence half reads "skipped: no License.swift".
- [ ] **Step 2:** Pass `--account drakar` to every `generate_keys` and `sign_update` call (keychain path only; `--ed-key-file` ignores it). `install-release` accepts `io.mgcrea.Drakar` only, and never quits a running Drakar: it refuses while one is running. That departs from armada, so it gets a `DIVERGES` note pointing at the never-quit rule. Make `$(APPLE_TARGETS)` exclude the new root names so nothing forwards twice.
- [ ] **Step 3:** Run `make bundle`. Expected: it stops in `sign` with "SUPublicEDKey is the placeholder". This is Review Focus 4.
- [ ] **Step 4:** Run `make bundle ALLOW_PLACEHOLDER_KEYS=1`, a flag that only skips the placeholder refusal and prints that it did. Expected: an app signed with the Apple Development fallback and its loud warning. Then run `codesign --verify --deep --strict --verbose=2 apps/apple/.build/Release/Drakar.app`. Expected: "valid on disk" and "satisfies its Designated Requirement".
- [ ] **Step 5:** Run `/usr/bin/make -n help appcast` (GNU make 3.81, as CI has). Expected: no parse error.
- [ ] **Step 6:** Commit: `build: sign, notarize and the appcast, armada's, with Drakar's own key account`.

### Task 5: The licence stack

**Files:**
- Create (armada's, renamed): `apps/apple/Drakar/Licence/License.swift`, `LicenseStore.swift`, `Trial.swift` (holds `Entitlement`), `Revocations.swift`, `LicenceLinks.swift`
- Create (armada's): `scripts/lib/license.mjs`, `scripts/lib/license.test.mjs`, `scripts/lib/license-record.mjs` (+ test), `scripts/lib/revocations.mjs` (+ test), `scripts/mint-license.mjs`, `scripts/verify-license.mjs`, `scripts/license-check.mjs`, `scripts/license-check.swift`, `scripts/generate-revocations.mjs` (+ test)
- Modify: `Makefile` (root: `license-check`, `revocations`)
- Test: `apps/apple/DrakarTests/LicenseKeyTests.swift`

**Interfaces:**
- Produces: `LicenseKey.check(_:major:revoked:publicKey:) -> LicenseCheck`, `LicenseKey.prefix == "drk1"`, `LicenseStore.{raw, check, isLicensed, store(_:), clear()}`, `Trial.{start(), isActive, hasRun, remainingText}`, `Entitlement.current` (verbatim armada's, comment included), `LicenceLinks.{buy, isSelling}`. `Trial.expire()` calls `EntitlementMonitor.shared.apply()`, which Task 6 defines; until then a stub `EntitlementMonitor` with an empty `apply()` sits in `Trial.swift`, and Task 6 moves it out.

- [ ] **Step 1: Write the failing tests**, signing keys in-test with `Curve25519.Signing.PrivateKey()`, as armada's `make unit` does, through a helper `mint(id:email:major:issuedAt:with:) -> String` built on the key format in `scripts/lib/license.mjs`:
  - `acceptsAValidKey`: `.valid`, with the id and email read back.
  - `acceptsWrappedKey`: the same key with `"\n"` every 60 characters and spaces at both ends is `.valid`.
  - `refusesOtherPrefix`: `arm1.` + the same payload and signature is `.refused`.
  - `refusesTamperedPayload`: `.refused`.
  - `refusesRevoked`: `revoked: [id]` is `.refused`.
  - `refusesOlderMajor`: a key minted with major 1, checked with `major: 2`, is `.refused`.
  - `trialStartIsIdempotent`: `Trial.start()` twice returns the same deadline.
  - `entitlementPrefersKeyOverTrial`: with a valid stored key and an active trial, the result is `.licensed`.
  - `publicKeyIsPlaceholderUntilPhase2`: `LicenseKey.publicKey == "PLACEHOLDER-SET-IN-PHASE-2"`. Phase 2 deletes this test when the real key lands.
- [ ] **Step 2:** Run `make -C apps/apple test-app`. Expected: compile failure.
- [ ] **Step 3:** Copy the Swift files with `prefix = "drk1"` and `publicKey = "PLACEHOLDER-SET-IN-PHASE-2"`; a placeholder decodes to no key, so every check is `.refused("…")`. `LicenceLinks` gets the buy URL and `isSelling = false`, its doc comment saying that flipping it is the release that opens the store. Copy the scripts with the `drk1` prefix and D1 names `drakar-licenses` / `drakar-licenses-test`.
- [ ] **Step 4:** Run `make -C apps/apple test-app && pnpm test:scripts`. Expected: all pass.
- [ ] **Step 5:** `scripts/license-check.swift` passes `publicKey: env["LICENSE_PUBLIC_KEY"] ?? LicenseKey.publicKey` (a `DIVERGES` note: Drakar has no real key until Phase 2). Run `node scripts/mint-license.mjs --keygen` to get a throwaway pair, then `LICENSE_SIGNING_KEY=… LICENSE_PUBLIC_KEY=… make license-check`. Expected: "verifies". `git status` shows no new file.
- [ ] **Step 6:** Commit: `feat(apple): the drk1 licence, offline, and the 30-minute trial`.

### Task 6: The entitlement gate and the Licence pane

**Files:**
- Create: `apps/apple/Drakar/Licence/EntitlementMonitor.swift`, `apps/apple/Drakar/Licence/LicensePane.swift` (armada's, adapted), `apps/apple/Drakar/Views/LockedComposerCard.swift`
- Modify: `apps/apple/Drakar/Services/AgentSession.swift:406-417` (`canSend`, `canQueue`), `apps/apple/Drakar/DrakarApp.swift` (launch: `EntitlementMonitor.shared.apply()` replaces the direct `IDEBridge.shared.start()`), `apps/apple/Drakar/Views/SessionView.swift:~115` (card instead of composer), `apps/apple/Drakar/Views/SettingsView.swift` (`case licence`)
- Test: `apps/apple/DrakarTests/EntitlementGateTests.swift`

**Interfaces:**
- Consumes: `Entitlement.current`, `Trial`, `LicenseStore`, `LicenceLinks.isSelling` (Task 5).
- Produces:

```swift
@MainActor @Observable final class EntitlementMonitor {
  static let shared: EntitlementMonitor
  /// Tests only: forces `allowsWork` for the current task, so parallel suites never share a flipped global.
  @TaskLocal static var forced: Bool?
  /// What `AgentSession.canSend`/`canQueue` read: `forced ?? shared.allowsWork`.
  static var allowsWorkNow: Bool
  init(isSelling: Bool = LicenceLinks.isSelling)
  var isSelling: Bool
  private(set) var current: Entitlement
  var allowsWork: Bool                // forced ?? (!isSelling || current.isEntitled)
  func apply()                        // recompute; IDEBridge start when allowsWork, stop otherwise
  func startTrial(); func enterKey(_: String) -> LicenseCheck; func removeKey()
}
```

- [ ] **Step 1: Write the failing tests** (Swift Testing, `@MainActor`, each body inside `EntitlementMonitor.$forced.withValue(…)`). Build the session the way `AgentSessionTests` and `PermissionSheetTests` do, with a `ReplayTransport`:
  - `refusesSendWhenNotEntitled`: with `forced = false`, `session.send("hi")` leaves the transcript's entries unchanged and writes nothing to the transport.
  - `refusedSendKeepsDraft`: `ComposerView.submit()` (`ComposerView.swift:267`) already returns before `text = ""` when its `canSend` is false, and `SessionView` passes `session.canSend || session.canQueue`. So the test checks that, under `forced = false`, `Project.broadcast` to two marked sessions returns `sent == 0, skipped == 2`, and that a `ProjectSession` with `draft = "hi"` still has it after `EntitlementMonitor.shared.apply()`. Nothing in the gate writes a draft.
  - `refusesQueueWhenNotEntitled`: a session mid-turn has `canQueue == false` under `forced = false`.
  - `answersPermissionAfterTrialEnds`: a replay that stops on a permission request, then `forced = false`; answering allow writes the control response, and `stop()` still interrupts.
  - `fanOutRefusedWhenNotEntitled`: `Project.runInSubfolders` under `forced = false` sends no prompt.
  - `allowsEverythingWhileNotSelling`: `EntitlementMonitor(isSelling: false)` with no key and no trial has `allowsWork == true`.
  - `trialAllowsWork`: with `isSelling = true` and `Trial.start()` called, `apply()` gives `allowsWork == true`.
- [ ] **Step 2:** Run `make -C apps/apple test-app`. Expected: compile failure.
- [ ] **Step 3:** Implement `EntitlementMonitor` (armada's `apply()` shape, but its only side effect is the IDE bridge) and replace Task 5's stub. Append `&& EntitlementMonitor.allowsWorkNow` to both `canSend` and `canQueue`; `allowsWorkNow` is a static that reads `forced` first, then `shared.allowsWork`. Check that `controlsTasks`, permission answers, elicitation answers and `stop()` do not read `canSend`; if one does, give it its own condition without the gate, since Review Focus 1 depends on it.
- [ ] **Step 4:** `LockedComposerCard`, shown by `SessionView` in place of `ComposerView` when `!allowsWork` and the session is not read-only. The copy is armada's `LockedCard`, adapted:
  - before a trial: title "Drakar needs a licence"; body "A 30-minute trial runs everything, with your own `claude` and accounts, and no key."; buttons "Start a 30-minute trial" and "Enter a key…".
  - after a trial: title "The trial has ended"; body "Sessions keep running and their questions can still be answered. Enter a key to send more, or quit and reopen Drakar for another trial."; button "Enter a licence key…".
  - "Buy a licence" only when `isSelling`.
  - The draft stays in `ProjectSession.draft`; the card never touches it.
- [ ] **Step 5:** `LicensePane`: armada's, with `case licence` (title "Licence", symbol `key`) after `.updates`, and `"licence"` inserted after `"updates"` in `keepsPaneIdentifiersStable`. While `!isSelling`, the pane reads "Drakar is free while it is in beta. A licence will be a one-time purchase." and shows no Buy button and no trial button; key entry stays available.
- [ ] **Step 6:** Run `make -C apps/apple test-app`. Expected: all pass. Rerun any failure in `CapabilityProbe`, `AgentSession` opened-elsewhere or `SessionMoves` alone first.
- [ ] **Step 7:** Commit: `feat(apple): the licence gate on sending work, open while nothing is sold`.

### Task 7: The checkable claim

**Files:**
- Modify: `scripts/audit-network.sh`, root `Makefile` (`audit-release`), `PLAN.md` §5, `README.md`
- Create: `SECURITY.md`

**Interfaces:**
- Produces: `scripts/audit-network.sh [--running] [--app path/to/Drakar.app]`; `make audit-release` runs it with `--app apps/apple/.build/Release/Drakar.app`.

- [ ] **Step 1:** Add armada's binary sweep (the `nm -u`/`otool -L` loop over every Mach-O, with a symbol allowance table) under a "Bundle" heading that runs only with `--app`. The allowance table is Sparkle's frameworks and helpers, with the symbols armada measured. Measure Drakar's own: run the sweep with an empty table against Task 4's bundle and allow exactly what is in Sparkle's binaries. A network symbol in `Drakar` or `DrakarHost` themselves is a FAIL; `NWListener` (the IDE bridge) and the Unix socket are already asserted by the "Sources" section, so the sweep leaves those two alone. Also assert that no entitlements are embedded: `codesign -d --entitlements - "$app"` prints no keys.
- [ ] **Step 2:** Run `scripts/audit-network.sh --app apps/apple/.build/Release/Drakar.app`. Expected: all ok. Copy a bare `nc`-linked dylib into the bundle's Frameworks folder in a scratch copy and rerun. Expected: FAIL naming it. Delete the scratch copy.
- [ ] **Step 3:** Add "…or Sparkle, once you said yes to update checks" to the claim's last sentence in the script header, PLAN.md §5 and the new `SECURITY.md`, which follows armada's structure: the claim, how to check it yourself, how to report.
- [ ] **Step 4:** Commit: `test: the network claim checked against the built bundle, Sparkle the one allowance`.

### Task 8: The licence Worker

**Files:**
- Create: `apps/api/` from armada's `apps/api` (`src/*`, `test/*`, `package.json`, `tsconfig.json`, `vitest.config.ts`, `wrangler.jsonc`, `worker-configuration.d.ts`), with `migrations/0001_licenses.sql` replacing armada's four
- Modify: root `Makefile` (`api-deploy`, `api-test`; `test` grows `pnpm -C apps/api test`), `scripts/push-worker-secrets.mjs` (+ test, armada's)

**Interfaces:**
- Produces: a Worker `drakar-api` on `api.drakar.mgcrea.io`; D1 `drakar-licenses` (and `drakar-licenses-test` in `env.test`, `"routes": []`); vars `CURRENT_MAJOR "1"`, `EXPECTED_PRICE_ID ""` (production fails closed: nothing is fulfilled until Phase 4 sets it), `SITE_URL https://drakar.mgcrea.io`, `LICENSE_FROM_EMAIL licences@mgcrea.io`; `database_id` left out until Phase 2 creates the databases; rate-limit namespace ids 5001/5002 (prod) and 6001/6002 (test), clear of armada's 3001–4002 (check bastion's and cupertino's `wrangler.jsonc` for clashes first).

- [ ] **Step 1:** Copy armada's `apps/api`, renamed. Write `0001_licenses.sql` as the schema armada's 0001–0004 produce together, taken from armada's `src/schema.ts` (which its `schema.test.ts` checks against the migrations). Keep `schema.test.ts`, pointed at the single file.
- [ ] **Step 2:** Run `pnpm install && pnpm -C apps/api test`. Expected: every armada test passes under Drakar's names, the fail-closed price guard included (`EXPECTED_PRICE_ID` empty → refused).
- [ ] **Step 3:** Copy `api-deploy` (it refuses while migrations are unapplied) and `revocations` from armada's root Makefile, with the database names changed. Run `make -n api-deploy`. Expected: the commands print and nothing runs.
- [ ] **Step 4:** Commit: `feat(api): the licence Worker, armada's, failing closed until a price exists`.

### Task 9: The site skeleton

**Files:**
- Create: `apps/website/` with `package.json`, `astro.config.mjs`, `tsconfig.json`, `wrangler.jsonc`, `src/layouts/Layout.astro`, `src/pages/index.astro`, `src/pages/privacy.astro`, `src/pages/404.astro`, `src/styles/tokens.css`, `public/_redirects`, `public/_headers`, `public/robots.txt`, `public/favicon.svg` (from `design/drakar-icon.svg`)
- Modify: root `Makefile` (`site-build`, `site-deploy`, `deploy`; remove the "No deploy block yet" comment)

**Interfaces:**
- Consumes: `/thanks` and the revoked page are served by the Worker (Task 8), so the site has no `/thanks`.
- Produces: `dist/_redirects` with `/appcast.xml`, `/download`, `/checksum` and `/releases` as 302s to `github.com/mgcrea/drakar/releases/...` (armada's file and comments, renamed). It has no `/buy` line until Phase 4.

- [ ] **Step 1:** Take armada's Astro config, layout, tokens and `_headers`, and drop the twenty marketing components. `index.astro` is one screen: the name, README's first sentence, "Download for macOS 26" → `/download`, "Source on GitHub" → `/releases`'s repo, and "Free while in beta". `privacy.astro` states the claim from Task 7 and what Sparkle sends once update checks are on: the version and macOS version, Sparkle's default, with no profile.
- [ ] **Step 2:** Run `pnpm -C apps/website build && cat apps/website/dist/_redirects`. Expected: the four 302 lines, no `/buy`, and no 301 anywhere.
- [ ] **Step 3:** Commit: `feat(website): the skeleton drakar.mgcrea.io needs to serve updates`.

### Task 10: CI, the release runbook, and the docs

**Files:**
- Create: `.github/workflows/ci.yml` (armada's, adapted), `docs/releasing.md` (armada's), `.claude/skills/cut-a-release/SKILL.md` (armada's)
- Modify: `PLAN.md` (§5 "Still to land" becomes what landed, §7.4 decided: Drakar's own key, §7.5 decided: $14.99 one-time with the 30-minute trial, not sold until Phase 4), `README.md` (Building gets the release targets; the distribution line says MIT on GitHub)

- [ ] **Step 1:** Adapt armada's `ci.yml`. Jobs: `node` (`pnpm test:scripts`, `pnpm -C apps/api test`, lint and format), `website` (build), `revocations` (`environment: production`, skipped on PRs, token on the step), `app` (macos: `make -C apps/apple sparkle test`, `make -C apps/apple format-swift-check`, `make audit`, `make changelog-check`; no `test-app`, which launches the app), `release-app` (`needs: [node, app, revocations]`, on `app-v*` only), `deploy-api` and `deploy-website` (both from `main`). Keep armada's action SHAs verbatim. Drop its screenshot and icon checks. `release-app` runs `make audit-release` after verify.
- [ ] **Step 2:** Run `actionlint .github/workflows/ci.yml`. Expected: no findings.
- [ ] **Step 3:** Copy `docs/releasing.md` and `cut-a-release`, with **tag before `main`** in both, since armada's skill gets the order backwards (`fleet-direct-conventions` SKILL.md, "Still open for armada"). The skill adds one Drakar step before tagging: confirm the release isn't being made from a running Drakar the owner is using (`make install-release` refuses anyway).
- [ ] **Step 4:** Update PLAN.md and README as listed. Run `bash ~/Projects/claude-skills/projects/apps/fleet-direct-conventions/scripts/survey.sh drakar ~/Projects/apps`. Expected: every ✗ from the 2026-10-28 run is now ✓, except "no app-v* tags" (Phase 3).
- [ ] **Step 5:** Commit: `ci: test, release and deploy, armada's jobs`.

---

## Phases 2–4: going public, the first release, selling

Not for an implementer subagent. The executing session asks the owner before each step.

The steps live in one tracked checklist, `docs/releasing.md`, "Once, before the first
release", in the order they must run; this plan no longer carries its own copy. Its first
version here was unsafe: it set the GitHub secrets and environments before creating D1, and
once `CLOUDFLARE_API_TOKEN` exists CI runs `make api-deploy` and the site's deploy on every
push to `main`, so the database id has to be committed first. The runbook also holds what
this list lacked: the `production` environment admitting `app-v*` tags, the release secrets
going in the `release` environment, every place the placeholder key lives, the site going up
in Phase 2 under its `noindex` (which comes out in the Phase 3 release commit), and the
refund terms the owner confirms before Phase 4 opens the store.
