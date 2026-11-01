# Sessions on Another Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Drakar on the person's Mac starts and drives Claude Code sessions whose `claude` runs on a second Mac (the runner), held by the runner's `DrakarHost` and reached through `ssh <runner> …/Drakar --relay`.

**Architecture:** A relay mode of the app's own binary copies bytes between ssh's stdio and the runner's `host-v1.sock`, after one JSON line of runner facts. On the Mac, `SessionHost` gains a runner endpoint that spawns `/usr/bin/ssh` on a `socketpair` and hands the fd to `HostClient`; everything above the connection (attach, replay, reconnect, `released`) is the code that exists. Runner sessions are Claude Code only, new only, conversation-only, never ended but by End Session, and carry `origin`/`owner` in `meta` so the runner's own Drakar never takes a Mac's session on its own.

**Tech Stack:** Swift 6, SwiftUI/AppKit, DrakarKit (local SPM package, Swift Testing), hosted app tests (`make test-app`), `/usr/bin/ssh`, `/usr/bin/open`.

**Spec:** `docs/superpowers/specs/2026-11-01-remote-sessions-design.md`. Read it first; this plan argues from it and does not repeat its reasons. Host protocol: `docs/session-host.md`.

## Global Constraints

- `DrakarHost` (`apps/apple/DrakarHost/`, `Host/HostServer.swift`, `Host/HostCore.swift`, `PeerSignature.swift`) does not change. No new HostWire request, no change to the peer requirement.
- The relay parses no HostWire: after the facts line it is a byte copier.
- Drakar links nothing new for networking; the only new spawned program is `/usr/bin/ssh` (and `/usr/bin/open` on the runner). `make audit`, `make audit-running`, `make audit-release` pass unchanged.
- Off unless configured: with no runner in Settings and the runner opt-in off, no code path below runs.
- Runner sessions: Claude Code only; no resume, no fork, no transcript reads, no `CapabilityProbe`, no `AccountStore` records, no Mac environment or Mac paths in their spawn.
- Values the spec pins: opt-in key text "Let my other Macs start sessions here" (off by default); relay protocol `1`; host wait on the runner 15 s; stale-relay reattach retry up to 3 minutes; ssh args `-T -o BatchMode=yes`; default runner Drakar path `/Applications/Drakar.app`; environment file `runner-environment.json`, mode 0600, in `~/Library/Application Support/<bundle id>/` (beside `host/`); variables removed in the ssh fallback: `SSH_CONNECTION`, `SSH_CLIENT`, `SSH_TTY`, `SSH_AUTH_SOCK`.
- Tests never reach the real host or a real runner: hosted tests use `SessionHost.testDirectory` and a fake `ssh` script; the relay under test always gets `--directory`.
- Match the codebase: Swift Testing (`@Test`, `#expect`) in DrakarKit and the hosted suite, doc comments that say why, `make format-swift-check` clean.
- Work on a branch in a worktree under `.claude/worktrees/` (check it is git-ignored first): the main checkout is shared with other sessions.

## Review Focus

1. **The Mac's environment reaching a runner spawn** (HOME, TMPDIR, PATH, SSH_AUTH_SOCK, `CLAUDE_CONFIG_DIR` of the Mac): the runner's `claude` must see only the runner's facts' environment plus the account's variables. Pinned in Task 9 (`runnerSpawnCarriesNothingOfTheMac`).
2. **The runner's own Drakar taking a Mac's session** when the Mac sleeps (ssh drops → `released`), at its launch (`HeldWindows`), or in `settle`. Pinned in Task 11 (`aReleasedProcessAnotherMacOwnsIsNotTaken`, `heldWindowsSkipsAnotherMacsSessions`).
3. **A runner folder at the same path as a local project** merging with it in Home, window restore or `adoptHeld`. Pinned in Task 8 (`aRunnerProjectIsNotTheLocalOneAtTheSamePath`) and Task 12.
4. **A stale relay** making a reattach answer "attached to another app" and the Mac showing the session as taken. Pinned in Task 6 (`aRefusedReattachIsRetriedWhileTheMacOwnsIt`).
5. **ssh failing without a word**: no key, host key changed, Drakar not at the path, opt-in off: the failure's stderr reaches Settings and the session's error. Pinned in Task 6 (`sshFailuresCarryTheirStderr`) and Task 4 (`refusesWhenTheRunnerHasNotOptedIn`).

---

### Task 0: Spike: where the runner's processes live (gate)

Throwaway; nothing is committed but the findings. Needs the real runner and an ssh login to it. If either check fails, stop and bring the finding back before Task 4.

- [ ] **Step 1:** On the runner, logged in to the desktop, with Claude Code logged in from the desktop: over ssh, run `claude -p "say ok"`. Record whether it is logged in (expected: not, or a Keychain error: this is why §2 exists).
- [ ] **Step 2:** Build a scratch app (`/tmp/spike/Spike.app`, any signed bundle whose executable runs `claude -p "say ok" > ~/spike.txt 2>&1` via `Process` then quits). Over ssh: `open -g -j -a /tmp/spike/Spike.app`. Expected: `~/spike.txt` says ok, so a process started by an app LaunchServices launched from ssh is in the GUI session.
- [ ] **Step 3:** From the scratch app, also run `/usr/sbin/screencapture -x ~/spike.png` and record which app macOS asks Screen Recording for.
- [ ] **Step 4:** Write the three results under "Departures in the build" in the spec (create the section), with the macOS build. Commit only the spec change: `git commit -m "docs(spec): remote sessions spike findings"`.

### Task 1: `HostClient` over any connected fd

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostClient.swift:43-47`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/HostSocketTests.swift`

**Interfaces:**
- Produces: `public static func connect(fd: Int32) -> HostClient`. Takes ownership of `fd` (closed with the client). `connect(socket:)` becomes a call to it.

- [ ] **Step 1: Write the failing test** `aClientOverASocketPairTalksToTheHost`: make a `socketpair`, serve one end with the existing in-test `HostServer` path used by the suite's other tests (as `HostSocketTests.swift:314` does), `HostClient.connect(fd: fds[1])`, then `hello`, `spawn` a stand-in agent, `attach` from 0 and expect its first record, as `aClientSpawnsAndAttaches` (or the suite's equivalent) does over a socket path.
- [ ] **Step 2:** `cd apps/apple && make test` → FAIL: `connect(fd:)` not found.
- [ ] **Step 3:** Implement `connect(fd:)` as `HostClient(UnixConnection(fd: fd, label: "HostClient"))`; make `connect(socket:)` call it. `UnixConnection` already works on one fd.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat(kit): a host client over any connected descriptor`.

### Task 2: Runner facts and the runner's environment

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/RunnerFacts.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/RunnerFactsTests.swift`

**Interfaces:**
- Produces:
  - `public struct RunnerFacts: Codable, Equatable, Sendable` with `relay: Int`, `drakar: String`, `build: String`, `hostMajors: [Int]`, `home: String`, `user: String`, `hostname: String`, `environment: [String: String]`, `environmentFrom: EnvironmentSource`, `claude: [ClaudeCandidate]`, `accounts: [String]` (account directories, as paths).
  - `public enum EnvironmentSource: String, Codable, Sendable { case gui, ssh }`
  - `public struct ClaudeCandidate: Codable, Equatable, Sendable { public var path: String; public var version: String? }`
  - `public static let relayVersion = 1`
  - `public func line() throws -> Data` (one JSON object, then `\n`); `public static func parse(_ line: Data) throws -> RunnerFacts`
  - `public enum RunnerEnvironment` with `static let fileName = "runner-environment.json"`, `static func file(in appSupport: URL) -> URL`, `static func write(_ environment: [String: String], to url: URL) throws` (mode 0600, atomic), `static func read(from url: URL) -> [String: String]?`, `static func withoutSSH(_ environment: [String: String]) -> [String: String]`.

- [ ] **Step 1: Write the failing tests:**
  - `factsSurviveTheirLine`: encode → `line()` ends with exactly one `\n`, contains no other newline even when an environment value holds `"a\nb"`; `parse` gives back an equal value.
  - `aLineOfAnotherShapeIsRefused`: `parse(Data("{}\n".utf8))` throws.
  - `withoutSSHDropsTheSessionsVariables`: input with `SSH_CONNECTION`, `SSH_CLIENT`, `SSH_TTY`, `SSH_AUTH_SOCK`, `PATH`, `HOME` → only `PATH`, `HOME` remain.
  - `theEnvironmentFileIsOwnersOnly`: `write` then `stat` mode `& 0o777 == 0o600`; `read` returns the dictionary; `read` of a missing file is nil.
- [ ] **Step 2:** `make test` → FAIL (types missing).
- [ ] **Step 3:** Implement in `RunnerFacts.swift` with `JSONEncoder` (`.sortedKeys` for stable tests).
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat(kit): the facts a runner's relay states first`.

### Task 3: The relay's byte pump

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/Relay.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/RelayTests.swift`

**Interfaces:**
- Produces: `public enum Relay { public enum End: Equatable, Sendable { case inputClosed, socketClosed }; public static func pump(input: Int32, output: Int32, socket: Int32) async -> End }`. Copies input → socket and socket → output until either side reaches EOF or errors; then shuts the other direction (`shutdown(socket, SHUT_WR)` on input EOF) and returns. Writes handle partial writes and `EINTR`; `SIGPIPE` is off for the socket (`UnixSocket.prepare`).

- [ ] **Step 1: Write the failing tests** (pipes for stdin/stdout, a `socketpair` for the socket):
  - `bytesCrossBothWays`: 1 MiB of random bytes each way arrive intact and in order.
  - `inputEOFEndsThePump`: closing the input's write end → returns `.inputClosed` within 1 s, and the socket peer reads EOF.
  - `socketEOFEndsThePump`: closing the socket peer → returns `.socketClosed`, and the output's read end reaches EOF once the pump's caller closes it.
- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Implement with two blocking-read threads (or `DispatchSource` readers as `UnixConnection` does), first end wins.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat(kit): the relay's pump between stdio and the host's socket`.

### Task 4: `Drakar --relay`

**Files:**
- Create: `apps/apple/Drakar/DrakarMain.swift` (the new `@main`), `apps/apple/Drakar/Services/RelayCommand.swift`
- Modify: `apps/apple/Drakar/DrakarApp.swift:7-8` (drop `@main` from `DrakarApp`)
- Test: `apps/apple/DrakarTests/RelayCommandTests.swift`

**Interfaces:**
- Consumes: `RunnerFacts`, `RunnerEnvironment`, `Relay.pump` (Tasks 2–3); `HostWire.directory/socket`; `ClaudeLocator`; `RunnerRole.acceptsKey` (defined here, used by Task 5).
- Produces:
  - `@main enum DrakarMain { static func main() }`: `CommandLine.arguments.contains("--relay")` → `RelayCommand.run(arguments:)`, before anything touches AppKit, Sparkle, licensing or `NSApplication`; else `DrakarApp.main()`.
  - `enum RelayCommand { static func run(arguments: [String]) -> Never; static func facts(environmentFile: URL) async -> RunnerFacts }`. Arguments: `--relay`, optional `--directory <host dir>` (tests; with it the relay never runs `open`).
  - `enum RunnerRole { static let acceptsKey = "runner.acceptsSessions" }` (the type grows in Task 5 into a `@MainActor` class; keep the key `nonisolated static let` so the relay, which never runs the main actor's app, reads it).
  - Exit codes: 0 after a pump end; 64 opt-in off; 69 no host within 15 s; 70 the socket path does not fit. Each writes one line to stderr first, in words the Mac shows as is.

- [ ] **Step 1: Write the failing tests** (hosted; spawn `Bundle.main.executableURL` with `Process`):
  - `refusesWhenTheRunnerHasNotOptedIn`: `UserDefaults.standard.set(false, forKey: RunnerRole.acceptsKey)`, run `--relay --directory <tmp>` → exit 64, stdout empty, stderr contains "Let my other Macs start sessions here".
  - `statesItsFactsThenRelays`: opt-in true; `SessionHost.startHelper(in: tmp)`; run `--relay --directory tmp` with pipes; first stdout line parses as `RunnerFacts` with `relay == 1` and `hostMajors.contains(HostWire.major)`; then `HostClient.connect(fd:)` over a socketpair bridged to the pipes says `hello` and `list()` returns `[]`.
  - `withNoHostItGivesUp`: opt-in true, empty `--directory`, no helper → exit 69 within 16 s.
  - `factsPreferTheGUIEnvironment`: with an environment file holding `MARK=gui` → `facts.environmentFrom == .gui` and `environment["MARK"] == "gui"`; without it → `.ssh`, and no `SSH_*` key from the test's own environment survives.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement. Without `--directory`, when the socket does not answer, run `/usr/bin/open -g -j -a <Bundle.main.bundleURL>` once and poll the socket (the backoff `SessionHost.connect` uses) for 15 s. `facts`: environment from `RunnerEnvironment.read` else `RunnerEnvironment.withoutSSH(ShellEnvironment.read())`; `claude` candidates and versions as Settings › General lists them (`ClaudeLocator`, `ClaudeVersion.read`) with that environment's `PATH`; `accounts` as `AccountStore` discovers them, as paths; `hostname` from `Host.current().localizedName`.
- [ ] **Step 4:** `make test-app` → PASS. Also `make build-release`, then by hand from Terminal: `…/Drakar.app/Contents/MacOS/Drakar --relay` with the opt-in off exits 64 with no Dock icon flashing.
- [ ] **Step 5:** Commit `feat(app): Drakar --relay, the runner's end of a remote session`.

### Task 5: The runner's opt-in keeps its host up and records its environment

**Files:**
- Modify: `apps/apple/Drakar/Services/RelayCommand.swift` (grow `RunnerRole` into its own file: `apps/apple/Drakar/Services/RunnerRole.swift`)
- Modify: `apps/apple/Drakar/DrakarApp.swift:236-256` (`applicationDidFinishLaunching` calls `RunnerRole.shared.apply()`)
- Modify: `apps/apple/Drakar/Services/SessionHost.swift` (a `keepConnected` loop)
- Test: `apps/apple/DrakarTests/RunnerRoleTests.swift`

**Interfaces:**
- Produces: `@MainActor final class RunnerRole { static let shared; static let acceptsKey; var accepts: Bool (UserDefaults-backed); func apply() }`. `apply()`, with `accepts` true: writes `RunnerEnvironment` file (from `AgentSession.environment`) and starts `SessionHost.keepConnected()`; with it false: stops that loop and closes the connection if no session uses it. Called at launch and when the toggle changes.
- Produces: `SessionHost.keepConnected()` / `stopKeepingConnected()`: `client()` now, and `reconnect()` after each `disconnected`, until stopped.

- [ ] **Step 1: Write the failing tests:**
  - `acceptingWritesTheEnvironmentFile`: point `RunnerRole`'s app-support directory at a temp dir (an injectable `directory`), `accepts = true`, `apply()` → the file exists with mode 0600 and holds `PATH`.
  - `acceptingKeepsAHostUp`: `SessionHost.testDirectory = tmp`, `apply()` → after 35 s (longer than the host's 30 s idle exit) `SessionHost.isRunning(started)` still true. Mark `.timeLimit(.minutes(2))`.
  - `notAcceptingLetsTheHostLeave`: then `accepts = false`, `apply()` → the helper exits within 40 s.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `make test-app` → PASS.
- [ ] **Step 5:** Commit `feat(app): a runner that accepts sessions keeps its host up`.

### Task 6: `SessionHost` for a runner, over ssh

**Files:**
- Modify: `apps/apple/Drakar/Services/SessionHost.swift` (endpoint, connect path, `heldIfRunning`, `heldByOlderHosts`, `hostPID`, `hostedChanged`)
- Create: `apps/apple/Drakar/Services/RunnerSettings.swift`, `apps/apple/Drakar/Services/RunnerConnection.swift`
- Test: `apps/apple/DrakarTests/RunnerHostTests.swift`, fake ssh scripts written by the tests into their temp dir

**Interfaces:**
- Consumes: `HostClient.connect(fd:)`, `RunnerFacts.parse`.
- Produces:
  - `struct RunnerSettings: Codable, Equatable { var name: String; var destination: String; var drakarPath: String = "/Applications/Drakar.app"; static let key = "runner.settings"; static var current: RunnerSettings? }` (nil when `destination` is empty). `static var sshExecutable = URL(filePath: "/usr/bin/ssh")` (tests replace it).
  - `enum RunnerConnection { static func open(_ settings: RunnerSettings) async throws(RunnerFailure) -> (HostClient, RunnerFacts) }`: spawns `sshExecutable` with `["-T", "-o", "BatchMode=yes", destination, drakarPath + "/Contents/MacOS/Drakar", "--relay"]`, stdin+stdout on one end of a `socketpair`, stderr on a pipe whose last 4 KiB are kept; reads the facts line (10 s), refuses a `relay` it does not know or `hostMajors` without `HostWire.major`, then `HostClient.connect(fd:)` and `hello`.
  - `struct RunnerFailure: Error, Equatable { var message: String; var stderr: String }` with the message "Update Drakar on <name>" for the two version refusals.
  - `SessionHost.Endpoint { case local; case runner(RunnerSettings) }`; `SessionHost(endpoint:)`; `@MainActor static var runner: SessionHost?` (made for `RunnerSettings.current`, replaced when it changes); `private(set) var facts: RunnerFacts?`; `private(set) var failure: RunnerFailure?`; `var isRunner: Bool`. For `.runner`: `hostPID` stays nil, `heldIfRunning()` is `held()`, `heldByOlderHosts()` is `[]`, `hostedChanged()` does nothing, no helper is ever started, the test-directory rule does not apply (tests reach the relay through the fake ssh, which passes `--directory`).
  - `SessionHost.reattachRefused(_ id: String) -> Bool`: for a runner endpoint and a process whose `meta.owner == ThisMac.name`, true means "still releasing, retry" (Task 11 defines `ThisMac`; here, take the owner check as a closure parameter so this task stands alone).

- [ ] **Step 1: Write the failing tests:**
  - `aRunnerHostConnectsThroughSSH`: fake ssh script `#!/bin/sh\nexec "$DRAKAR" --relay --directory "$DIR"` (both injected through the script's text), opt-in true, `SessionHost.startHelper(in: DIR)`; `SessionHost(endpoint: .runner(settings)).client()` non-nil; `facts?.relay == 1`; `hostPID == nil`.
  - `sshFailuresCarryTheirStderr`: script `echo "Permission denied (publickey)." >&2; exit 255` → `client()` nil, `failure?.stderr` contains "Permission denied".
  - `aRelayOfAnotherVersionAsksForAnUpdate`: script prints a facts line with `relay: 2` → `failure?.message == "Update Drakar on <name>"`.
  - `aSilentSSHGivesUp`: script `sleep 60` → `client()` nil within 11 s.
  - `aRefusedReattachIsRetriedWhileTheMacOwnsIt`: two clients through two relays to one test host; client A spawns and attaches a stand-in process with `owner` = this Mac; A's relay is kept open (stale); B's session's `attach` is refused; with the owner check true, `reattachRefused` returns true and a retry after A's relay closes succeeds; with it false, false.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement: move today's `connect(in:)` behind `.local`, add `.runner` via `RunnerConnection.open`. Reuse `reconnect()`'s backoff unchanged; cap the "still releasing" retries at 3 minutes in the caller (`HostedProcess` reattach path in `AgentSession`).
- [ ] **Step 4:** `make test-app` → PASS; `make test` still passes.
- [ ] **Step 5:** Commit `feat(app): a session host on another Mac, through ssh`.

### Task 7: Settings › Runner

**Files:**
- Modify: `apps/apple/Drakar/Views/SettingsView.swift:17-40` (`case runner`, title "Runner", a symbol), plus its pane body
- Create: `apps/apple/Drakar/Views/RunnerSettingsPane.swift`
- Test: `apps/apple/DrakarTests/SettingsPaneTests.swift`

**Interfaces:**
- Consumes: `RunnerSettings`, `RunnerConnection.open`, `RunnerRole`.
- Produces: the pane, two sections. **This Mac as a runner:** the toggle "Let my other Macs start sessions here" bound to `RunnerRole.shared.accepts` (calls `apply()`), with one line under it saying sessions started from another Mac run here under this Mac's login and its Claude Code. **Use a runner:** Name, ssh destination, Drakar path (default `/Applications/Drakar.app`), **Test** (connects, shows Drakar version, `claude` found with version, accounts, `environmentFrom == .ssh` as a warning "Open Drakar on the runner once, so its sessions get its desktop's environment", then disconnects; on failure shows `message` and `stderr`). Saving replaces `SessionHost.runner`.

- [ ] **Step 1: Write the failing tests:** `theRunnerPaneIsListed` (pane enumerates after `.attention` or where the builder sees fit, title "Runner"); `anEmptyDestinationMeansNoRunner` (`RunnerSettings.current == nil`, `SessionHost.runner == nil`); `savingARunnerMakesItsHost` (`SessionHost.runner?.isRunner == true`).
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement the pane in the style of the General pane.
- [ ] **Step 4:** `make test-app` → PASS; check the pane by eye with `make run ARGS='-drakar.settingsPane runner'`.
- [ ] **Step 5:** Commit `feat(app): Settings › Runner`.

### Task 8: A runner project is its own project

**Files:**
- Modify: `apps/apple/Drakar/Services/SessionMeta.swift` (fields), `apps/apple/Drakar/Services/SessionRoute.swift:11-28` (`WindowRoute`), `apps/apple/Drakar/Services/Project.swift:371-430` (`runner`, `sessionHost`), `apps/apple/Drakar/Services/AgentSession.swift` (`runner`)
- Create: `apps/apple/Drakar/Services/ThisMac.swift`
- Test: `apps/apple/DrakarTests/ProjectTests.swift`, `apps/apple/DrakarTests/ReopenedWindowsTests.swift`, `apps/apple/DrakarTests/HostedSessionTests.swift`

**Interfaces:**
- Produces:
  - `SessionMeta.runner: String?`, `origin: String?`, `owner: String?` (all optional so older metas decode).
  - `enum ThisMac { static var name: String }` (`Host.current().localizedName ?? "this Mac"`, overridable in tests).
  - `WindowRoute.runnerProject(runner: String, folder: String)` (a new case, so stored routes still decode); `var runner: String?`; `WindowRoute.project(_:runner:)`.
  - `Project.runner: String?` (init gains `runner: String? = nil`); its `sessionHost` is `SessionHost.runner` for a runner project. A runner project's identity in `OpenSessions`, `ReopenedWindows`, `HeldWindows` and Home is `(runner, normalized path)`.
  - `AgentSession.runner: String?`; `var isOnRunner: Bool { runner != nil }`.

- [ ] **Step 1: Write the failing tests:**
  - `anOlderMetaStillDecodes`: a meta JSON without the three keys decodes with all three nil.
  - `aRunnerProjectIsNotTheLocalOneAtTheSamePath`: open `/tmp/x` locally and on runner "R" → two projects, two windows, `OpenSessions.shared.folders` keeps them apart.
  - `aRunnerWindowIsReopenedThoughItsFolderIsMissingHere`: `ReopenedWindows` records a `.runnerProject(runner: "R", folder: "/nowhere")` and reopens it.
  - `aRouteRoundTrips`: encode/decode `.runnerProject`.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement. `ReopenedWindows.swift:72` and `HomeView.swift:283` skip the local `fileExists` for runner routes.
- [ ] **Step 4:** `make test-app` → PASS.
- [ ] **Step 5:** Commit `feat(app): a runner's project is kept apart from a local one at the same path`.

### Task 9: Spawning on the runner

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentSession.swift:830-880` (spawn), `:1480-1488` (environment), `:1360-1365` (usage), `loadHistory`/`followFromHere`/`locateTarget` guards; `apps/apple/Drakar/Services/ClaudeLaunch.swift` (a runner variant); `apps/apple/Drakar/Services/AgentSession.swift:417-426` (`meta` with `runner`, `origin`, `owner`)
- Test: `apps/apple/DrakarTests/ClaudeLaunchTests.swift`, `apps/apple/DrakarTests/HostedSessionTests.swift`

**Interfaces:**
- Consumes: `SessionHost.runner`, `facts`, `ThisMac.name`.
- Produces: `ClaudeLaunch.make(onRunner facts: RunnerFacts, folder: URL, account: ClaudeAccount?, executable: String?) -> ClaudeLaunch`: executable is `executable` or `facts.claude.first?.path`; environment is `facts.environment` then the account's variables (`ClaudeAccount.environment`) then the checkpointing default as `make` does; never reads `ClaudeChoice`, `ClaudeLocator` or the Mac's environment.
- A runner session: no `FileManager.fileExists(folder)` check; no `loadHistory()` (history `.none`, `hasLoadedHistory = true`); no `TranscriptFollower`, `followFromHere`, `locateTarget`; no `CapabilityProbe` (the composer's slash commands, tools and MCP servers come from the stream's `system`/`init` only, and it offers none before that arrives); rate limits and model list kept on the session, not sent to `AccountStore`; `meta.runner = runner`, `meta.origin = meta.owner = ThisMac.name` at the spawn; agent forced to `.claude`.

- [ ] **Step 1: Write the failing tests:**
  - `runnerSpawnCarriesNothingOfTheMac`: facts environment `["PATH": "/runner/bin", "HOME": "/Users/r"]`, the test process's own `TMPDIR`/`HOME` differ → the configuration's environment has `HOME == "/Users/r"`, no key whose value equals the Mac's `TMPDIR`, executable `/runner/bin/claude` when that is `facts.claude[0].path`.
  - `aRunnerAccountNamesItsDirectory`: account `/Users/r/.claude-work` → `CLAUDE_CONFIG_DIR == "/Users/r/.claude-work"`.
  - `aRunnerSessionRunsThroughTheRelay` (hosted, fake ssh as Task 6, a stand-in CLI path in the facts via the environment file): send a prompt → the stand-in's echo arrives in the transcript; `meta.origin == ThisMac.name`; no `TranscriptFollower` was made (`session.follower == nil`).
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement, branching on `isOnRunner` at the points listed, nowhere else.
- [ ] **Step 4:** `make test-app` → PASS.
- [ ] **Step 5:** Commit `feat(app): a session's claude runs on the runner, with the runner's environment`.

### Task 10: Runner sessions end only by End Session

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentSession.swift:1117-1147` (`stop`), the End Session action (find its `stop()` call: `grep -rn "End Session" Drakar/`)
- Test: `apps/apple/DrakarTests/ClosingTests.swift`

**Interfaces:**
- Produces: `func stop(handingOver: Bool = false, ending: Bool = false)`. For a hosted process on the runner: `ending` → today's terminate-and-forget path; otherwise `hosted.detach()`, at work or idle. End Session passes `ending: true` for every session (no change for local ones, which already terminate). The close confirmation of a runner session's End Session says "This conversation can't be resumed from this Mac."

- [ ] **Step 1: Write the failing tests:** `closingAnIdleRunnerSessionDetachesIt` (the host lists it afterwards with `attachedApp == nil`, `running == true`); `quittingDetachesRunnerSessions` (with `AppLifecycle.isTerminating = true`); `endSessionEndsARunnerSession` (gone from `list()` after exit).
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `make test-app` → PASS, and the existing `ClosingTests` unchanged.
- [ ] **Step 5:** Commit `feat(app): closing or quitting leaves a runner session to its host`.

### Task 11: Who may take a session, and the handoff

**Files:**
- Modify: `apps/apple/Drakar/Services/SessionMeta.swift` (the rule), `apps/apple/Drakar/Services/Project.swift:1479-1560` (`adoptHeld`, `released`, `settle`), `apps/apple/Drakar/DrakarApp.swift:406-456` (`HeldWindows.folders`), Session menu commands (`SessionCommands`) and the session toolbar
- Test: `apps/apple/DrakarTests/RunnerOwnershipTests.swift`, `apps/apple/DrakarTests/ReattachTests.swift`

**Interfaces:**
- Produces:
  - `extension SessionMeta { func mayBeTaken(by mac: String, onRunner: Bool) -> Bool }`: true when `owner == nil` and this app is the runner's own (`onRunner == false`, i.e. a local host), or `owner == mac` and this app reaches the host as a runner (`onRunner == true`). Everything else false.
  - `Project` uses it in `adoptHeld`'s `free` filter, in `settle`, and in `released`; `HeldWindows.folders` uses it with `onRunner: false`.
  - A runner `Project` never makes read-only rows (`AgentSession(heldElsewhere:)`) for runner processes: those are Home rows (Task 12).
  - Commands: **Open on the Runner** (Mac, runner session): `setMeta` with `owner = nil`, `detach`, close the row. **Bring Back to <origin>** (runner's own Drakar, session with `origin != nil`): `setMeta` with `owner = origin`, `detach`. **Take Over Here** (runner's own Drakar, read-only row whose `owner` is a Mac): when the host lists it with `attachedApp == nil`, `setMeta` with `owner = nil` and attach; else show "In use on <owner>".

- [ ] **Step 1: Write the failing tests:**
  - `theRuleTable`: the six cases of (`owner` nil / this Mac / another Mac) × (`onRunner` true / false) against the rule above.
  - `aReleasedProcessAnotherMacOwnsIsNotTaken`: local test host, a process with `owner = "Other Mac"` shown read-only, `released` → not attached.
  - `heldWindowsSkipsAnotherMacsSessions`: `HeldWindows.folders` of a free process with `owner = "Other Mac"` → `[]`.
  - `openOnTheRunnerHandsItOver`: two `SessionHost`s on one test host (one local = the runner's Drakar, one `.runner` through the fake ssh = the Mac); the Mac's session runs Open on the Runner; the local one, showing it read-only, attaches on `released`.
  - `bringBackReturnsIt`: the reverse; the Mac's runner project attaches on `released`.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `make test-app` → PASS.
- [ ] **Step 5:** Commit `feat(app): a session another Mac owns is never taken on its own; hand it over and back`.

### Task 12: Home lists the runner; New Session on Runner

**Files:**
- Modify: `apps/apple/Drakar/Views/HomeView.swift` (a runner section), `apps/apple/Drakar/Services/BackgroundSessions.swift` (count runner processes apart), File menu (`NewWindowCommand` area in `DrakarApp.swift`)
- Create: `apps/apple/Drakar/Views/RunnerSection.swift`, `apps/apple/Drakar/Views/NewRunnerSessionSheet.swift`
- Test: `apps/apple/DrakarTests/BackgroundSessionsTests.swift`, `apps/apple/DrakarTests/RunnerSectionTests.swift`

**Interfaces:**
- Consumes: `SessionHost.runner` (`listed()`, `failure`, `facts`), `SessionMeta.mayBeTaken`.
- Produces:
  - `struct RunnerRow: Identifiable, Equatable { var id: String; var folder: String; var name: String?; var running: Bool; var state: State; enum State { case here, idle, onTheRunner } }` and `enum RunnerSection { static func rows(held: [HeldProcess], mac: String) -> [RunnerRow] }` (pure: held by this Mac's app → `.here`; free and `mayBeTaken(by: mac, onRunner: true)` → `.idle`; else `.onTheRunner`).
  - Home's runner section: the runner's name, its state (connected / reconnecting / `failure.message`), rows grouped by folder; click `.idle` or `.here` opens `.runnerProject` and the window adopts it (`adoptHeld` from 0); click `.onTheRunner` says "Open it in Drakar on <runner>"; **End Idle Sessions…** (count of `.idle`, confirmation, then `terminate` + `forget` each); recent folders = distinct `meta.windowFolder`.
  - **File › New Session on Runner…** (disabled with no runner): a path field (runner path, typed) above the recent folders; opens `.runnerProject` and starts a new session there.
  - Runner processes never enter `BackgroundSessions.count` for local projects.
  - At launch, runner windows come back through `ReopenedWindows` (Task 8), not `HeldWindows`, which stays local: a runner window that was open at the quit reopens and its project adopts what the runner's host holds for it, as a local window does.

- [ ] **Step 1: Write the failing tests:** `rowsSortThreeWays` (one held here, one free owned by this Mac, one free with no owner → `.here`, `.idle`, `.onTheRunner`); `runnerProcessesAreNotCountedForALocalProjectAtTheSamePath`; `endIdleSessionsEndsOnlyIdleOnes` (hosted, fake ssh).
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement; layout is the builder's (spec, Left to the builder).
- [ ] **Step 4:** `make test-app` → PASS; check Home and the sheet by eye with `make run`.
- [ ] **Step 5:** Commit `feat(app): Home lists the runner's sessions, and a new session starts there`.

### Task 13: What a runner session does not offer

**Files:** each row of spec §4's table: `Views/SessionView.swift` (no sidebar), `Workspace.swift` (not built for runner projects), `Views/LinkText.swift`, `Views/SessionInspector.swift`, `Views/ProjectSidebar.swift`, `ShowInVSCode.swift`, `Views/PermissionSheet.swift:69-78`, `Project.swift:1176-1262` (fork), `AgentSession.swift:971-980` (rename), `SubagentFeed.swift`, `SessionMoves.swift`, `SkillsManager` entry points, `FanOutDraft.swift`, `Views/ComposerView.swift:279-296`, `Views/ElicitationPanel.swift:440-444`.
- Test: the existing test file of each (`PermissionSheetTests`, `SessionMovesTests`, `SubagentFeedTests`, `ElicitationPanelTests`, `ProjectFanOutTests`, `ProjectTests`).

**Interfaces:**
- Consumes: `AgentSession.isOnRunner`, `Project.runner`. Every gate reads one of these two; no other flag.

- [ ] **Step 1: Write the failing tests** (one per row, in the row's file): `aRunnerWriteShowsItsContentWithoutADiff` (labelled "on R"), `movingARunnerSessionIsRefused`, `aRunnerSubagentSaysWhereItRuns`, `aLocalhostElicitationOnARunnerSaysWhereItLands`, `noFanOutOnARunnerFolder`, `noForkOnARunnerSession`, `renameWithoutAProcessIsUnavailableOnARunner`, `aRunnerProjectBuildsNoWorkspace`.
- [ ] **Step 2:** `make test-app` → FAIL.
- [ ] **Step 3:** Implement each gate.
- [ ] **Step 4:** `make test-app` → PASS.
- [ ] **Step 5:** Commit `feat(app): a runner session shows nothing of this Mac as the runner's`.

### Task 14: The network promise and the runner page

**Files:**
- Modify: `README.md` (the network paragraph), `SECURITY.md`, `apps/apple/Drakar/Services/RunnerConnection.swift` (comment at the ssh spawn pointing at spec §6)
- Create: `docs/runner.md` (spec "Setting up the runner", as a user page)
- Test: `make audit`, `make audit-running`, `make audit-release`

- [ ] **Step 1:** README: "Everything else that reaches the network is the `claude` or `codex` you installed" → "… is the `claude`, `codex` or, once you name a runner, `ssh` you installed", and a short "Sessions on another Mac" section linking `docs/runner.md`. SECURITY: the same sentence, plus that the relay is reached only through the person's own ssh login and is the app's own signed binary, which the host checks, and only once the runner's opt-in is on.
- [ ] **Step 2:** Write `docs/runner.md` from the spec's setup section (including `ClientAliveInterval 30`, `ClientAliveCountMax 3`, the opt-in, Claude Code logged in from the runner's desktop, Cupertino's two settings and its updates off).
- [ ] **Step 3:** `make audit && make build-release && make audit-release` → pass with no new allowance.
- [ ] **Step 4:** `make format-swift-check && make test-all` → pass.
- [ ] **Step 5:** Commit `docs: sessions on another Mac`.

### Task 15: On the real runner (by hand, reported)

Not code. Needs the person's runner and a hands-off window on the runner only.

- [ ] **Step 1:** Install the branch's signed Release build on both Macs; runner opt-in on; Settings › Runner on the Mac; **Test** shows `environmentFrom: gui`.
- [ ] **Step 2:** From the Mac, New Session on Runner in a Cupertino checkout there; ask it to run `make smoke`. Expected: it runs on the runner's screen, nothing moves on the Mac.
- [ ] **Step 3:** Mid-turn, sleep the Mac for 10 minutes. Expected on wake: reconnecting, then the turn replayed and live; a permission prompt raised meanwhile is answerable.
- [ ] **Step 4:** Pull the network for 2 minutes mid-turn. Expected: "reconnecting" for at most ~3 minutes after it returns, never "held elsewhere".
- [ ] **Step 5:** Open on the Runner, then over Screen Sharing the runner's Drakar takes it with its editor; Bring Back; Take Over Here while the Mac is asleep.
- [ ] **Step 6:** Write the results into the spec's "Departures in the build", commit `docs(spec): remote sessions, checked on the runner`.
