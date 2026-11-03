import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Closing a session's tab (session tabs spec, Closing): an idle session ends as a removed row
/// did, one at work goes on in the session host, marked closed so no window takes it back on
/// its own, and ends once its turn does. The host is the test's own (`LocalHost`), the
/// stand-in `claude` streams a turn a step at a time as `ReattachTests`' does. Serialized:
/// `SessionHost.testDirectory` is one for the app.
@MainActor
@Suite("Closing a tab", .serialized, .timeLimit(.minutes(2)))
struct CloseTabTests {
  private let host: LocalHost
  private let folder: URL
  private let bin: URL
  private let fake: URL
  private var received: URL { fake.appendingPathExtension("stdin") }

  init() throws {
    host = try LocalHost()
    let scratch = FileManager.default.temporaryDirectory.appending(
      path: "drakar-closetab-\(UUID().uuidString)", directoryHint: .isDirectory)
    folder = scratch.appending(path: "project", directoryHint: .isDirectory)
    bin = scratch.appending(path: "bin", directoryHint: .isDirectory)
    for directory in [folder, bin] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    fake = bin.appending(path: "claude")
    try Data(Self.script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  /// What the prompt names it plays, after `system/init`: `go-stream` says one, then two
  /// and three a step apart; `go-stream-end` does too, then ends its turn; `go-ask-later` says
  /// one, then a step on asks to run a tool; `go-idle` ends its turn.
  private static let script = """
    #!/bin/sh
    sid="s-$$"
    log() { printf '%s\\n' "$1" >> "$0.stdin"; }
    step() { while [ ! -f "$0.$1" ]; do sleep 0.02; done; }
    say() { printf '%s\\n' '{"type":"assistant","message":{"id":"m-'"$1"'","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"'"$1"'"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"'"$sid"'"}'; }
    result() { printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","session_id":"'"$sid"'"}'; }
    while read -r line; do
      log "$line"
      case "$line" in *'"type":"user"'*) break;; esac
    done
    printf '%s\\n' '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"'"$sid"'","model":"m","permissionMode":"default"}'
    case "$line" in
      *go-stream-end*) say one; step a; say two; step b; say three; result;;
      *go-stream*) say one; step a; say two; step b; say three;;
      *go-ask-later*)
        say one; step a
        printf '%s\\n' '{"type":"assistant","message":{"id":"m-ls","type":"message","role":"assistant","model":"m","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"'"$sid"'"}'
        printf '%s\\n' '{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}';;
      *go-idle*) result;;
    esac
    while read -r line; do log "$line"; done

    """

  private func cleanUp() {
    host.close()
    SessionHost.testDirectory = nil
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  /// An app's way to the test's host. Its helper starts nothing: a reconnect waits for the
  /// host to take connections again.
  private func app() -> SessionHost {
    SessionHost.testDirectory = host.directory
    return SessionHost(cooldown: .milliseconds(100), helper: URL(filePath: "/usr/bin/true"))
  }

  private func window(on app: SessionHost) -> Project {
    let project = Project(folder: folder)
    project.executableOverride = fake
    project.sessionHost = app
    return project
  }

  /// The first start of the run waits on the login shell's environment, which takes a
  /// while when the whole suite starts at once: waited for here, not in the test's limits.
  private func start(_ prompt: String, in project: Project) async -> AgentSession {
    _ = await AgentSession.environment.value
    let session = project.newSession(agent: .claude).session
    session.accounts = { [] }
    session.send(prompt)
    return session
  }

  /// The stand-in's next step.
  private func step(_ name: String) throws {
    try Data().write(to: fake.appendingPathExtension(name))
  }

  private func eventually(
    within limit: Duration = .seconds(60), _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
  }

  /// The host logged more of the process than `length`: what it wrote once the tab closed.
  private func grew(past length: UInt64, on app: SessionHost) async -> Bool {
    await eventually { (await app.held().first?.logLength ?? 0) > length }
  }

  private func says(_ session: AgentSession, _ text: String) -> Bool {
    session.transcript.entries.contains { $0.kind == .text(text) }
  }

  /// The lines the stand-ins were sent that hold `text`.
  private func sent(_ text: String) -> Int {
    let log = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
    return log.split(separator: "\n").count { $0.contains(text) }
  }

  /// A monitor that lists `sessionID` as a Claude Code session of the window's folder, as its
  /// transcript on disk would.
  private func monitor(listing sessionID: String) async throws -> SessionMonitor {
    let path = ProjectPath.normalize(folder)
    let account = ClaudeAccount(
      directory: bin.appending(path: "claude-config", directoryHint: .isDirectory),
      isDefault: false)
    let transcripts = account.directory.appending(
      path: "projects/\(ProjectPath.encodedPrefixes(for: path)[0])", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try Data(#"{"type":"user","cwd":"\#(path)","message":{"role":"user","content":"go"}}"#.utf8)
      .write(to: transcripts.appending(path: "\(sessionID).jsonl"))
    let monitor = SessionMonitor(accounts: [account])
    await monitor.include(folder: path)
    return monitor
  }

  /// The meta the host keeps for its one process, decoded.
  private func heldMeta(on app: SessionHost) async -> SessionMeta? {
    guard let meta = await app.held().first?.meta else { return nil }
    return try? JSONDecoder().decode(SessionMeta.self, from: meta)
  }

  /// A window with a session at work in the host, whose tab is closed once it said one.
  private func closedAtWork(_ prompt: String, on app: SessionHost) async throws -> Project {
    let project = window(on: app)
    let live = await start(prompt, in: project)
    #expect(await eventually { says(live, "one") })
    let row = try #require(project.sessions.first { $0.session === live })
    project.closeTab(row)
    #expect(await eventually { await app.held().first?.attachedApp == nil })
    return project
  }

  @Test func aTabClosedAtWorkKeepsWorkingInTheHost() async throws {
    defer { cleanUp() }
    let app = app()
    let project = try await closedAtWork("go-stream", on: app)
    defer { project.stopAll() }
    #expect(project.sessions.isEmpty)
    let held = try #require(await app.held().first)
    #expect(held.attachedApp == nil)
    #expect(held.running)
    #expect(await heldMeta(on: app)?.closedAtWork == true)
    try step("a")
    #expect(await grew(past: held.logLength, on: app))
  }

  /// Once its turn ends, the host ends the process and forgets it.
  @Test func aTabClosedAtWorkEndsWithItsTurn() async throws {
    defer { cleanUp() }
    let app = app()
    let project = try await closedAtWork("go-stream-end", on: app)
    defer { project.stopAll() }
    try step("a")
    try step("b")
    #expect(await eventually { await app.held().isEmpty })
  }

  /// A turn waiting on the person is still at work: the ask does not end it.
  @Test func aTabClosedWhileAskingIsNotEndedByTheAsk() async throws {
    defer { cleanUp() }
    let app = app()
    let project = try await closedAtWork("go-ask-later", on: app)
    defer { project.stopAll() }
    let length = try #require(await app.held().first?.logLength)
    try step("a")
    // The tool use and the request after it.
    #expect(await grew(past: length, on: app))
    try await Task.sleep(for: .milliseconds(300))
    let held = try #require(await app.held().first)
    #expect(held.running)
    #expect(held.attachedApp == nil)
  }

  @Test func aTabClosedAtWorkStaysClosedWhenTheWindowReopens() async throws {
    defer { cleanUp() }
    let app = app()
    let closed = try await closedAtWork("go-stream", on: app)
    closed.stopAll(handingOver: true)

    let back = window(on: app)
    defer { back.stopAll() }
    await back.adoptHeld(await app.held())
    #expect(back.sessions.isEmpty)
    #expect(await app.held().first?.attachedApp == nil)
  }

  /// At launch, no window opens for a process whose tab was closed at work.
  @Test func heldWindowsSkipATabClosedAtWork() throws {
    var meta = SessionMeta(
      start: AgentStart(
        folder: folder, environment: [:], executableOverride: fake, allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), history: .none)
    let open = HeldProcess(
      id: "open", meta: try JSONEncoder().encode(meta), running: true, logLength: 0)
    meta.closedAtWork = true
    let closed = HeldProcess(
      id: "closed", meta: try JSONEncoder().encode(meta), running: true, logLength: 0)
    #expect(HeldWindows.folders(of: [closed]).isEmpty)
    #expect(
      HeldWindows.folders(of: [closed, open])
        == [ProjectPath.normalize(folder.path(percentEncoded: false))])
  }

  /// A prompt queued behind the turn is work still to do: the turn's end does not end it.
  @Test func aTabClosedWithAPromptQueuedRunsItsQueue() async throws {
    defer { cleanUp() }
    let app = app()
    let project = window(on: app)
    defer { project.stopAll() }
    let live = await start("go-stream-end", in: project)
    #expect(await eventually { says(live, "one") })
    live.send("later")
    #expect(live.transcript.queuedPrompts.map(\.text) == ["later"])
    let row = try #require(project.sessions.first { $0.session === live })
    project.closeTab(row)
    #expect(await eventually { await app.held().first?.attachedApp == nil })
    #expect(await heldMeta(on: app)?.closedAtWork == true)
    try step("a")
    try step("b")
    #expect(await eventually { sent("later") == 1 })
    // Long enough for the turn's `result` to have been read.
    try await Task.sleep(for: .milliseconds(300))
    let held = try #require(await app.held().first)
    #expect(held.running)
  }

  /// Until it ends, it is listed under Elsewhere in its own window, and in a window opened on
  /// the folder later; opened from there, it comes back as a live tab, not watched.
  @Test func aTabClosedAtWorkIsListedElsewhereAndOpensLive() async throws {
    defer { cleanUp() }
    let app = app()
    let project = window(on: app)
    defer { project.stopAll() }
    let live = await start("go-stream", in: project)
    #expect(await eventually { says(live, "one") })
    let sessionID = try #require(live.sessionID)
    project.monitor = try await monitor(listing: sessionID)
    #expect(project.groups.elsewhere.isEmpty)
    let row = try #require(project.sessions.first { $0.session === live })
    project.closeTab(row)
    #expect(await eventually { await app.held().first?.attachedApp == nil })
    #expect(project.groups.elsewhere.map(\.sessionID) == [sessionID])

    let later = window(on: app)
    defer { later.stopAll() }
    later.monitor = project.monitor
    await later.adoptHeld(await app.held())
    #expect(later.sessions.isEmpty)
    #expect(later.groups.elsewhere.map(\.sessionID) == [sessionID])

    let summary = try #require(project.groups.elsewhere.first)
    project.openElsewhere(summary)
    #expect(await eventually { project.sessions.count == 1 })
    let back = try #require(project.sessions.first)
    #expect(!back.isWatching)
    #expect(back.session.isHosted)
    #expect(back.session.transcript.isRunning)
    #expect(project.selectedID == back.id)
    #expect(project.groups.elsewhere.isEmpty)
    #expect(await eventually { await heldMeta(on: app)?.closedAtWork == nil })
    #expect(await app.held().first?.attachedApp == getpid())
  }

  /// A double-click on its row opens it twice: the second open, landing while the first
  /// takes the process back, finds it still being reopened, so one live tab comes of both
  /// and no preview is opened beside it.
  @Test func aClosedTabOpenedTwiceComesBackOnce() async throws {
    defer { cleanUp() }
    let app = app()
    let project = window(on: app)
    defer { project.stopAll() }
    let live = await start("go-stream", in: project)
    #expect(await eventually { says(live, "one") })
    let sessionID = try #require(live.sessionID)
    project.monitor = try await monitor(listing: sessionID)
    let row = try #require(project.sessions.first { $0.session === live })
    project.closeTab(row)
    #expect(await eventually { await app.held().first?.attachedApp == nil })
    let summary = try #require(project.groups.elsewhere.first)

    project.openElsewhere(summary)
    // The second click: as soon as the row leaves Elsewhere, or the tab is back.
    let deadline = ContinuousClock.now + .seconds(30)
    while project.sessions.isEmpty, !project.groups.elsewhere.isEmpty,
      ContinuousClock.now < deadline
    {
      await Task.yield()
    }
    project.openElsewhere(summary)
    #expect(!project.sessions.contains { $0.isWatching })
    #expect(await eventually { project.sessions.contains { $0.session.isHosted } })
    try await Task.sleep(for: .milliseconds(300))
    #expect(project.sessions.count == 1)
    let back = try #require(project.sessions.first)
    #expect(!back.isWatching)
    #expect(back.session.isHosted)
    #expect(project.selectedID == back.id)
  }

  /// Closed while the app reconnects to its host, nothing sent would reach the host: the
  /// process is handed over unmarked, as a closed window leaves it, listed as closed nowhere,
  /// and the next window on the folder takes it back.
  @Test func aTabClosedWhileReconnectingIsHandedOverUnmarked() async throws {
    defer { cleanUp() }
    let app = app()
    let project = window(on: app)
    defer { project.stopAll() }
    let live = await start("go-stream", in: project)
    #expect(await eventually { says(live, "one") })
    let sessionID = try #require(live.sessionID)
    project.monitor = try await monitor(listing: sessionID)

    host.stop()
    #expect(await eventually { live.isReconnecting })
    let row = try #require(project.sessions.first { $0.session === live })
    project.closeTab(row)
    #expect(project.sessions.isEmpty)
    #expect(project.groups.elsewhere.isEmpty)

    try host.start()
    #expect(await eventually { await app.held().first?.attachedApp == nil })
    #expect(await heldMeta(on: app)?.closedAtWork == nil)
    #expect(await app.held().first?.running == true)
    let later = window(on: app)
    defer { later.stopAll() }
    await later.adoptHeld(await app.held())
    #expect(later.sessions.count == 1)
    #expect(later.sessions.first?.session.isHosted == true)
  }

  /// A preview of a session another process runs holds no process of this app's: closing it
  /// stops nothing, so it asks nothing, and Close Other Tabs closes it. Its transcript reads
  /// as at work, a tool call unanswered, yet a followed transcript is never running here.
  @Test func closingAPreviewOfASessionAtWorkElsewhereAsksNothing() async throws {
    defer { cleanUp() }
    let project = Project(folder: folder)
    project.sessionHost = SessionHost()
    defer { project.stopAll() }
    let path = ProjectPath.normalize(folder)
    let file = bin.appending(path: "w.jsonl")
    let lines = [
      #"{"type":"user","cwd":"\#(path)","sessionId":"w","message":{"role":"user","content":"go"}}"#,
      #"{"type":"assistant","cwd":"\#(path)","sessionId":"w","message":{"id":"m-ls","type":"message","role":"assistant","model":"m","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"stop_reason":null}}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    let kept = project.newSession(agent: .claude)
    let preview = project.attach(
      ResumeTarget(
        sessionID: "w", cwd: path, file: file.path(percentEncoded: false),
        accountDirectory: bin.path(percentEncoded: false), accountIsDefault: false),
      watching: true, readOnly: true)
    #expect(await eventually { preview.session.status.hasEntries })
    #expect(preview.session.transcript.entries.count > 1)
    #expect(preview.session.isReadOnly && !preview.session.isProcessRunning)
    #expect(!preview.session.isAtWork)
    #expect(project.closeAsk(for: preview) == nil)
    project.closeOthers(than: kept)
    #expect(project.tabs.map(\.id) == [kept.id])
  }

  /// Opened again from Home: a live tab, the mark cleared, and no longer ended by its turn.
  @Test func reopeningClearsTheMark() async throws {
    defer { cleanUp() }
    let app = app()
    let closed = try await closedAtWork("go-stream-end", on: app)
    closed.stopAll(handingOver: true)
    let id = try #require(await app.held().first?.id)

    let back = window(on: app)
    defer { back.stopAll() }
    await back.reopen(id, among: await app.held())
    #expect(back.sessions.count == 1)
    let session = try #require(back.sessions.first?.session)
    #expect(session.isHosted)
    #expect(session.transcript.isRunning)
    #expect(await eventually { await heldMeta(on: app)?.closedAtWork == nil })

    try step("a")
    try step("b")
    #expect(await eventually { session.transcript.turnEnd != nil })
    try await Task.sleep(for: .milliseconds(300))
    #expect(await app.held().first?.id == id)
    #expect(session.isHosted)
  }

  /// Opened again, a tab closed at work comes back right of the tab shown, as a new one does.
  @Test func aReopenedTabOpensRightOfTheShownOne() async throws {
    defer { cleanUp() }
    let app = app()
    let closed = try await closedAtWork("go-stream", on: app)
    closed.stopAll(handingOver: true)
    let id = try #require(await app.held().first?.id)

    let back = window(on: app)
    defer { back.stopAll() }
    let a = back.newSession()
    let b = back.newSession()
    back.select(a)
    await back.reopen(id, among: await app.held())
    let reopened = try #require(back.sessions.first { $0.session.hostID == id })
    #expect(back.tabs.map(\.id) == [a.id, reopened.id, b.id])
    #expect(back.selectedID == reopened.id)
  }

  /// An idle tab ends its process, as a removed row did: the host forgets it.
  @Test func anIdleTabClosesAndEnds() async throws {
    defer { cleanUp() }
    let app = app()
    let project = window(on: app)
    defer { project.stopAll() }
    let live = await start("go-idle", in: project)
    #expect(await eventually { live.transcript.turnEnd != nil })
    #expect(await app.held().count == 1)
    let row = try #require(project.sessions.first { $0.session === live })
    project.closeTab(row)
    #expect(project.sessions.isEmpty)
    #expect(await eventually { await app.held().isEmpty })
  }

  /// Closing asks only when something would be lost: a draft or attachments, or a turn at
  /// work the host does not hold, running or waiting on the person. The draft is said first.
  @Test func closeAskSaysWhatWouldBeLost() async throws {
    defer { cleanUp() }
    // No host to be had: the session is the app's own child.
    let project = Project(folder: folder)
    project.executableOverride = fake
    project.sessionHost = SessionHost()
    defer { project.stopAll() }
    let row = project.newSession(agent: .claude)
    #expect(project.closeAsk(for: row) == nil)
    row.draft = "hi"
    #expect(project.closeAsk(for: row) == .unsentDraft)
    row.draft = "  \n"
    #expect(project.closeAsk(for: row) == nil)
    let note = bin.appending(path: "note.txt")
    try Data("a note".utf8).write(to: note)
    row.attachments = [try Attachment.file(at: note)]
    #expect(project.closeAsk(for: row) == .unsentDraft)
    row.attachments = []

    _ = await AgentSession.environment.value
    row.session.accounts = { [] }
    row.session.send("go-ask-later")
    #expect(await eventually { says(row.session, "one") })
    #expect(!row.session.isHosted)
    #expect(project.closeAsk(for: row) == .stopsTurn)
    try step("a")
    #expect(await eventually { row.session.status.isWaitingOnPerson })
    #expect(project.closeAsk(for: row) == .stopsTurn)
    row.draft = "hi"
    #expect(project.closeAsk(for: row) == .unsentDraft)
    // The draft given up, the turn is still asked about.
    #expect(project.closeAsk(for: row, draftConfirmed: true) == .stopsTurn)
  }
}
