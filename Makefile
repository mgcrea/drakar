# One entrypoint at the repo root. This is not a build system: the whole build is `make` in
# apps/apple, and this file forwards to it so the commands are the same from either place.
#
# Why forwarding is safe: `make -C` chdirs *before reading the makefile* (man make: "Change
# to directory dir before reading the makefiles or doing anything else"), so every relative
# path in apps/apple/Makefile — .build/, Packages/, Drakar.xcodeproj — resolves exactly as
# it does when you cd there yourself. That matters more than it looks: xcodebuild has no
# notion of a project root and resolves every path against the process working directory.
#
# Command-line variables reach the sub-make through MAKEFLAGS, so `make run
# ARGS='-drakar.settingsPane about'` works from here.
#
# It also deploys what this repo serves, both halves, from the blocks fleet-ship-conventions
# owns: the licence Worker (apps/api, `api-deploy`) and the website (apps/website,
# `site-deploy`). `make deploy` runs the two in that order.

APPLE := apps/apple

# Read out of the sub-makefile's own `## ` help comments, so a target added there is
# forwardable from here without touching this file.
#
# Deliberately NOT copied from its .PHONY list: that list is maintained by hand and drifts.
# Every name this file defines itself is dropped, read the same way out of this file's
# own `## ` comments, so a root target is never also a forwarding rule: `help`, and
# `build-release`, which apps/apple has too (there the unsigned Release build, here the
# shippable one that calls it). DIVERGES from armada, which lists its root names by hand.
# Every root target carries a `## ` comment, which is what makes this complete.
#
# The `##` goes through HASH: /usr/bin/make on macOS (and so on every macOS CI runner) is
# GNU make 3.81, which reads a literal `#` inside `$(shell ...)` in an assignment as a
# comment and aborts with "unterminated call to function `filter-out'". Homebrew's make 4.x
# parses it fine, which is why the bug is invisible locally. Check with
# `/usr/bin/make -n help` after touching this line.
HASH := \#
ROOT_TARGETS := $(shell sed -n 's/^\([a-zA-Z0-9_-]*\):.*$(HASH)$(HASH).*/\1/p' \
	$(firstword $(MAKEFILE_LIST)))
APPLE_TARGETS := $(filter-out $(ROOT_TARGETS),\
	$(shell sed -n 's/^\([a-zA-Z0-9_-]*\):.*$(HASH)$(HASH).*/\1/p' $(APPLE)/Makefile))

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@echo "  \033[1mdrakar\033[0m"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  \033[1mapp\033[0m — forwarded to $(APPLE), so 'make build' here is 'make build' there"
	@$(MAKE) --no-print-directory -C $(APPLE) help

audit: ## Check the network claim against the sources (scripts/audit-network.sh)
	@scripts/audit-network.sh

audit-running: ## The same, plus the running app: its sockets, lock files and token
	@scripts/audit-network.sh --running

# The same script against the artifact that ships. No `bundle` prerequisite on purpose:
# rebuilding here would replace the signed, stapled bundle it exists to inspect with an
# unsigned one. RELEASE_APP is defined below; recipes expand late, so it is set by then.
audit-release: ## The same, plus the built Release bundle: every Mach-O, Sparkle's defaults, the signatures
	@SPARKLE_EXPECTED=1 scripts/audit-network.sh --app "$(RELEASE_APP)"

extension-diff: ## What the installed VS Code extension changed since the reviewed snapshot
	@scripts/extension-surface.sh

extension-accept: ## Make the installed extension the reviewed snapshot (ledger updated first)
	@scripts/extension-surface.sh --accept

# ── Changelog ─────────────────────────────────────────────────────────────────
#
# CHANGELOG.md → Changelog.swift, the What's New pane's data. Root-level because the
# source is at the root and the output is in apps/apple. `changelog-check` is the CI
# gate: a stale Changelog.swift fails there rather than shipping notes that describe a
# different build.
#
# DIVERGES from armada, whose two targets also render its website's release cards.
# Drakar has no website half yet, so they write and check Changelog.swift alone.

changelog: ## Regenerate Changelog.swift from CHANGELOG.md
	@node scripts/generate-changelog.mjs

changelog-check: ## Fail if Changelog.swift is stale against CHANGELOG.md
	@node scripts/generate-changelog.mjs --check

# node:test for scripts/: the CHANGELOG parse the appcast, the release body and the
# What's New pane share, and the Sparkle signature check `appcast` will run. Not called
# `test`, which runs this and every other suite (below).
test-scripts: ## Run the Node tests under scripts/
	@pnpm test:scripts

# Every suite that runs offline: scripts/, the licence Worker (in workerd, against a local
# D1), and DrakarKit (apps/apple `test`). Root-level because two of the three are not
# apps/apple's, and it carries a `## ` comment, so ROOT_TARGETS drops `test` from
# APPLE_TARGETS: forwarded, it would run only the package suite under a name that promises
# all of them.
#
# DIVERGES from armada, whose `test` runs apps/apple's `unit` and then its package `test`.
# Drakar's apps/apple has no `unit`; its hosted suite is `test-app`, which needs Xcode and
# launches the app, so it stays out of here as it stays out of apps/apple's own `test`.
#
# Cheapest first, and it stops at the first failure. `license-check` is not here: it
# needs a signing key, which a clone does not have.
test: ## Run every offline suite: scripts, the licence Worker, DrakarKit
	@pnpm test:scripts
	@pnpm -C apps/api test
	@$(MAKE) --no-print-directory -C $(APPLE) test

# ── Release ───────────────────────────────────────────────────────────────────
#
# The direct-distribution path bastion, cupertino and armada share: an unsigned Release
# build, signed inside out, notarized, stapled, re-zipped, and a one-item Sparkle appcast
# signed over the stapled zip. Root-level for the changelog's reason (it reads CHANGELOG.md
# and scripts/ here and writes into apps/apple/.build), so apps/apple/Makefile only ever
# builds.
#
# There is no bump or release script. A release is a commit, a signed `app-v<version>` tag,
# and the release-app job in CI, which runs build-release, verifies the artifact, then runs
# checksum and appcast. `make build-release` locally is a rehearsal, never how one ships.
#
# Drakar's own EdDSA key, not the one bastion, cupertino and armada share: every
# `generate_keys` and `sign_update` call that reads the keychain passes `--account drakar`.
# This is the first Makefile in the fleet to do so. `--ed-key-file`, CI's path, never
# consults the keychain, so it takes no account.

TEAM_ID     := 75QE9PRT3V
BUNDLE_ID   := io.mgcrea.Drakar
RELEASE_DIR := apps/apple/.build
RELEASE_APP ?= $(RELEASE_DIR)/Build/Products/Release/Drakar.app
# Deferred, so they follow RELEASE_APP if a caller overrides that.
RELEASE_SPARKLE = $(RELEASE_APP)/Contents/Frameworks/Sparkle.framework
RELEASE_HOST = $(RELEASE_APP)/Contents/Helpers/DrakarHost
RELEASE_ZIP := $(RELEASE_DIR)/Drakar.zip
APPCAST     := $(RELEASE_DIR)/appcast.xml
SPARKLE_TOOLS := apps/apple/Vendor/bin
SPARKLE_ACCOUNT := drakar
INSTALLED   := /Applications/Drakar.app
INFO_PLIST  := apps/apple/Drakar-Info.plist
LICENSE_SWIFT := apps/apple/Drakar/Licence/License.swift

# Both public keys shipped as this literal until the real ones replaced it on 2026-10-29,
# and `sign` still refuses a bundle that carries it, should it ever come back.
# ALLOW_PLACEHOLDER_KEYS=1 is the local rehearsal with a placeholder: it
# skips that refusal, says so, and signs with Apple Development even where a Developer ID
# is present, so what it makes can never be notarized and mistaken for a release.
PLACEHOLDER_KEY := PLACEHOLDER-SET-IN-PHASE-2
ALLOW_PLACEHOLDER_KEYS ?=

# Signing is switched OFF for the build and done by `sign` alone. Xcode's own signing step
# would sign with whatever Automatic resolves to, in whatever order it likes; the release
# has to be one identity, one order, and assertions after.
#
# DIVERGES from armada, whose apps/apple `build CONFIG=Release` this is: Drakar's
# apps/apple has a `build-release` for the Release build, so that is what is called.
bundle: ## Build an unsigned Release Drakar.app, then sign it
	@$(MAKE) --no-print-directory -C $(APPLE) build-release \
		XCARGS="$(XCARGS) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
	@$(MAKE) --no-print-directory sign

# Inside out: Sparkle's Updater.app, then Autoupdate, then the framework, then the session
# host in Contents/Helpers, then the app. A signature over a bundle is a signature over its
# contents, so anything signed after the wrapper invalidates it.
#
# Never `--deep`. It re-signs nested code with the OUTER identity and options and drops
# nested designated requirements; Apple documents it as unsuitable for signing.
# `codesign --verify --deep` below is a different verb.
#
# DIVERGES from armada: no entitlements, on anything. Armada names one (the microphone, for
# voice); Drakar has no voice and no speech framework, and needs none. Bastion's precedent:
# an empty permission set that is true by construction is checkable, one arrived at by
# deletion is not. So `sign` refuses while any .entitlements file exists in apps/apple, and
# asserts after that the signed app and host carry none.
#
# DIVERGES from armada: DrakarHost is signed with an explicit `--identifier`. It is a bare
# executable, so codesign infers its identifier: from the Info.plist section Xcode embeds
# in it today (io.mgcrea.Drakar.DrakarHost), from its file name without one, which is
# what the linker's ad-hoc signature carries. PeerSignature.swift derives the app's
# identifier from the host's by dropping `.DrakarHost`, and lets nobody in when the suffix
# is missing, so a release host signed as plain `DrakarHost` would refuse every session.
# Named here rather than inferred, and asserted after, with the app's.
#
# DIVERGES from armada: both public keys are refused while they are the placeholder, at
# the top, before anything is signed. Armada's only check is the shape of SUPublicEDKey, at
# the end. The licence key is grepped out of License.swift, where Task 5 puts it.
#
# The identity block is ONE shell invocation because `$$id` has to survive across the
# codesign calls.
sign: ## Sign the Release bundle inside out (Developer ID if present, else Apple Development)
	@test -d "$(RELEASE_APP)" || { echo "  no $(RELEASE_APP) — run 'make bundle'" >&2; exit 1; }
	@test -d "$(RELEASE_SPARKLE)" || { echo "  no Sparkle.framework in $(RELEASE_APP) — the updater is missing" >&2; exit 1; }
	@test -f "$(RELEASE_HOST)" || { echo "  no Contents/Helpers/DrakarHost in $(RELEASE_APP) — the session host is missing" >&2; exit 1; }
	@found=$$(find apps/apple \( -name .build -o -name Vendor \) -prune -o -name '*.entitlements' -print); \
	[ -z "$$found" ] || { echo "  refusing to sign: Drakar ships no entitlements, but these exist:" >&2; \
		printf '    %s\n' $$found >&2; exit 1; }
	@key=$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$(RELEASE_APP)/Contents/Info.plist" 2>/dev/null); \
	if [ "$$key" = "$(PLACEHOLDER_KEY)" ]; then \
		if [ "$(ALLOW_PLACEHOLDER_KEYS)" = 1 ]; then \
			echo "  !! SUPublicEDKey is the placeholder — signing anyway (ALLOW_PLACEHOLDER_KEYS=1); this build can never be updated"; \
		else \
			echo "  SUPublicEDKey is the placeholder ($(PLACEHOLDER_KEY)), not Drakar's key." >&2; \
			echo "  ALLOW_PLACEHOLDER_KEYS=1 signs a local rehearsal anyway." >&2; \
			exit 1; \
		fi; \
	fi
	@if [ ! -f "$(LICENSE_SWIFT)" ]; then \
		echo "  LicenseKey.publicKey: skipped: no License.swift"; \
	else \
		key=$$(sed -n 's/.*static let publicKey[^=]*= *"\([^"]*\)".*/\1/p' "$(LICENSE_SWIFT)" | head -n 1); \
		test -n "$$key" || { echo "  could not read LicenseKey.publicKey out of $(LICENSE_SWIFT)" >&2; exit 1; }; \
		if [ "$$key" = "$(PLACEHOLDER_KEY)" ]; then \
			if [ "$(ALLOW_PLACEHOLDER_KEYS)" = 1 ]; then \
				echo "  !! LicenseKey.publicKey is the placeholder — signing anyway (ALLOW_PLACEHOLDER_KEYS=1); no licence key can verify"; \
			else \
				echo "  LicenseKey.publicKey is the placeholder ($(PLACEHOLDER_KEY)), not Drakar's licence key." >&2; \
				echo "  ALLOW_PLACEHOLDER_KEYS=1 signs a local rehearsal anyway." >&2; \
				exit 1; \
			fi; \
		fi; \
	fi
	@if [ "$(ALLOW_PLACEHOLDER_KEYS)" = 1 ]; then \
		id=""; why="ALLOW_PLACEHOLDER_KEYS=1 is a rehearsal"; \
	else \
		id=$$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $$2; exit}'); \
		why="no Developer ID Application certificate"; \
	fi; \
	if [ -z "$$id" ]; then \
		id=$$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $$2; exit}'); \
		echo "  !! $$why — signing with Apple Development."; \
		echo "     This build will NOT notarize and will not run on another Mac."; \
	fi; \
	test -n "$$id" || { echo "  no codesigning identity at all" >&2; exit 1; }; \
	codesign --force --options runtime --timestamp --sign "$$id" \
		"$(RELEASE_SPARKLE)/Versions/B/Updater.app" && \
	codesign --force --options runtime --timestamp --sign "$$id" \
		"$(RELEASE_SPARKLE)/Versions/B/Autoupdate" && \
	codesign --force --options runtime --timestamp --sign "$$id" \
		"$(RELEASE_SPARKLE)" && \
	codesign --force --options runtime --timestamp --sign "$$id" \
		--identifier $(BUNDLE_ID).DrakarHost "$(RELEASE_HOST)" && \
	codesign --force --options runtime --timestamp --sign "$$id" "$(RELEASE_APP)"
	@codesign --verify --deep --strict --verbose=1 "$(RELEASE_APP)"
	@for code in "$(RELEASE_APP)" "$(RELEASE_HOST)"; do \
		codesign -d --entitlements - --xml "$$code" 2>/dev/null | grep -q '<key>' \
			&& { echo "  $$code carries entitlements — Drakar ships none" >&2; exit 1; }; \
	done; \
	echo "  no entitlements on the app or the host"
	@codesign -dv "$(RELEASE_APP)" 2>&1 | grep -qx 'Identifier=$(BUNDLE_ID)' \
		|| { echo "  the app is not signed as $(BUNDLE_ID)" >&2; exit 1; }
	@codesign -dv "$(RELEASE_HOST)" 2>&1 | grep -qx 'Identifier=$(BUNDLE_ID).DrakarHost' \
		|| { echo "  DrakarHost is not signed as $(BUNDLE_ID).DrakarHost — it would let no session in" >&2; exit 1; }
	@echo "  signed as $(BUNDLE_ID), host as $(BUNDLE_ID).DrakarHost"
	@# The hardened runtime is on and nothing disables library validation, so a Sparkle
	@# signed by another team fails at dlopen — at launch, on a user's Mac, long after this.
	@# Assert the team here, where the message is readable.
	@codesign -dv --verbose=2 "$(RELEASE_SPARKLE)" 2>&1 | grep -q 'TeamIdentifier=$(TEAM_ID)' \
		|| { echo "  Sparkle is not signed by $(TEAM_ID) — library validation will reject it" >&2; exit 1; }
	@echo "  Sparkle signed by $(TEAM_ID)"
	@# A bundle whose public key is not a real one can verify no appcast, so it can never be
	@# updated, and the only moment anyone would notice is the release that needed to ship.
	@# The placeholder already stopped above unless ALLOW_PLACEHOLDER_KEYS=1 let it through.
	@key=$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$(RELEASE_APP)/Contents/Info.plist" 2>/dev/null); \
	if [ "$(ALLOW_PLACEHOLDER_KEYS)" = 1 ] && [ "$$key" = "$(PLACEHOLDER_KEY)" ]; then \
		echo "  SUPublicEDKey shape check skipped: the placeholder (ALLOW_PLACEHOLDER_KEYS=1)"; \
	else \
		printf '%s\n' "$$key" | grep -qE '^[A-Za-z0-9+/]{43}=$$' \
			|| { echo "  SUPublicEDKey is not an ed25519 public key — this build could never be updated" >&2; exit 1; }; \
	fi
	@echo "  size: $$(du -sh "$(RELEASE_APP)" | cut -f1)"

notarize: ## Submit the signed bundle to Apple and staple the ticket
	@# All three, not just the first: bastion's guard once checked only AC_KEY_ID, and
	@# notarytool then failed on an empty --key after a minute of zipping.
	@for v in AC_KEY_ID AC_ISSUER_ID AC_KEY_PATH; do \
		eval "value=\$$$$v"; \
		[ -n "$$value" ] || { echo "set AC_KEY_ID, AC_ISSUER_ID and AC_KEY_PATH first ($$v is empty)" >&2; exit 1; }; \
	done
	@ditto -c -k --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"
	@xcrun notarytool submit "$(RELEASE_ZIP)" --wait \
		--key "$$AC_KEY_PATH" --key-id "$$AC_KEY_ID" --issuer "$$AC_ISSUER_ID"
	@xcrun stapler staple "$(RELEASE_APP)"
	@# Re-zipped AFTER stapling: the ticket is written into the bundle, so the archive made
	@# before it carries none, and Gatekeeper on a Mac that is offline would reject it.
	@# Shipping the first zip is the classic mistake here.
	@ditto -c -k --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"
	@echo "  stapled: $(RELEASE_ZIP)"

# Sequential sub-makes rather than `build-release: bundle notarize`, because prerequisites
# may run in parallel under -j and notarizing a bundle that is still being signed staples a
# ticket to a cdhash that is about to change.
build-release: ## Build, sign and notarize a shippable Drakar.app
	@$(MAKE) --no-print-directory bundle
	@$(MAKE) --no-print-directory notarize

# Bastion's format, not cupertino's: the website serves /checksum raw, so the file is the
# bare digest and a newline (65 bytes), never "<hash>  Drakar.zip".
#
# DIVERGES from armada, which writes it in a CI step: here it is a target, so CI and a
# rehearsal write it the same way. Run it after `notarize`, never before: notarize
# re-creates the zip once the ticket is stapled, and the checksum, the appcast and the
# upload must all describe those bytes.
checksum: ## Write Drakar.zip.sha256, the bare digest /checksum serves
	@test -f "$(RELEASE_ZIP)" || { echo "no $(RELEASE_ZIP) — run 'make build-release' first" >&2; exit 1; }
	@shasum -a 256 "$(RELEASE_ZIP)" | cut -d' ' -f1 > "$(RELEASE_ZIP).sha256"
	@test "$$(wc -c < "$(RELEASE_ZIP).sha256" | tr -d ' ')" -eq 65 \
		|| { echo "  !! $(RELEASE_ZIP).sha256 is not a bare 64-char digest" >&2; rm -f "$(RELEASE_ZIP).sha256"; exit 1; }
	@echo "  checksum: $$(cat "$(RELEASE_ZIP).sha256")"

# One item, never a history: Sparkle only needs the newest, and a feed that accumulates
# releases has to stay consistent with every zip still hosted.
#
# A RELEASE ASSET, not a site asset, with the enclosure at the tag's own upload. Publishing
# a release then never needs a site deploy, which is why /appcast.xml on the website can be
# a permanent 302, and SUFeedURL is baked into every binary ever shipped, so it has to
# outlive any decision about where files live.
#
# Signed over the STAPLED zip, which is why this is not folded into `notarize`: a signature
# made earlier is valid over an archive with no ticket, so Sparkle would accept the
# download and Gatekeeper would refuse it on first launch.
#
# The guards are the union of the siblings': cupertino's `set -e` with a trap that removes
# the key file on every exit path and its version-selected notes, which exit non-zero on a
# missing or empty section; bastion's enclosure length and its hard stop on an empty
# edSignature, the failure that otherwise ships a well-formed feed every installed updater
# refuses, forever. The length is `wc -c` rather than `stat`, whose flags differ between
# BSD and the GNU coreutils this Mac puts first on PATH.
#
# And checked against the key the app trusts, which nothing else in the pipeline does.
# `sign` only asserts that SUPublicEDKey is shaped like a key, and sign_update signs with
# whichever private key it is handed: the keychain's `drakar` item here,
# SPARKLE_ED_PRIVATE_KEY in CI. A mismatch is a well-formed feed with a valid signature
# that every installed copy refuses, and the fix could only reach them as the update they
# are refusing. So the extracted value has to be exactly one signature, and
# scripts/verify-update-signature.mjs has to accept it over the zip for the key read out of
# the built Info.plist, before the feed is written.
appcast: ## Sign the stapled zip and write a one-item appcast
	@test -f "$(RELEASE_ZIP)" || { echo "no $(RELEASE_ZIP) — run 'make build-release' first" >&2; exit 1; }
	@$(MAKE) --no-print-directory -C $(APPLE) sparkle
	@set -e; \
	trap 'rm -f $(RELEASE_DIR)/sparkle.key' EXIT INT TERM; \
	if [ -n "$$SPARKLE_ED_PRIVATE_KEY" ]; then \
		: "# CI. The key reaches sign_update through a file, never argv: a private"; \
		: "# key on a command line is readable by every other process via ps."; \
		umask 077; printf '%s' "$$SPARKLE_ED_PRIVATE_KEY" > $(RELEASE_DIR)/sparkle.key; \
		raw=$$($(SPARKLE_TOOLS)/sign_update --ed-key-file $(RELEASE_DIR)/sparkle.key "$(RELEASE_ZIP)"); \
		rm -f $(RELEASE_DIR)/sparkle.key; \
	else \
		: "# A developer's Mac, where generate_keys keeps the key in the keychain,"; \
		: "# under Drakar's own account rather than the fleet's shared default item."; \
		raw=$$($(SPARKLE_TOOLS)/sign_update --account $(SPARKLE_ACCOUNT) "$(RELEASE_ZIP)"); \
	fi; \
	signature=$$(printf '%s' "$$raw" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/'); \
	test -n "$$signature" && [ "$$signature" != "$$raw" ] \
		|| { echo "  !! sign_update produced no edSignature; not shipping a feed" >&2; exit 1; }; \
	: "# sed works a line at a time, so output of more than one line leaves the other"; \
	: "# lines in the value, and two signature lines leave two. One line holding one"; \
	: "# 64-byte signature in base64, or no feed."; \
	[ "$$(printf '%s\n' "$$signature" | wc -l | tr -d ' ')" = 1 ] \
		&& printf '%s\n' "$$signature" | grep -Eq '^[A-Za-z0-9+/]{86}==$$' \
		|| { echo "  !! sign_update's output is not exactly one ed25519 signature; not shipping a feed" >&2; exit 1; }; \
	edkey=$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$(RELEASE_APP)/Contents/Info.plist"); \
	node scripts/verify-update-signature.mjs "$(RELEASE_ZIP)" "$$signature" "$$edkey" \
		|| { echo "  !! the signature does not verify against the app's SUPublicEDKey; every installed copy would refuse this update" >&2; exit 1; }; \
	version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(RELEASE_APP)/Contents/Info.plist"); \
	build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(RELEASE_APP)/Contents/Info.plist"); \
	length=$$(wc -c < "$(RELEASE_ZIP)" | tr -d ' '); \
	notes=$$(node scripts/changelog-notes.mjs "$$version" CHANGELOG.md); \
	printf '%s\n' \
		'<?xml version="1.0" encoding="utf-8"?>' \
		'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
		'  <channel>' \
		'    <title>Drakar</title>' \
		'    <link>https://drakar.mgcrea.io/appcast.xml</link>' \
		'    <item>' \
		"      <title>Drakar $$version</title>" \
		"      <pubDate>$$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>" \
		"      <sparkle:version>$$build</sparkle:version>" \
		"      <sparkle:shortVersionString>$$version</sparkle:shortVersionString>" \
		'      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>' \
		"      <description><![CDATA[$$notes]]></description>" \
		"      <enclosure url=\"https://github.com/mgcrea/drakar/releases/download/app-v$$version/Drakar.zip\"" \
		"                 length=\"$$length\"" \
		'                 type="application/octet-stream"' \
		"                 sparkle:edSignature=\"$$signature\" />" \
		'    </item>' \
		'  </channel>' \
		'</rss>' > "$(APPCAST)"
	@xmllint --noout "$(APPCAST)" \
		|| { echo "  !! appcast.xml is not well-formed; not shipping it" >&2; rm -f "$(APPCAST)"; exit 1; }
	@echo "  appcast: $(APPCAST)"

# Deliberately NOT dependent on `bundle`: re-signing would invalidate the stapled ticket
# this exists to install.
#
# DIVERGES from armada, which quits the running app here. Drakar is never quit by a make
# target: quitting it ends the owner's live sessions mid-turn (the rule that also keeps
# `make run` and `make quit` out of every release step). So this refuses while any Drakar
# is running, and the person quits it when no turn is in flight. A running DrakarHost is
# fine: the session host keeps running from its open inode across a bundle replacement and
# the new app attaches (docs/session-host.md). Only the release bundle id is accepted at
# /Applications; armada also takes its debug id, which Drakar does not have.
install-release: ## Install the notarized Release build into /Applications (refuses while Drakar runs)
	@test -d "$(RELEASE_APP)" || { echo "no $(RELEASE_APP) — run 'make build-release' first" >&2; exit 1; }
	@xcrun stapler validate "$(RELEASE_APP)" >/dev/null 2>&1 \
		|| { echo "$(RELEASE_APP) carries no stapled ticket — run 'make build-release'" >&2; exit 1; }
	@if [ -d "$(INSTALLED)" ]; then \
		id=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(INSTALLED)/Contents/Info.plist" 2>/dev/null); \
		case "$$id" in \
			$(BUNDLE_ID)) ;; \
			*) echo "refusing to replace $(INSTALLED): its identifier is '$$id'" >&2; exit 1 ;; \
		esac; \
	fi
	@if pgrep -x Drakar >/dev/null 2>&1; then \
		echo "refusing to install: Drakar is running. Quit it yourself once no turn is running, then rerun." >&2; \
		exit 1; \
	fi
	@rm -rf "$(INSTALLED)"
	@ditto "$(RELEASE_APP)" "$(INSTALLED)"
	@spctl -a -t exec "$(INSTALLED)" >/dev/null 2>&1 \
		&& echo "  installed $(INSTALLED) — Gatekeeper accepts it" \
		|| echo "  installed $(INSTALLED) — NOT accepted by Gatekeeper; it will not run on another Mac"

# Sparkle stores its signing keys in the login keychain under https://sparkle-project.org,
# one item per account. Bastion, cupertino and armada share the default item; Drakar has
# its own, `--account drakar`, decided in the direct-distribution spec: with no copies
# installed yet a separate key costs nothing, while rotating a shared one later would take
# two releases. Made 2026-10-29 (`generate_keys --account drakar`); nothing here generates
# one.
#
# That private key is the most dangerous secret this project has: together with the
# Developer ID certificate it is enough to hand every user a new version of an app that
# drives Claude Code on their Mac. It belongs in the keychain and in one repository secret,
# never in an org-wide one and never anywhere a pull_request workflow can read it.
#
# DIVERGES from armada: refuses first while SUPublicEDKey is the placeholder, which has no
# keychain half to compare with.
sparkle-keys: ## Assert the keychain's drakar EdDSA key is the one the app ships, and how to export it for CI
	@$(MAKE) --no-print-directory -C $(APPLE) sparkle
	@want=$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' $(INFO_PLIST)); \
	[ "$$want" != "$(PLACEHOLDER_KEY)" ] || { \
		echo "  SUPublicEDKey in $(INFO_PLIST) is still the placeholder." >&2; \
		echo "  $(SPARKLE_TOOLS)/generate_keys --account $(SPARKLE_ACCOUNT) -p prints the one to put there." >&2; \
		exit 1; }
	@security find-generic-password -s "https://sparkle-project.org" -a $(SPARKLE_ACCOUNT) >/dev/null 2>&1 \
		|| { echo "  no '$(SPARKLE_ACCOUNT)' Sparkle key in this login keychain — the shared default item is not Drakar's" >&2; exit 1; }
	@# Asserted, not printed for someone to compare by eye. The export below is how CI gets
	@# its signing key, and a key that is not SUPublicEDKey's other half signs updates no
	@# installed copy will accept. `make appcast` checks the same thing again over the real
	@# zip; this is the moment before the secret is set.
	@want=$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' $(INFO_PLIST)); \
	got=$$($(SPARKLE_TOOLS)/generate_keys --account $(SPARKLE_ACCOUNT) -p | grep -Eo '[A-Za-z0-9+/]{43}=' | tail -n 1); \
	if [ -n "$$got" ] && [ "$$got" = "$$want" ]; then \
		echo "  ok    the keychain's '$(SPARKLE_ACCOUNT)' public key is SUPublicEDKey in $(INFO_PLIST)"; \
		echo "        $$got"; \
	else \
		echo "  FAIL  the keychain's '$(SPARKLE_ACCOUNT)' public key is $${got:-unreadable}, but $(INFO_PLIST) trusts $$want" >&2; \
		echo "        do not export this key for CI: nothing it signs would install" >&2; \
		exit 1; \
	fi
	@echo ""
	@echo "  To give CI the private key:"
	@echo "    $(SPARKLE_TOOLS)/generate_keys --account $(SPARKLE_ACCOUNT) -x sparkle_key.pem   # -x EXPORTS; without it you get a NEW key"
	@echo "    gh secret set SPARKLE_ED_PRIVATE_KEY -R mgcrea/drakar --env release < sparkle_key.pem   # the release environment, as ci.yml's release-app reads it"
	@echo "    make sparkle-key-shred"

# Not `rm -P`: that flag is BSD-only, and a Mac with Homebrew's coreutils ahead of /bin on
# PATH gets GNU rm, which errors on it — leaving the private key in the working tree after
# the one command whose whole job was to remove it. Overwrite first, then unlink by
# absolute path. Cupertino's target, by way of armada's.
#
# DIVERGES from armada: the byte count goes through `tr -d ' '`. BSD `wc -c` pads it with
# spaces, so armada's unquoted `bs=$$(wc -c < ...)` splits into `bs=` and the number on
# CI's Macs, dd fails into /dev/null, and the key is unlinked without being overwritten.
# And dd's status is checked: a dd that fails for any other reason (an unreadable or empty
# file, whose zero byte count dd refuses) leaves the key where it is and fails loudly,
# rather than reporting an overwrite that never happened.
sparkle-key-shred: ## Overwrite and remove an exported sparkle_key.pem
	@if [ ! -f sparkle_key.pem ]; then \
		echo "  no sparkle_key.pem here — nothing to shred"; \
	else \
		dd if=/dev/urandom of=sparkle_key.pem bs=$$(wc -c < sparkle_key.pem | tr -d ' ') count=1 \
			conv=notrunc 2>/dev/null \
			|| { echo "  !! could not overwrite sparkle_key.pem; it was not removed" >&2; exit 1; }; \
		/bin/rm -f sparkle_key.pem; \
		echo "  sparkle_key.pem overwritten and removed — the keychain copy is untouched"; \
	fi

.PHONY: bundle sign notarize build-release checksum appcast install-release sparkle-keys \
	sparkle-key-shred

# ── Licence ───────────────────────────────────────────────────────────────────
#
# The other half of the money loop. A refund or a lost chargeback marks the row in the
# Worker's D1; nothing reaches the app until this bakes the list into the next build,
# because the app is not allowed to ask anyone anything at runtime. Until Phase 2 creates
# the database there is nothing to read, and the generator says so and keeps the list
# empty.
revocations: ## Rewrite the baked-in revocation list from the Worker's D1
	@node scripts/generate-revocations.mjs

# JavaScript mints the keys and Swift accepts them, so the disagreement that would cost
# money lives between the two — and neither side's own tests can see it. This compiles the
# real License.swift and feeds it keys signed with the real private key from .env, which is
# also what proves that key matches the public one compiled in.
#
# DIVERGES from armada: while the compiled key is the placeholder (as it was until
# 2026-10-29), the check runs against a throwaway pair passed on the command line, which
# proves the two languages agree and nothing about .env:
#   node scripts/mint-license.mjs --keygen
#   LICENSE_SIGNING_KEY=… LICENSE_PUBLIC_KEY=… make license-check
# scripts/license-check.mjs refuses LICENSE_PUBLIC_KEY while a real key is compiled in.
license-check: ## Prove a minted licence key verifies in the app's own verifier
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/license-check \
		apps/apple/Drakar/Licence/License.swift apps/apple/Drakar/Licence/Revocations.swift \
		scripts/license-check.swift
	@node --env-file-if-exists=.env scripts/license-check.mjs \
		| apps/apple/.build/license-check

.PHONY: revocations license-check

# ── Website ───────────────────────────────────────────────────────────────────
#
# drakar.mgcrea.io: the vanity redirects the app depends on (/appcast.xml is SUFeedURL),
# a landing page and the privacy page. Armada's block.
#
# `pnpm -C apps/website release`, the line every sibling's recipe carries, so a
# fix reads across from any of them. Never a bare `pnpm deploy`: `deploy` is a
# pnpm builtin that exits 0 and ships nothing, which is why the package script is
# called `release` fleet-wide.
# The curl is the part that proves a deploy happened rather than that a command
# returned, and `--max-time` is api-deploy's: a host that accepts the connection
# and never answers would otherwise hold the recipe, and a CI job, until the job's
# own timeout.
SITE_URL := https://drakar.mgcrea.io/

# DIVERGES from armada, which has no build-only target: this is the one that touches
# nothing outside the tree, so CI's verify job and a check of dist/_redirects can run it
# with no Cloudflare token.
site-build: ## Build the website into apps/website/dist, deploying nothing
	pnpm -C apps/website build

site-deploy: ## Build and publish the website to Cloudflare
	pnpm -C apps/website release
	@# `wrangler deploy` exiting 0 is not proof the site moved. This is.
	@curl -fsS --max-time 20 -o /dev/null $(SITE_URL)
	@echo "deployed $(SITE_URL)"

.PHONY: site-build site-deploy

# ── API ───────────────────────────────────────────────────────────────────────
#
# The licence Worker at api.drakar.mgcrea.io: Stripe's webhook in, a signed key out by
# email and on /thanks. Armada's target, which is bastion's with its one hard lesson.
#
# Nothing here has run against Cloudflare yet. Until Phase 2 creates drakar-licenses and
# puts its id in apps/api/wrangler.jsonc, `wrangler d1 migrations list` has no database to
# read, the grep below finds no "No migrations to apply", and api-deploy refuses.

API_URL := https://api.drakar.mgcrea.io/health

# Wrangler's d1 subcommands do not take `account_id` from wrangler.jsonc the way `deploy`
# does, and the token reaches three accounts, so without an explicit one they stop to ask,
# which inside a recipe is just a failure. The same value as wrangler.jsonc, which already
# documents it as public.
CF_ACCOUNT_ID := 0121e8859874c6fc0d674676e17d9f18

api-deploy: ## Build and publish the licence Worker, refusing on unapplied migrations
	@# Code expecting a table the database has not got deploys green and then fails
	@# on the first webhook: bastion's Worker spent four days answering 500 to
	@# every checkout that way, while the /health check below stayed 200. This
	@# refuses rather than applies; `pnpm -C apps/api migrate` stays deliberate.
	@CLOUDFLARE_ACCOUNT_ID=$(CF_ACCOUNT_ID) pnpm -C apps/api exec wrangler d1 migrations list drakar-licenses --remote 2>&1 \
		| grep -q 'No migrations to apply' \
		|| { echo 'refusing to deploy: unapplied migrations in apps/api - run: pnpm -C apps/api migrate'; exit 1; }
	pnpm -C apps/api release
	@# A green `wrangler deploy` does not prove the Worker answers. This does.
	@curl -fsS --max-time 20 -o /dev/null $(API_URL)
	@echo "deployed $(API_URL)"

# The Worker's suite on its own: Node for the minter and the schemas, workerd with a local
# D1 for the handlers. No Cloudflare account, no database id, no network.
api-test: ## Run the licence Worker's tests (vitest, workerd, a local D1)
	@pnpm -C apps/api test

# Sequential sub-makes rather than prerequisites: under -j they may run in parallel, and
# the Worker the site's /buy flow will land on has to be live first. Until Phase 2 creates
# the database, api-deploy refuses (see above) and this stops there; `make site-deploy`
# publishes the site on its own.
deploy: ## Deploy both halves: the licence Worker, then the website
	@$(MAKE) --no-print-directory api-deploy
	@$(MAKE) --no-print-directory site-deploy

.PHONY: api-deploy api-test deploy

# Explicit targets rather than a `%:` catch-all. A match-anything rule prints "'X' is up to
# date" instead of forwarding whenever the goal happens to name a file or directory at the
# root — and apps/ and docs/ are both real paths. Silent success is the one failure a
# delegator must never have.
$(APPLE_TARGETS):
	@$(MAKE) --no-print-directory -C $(APPLE) $@

.PHONY: help audit audit-running audit-release extension-diff extension-accept changelog changelog-check \
	test-scripts test $(APPLE_TARGETS)

# ─── directory goals ─────────────────────────────────────────────────────────
# A goal naming an existing directory is a target make considers already built, so
# `make docs` printed "Nothing to be done" and exited 0 — the silent success a mistyped
# goal must never have. Every root directory gets a rule that fails instead: phony, or
# make would still call it up to date, and read from the tree, so a directory added
# later is covered without editing this file.
ROOT_DIRS := $(filter-out $(APPLE_TARGETS),$(patsubst %/,%,$(wildcard */)))
$(ROOT_DIRS):
	@echo "make: '$@' is a directory, not a target. Try 'make help'." >&2; exit 2

.PHONY: $(ROOT_DIRS)
