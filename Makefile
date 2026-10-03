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

# Explicit targets rather than a `%:` catch-all. A match-anything rule prints "'X' is up to
# date" instead of forwarding whenever the goal happens to name a file or directory at the
# root — and apps/ and docs/ are both real paths. Silent success is the one failure a
# delegator must never have.
$(APPLE_TARGETS):
	@$(MAKE) --no-print-directory -C $(APPLE) $@

.PHONY: help audit audit-running $(APPLE_TARGETS)
