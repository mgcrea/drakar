PROJECT = Amiral.xcodeproj
DERIVED_DATA = .build
BUNDLE_ID = io.mgcrea.Amiral

# The local packages, cheapest and most load-bearing first. AmiralKit is the only one today;
# later ones join this list, `test-all` and SWIFT_SRC as they arrive.
KIT = Packages/AmiralKit

# Mac only: a Developer ID app, never on the store, so there is no iOS destination and no
# `build-ios` (fleet-direct-conventions). DESTINATION stays a variable for an arm64/x86_64 pin.
SCHEME      ?= Amiral
APP_NAME    ?= Amiral
DESTINATION ?= platform=macOS

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ── Build ─────────────────────────────────────────────────────────────────────

build: ## Build the app in Debug
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA)

build-release: ## Build the app in Release
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA)

# ── Tests ─────────────────────────────────────────────────────────────────────
#
# `test` is the package suite and resolves nothing: AmiralKit has no dependencies and no
# networking, and its tests are where the model is argued about. `test-app` is the hosted
# suite, which needs Xcode and launches the app.

test: ## Run the AmiralKit tests (offline, no network, no Xcode)
	swift test --package-path $(KIT)

# `xcodebuild test` on the app scheme does NOT run the local SPM test targets -- it reports
# green while skipping them -- so `test-all` invokes each half explicitly. A suite that
# silently stops running is worse than one that fails.
test-app: ## Run the app target's tests
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA)

test-all: test test-app ## Every suite

# ── Build and relaunch ────────────────────────────────────────────────────────
#
# Copy-paste block, identical in every Mac app here. The canonical copy lives in
# ~/.claude/skills/appshot-screenshot-pipeline/assets/Makefile.run — take a fix there and
# bring it back, rather than letting the copies drift into that many dialects.
#
# It needs SCHEME, BUNDLE_ID and a `build` target. Everything else is a variable below, and
# an override goes *above* this block, never after it: `?=` only defers to an assignment
# make has already seen, so a later plain `=` wins and silently changes what runs.
#
# Quit before launching, because `open` on a bundle that is already running activates the
# existing process rather than launching the one just built. The build goes green, a window
# comes to the front, and it is yesterday's binary — which reads as "my fix did not work"
# rather than "the app never restarted". Graceful `quit` rather than `kill` so the app gets
# to save its documents; leading `-` so a first run with nothing to quit is not an error.
#
# The wait is not padding. `quit` returns before the process is gone, and `open` on a bundle
# that is still terminating fails outright with LaunchServices error -600 rather than
# launching — so without it the target trades a stale app for a broken one.
#
# The wait alone is not enough, though, which is what the retry below is for: `pgrep` going
# quiet means the process is gone, not that Launch Services has let go of it. It holds the
# dead instance's ASN a moment longer, and `open` resolves the bundle to that ASN and reports
# -600 for a process that has already exited. Retrying beats lengthening the wait, because it
# costs nothing in the common case where nothing was running to begin with.
#
# BUNDLE_ID is who the quit is addressed to, and is read out of the pbxproj rather than
# guessed from the scheme: the two need not agree, and an id nothing answers to turns the
# quit into a no-op that hands back the stale binary this block exists to prevent.
#
# QUIT_TIMEOUT is in quarter-seconds, so 40 is ten seconds.
APP_NAME      ?= $(SCHEME)
CONFIGURATION ?= Debug
APP_BUNDLE    ?= $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
QUIT_TIMEOUT  ?= 40

quit: ## Quit the running app and wait for the process to go
	-@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null
	@i=0; while pgrep -qx "$(APP_NAME)" && [ $$i -lt $(QUIT_TIMEOUT) ]; do \
		sleep 0.25; i=$$((i + 1)); \
	done

# The path goes through a shell variable rather than being named twice: a project that
# resolves its bundle with `xcodebuild -showBuildSettings` instead of a literal path would
# otherwise run xcodebuild a second time just to retry the `open`.
# ARGS reaches the app as launch arguments, which UserDefaults reads ahead of anything
# stored: `make run ARGS='-amiral.settingsPane about'` opens Settings on a pane without
# touching the stored defaults, so a forced pane never outlives the launch that forced it.
run: build quit ## Build and launch the app (ARGS='-amiral.settingsPane about')
	@app="$(APP_BUNDLE)"; open "$$app" --args $(ARGS) 2>/dev/null \
		|| { sleep 1; open "$$app" --args $(ARGS); }

# ── Formatting ────────────────────────────────────────────────────────────────
#
# `xcrun swift-format`, not Homebrew's SwiftFormat: it ships inside the toolchain, so every
# machine that can build the app already has it, and its lint mode carries enough rules that
# there is no SwiftLint to install either. Config is the repo root's `.swift-format`, which
# swift-format finds by walking up from each file -- no `--configuration` belongs here or in
# CI.
#
# Paths are relative to THIS makefile, because the root forwards with `make -C` and that
# chdirs first, and are spelled out rather than pointing `-r` at the parent. That is not
# tidiness: a SwiftPM package hides its dependencies' source under .build/checkouts, and
# swift-format has no ignore file, so a recursive walk from above reformats other people's
# code. The list is what `swift_src.py apps/apple` in fleet-apple-conventions computes;
# rerun it when a package is added.
SWIFT_SRC := \
	Amiral \
	AmiralTests \
	$(KIT)/Package.swift \
	$(KIT)/Sources \
	$(KIT)/Tests

# swift-format's version follows whichever Xcode is selected, so a toolchain bump can
# reformat the whole tree with no change to `.swift-format` and turn the gate red on code
# nobody edited. Assert it, so that day arrives as a sentence rather than a mystery diff.
#
# A list, because CI and a current Mac are legitimately on different Xcodes (the GitHub
# runner on 6.3, Xcode 27 on 6.4). Add a version only after linting the tree clean under it
# with `--strict`.
SWIFT_FORMAT_VERSIONS := 6.3 6.4

# Read off `swift --version`, never `swift-format --version`: Xcode 27's formatter reports
# the literal string `main`, which no pin can match. The compiler it ships inside is what
# decides its style, so that is the honest thing to assert.
#
# The assertion is fatal in CI and before anything is rewritten. A local lint under another
# toolchain only warns: it changes no file, and CI still lints under a listed version. $(1)
# is `fail` or `warn`. A macro each recipe calls rather than a shared prerequisite, which
# make would run once per invocation with whichever mode reached it first.
swift_format_guard = v="$$(xcrun swift --version 2>/dev/null \
	| sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"; \
	ok=""; for w in $(SWIFT_FORMAT_VERSIONS); do \
	  case "$$v" in $$w|$$w.*) ok=1;; esac; \
	done; \
	if [ -z "$$ok" ]; then \
	  echo "Swift toolchain $${v:-unknown}, expected one of: $(SWIFT_FORMAT_VERSIONS) — the toolchain moved."; \
	  if [ -n "$$CI" ] || [ "$(1)" != warn ]; then \
	    echo "Reformat deliberately and add it to SWIFT_FORMAT_VERSIONS, or select a matching Xcode."; \
	    exit 1; \
	  fi; \
	  echo "Linting anyway. CI lints under $(SWIFT_FORMAT_VERSIONS) and may disagree."; \
	fi

swift-format-version:
	@$(call swift_format_guard,fail)

format-swift: ## Format the Swift half with swift-format
	@$(call swift_format_guard,fail)
	@xcrun swift-format format --in-place --recursive --parallel $(SWIFT_SRC)

# `--strict` is what makes this a gate: without it lint prints its findings and still exits
# 0, so CI would pass while reporting every violation it found.
format-swift-check: ## Fail on unformatted Swift
	@$(call swift_format_guard,warn)
	@xcrun swift-format lint --recursive --parallel --strict $(SWIFT_SRC)

# `git blame` walks straight into a reformat commit unless told not to, and the file that
# says so is per-clone config the repo cannot set for you. Empty until Amiral has one.
blame-setup: ## Teach git blame to skip the formatting-only commits
	@git -C ../.. config blame.ignoreRevsFile .git-blame-ignore-revs
	@echo "git blame will skip the commits in .git-blame-ignore-revs"

# ── Clean ─────────────────────────────────────────────────────────────────────

clean: ## Remove build products
	rm -rf $(DERIVED_DATA) $(KIT)/.build

.PHONY: help build build-release test test-app test-all quit run \
	swift-format-version format-swift format-swift-check blame-setup clean
