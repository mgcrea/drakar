# Session Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sessions at work keep running across a quit, crash, update or relaunch of Drakar, and come back live in their windows.

**Architecture:** A helper, `DrakarHost`, owns the agents' processes and logs every byte between app and CLI, plus notes from the app, to a file per process. The app talks to it over a Unix socket through `HostedProcess`, which replaces `AgentProcess` behind a new `ProcessTransport` protocol. After a relaunch, a session rebuilds itself by loading the history from before its process, then re-running its own code over the log (notes and CLI lines in order) with writes muted.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit (app), Foundation + Darwin only (DrakarKit), Security (host's peer check), POSIX Unix sockets, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-25-session-host-design.md`

## Global Constraints

- macOS 26 (`platforms: [.macOS(.v26)]`); DrakarKit keeps zero dependencies and imports nothing above Foundation (Darwin is in Foundation). `Security` is imported only by the `DrakarHost` target.
- The host never parses what it stores or forwards: lines are framed on `\n`, nothing else. Notes and `meta` are opaque `Data` to it.
- Socket: `~/Library/Application Support/<bundle id>/host/host-v1.sock` (`HostWire.major = 1`), directory 0700, socket 0600. A path over 103 bytes is refused with an error, never truncated.
- Peer check: same uid (`getpeereid`) and the host's own team identifier on the peer's signature (team `75QE9PRT3V`); no Debug exception.
- Idle exit: no process held (running or ended-unacknowledged) and no app connected for 30 seconds.
- Tests never reach the real host and never leave one running: `SessionHost` is off under XCTest (`XCTestConfigurationFilePath`) unless a test gives it a directory; test socket directories are short (`/tmp/dh-<6 chars>`) because of the 104-byte `sun_path`.
- The IDE bridge stays the only `NWListener`. `scripts/audit-network.sh` and the README's network claim gain exactly one Unix socket.
- Work in a worktree at `.claude/worktrees/session-host`; merge `main` in before landing, run `make -C apps/apple test test-app`, land with `git merge --ff-only`. Never `make run` or `make quit`: the person's Drakar holds live sessions. `CapabilityProbeTests` and `AgentSessionTests.aSessionOpenedElsewhereDuringTheStartIsNotWritten` fail on timing under load: rerun with `-only-testing` before calling it a regression.
- Another session's MCP-elicitation work (`docs/superpowers/plans/2026-10-25-mcp-elicitation.md`) touches `ClaudeBackend.receive`; merge `main` before Tasks 1, 8 and 9.
- Commit style as the repo's log: `feat(apple): …`, `refactor(apple): …`, `test(apple): …`, `docs: …`. No co-author trailers. Format each changed Swift file with `xcrun swift-format format --in-place <files>`; never the whole tree.
- Code reads like the surrounding code: terse `///` comments saying why, no comment restating the code.

## Review Focus

1. **A long session.** A process that ran for hours leaves a log of tens of MB: its replay must not freeze the window (off the main thread, then applied), and must finish in seconds. Task 9 adds `aLongLogReplaysQuickly`.
2. **Replay must not go off.** Replaying a log that holds 40 turn ends and 10 permission requests must not fire 40 turn-end notifications or 10 permission sheets. Only the state at the end counts. Task 1 adds `replayFiresNoCallbacks`.
3. **A crash, not a quit.** When the app is killed, no handover runs, so idle sessions are left in the host too. On relaunch they all come back, and the idle ones are ordinary idle sessions. Task 9 adds `aKilledAppLeavesEverySessionToReattach`.
4. **Two apps starting at once.** Each finds no host and starts one. Exactly one host must survive, and both apps must end up connected to it. Task 7 adds `twoHostsStartingAtOnceLeaveOne`.
5. **The folder is gone.** A session's process ends while the app is away and its folder is deleted before relaunch. The session must come back ended, with no crash and no new process. Task 9 adds `anEndedSessionWhoseFolderIsGoneComesBackEnded`.

---

## Part A: replay without a host (the spec's first risk)

Tasks 1 and 2 build recording and replay against an in-memory log, before any host exists. If either task's tests can't be made to pass without changing what the transcript shows live, stop and report back with the difference. The design depends on these two tasks.

### Task 1: Notes, the muted transport, and Claude Code replay

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ProcessTransport.swift`
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostRecord.swift`
- Create: `apps/apple/Drakar/Services/SessionNote.swift`
- Create: `apps/apple/Drakar/Services/SessionMeta.swift`
- Create: `apps/apple/Drakar/Services/ReplayTransport.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AgentProcess.swift` (conform to `ProcessTransport`; `Configuration: Codable`)
- Modify: `apps/apple/Drakar/Services/AgentBackend.swift`, `ClaudeBackend.swift`, `CodexBackend.swift` (take `any ProcessTransport` wherever they take `AgentProcess`)
- Modify: `apps/apple/Drakar/Services/AgentSession.swift`
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/TranscriptFollower.swift` (`catchUp(_:upTo:)`)
- Codable conformances where missing: `JSONValue`, `EditorSelection` (+ its `TextPosition`), `Attachment` (decoding mints a new `id`), `AttachmentPreview`, `PermissionDecision`, `PermissionMode`, `ClaudeAccount`, `AgentCommand`, `AgentStart`
- Test: `apps/apple/DrakarTests/SessionReplayTests.swift`, `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/TranscriptFollowerTests.swift` (add to the existing suite, or create)

**Interfaces:**
- Produces (DrakarKit):
  ```swift
  public protocol ProcessTransport: AnyObject, Sendable {
    var isRunning: Bool { get }
    func start() throws -> AsyncStream<AgentProcess.Event>
    func send(line: Data) throws
    func closeInput()
    func terminate()
  }
  extension ProcessTransport { public func send(_ json: JSONValue) throws }  // moved from AgentProcess, with the ClientMessage overload
  public struct HostRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case out, `in`, note }
    public var offset: UInt64; public var kind: Kind; public var time: Date
    public var attached: Bool   // an app was attached when the host logged it
    public var bytes: Data
  }
  extension TranscriptFollower { public mutating func catchUp(_ transcript: inout Transcript, upTo length: UInt64) throws }
  ```
- Produces (app):
  ```swift
  enum NoteEffect: Codable, Equatable {
    case prompt(text: String, context: String?, attachments: [AttachmentPreview])
    case queued(QueuedPrompt)            // QueuedPrompt gains Codable
    case answered(requestID: String)
    case none
  }
  enum SessionNote: Codable, Equatable {
    case started(first: AgentCommand?, effect: NoteEffect)  // backend.started ran
    case sent(AgentCommand, effect: NoteEffect)             // backend.send ran
  }
  enum HistoryMark: Codable, Equatable { case none, claudeFile(path: String, length: UInt64), codexTurns(Int) }
  struct SessionMeta: Codable, Equatable {
    var start: AgentStart            // what the process was launched with
    var windowFolder: String
    var name: String?
    var modePick: PermissionMode?; var modelPick: String?; var effortPick: String?
    var accountPick: ClaudeAccount?
    var sessionID: String?           // once system/init said it
    var savedTarget: ResumeTarget?
    var history: HistoryMark
    var fanOut: FanOutMark?          // Task 11; nil until then
  }
  final class ReplayTransport: ProcessTransport {
    enum Mode { case muted, owed }   // owed: keep writes to send once replay ends
    var mode: Mode
    private(set) var owed: [Data]
  }
  // AgentSession
  init(replaying records: [HostRecord], meta: SessionMeta, backend: AgentBackend? = nil) async
  /// What a spawn runs on; `AgentProcess.init` until Task 8 puts the host first. Tests give a recorder.
  @ObservationIgnored var makeTransport: (AgentProcess.Configuration) async -> any ProcessTransport
  // AgentProcess: `public static func parse(_ line: Data) -> AgentProcess.Line` (was private)
  ```

- [ ] **Step 1: Write the failing tests** in `SessionReplayTests` (`@MainActor @Suite("Replaying a session")`). Each test drives a live session against a stand-in `claude` script and records it, then replays the record into a fresh session:
  - Stand-in script: on its first stdin line it prints `system/init` with `session_id`. After the user line: an assistant text message, a `can_use_tool` `control_request` `req-1`, then waits for a stdin line holding `"req-1"`. Then a second assistant message and a `result`. Build it from the shapes in `Packages/DrakarKit/Tests/DrakarKitTests/Fixtures`.
  - `replayRebuildsTheTranscript`: live send "hi", answer `req-1` allow, wait for the `result`. Replay `recorder.records` into `AgentSession(replaying:meta:)`. `#expect(replayed.transcript.entries == live.transcript.entries)`.
  - `replayWritesNothing`: the `ReplayTransport` in `.muted` holds `owed.isEmpty`, and the stand-in got no line during replay (it logs its stdin to `$0.stdin`; the file's line count is unchanged).
  - `anAnsweredPermissionIsNotPendingAgain`: replay cut right after the answer note: `#expect(replayed.transcript.pendingPermissions.isEmpty)`.
  - `anUnansweredPermissionIsPending`: replay cut before the answer note: `#expect(replayed.transcript.pendingPermissions.map(\.requestID) == ["req-1"])`.
  - `replayFiresNoCallbacks`: a log with 3 turn ends and 2 permission requests: `onTurnEnded`, `onPermissionRequested` and `onPromptSent` are never called during replay.
  - `owedRepliesAreSentOnce`: an `out` record with `attached: false` holding an elicitation `control_request`. After replay, `owed` holds exactly one reply line for it. A second record for the same request with `attached: true` adds nothing.
  - In `TranscriptFollowerTests`, `catchUpStopsAtALength`: a file of 3 lines, `upTo:` the length after line 2, gives the entries of 2 lines.
- [ ] **Step 2: Run them to see them fail.** Run: `xcodebuild test -project apps/apple/Drakar.xcodeproj -scheme Drakar -destination 'platform=macOS' -only-testing:DrakarTests/SessionReplayTests`. Expected: compile failure (no `AgentSession(replaying:meta:)`).
- [ ] **Step 3: Introduce `ProcessTransport`.** `AgentSession.process` becomes `(any ProcessTransport)?`, and the backends' parameters change with it. Add a test-only in-memory recorder, `RecordingTransport` in `SessionReplayTests`. It wraps an `AgentProcess`, logs `.in`/`.out` records with `attached: true` into `records`, and is handed to the live session through `makeTransport`. `AgentSession` writes `.note` records to the transport when it conforms to the new internal protocol `NoteSink { func note(_ bytes: Data) }`. `RecordingTransport` and Task 6's `HostedProcess` conform.
- [ ] **Step 4: Write notes.** Each place `AgentSession` calls `backend.started` or `backend.send` first writes the matching `SessionNote`, JSON-encoded, through `NoteSink`, with the transcript effect it applies: `send()` gives `.prompt` or `.queued`, `answer()` gives `.answered`, anything else `.none`.
- [ ] **Step 5: Implement `AgentSession(replaying:meta:)`.**
  1. Set folder, backend, picks, name, `accountPick`, `resuming = meta.savedTarget ?? meta.start.resuming`.
  2. Load the history named by `meta.history`: `.claudeFile` reads through `catchUp(_:upTo:)`. Codex comes in Task 2.
  3. Run `backend.launch(meta.start)` for its state.
  4. Go through the records in order, with an internal `isReplaying` flag that silences every `on…` callback:
     - `.note`: apply its effect to the transcript, then `backend.started`/`backend.send` it to a `ReplayTransport`.
     - `.out`: parse it with `AgentProcess.parse` and handle it through the same code as live lines, at `record.time`. The transport's mode is `.owed` when `record.attached == false`, `.muted` otherwise.
     - `.in`: skip.

  Owed writes stay in `ReplayTransport.owed` for the caller (Task 9). An auto-reply to an `attached: true` record was written live, so muting it is right. One to an `attached: false` record never was, so it's owed.
- [ ] **Step 6: Run the tests.** Same command as Step 2. Expected: PASS. Then run `make -C apps/apple test` and the `AgentSessionTests`, `ProjectFanOutTests` and `CodexSessionsTests` suites. Expected: PASS.
- [ ] **Step 7: Commit.** `git commit -m "feat(apple): a session can be rebuilt from a log of its process and its own notes"`

### Task 2: Codex replay

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentSession.swift`, `apps/apple/Drakar/Services/CodexBackend.swift`
- Create or modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/AgentEvent.swift` (history cut)
- Test: `apps/apple/DrakarTests/SessionReplayTests.swift` (Codex cases), `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/AgentEventHistoryTests.swift`

**Interfaces:**
- Consumes: Task 1's `SessionNote`, `HistoryMark.codexTurns`, `ReplayTransport`, `AgentSession(replaying:meta:)`.
- Produces: `extension Array where Element == AgentEvent { public func throughTurns(_ count: Int) -> [AgentEvent] }`, which keeps events up to and including the `count`th `.turnEnded`; `0` keeps those before the first `.turnStarted`. `SessionMeta.history` is `.codexTurns(n)` for a Codex session, `n` being the history's `.turnEnded` count when the process started.

- [ ] **Step 1: Write the failing tests.**
  - `AgentEventHistoryTests.cutsAtTheNthTurnEnd`: the events `[sessionStarted, turnStarted, prompt, turnEnded, turnStarted, prompt, turnEnded]` give a prefix of 4 for `throughTurns(1)`, all 7 for `throughTurns(5)`, and `[sessionStarted]` for `throughTurns(0)`.
  - `SessionReplayTests.codexReplayRebuildsTheThread`: a stand-in `codex app-server` replies to `initialize`, `thread/start` and `turn/start` and streams one turn (shapes from `docs/codex-app-server.md` and the existing Codex test stand-ins). Live, then replayed: equal `transcript.entries`. Replay a log cut mid-turn, set the `ReplayTransport` to `.owed`, and have the replayed session send `.interrupt`. `owed` then holds one `turn/interrupt` naming the live turn's id.
- [ ] **Step 2: Run them to see them fail.** Run: the Step 2 command of Task 1 plus `swift test --package-path apps/apple/Packages/DrakarKit --filter AgentEventHistoryTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `throughTurns` goes in DrakarKit. In replay, `.codexTurns(n)` loads `CodexHistory.events` and cuts it with `throughTurns(n)`. Re-running `CodexBackend.launch`, `started` and `send` in order puts `CodexSession` back in the same state, as its ids come from counters. If a test shows it doesn't, add a `CodexSession` init from its state, and keep that state in `meta` rather than in the notes.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): a Codex session can be rebuilt from its process log too"`

**Stop point.** Run the opt-in live check: `SessionReplayTests.liveClaudeReplayMatches`, gated on the environment variable `DRAKAR_LIVE_CLI=1`. It runs the real `claude` with `--model claude-haiku-4-5-20251001 --setting-sources project` in a scratch folder, and `codex` the same way. Report to the person: pass or fail, plus every entry that differs. Wait for their go-ahead before starting Part B.

## Part B: the host

### Task 3: Wire types and the log file

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostWire.swift`, `Host/HostLog.swift`
- Modify: `docs/superpowers/specs/2026-10-25-session-host-design.md` §2 (add the `note` request and the `caughtUp` event; record fields `time`, `attached`)
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/HostWireTests.swift`, `HostLogTests.swift`

**Interfaces:**
- Consumes: `HostRecord` (Task 1), `AgentProcess.Configuration: Codable` (Task 1).
- Produces:
  ```swift
  public enum HostWire {
    public static let major = 1, minor = 0
    public static func directory(bundleID: String, home: URL) -> URL   // <home>/Library/Application Support/<id>/host
    public static func socket(in directory: URL, major: Int = major) throws -> URL  // throws PathTooLong over 103 bytes
  }
  public struct HeldProcess: Codable, Sendable, Equatable {
    public var id: String; public var meta: Data; public var running: Bool
    public var exitStatus: Int32?; public var logLength: UInt64; public var attachedApp: Int32?
  }
  public enum HostRequest: Codable, Sendable, Equatable {
    case hello(protocol: Int, appVersion: String), list
    case spawn(AgentProcess.Configuration, meta: Data)
    case attach(id: String, from: UInt64), write(id: String, bytes: Data), note(id: String, bytes: Data)
    case closeInput(id: String), terminate(id: String), setMeta(id: String, meta: Data), acknowledge(id: String)
  }
  public enum HostEvent: Codable, Sendable, Equatable {
    case welcome(protocol: Int, hostVersion: String, pid: Int32), listed([HeldProcess]), spawned(id: String)
    case record(id: String, HostRecord), caughtUp(id: String, offset: UInt64)
    case stderr(id: String, text: String), exited(id: String, status: Int32)
    case released(id: String), refused(reason: String)
  }
  public final class HostLog: @unchecked Sendable {
    public init(url: URL) throws
    @discardableResult public func append(_ kind: HostRecord.Kind, bytes: Data, time: Date, attached: Bool) throws -> HostRecord
    public func records(from offset: UInt64) throws -> [HostRecord]
    public var length: UInt64 { get }
    public func remove() throws
  }
  ```
  On disk, each record is one JSON line (`JSONEncoder`, `Data` as base64), and `offset` is the byte offset where its line starts. Request ids and replies on the wire are the builder's choice (spec, "Left to the builder"), inside Task 5.

- [ ] **Step 1: Write the failing tests.**
  - `HostWireTests.requestsAndEventsRoundTrip`: every case survives encode and decode.
  - `socketPathIsUnderTheBundlesFolder`: equals `<home>/Library/Application Support/io.mgcrea.Drakar/host/host-v1.sock`.
  - `aPathTooLongThrows`: a 120-byte directory throws `HostWire.PathTooLong`.
  - `HostLogTests.appendsAndReadsFromAnOffset`: 3 appends, then `records(from: second.offset)` gives the last 2.
  - `aTornLastLineIsIgnored`: append 2, add half a JSON line to the file by hand, then `records(from: 0)` gives 2 and `length` stays the end of record 2.
  - `bytesSurviveExactly`: a record holding `0x00`, `\n`, and invalid UTF-8 comes back byte for byte.
- [ ] **Step 2: Run them to see them fail.** Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter 'HostWireTests|HostLogTests'`. Expected: FAIL (missing types).
- [ ] **Step 3: Implement** in the two files. The spec edit goes in the same commit.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): the session host's wire types and log file"`

### Task 4: The host's core

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostCore.swift`, `Host/HostChild.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/HostCoreTests.swift`

**Interfaces:**
- Consumes: Task 3's types; `LineBuffer` (existing).
- Produces:
  ```swift
  public final class HostCore: @unchecked Sendable {
    public typealias Client = Int
    public init(directory: URL, hostVersion: String, now: @escaping @Sendable () -> Date = Date.init)
    public var deliver: @Sendable (Client, HostEvent) -> Void       // events to one connected app
    public func connected(pid: Int32) -> Client
    public func disconnected(_ client: Client)                      // detaches its processes; `released` to the rest
    public func handle(_ request: HostRequest, from client: Client) -> [HostEvent]  // direct replies
    public var isIdle: Bool { get }                                 // no process held, no client
  }
  ```
  `HostChild` holds one process: `Process` and its three pipes, raw bytes. Stdout is split into lines with `LineBuffer`, each line an `.out` record. Bytes after the last newline at exit are one more `.out` record. Stderr keeps only its last 64 KB. A `write` is written, then logged `.in`. A `note` is only logged.

- [ ] **Step 1: Write the failing tests** (stand-in scripts as in `ProcessTests`):
  - `spawnLogsAndForwards`: spawn `cat`, attach, write `a\n`. The client gets `.record(.in, "a\n")`, then `.record(.out, "a\n")`.
  - `attachReplaysThenCaughtUp`: write two lines unattached, then `attach(from: 0)` gives 4 records, then `.caughtUp(offset: log.length)`.
  - `aRecordWhileNobodyIsAttachedSaysSo`: an `.out` logged after `disconnected` has `attached == false`.
  - `exitWhileUnattachedIsKept`: the process exits with no client. `list` shows `running: false, exitStatus: 0`, and the log is still there. `acknowledge` removes it and its log file.
  - `attachIsRefusedWhileAnotherAppHolds`: client 2's `attach` gives `.refused`. When client 1 disconnects, client 2 gets `.released`.
  - `idleOnlyWithNothingHeld`: `isIdle` is false while a process runs or an ended one is unacknowledged.
  - `notesAreLoggedNotWritten`: a `note` shows up in the log as `.note`, and `cat` echoes nothing.
- [ ] **Step 2: Run them to see them fail.** Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter HostCoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Process ids are `UUID().uuidString` and log files are `<directory>/<id>.log`. The core is thread-safe behind a `Mutex`, like `AgentProcess.State`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): the session host's core holds processes and their logs"`

### Task 5: The socket, server and client

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/UnixSocket.swift`, `Host/HostServer.swift`, `Host/HostClient.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/HostSocketTests.swift`

**Interfaces:**
- Consumes: `HostCore` (Task 4), the wire types (Task 3).
- Produces:
  ```swift
  public final class HostServer: @unchecked Sendable {
    /// Takes `host.lock` (flock, non-blocking) in `directory`; nil when another host holds it.
    public static func start(directory: URL, core: HostCore,
      peerCheck: @escaping @Sendable (_ fd: Int32) -> Bool) throws -> HostServer?
    public func stop()
  }
  public final class HostClient: @unchecked Sendable {
    public static func connect(socket: URL) throws -> HostClient        // throws when nothing answers
    public func hello(appVersion: String) async throws -> (protocol: Int, hostVersion: String, pid: Int32)
    public func list() async throws -> [HeldProcess]
    public func spawn(_ configuration: AgentProcess.Configuration, meta: Data) async throws -> String
    public func attach(_ id: String, from: UInt64) -> AsyncStream<HostEvent>  // records…, caughtUp, then live
    public func send(_ request: HostRequest) throws                          // write, note, closeInput, terminate, setMeta, acknowledge
    public var released: AsyncStream<String> { get }
    public var disconnected: AsyncStream<Void> { get }
    public func close()
  }
  ```
  `HostServer.start` creates the directory 0700, unlinks a stale socket under the lock, binds and sets 0600, and refuses a peer whose `getpeereid` uid differs before `peerCheck` runs. Framing is newline JSON, with request ids however the builder wants.

- [ ] **Step 1: Write the failing tests**, with the directory `/tmp/dh-<6 random chars>`, removed in `defer`:
  - `aClientSpawnsAndAttaches`: connect, `hello`, `spawn` a `cat`, `attach`, `send(.write)`, and receive the `.out` record.
  - `theSocketIsTheUsersAlone`: `stat` shows the directory 0700 and the socket 0600.
  - `aSecondServerFindsTheLock`: `start` on the same directory returns nil while the first runs.
  - `aStaleSocketIsReplaced`: leave a socket file with no listener, and `start` succeeds.
  - `aRefusedPeerLearnsNothing`: with `peerCheck` returning false, `hello` throws and the core saw no `connected`.
  - `losingTheConnectionDetaches`: `close()` one client, and a second gets `.released` for its processes.
- [ ] **Step 2: Run them to see them fail.** Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter HostSocketTests`. Expected: FAIL.
- [ ] **Step 3: Implement** with POSIX `socket(AF_UNIX, SOCK_STREAM)`, `bind`, `listen`, `accept` and `DispatchSource` reads. No `NWListener`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): the session host's Unix socket, server and client"`

### Task 6: `HostedProcess`

**Files:**
- Create: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Host/HostedProcess.swift`
- Test: `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/HostedProcessTests.swift`

**Interfaces:**
- Consumes: `HostClient` (Task 5), `ProcessTransport` (Task 1).
- Produces:
  ```swift
  public final class HostedProcess: ProcessTransport, @unchecked Sendable {
    public init(client: HostClient, configuration: AgentProcess.Configuration, meta: Data)  // start() spawns
    public init(client: HostClient, held: HeldProcess)                                     // reattach (Task 9)
    public private(set) var id: String?
    public func note(_ bytes: Data)            // satisfies the app's NoteSink (Task 1)
    public func setMeta(_ meta: Data)
    public func replay() async throws -> (records: [HostRecord], offset: UInt64)  // attach from 0 up to caughtUp
    public func live() -> AsyncStream<AgentProcess.Event>   // after replay: what start() returns for a new one
    public func acknowledge()
    public func detach()                       // leaves the process running in the host
  }
  ```
  The app declares `extension HostedProcess: NoteSink {}`. `start()` (new process) and `live()` (reattached) yield the same `AgentProcess.Event`s `AgentProcess` does: `.out` records become `.lines`, parsed with the same `parse` (`AgentProcess.parse`, made public in Task 1). `.in` and `.note` records are skipped. Exit becomes `.exited(status:remainder:)`, with `remainder` empty, since the host already logged it as an `.out`.

- [ ] **Step 1: Write the failing tests.** Run the existing `ProcessTests` behaviours against `HostedProcess`, through a parameterised test over both transports, a server in `/tmp/dh-…` and the same stand-in scripts: lines in order, stderr kept, exit status, `closeInput` ending `cat`, `terminate`. Add `reattachReplaysThenGoesLive`: write, `detach()`, then a new `HostedProcess(client:held:)` gets the records from `replay()` and new output from `live()`.
- [ ] **Step 2: Run them to see them fail.** Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter 'HostedProcessTests|ProcessTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): HostedProcess runs an agent through the session host"`

### Task 7: The `DrakarHost` helper, its launch, and the network audit

**Files:**
- Create: `apps/apple/DrakarHost/main.swift`, `apps/apple/DrakarHost/PeerSignature.swift`
- Modify: `apps/apple/Drakar.xcodeproj/project.pbxproj`: a `com.apple.product-type.tool` target `DrakarHost`, with a synchronized root group `DrakarHost` and the `DrakarKit` package product, hardened runtime on, signing as the app's, and `SKIP_INSTALL = YES`. The app target depends on it and copies it in a `PBXCopyFilesBuildPhase` (`dstSubfolderSpec = 1`, `dstPath = Contents/Helpers`, `CodeSignOnCopy`).
- Create: `apps/apple/Drakar/Services/SessionHost.swift`
- Modify: `scripts/audit-network.sh`, `README.md` (the network claim)
- Test: `apps/apple/DrakarTests/SessionHostTests.swift`

**Interfaces:**
- Consumes: `HostServer`, `HostCore`, `HostClient`, `HostWire`.
- Produces:
  - `DrakarHost --directory <dir>`: runs `HostServer.start`, exits 0 at once when that returns nil, and exits after `isIdle` holds for 30 seconds (checked every 5 s). `PeerSignature.sameTeam(fd:) -> Bool`: `LOCAL_PEERTOKEN`, then `SecCodeCopyGuestWithAttributes` (audit token), then the requirement `anchor apple generic and certificate leaf[subject.OU] = "<own team>"`. The host's own team comes from `SecCodeCopySelf` + `kSecCodeInfoTeamIdentifier`.
  - ```swift
    @MainActor final class SessionHost {
      static let shared: SessionHost
      /// Tests only: a directory to use under XCTest instead of none.
      static var testDirectory: URL?
      var isAvailable: Bool { get }                 // false until connected; false for good when the helper can't start
      func client() async -> HostClient?            // connects, starting the helper when nothing answers (backoff 50 ms → 2 s, give up after 5 s)
      func held() async -> [HeldProcess]
      var onReleased: ((String) -> Void)?
    }
    ```
    The helper is started with `posix_spawn` and `POSIX_SPAWN_SETSID`, stdio on `/dev/null`, from `Bundle.main.url(forAuxiliaryExecutable: "DrakarHost")`.
- [ ] **Step 1: Write the failing tests**, hosted in the app, so `Contents/Helpers/DrakarHost` exists:
  - `theHelperIsBundledAndSigned`: the file exists, and `SecStaticCode` gives the app's team identifier.
  - `aClientStartsTheHelper`: with `testDirectory = /tmp/dh-…`, `client()` returns a client whose `hello` names `HostWire.major`. `defer` terminates the helper through its pid.
  - `twoHostsStartingAtOnceLeaveOne`: two `posix_spawn`s of the helper on one directory, 1 s apart. One pid is left, and two clients both connect to it.
  - `theHelperLeavesWhenIdle`: after `close()`, the helper's pid is gone within 40 s (`#expect` polling; tag the test `.timeLimit(.minutes(1))`).
  - `noHostUnderTestsUnlessAsked`: with `testDirectory = nil`, `client()` returns nil and nothing is spawned.
- [ ] **Step 2: Run them to see them fail.** Run: `xcodebuild test … -only-testing:DrakarTests/SessionHostTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the target, `SessionHost` and the peer check.
- [ ] **Step 4: Update the network audit.** In `scripts/audit-network.sh`, keep "exactly one NWListener". Add checks, written portably for BSD tools:
  - Exactly one `socket(AF_UNIX` in `apps/apple/DrakarHost` and `Packages/DrakarKit/Sources`.
  - The host directory is created 0700.
  - Under `--running`: the socket file is mode 0600 and belongs to the user.

  Update the README's claim to say: one loopback listener for the IDE bridge, and one Unix socket for the session host that only the user's own Drakar can reach. Run `scripts/audit-network.sh`. Expected: all `ok`.
- [ ] **Step 5: Run the tests.** Expected: PASS. Then `xcodebuild build`, `codesign -dv --verbose=2 <app>/Contents/Helpers/DrakarHost 2>&1 | grep TeamIdentifier`. Expected: `TeamIdentifier=75QE9PRT3V`.
- [ ] **Step 6: Commit.** `git commit -m "feat(apple): Drakar bundles and starts its session host"`

## Part C: the app

### Task 8: Sessions run through the host, and quitting hands them over

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentSession.swift`, `apps/apple/Drakar/DrakarApp.swift` (`applicationShouldTerminate`, `applicationWillTerminate`), `apps/apple/Drakar/Services/Workspace.swift` (`RunningSessions` counts only un-hosted ones), `apps/apple/Drakar/Views/SessionView.swift` (footer note)
- Create: `apps/apple/Drakar/Services/AppLifecycle.swift`
- Test: `apps/apple/DrakarTests/HostedSessionTests.swift`

**Interfaces:**
- Consumes: `SessionHost`, `HostedProcess`, `SessionMeta`, `SessionNote`.
- Produces:
  - `enum AppLifecycle { @MainActor static var isTerminating: Bool }`.
  - In `AgentSession`:
    - `var isHosted: Bool`.
    - `var isAtWork: Bool`: `transcript.isRunning || !transcript.pendingPermissions.isEmpty`.
    - `func meta() -> SessionMeta`, pushed with `setMeta` whenever its value changes: after each handled batch and each command.
    - `stop()` calls `HostedProcess.detach()` instead of terminating when `AppLifecycle.isTerminating && isHosted && isAtWork`.
  - `makeTransport`'s default becomes: `if let client = await SessionHost.shared.client()`, a `HostedProcess(client:configuration:meta:)`; otherwise an `AgentProcess`, as today.
  - The footer reads "Stops when Drakar quits." for a running session that isn't hosted.
  - `applicationShouldTerminate`: the running-sessions alert counts only sessions that aren't hosted.
- [ ] **Step 1: Write the failing tests**, with `SessionHost.testDirectory` set and a stand-in `claude`:
  - `aSessionRunsThroughTheHost`: after spawn, `session.isHosted`, and `held()` lists one process whose decoded `meta.windowFolder` is the project's.
  - `quittingHandsOverASessionAtWork`: mid-turn, with `isTerminating = true`, `stop()` leaves the process running in `held()`.
  - `quittingStopsAnIdleSession`: after a `result`, `stop()` under `isTerminating` terminates it, and `held()` shows `running: false`.
  - `closingTheWindowStillStops`: with `isTerminating = false`, `stop()` mid-turn terminates.
  - `withoutAHostSessionsRunAsBefore`: with `testDirectory = nil`, the session runs as an `AgentProcess`, and the quit alert counts it.
- [ ] **Step 2: Run them to see them fail.** Run: `xcodebuild test … -only-testing:DrakarTests/HostedSessionTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS. Then run `make -C apps/apple test-app`. Expected: PASS, except the known timing flakes (see Global Constraints).
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): sessions run in the session host, and quitting leaves the ones at work running"`

### Task 9: Coming back after a relaunch

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentSession.swift` (`init(reattaching:)`), `apps/apple/Drakar/Services/Project.swift` (adopt held processes), `apps/apple/Drakar/DrakarApp.swift` (open their windows at launch), `apps/apple/Drakar/Services/ReopenedWindows.swift`
- Test: `apps/apple/DrakarTests/ReattachTests.swift`

**Interfaces:**
- Consumes: `HostedProcess.replay()/live()/acknowledge()`, `AgentSession(replaying:meta:)` (Task 1), `ReplayTransport.owed`.
- Produces:
  - `AgentSession.init(reattaching held: HeldProcess, client: HostClient) async`: it decodes `meta`, replays with `AgentSession(replaying:meta:)`'s path (the parsing runs off the main actor, then is applied), sends `owed` through the `HostedProcess`, and goes live with `live()`. When `running == false`, it shows the exit as a live exit does, then calls `acknowledge()`.
  - `Project.adoptHeld(_ held: [HeldProcess]) async`: rows for the held processes whose `meta.windowFolder` is this project's and that no app holds (`attachedApp == nil`). A `StoredProject` session with the same `sessionID` isn't opened a second time.
  - At launch, `DrakarApp` lists `held()` and calls `WindowTabs.open(.project(folder), asTab: false)` for each folder among the unattached ones, whatever the reopen setting.
  - A lost connection while the app runs: `SessionHost` reconnects on `HostClient.disconnected` with Task 7's backoff. Meanwhile each hosted session shows "Reconnecting to the session host…" in its footer and sends nothing. Once reconnected, it attaches `from:` the offset it last read, and records after that are handled as live.
- [ ] **Step 1: Write the failing tests**, with a test host and a stand-in `claude` that streams slowly. The app's side of a session is dropped with `HostedProcess.detach()` plus discarding the `AgentSession`, standing in for a quit.
  - `aSessionAtWorkComesBackLive`: drop mid-turn, then `Project.adoptHeld`. The row's transcript equals the dropped one's plus anything streamed since, each entry once, and the turn is still running. The stand-in's next line reaches it.
  - `aPermissionWaitingIsAnsweredOnce`: drop while `req-1` is waiting, then reattach. It's pending; answer it, and the stand-in's stdin log holds exactly one reply to `req-1`.
  - `anElicitationThatArrivedWhileAwayIsDeclinedOnce`: one arrives while detached, then reattach. The stdin log holds one decline.
  - `anEndedSessionIsShownAndForgotten`: the process exits while detached. After reattach, the row shows the end, and `held()` no longer lists it.
  - `anEndedSessionWhoseFolderIsGoneComesBackEnded`: the same, with the folder removed before reattach. The row shows the end, nothing is spawned, and nothing crashes.
  - `aKilledAppLeavesEverySessionToReattach`: two sessions, one idle and one at work. Drop both with no handover: `client.close()`, no `stop()`. Both come back, the idle one idle.
  - `aLongLogReplaysQuickly`: a log of 50,000 `.out` records (≈30 MB of fixture assistant messages) replays in under 5 s, and the main actor is never blocked for more than 100 ms (time the gaps of a 10 ms repeating main-actor task).
  - `aLostConnectionReattachesFromWhereItWas`: kill the test host's client socket mid-turn (`client.close()` from the host side). The session shows the reconnecting footer, comes back once a new connection is up, and its transcript has each entry once.
  - `windowsOpenForHeldSessions`: `held()` names two folders, so launch opens two project routes (inject `WindowTabs.open` through a seam).
- [ ] **Step 2: Run them to see them fail.** Run: `xcodebuild test … -only-testing:DrakarTests/ReattachTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): a relaunched Drakar picks its sessions back up from the session host"`

### Task 10: Two apps, `released`, and an older host

**Files:**
- Modify: `apps/apple/Drakar/Services/AgentSession.swift`, `apps/apple/Drakar/Services/Project.swift`, `apps/apple/Drakar/Services/SessionHost.swift`, `apps/apple/Drakar/Views/SessionView.swift` (the Codex line)
- Test: `apps/apple/DrakarTests/TwoAppsTests.swift`

**Interfaces:**
- Consumes: `HeldProcess.attachedApp`, `HostClient.released`, `SessionHost.onReleased`.
- Produces:
  - `Project.adoptHeld` also makes rows for processes another app holds. Claude Code ones are read-only (`isReadOnly`), following `meta.savedTarget`'s file as a session live elsewhere does today. Codex ones load history through `throughTurns`, plus a note entry: "Running in another Drakar window." (localized, not live).
  - On `released(id)`, such a row reattaches, as in Task 9.
  - `SessionHost` lists the sockets in its directory with a lower major (`host-v<n>.sock`, `n < HostWire.major`). Their processes are always held elsewhere, using `hello` and `list` only.
- [ ] **Step 1: Write the failing tests.**
  - `aLaunchLeavesAnotherAppsSessionsAlone`: client A holds a process. Project B's `adoptHeld` makes it read-only, and B's attach is never sent (spy client).
  - `releasedBringsItBack`: A closes, B's row becomes live, and its transcript is whole.
  - `aCodexSessionElsewhereSaysSo`: the row ends with the note entry and can't send.
  - `anOlderHostIsReadOnly`: a v0 socket served by a test `HostServer` speaking only `hello`/`list`. Its process shows read-only and is never attached.
- [ ] **Step 2: Run them to see them fail.** Run: `xcodebuild test … -only-testing:DrakarTests/TwoAppsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): sessions another Drakar holds stay with it until it lets them go"`

### Task 11: Fan-out batches survive a relaunch

**Files:**
- Modify: `apps/apple/Packages/DrakarKit/Sources/DrakarKit/FanOut.swift` (`init(ids:limit:states:)`), `apps/apple/Drakar/Services/Project.swift` (`StoredProject.fanOuts`, restore), `apps/apple/Drakar/Services/SessionMeta.swift` (`FanOutMark`)
- Test: `apps/apple/DrakarTests/ProjectFanOutTests.swift`, `apps/apple/Packages/DrakarKit/Tests/DrakarKitTests/FanOutTests.swift`

**Interfaces:**
- Consumes: `Project.runInSubfolders`, `FanOutBatch`, `adoptHeld` (Task 9).
- Produces:
  ```swift
  struct FanOutMark: Codable, Equatable { var batch: UUID; var index: Int }
  struct StoredFanOut: Codable, Equatable {
    struct Entry: Codable, Equatable {
      var folder: String; var name: String; var accountDirectory: String?; var mode: PermissionMode?
      var hostID: String?                 // once spawned
      var state: FanOut<UUID>.State       // FanOut.State gains Codable
    }
    var batch: UUID; var skillName: String; var prompt: String; var limit: Int?; var entries: [Entry]
  }
  // StoredProject: var fanOuts: [StoredFanOut]?   (optional, so older stored windows still decode)
  public init(ids: [ID], limit: Int?, states: [ID: State])   // FanOut
  ```
  On restore, entries with a `hostID` take their reattached rows. Waiting entries become new sessions in their folders, named, with their account and mode, and are not sent. The batch's `FanOut` is rebuilt with its states, and sending carries on as running rows finish.
- [ ] **Step 1: Write the failing tests.**
  - `FanOutTests.restoredStatesCarryOn`: `init(ids: [a, b, c], limit: 1, states: [a: .running, b: .waiting, c: .waiting])`, then `finished(a) == [b]`.
  - `ProjectFanOutTests.aBatchSurvivesARelaunch`: limit 1 over three folders, with a test host. Store, drop the app's side, then restore into a new `Project`. One row is live, two wait. When the live turn ends, the second is sent `/check`.
- [ ] **Step 2: Run them to see them fail.** Run: `swift test --package-path apps/apple/Packages/DrakarKit --filter FanOutTests` and `xcodebuild test … -only-testing:DrakarTests/ProjectFanOutTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(apple): a skill run in each subfolder carries on after a relaunch"`

### Task 12: Docs, the full run, and landing

**Files:**
- Create: `docs/session-host.md` (the protocol as built: requests, events, records, framing, versions, where files live, how to inspect a log)
- Modify: `docs/superpowers/specs/2026-10-25-session-host-design.md` (only where the build departed from it, each departure said)

- [ ] **Step 1: Write the docs**, in the voice of `docs/claude-ide-bridge.md`.
- [ ] **Step 2: Merge `main` into the branch and run everything.** Run: `make -C apps/apple test test-app format-swift-check` and `scripts/audit-network.sh`. Expected: PASS, except the known timing flakes, rerun alone.
- [ ] **Step 3: Commit.** `git commit -m "docs: the session host's protocol"`
- [ ] **Step 4: Hand over for the live check.** The person relaunches their own Drakar, since only they may quit it. Give them the checklist:
  1. Start a long turn and one that asks a permission, then quit Drakar.
  2. In Activity Monitor, `claude` is still running under `DrakarHost`.
  3. Reopen Drakar: both windows come back, the turn is still streaming, and the permission can be answered.
  4. `make run` from a worktree does the same.

  Land with `git merge --ff-only` once they say so.
