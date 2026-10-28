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
# No deploy block yet: there is no apps/website half. When one arrives, fleet-ship-conventions
# owns what goes below.

APPLE := apps/apple

# Read out of the sub-makefile's own `## ` help comments, so a target added there is
# forwardable from here without touching this file.
#
# Deliberately NOT copied from its .PHONY list: that list is maintained by hand and drifts.
# `help` is dropped because the root has its own.
#
# The `##` goes through HASH: /usr/bin/make on macOS (and so on every macOS CI runner) is
# GNU make 3.81, which reads a literal `#` inside `$(shell ...)` in an assignment as a
# comment and aborts with "unterminated call to function `filter-out'". Homebrew's make 4.x
# parses it fine, which is why the bug is invisible locally. Check with
# `/usr/bin/make -n help` after touching this line.
HASH := \#
APPLE_TARGETS := $(filter-out help,\
	$(shell sed -n 's/^\([a-zA-Z0-9_-]*\):.*$(HASH)$(HASH).*/\1/p' $(APPLE)/Makefile))

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@echo "  \033[1mdrakar\033[0m"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  \033[1mapp\033[0m — forwarded to $(APPLE), so 'make test' here is 'make test' there"
	@$(MAKE) --no-print-directory -C $(APPLE) help

audit: ## Check the network claim against the sources (scripts/audit-network.sh)
	@scripts/audit-network.sh

audit-running: ## The same, plus the running app: its sockets, lock files and token
	@scripts/audit-network.sh --running

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
# `test`, which is apps/apple's and forwarded.
#
# DIVERGES from armada: package.json's `test:scripts` skips one test by name, the
# fleet's "accepts the SUPublicEDKey committed in this repository's Info.plist". That
# file is byte-identical across the fleet, so the skip lives outside it. The test reads
# apps/apple/*-Info.plist, which Drakar has no copy of until Task 3 moves its plist there,
# and even then the key is the placeholder until Phase 2. The commit that lands the real
# key drops the skip.
test-scripts: ## Run the Node tests under scripts/
	@pnpm test:scripts

# Explicit targets rather than a `%:` catch-all. A match-anything rule prints "'X' is up to
# date" instead of forwarding whenever the goal happens to name a file or directory at the
# root — and apps/ and docs/ are both real paths. Silent success is the one failure a
# delegator must never have.
$(APPLE_TARGETS):
	@$(MAKE) --no-print-directory -C $(APPLE) $@

.PHONY: help audit audit-running extension-diff extension-accept changelog changelog-check \
	test-scripts $(APPLE_TARGETS)

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
