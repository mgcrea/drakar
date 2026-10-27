import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A session host in this process, on a short directory of its own under `/tmp`
/// (`sun_path` holds 104 bytes): its core holds the stand-ins. `stop()` drops every app's
/// connection, as a host that lost them would, and `start()` takes new ones on the same core.
final class LocalHost {
  let directory: URL
  let core: HostCore
  private var server: HostServer?

  /// `minor`: what its `welcome` says; nil stands in for a host older than minor 3.
  init(minor: Int? = HostWire.minor) throws {
    let name = String(UUID().uuidString.prefix(6))
    directory = URL(fileURLWithPath: "/tmp/dh-\(name)", isDirectory: true)
    core = HostCore(directory: directory, hostVersion: "test", minor: minor)
    try start()
  }

  /// A child another test spawns that moment can hold the lock's descriptor until it execs,
  /// so a server started again waits for it.
  func start() throws {
    for _ in 0..<100 where server == nil {
      server = try HostServer.start(directory: directory, core: core, peerCheck: { _ in true })
      if server == nil { usleep(10_000) }
    }
  }

  func stop() {
    server?.stop()
    server = nil
  }

  /// Ends every stand-in it still holds, and its socket.
  func close() {
    server?.stop()
    let client = core.connected(pid: 0)
    if case .listed(let held) = core.handle(.list, from: client).first {
      for process in held { _ = core.handle(.terminate(id: process.id), from: client) }
    }
    core.disconnected(client)
    try? FileManager.default.removeItem(at: directory)
  }
}

/// A relaunched app picking its sessions back up from the session host (spec §3 Relaunch,
/// §5): the app's side of a session is dropped as a quit drops it, its process carrying on
/// in a host of the test's own, then a new window adopts what the host holds. The stand-in
/// `claude` streams a turn a step at a time, each step waiting for a file the test writes,
/// and logs what it is sent. Serialized: `SessionHost.testDirectory` is one for the app.
@MainActor
@Suite("Coming back after a relaunch", .serialized, .timeLimit(.minutes(2)))
struct ReattachTests {
  private let host: LocalHost
  private let folder: URL
  private let bin: URL
  private let fake: URL
  private var received: URL { fake.appendingPathExtension("stdin") }

  init() throws {
    host = try LocalHost()
    let scratch = FileManager.default.temporaryDirectory.appending(
      path: "drakar-reattach-\(UUID().uuidString)", directoryHint: .isDirectory)
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
  /// and three a step apart; `go-ask` asks to run a tool; `go-elicit` says one, then an MCP
  /// server asks a question; `go-exit` says one, then exits 3; `go-idle` ends its turn.
  private static let script = """
    #!/bin/sh
    sid="s-$$"
    log() { printf '%s\\n' "$1" >> "$0.stdin"; }
    step() { while [ ! -f "$0.$1" ]; do sleep 0.02; done; }
    say() { printf '%s\\n' '{"type":"assistant","message":{"id":"m-'"$1"'","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"'"$1"'"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"'"$sid"'"}'; }
    while read -r line; do
      log "$line"
      case "$line" in *'"type":"user"'*) break;; esac
    done
    printf '%s\\n' '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"'"$sid"'","model":"m","permissionMode":"default"}'
    case "$line" in
      *go-stream*) say one; step a; say two; step b; say three;;
      *go-ask*)
        printf '%s\\n' '{"type":"assistant","message":{"id":"m-ls","type":"message","role":"assistant","model":"m","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"'"$sid"'"}'
        printf '%s\\n' '{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}';;
      *go-elicit*)
        say one; step a
        printf '%s\\n' '{"type":"control_request","request_id":"el-1","request":{"subtype":"elicitation","mcp_server_name":"srv","message":"Pick one"}}';;
      *go-exit*) say one; step a; exit 3;;
      *go-idle*)
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","session_id":"'"$sid"'"}';;
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

  /// The app's side let go, as a quit lets a session at work go: its process carries on.
  private func drop(_ session: AgentSession) {
    (session.process as? HostedProcess)?.detach()
  }

  /// A Claude Code session the window kept, with an empty transcript: one it can resume.
  private func target(_ id: String) -> ResumeTarget {
    let file = bin.appending(path: "\(id).jsonl")
    FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())
    return ResumeTarget(
      sessionID: id, cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false), accountDirectory: bin.path(percentEncoded: false),
      accountIsDefault: true)
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

  /// The host logged more of the process than `length`: what it wrote while away.
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

  /// Mid-turn when dropped: back with what it said before, what it said while away, each
  /// once, and the turn still streaming to it.
  @Test func aSessionAtWorkComesBackLive() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-stream", in: window(on: app))
    #expect(await eventually { says(live, "one") })
    let before = live.transcript.entries
    let length = try #require(await app.held().first?.logLength)
    drop(live)
    try step("a")
    #expect(await grew(past: length, on: app))

    let back = window(on: app)
    defer { back.stopAll() }
    await back.adoptHeld(await app.held())
    let row = try #require(back.sessions.first)
    let session = row.session
    #expect(back.sessions.count == 1)
    #expect(session.isHosted)
    #expect(Array(session.transcript.entries.prefix(before.count)) == before)
    #expect(session.transcript.entries.map(\.kind) == before.map(\.kind) + [.text("two")])
    #expect(session.transcript.isRunning)
    #expect(session.phase == .ready)

    try step("b")
    #expect(await eventually { says(session, "three") })
    #expect(session.transcript.entries.count { $0.kind == .text("three") } == 1)
    #expect(session.transcript.entries.count { $0.kind == .text("two") } == 1)
  }

  /// A window closed mid-turn while the app runs hands its session to the host, and the
  /// project's next window takes it back live, with what it said meanwhile.
  @Test func aWindowClosedMidTurnComesBackWhenTheProjectReopens() async throws {
    defer { cleanUp() }
    let app = app()
    let closed = window(on: app)
    let live = await start("go-stream", in: closed)
    #expect(await eventually { says(live, "one") })
    #expect(closed.stoppedByClosing == 0)
    closed.stopAll(handingOver: true)
    #expect(await eventually { await app.held().first?.attachedApp == nil })
    try step("a")

    let back = window(on: app)
    defer { back.stopAll() }
    await back.adoptHeld(await app.held())
    let session = try #require(back.sessions.first?.session)
    #expect(session.isHosted)
    #expect(session.transcript.isRunning)
    #expect(await eventually { says(session, "two") })
    try step("b")
    #expect(await eventually { says(session, "three") })
  }

  /// The row the window kept for the session, from its stored project, is the one that
  /// comes back live, not a second row beside it; so is the blank row a window opens with.
  @Test func theRowsTheWindowOpenedWithGiveWay() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-stream", in: window(on: app))
    #expect(await eventually { says(live, "one") })
    let id = try #require(live.sessionID)
    drop(live)

    let kept = Project(
      folder: folder, restoring: StoredProject(sessions: [target(id)], selected: id))
    kept.executableOverride = fake
    kept.sessionHost = app
    defer { kept.stopAll() }
    try #require(kept.sessions.count == 1)
    kept.sessions[0].draft = "half typed"
    await kept.adoptHeld(await app.held())
    #expect(kept.sessions.count == 1)
    let row = try #require(kept.sessions.first)
    #expect(row.session.isHosted)
    #expect(says(row.session, "one"))
    #expect(row.draft == "half typed")
    #expect(kept.selectedID == row.id)

    drop(row.session)
    let blank = window(on: app)
    defer { blank.stopAll() }
    blank.newSession()
    await blank.adoptHeld(await app.held())
    #expect(blank.sessions.count == 1)
    #expect(blank.sessions.first?.session.isHosted == true)
    #expect(blank.selectedID == blank.sessions.first?.id)
  }

  /// A prompt to the row the window kept, sent while the window is still taking the session
  /// back, starts no second process beside the host's: it waits in the composer, which the
  /// row taking its place keeps, and the hosted row is the one that sends.
  @Test func aRowSentToWhileItIsTakenBackStartsNoOtherProcess() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-idle", in: window(on: app))
    #expect(await eventually { live.transcript.turnEnd != nil })
    let id = try #require(live.sessionID)
    drop(live)

    let kept = Project(
      folder: folder, restoring: StoredProject(sessions: [target(id)], selected: id))
    kept.executableOverride = fake
    kept.sessionHost = app
    defer { kept.stopAll() }
    let adoption = kept.takeBackHeld()
    let row = try #require(kept.sessions.first)
    #expect(!row.session.canSend && !row.session.canQueue)
    row.draft = "typed meanwhile"
    row.session.send("typed meanwhile")
    await adoption.value
    #expect(await app.held().count == 1)
    #expect(sent("typed meanwhile") == 0)

    #expect(kept.sessions.count == 1)
    let back = try #require(kept.sessions.first)
    #expect(back.session.isHosted)
    #expect(back.draft == "typed meanwhile")
    #expect(back.session.canSend)
    back.session.send("typed meanwhile")
    #expect(await eventually { sent("typed meanwhile") == 1 })
    #expect(await app.held().count == 1)
  }

  /// A Codex row waits the same way, though nothing tells Codex's sessions live elsewhere
  /// apart; with nothing held for it, it can send once the window has asked.
  @Test func aCodexRowWaitsWhileTheWindowTakesBackItsSessions() async throws {
    defer { cleanUp() }
    let app = app()
    let thread = ResumeTarget(
      sessionID: "thr-1", cwd: folder.path(percentEncoded: false), file: "",
      accountDirectory: bin.path(percentEncoded: false), accountIsDefault: true, agent: .codex)
    let kept = Project(
      folder: folder, restoring: StoredProject(sessions: [thread], selected: "thr-1"))
    // Its history is read from a CLI that fails at once.
    kept.executableOverride = URL(filePath: "/usr/bin/false")
    kept.sessionHost = app
    defer { kept.stopAll() }
    let adoption = kept.takeBackHeld()
    let row = try #require(kept.sessions.first)
    #expect(!row.session.canSend)
    await adoption.value
    await row.session.loadHistory()
    #expect(row.session.canSend)
  }

  /// A held process that could not be taken back runs on in the host: its row says so, and
  /// can neither send nor start another process for the session.
  @Test func aProcessNotTakenBackLeavesARowThatCannotSend() async throws {
    defer { cleanUp() }
    let app = app()
    let client = try #require(await app.client())
    let meta = SessionMeta(
      start: AgentStart(
        folder: folder, environment: [:], executableOverride: fake, allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), history: .none)
    let held = HeldProcess(
      id: "nope", meta: try JSONEncoder().encode(meta), running: true, logLength: 0)
    let session = try #require(await AgentSession(reattaching: held, client: client))
    #expect(session.isOutOfReach)
    guard case .failed = session.phase else {
      Issue.record("phase is \(session.phase)")
      return
    }
    #expect(!session.canSend && !session.canQueue)
    session.send("again")
    await session.spawn()
    #expect(!session.isProcessRunning)
    #expect(await app.held().isEmpty)
  }

  /// Waiting on the person when dropped: still waiting, and answered once.
  @Test func aPermissionWaitingIsAnsweredOnce() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-ask", in: window(on: app))
    #expect(await eventually { !live.transcript.pendingPermissions.isEmpty })
    drop(live)

    let back = window(on: app)
    defer { back.stopAll() }
    await back.adoptHeld(await app.held())
    let session = try #require(back.sessions.first?.session)
    #expect(session.transcript.pendingPermissions.map(\.requestID) == ["req-1"])
    let pending = try #require(session.transcript.pendingPermissions.first)
    session.answer(pending, .allow(updatedInput: pending.request.input))
    #expect(session.transcript.pendingPermissions.isEmpty)
    #expect(await eventually { sent("req-1") == 1 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(sent("req-1") == 1)
  }

  /// Asked while nobody was attached: it waits for the person when an app comes back, with
  /// nothing sent for it on its own; answered once, and neither asked nor answered again by
  /// the next app to come back to it.
  @Test func anElicitationThatArrivedWhileAwayWaitsAndIsAnsweredOnce() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-elicit", in: window(on: app))
    #expect(await eventually { says(live, "one") })
    let length = try #require(await app.held().first?.logLength)
    drop(live)
    try step("a")
    #expect(await grew(past: length, on: app))

    let back = window(on: app)
    await back.adoptHeld(await app.held())
    let session = try #require(back.sessions.first?.session)
    #expect(session.transcript.pendingElicitations.map(\.requestID) == ["el-1"])
    try await Task.sleep(for: .milliseconds(300))
    #expect(sent("el-1") == 0)

    let pending = try #require(session.transcript.pendingElicitations.first)
    session.answer(pending, .decline)
    #expect(session.transcript.pendingElicitations.isEmpty)
    #expect(await eventually { sent("el-1") == 1 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(sent("el-1") == 1)

    drop(session)
    let again = window(on: app)
    defer { again.stopAll() }
    await again.adoptHeld(await app.held())
    let adopted = try #require(again.sessions.first?.session)
    #expect(adopted.isHosted)
    #expect(adopted.transcript.pendingElicitations.isEmpty)
    try await Task.sleep(for: .milliseconds(300))
    #expect(sent("el-1") == 1)
  }

  /// An accepted form's values reach the CLI, and the host's log keeps its keys alone; the
  /// next app to come back to it has the question answered, and answers it no more.
  @Test func anAnsweredFormReachesTheCLIButNotTheLog() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-elicit", in: window(on: app))
    #expect(await eventually { says(live, "one") })
    try step("a")
    #expect(await eventually { !live.transcript.pendingElicitations.isEmpty })
    let pending = try #require(live.transcript.pendingElicitations.first)
    live.answer(pending, .accept(["team": .string("SECRET-XYZ")]))
    #expect(await eventually { sent("SECRET-XYZ") == 1 })

    let id = try #require(await app.held().first?.id)
    let log = host.directory.appending(path: "\(id).log")
    let records = { () -> [HostRecord] in
      let data = (try? Data(contentsOf: log)) ?? Data()
      return data.split(separator: 0x0A).compactMap {
        try? JSONDecoder().decode(HostRecord.self, from: Data($0))
      }
    }
    let redacted = #"{"action":"accept","content":{"team":"<redacted>"}}"#
    #expect(
      await eventually {
        records().contains {
          $0.kind == .in && String(decoding: $0.bytes, as: UTF8.self).contains(redacted)
        }
      })
    // A record's bytes are base64 in the file, so each is read back too. Booleans, so that a
    // failure does not print what it found.
    let fileLeaks =
      ((try? Data(contentsOf: log)) ?? Data()).range(of: Data("SECRET-XYZ".utf8)) != nil
    let recordLeaks = records().contains { $0.bytes.range(of: Data("SECRET-XYZ".utf8)) != nil }
    #expect(!fileLeaks)
    #expect(!recordLeaks)

    drop(live)
    let back = window(on: app)
    defer { back.stopAll() }
    await back.adoptHeld(await app.held())
    let session = try #require(back.sessions.first?.session)
    #expect(session.isHosted)
    #expect(session.transcript.pendingElicitations.isEmpty)
    #expect(says(session, "one"))
    #expect(
      session.transcript.entries.contains {
        $0.kind == .notice("Answered srv's question: Pick one")
      })
    try await Task.sleep(for: .milliseconds(300))
    #expect(sent("el-1") == 1)
  }

  /// A host older than minor 3 names no minor in its `welcome`, and logs an answer whole,
  /// what was typed among it: a session it holds says so, for its card to. One on ours does
  /// not.
  @Test func aSessionKnowsAnOlderHostLogsAnswersInFull() async throws {
    defer { cleanUp() }
    let current = await start("go-idle", in: window(on: app()))
    #expect(await eventually { current.transcript.turnEnd != nil })
    #expect(current.isHosted)
    #expect(!current.hostLogsAnswersInFull)

    let older = try LocalHost(minor: nil)
    defer { older.close() }
    SessionHost.testDirectory = older.directory
    let app = SessionHost(cooldown: .milliseconds(100), helper: URL(filePath: "/usr/bin/true"))
    let session = await start("go-idle", in: window(on: app))
    #expect(await eventually { session.transcript.turnEnd != nil })
    #expect(session.isHosted)
    #expect(session.hostLogsAnswersInFull)
  }

  /// Exited while nobody was attached: shown ended, as an exit seen live is, and then the
  /// host forgets it.
  @Test func anEndedSessionIsShownAndForgotten() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-exit", in: window(on: app))
    #expect(await eventually { says(live, "one") })
    drop(live)
    try step("a")
    #expect(await eventually { await app.held().first?.running == false })

    let back = window(on: app)
    await back.adoptHeld(await app.held())
    let row = try #require(back.sessions.first)
    #expect(await eventually { row.session.phase == .exited(status: 3) })
    #expect(says(row.session, "one"))
    #expect(row.stopReason != nil)
    #expect(await eventually { await app.held().isEmpty })
  }

  /// The same, its folder gone meanwhile: it comes back ended all the same, and nothing is
  /// started there.
  @Test func anEndedSessionWhoseFolderIsGoneComesBackEnded() async throws {
    defer { cleanUp() }
    let app = app()
    let live = await start("go-exit", in: window(on: app))
    #expect(await eventually { says(live, "one") })
    drop(live)
    try step("a")
    #expect(await eventually { await app.held().first?.running == false })
    try FileManager.default.removeItem(at: folder)

    let back = window(on: app)
    await back.adoptHeld(await app.held())
    let row = try #require(back.sessions.first)
    #expect(await eventually { row.session.phase == .exited(status: 3) })
    #expect(await eventually { await app.held().isEmpty })
    try await Task.sleep(for: .milliseconds(300))
    #expect(await app.held().isEmpty)
    #expect(!row.session.isProcessRunning)
  }

  /// An app that dies hands nothing over: every session it had is left to the next, the
  /// idle one idle and the one at work still at work.
  @Test func aKilledAppLeavesEverySessionToReattach() async throws {
    defer { cleanUp() }
    let killed = app()
    weak var idle: AgentSession?
    weak var busy: AgentSession?
    do {
      let first = window(on: killed)
      let quiet = await start("go-idle", in: first)
      #expect(await eventually { quiet.transcript.turnEnd != nil })
      let working = await start("go-stream", in: first)
      #expect(await eventually { says(working, "one") })
      #expect(quiet.isHosted && working.isHosted)
      (idle, busy) = (quiet, working)
    }
    // Nothing of the dead app's is left to reconnect.
    #expect(await eventually { idle == nil && busy == nil })
    await killed.client()?.close()

    let relaunched = app()
    #expect(
      await eventually {
        let held = await relaunched.held()
        return held.count == 2 && held.allSatisfy { $0.attachedApp == nil }
      })
    let back = window(on: relaunched)
    defer { back.stopAll() }
    await back.adoptHeld(await relaunched.held())
    #expect(back.sessions.count == 2)
    let sessions = back.sessions.map(\.session)
    #expect(sessions.allSatisfy { $0.isHosted })
    let working = try #require(sessions.first { says($0, "one") })
    let quiet = try #require(sessions.first { !says($0, "one") })
    #expect(working.transcript.isRunning)
    #expect(!quiet.transcript.isRunning)
    #expect(quiet.transcript.turnEnd == .completed)
    #expect(quiet.phase == .ready)
  }

  /// 50,000 lines the CLI wrote, ≈30 MB, come back in seconds, and the main actor is never
  /// held long enough to show: parsing them is done off it, and taking them is sliced.
  @Test func aLongLogReplaysQuickly() async throws {
    defer { cleanUp() }
    let app = app()
    let text = String(repeating: "All work and no play makes Jack a dull boy. ", count: 12)
    var fixture = Data()
    for index in 0..<50_000 {
      fixture.append(
        Data(
          #"{"type":"assistant","message":{"id":"m-\#(index)","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"\#(text)"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-long"}"#
            .utf8))
      fixture.append(0x0A)
    }
    #expect(fixture.count > 30_000_000)
    let lines = bin.appending(path: "long.jsonl")
    try fixture.write(to: lines)
    let meta = SessionMeta(
      start: AgentStart(
        folder: folder, environment: [:], executableOverride: fake, allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), history: .none)
    let client = try #require(await app.client())
    _ = try await client.spawn(
      AgentProcess.Configuration(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "cat \"$0\"; exec cat > /dev/null", lines.path(percentEncoded: false)],
        environment: [:], currentDirectory: folder),
      meta: try JSONEncoder().encode(meta))
    var length: UInt64 = 0
    #expect(
      await eventually(within: .seconds(30)) {
        let now = await app.held().first?.logLength ?? 0
        defer { length = now }
        return now > 30_000_000 && now == length
      })
    let held = try #require(await app.held().first)

    let ticker = Ticker()
    let ticking = Task { await ticker.run() }
    let began = ContinuousClock.now
    let session = try #require(await AgentSession(reattaching: held, client: client))
    let took = ContinuousClock.now - began
    ticker.stop()
    await ticking.value
    defer { session.stop() }
    #expect(session.transcript.entries.count == 50_000)
    #expect(took < .seconds(5), "took \(took)")
    #expect(
      session.longestReplayHold < .milliseconds(100),
      "the replay held the main actor for \(session.longestReplayHold)")
    // The main actor is the other suites' too, and the machine's load shows in it: a replay
    // taken in one go would hold it for seconds.
    #expect(ticker.longest < .milliseconds(500), "the main actor was held for \(ticker.longest)")
  }

  /// The window closes while it takes a session back: no row comes of the replay, and its
  /// process is ended and forgotten as a closed window's sessions are, not left attached to
  /// this app with no row to show it.
  @Test func aWindowClosedDuringATakeBackAdoptsNothing() async throws {
    defer { cleanUp() }
    let app = app()
    let text = String(repeating: "All work and no play makes Jack a dull boy. ", count: 12)
    var fixture = Data()
    for index in 0..<20_000 {
      fixture.append(
        Data(
          #"{"type":"assistant","message":{"id":"m-\#(index)","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"\#(text)"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-closed"}"#
            .utf8))
      fixture.append(0x0A)
    }
    let lines = bin.appending(path: "closed.jsonl")
    try fixture.write(to: lines)
    let size = UInt64(fixture.count)
    let meta = SessionMeta(
      start: AgentStart(
        folder: folder, environment: [:], executableOverride: fake, allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), history: .none)
    let client = try #require(await app.client())
    _ = try await client.spawn(
      AgentProcess.Configuration(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "cat \"$0\"; exec cat > /dev/null", lines.path(percentEncoded: false)],
        environment: [:], currentDirectory: folder),
      meta: try JSONEncoder().encode(meta))
    var length: UInt64 = 0
    #expect(
      await eventually(within: .seconds(30)) {
        let now = await app.held().first?.logLength ?? 0
        defer { length = now }
        return now > size && now == length
      })

    let closing = window(on: app)
    let adoption = Task { await closing.adoptHeld(await app.held()) }
    #expect(await eventually { await app.held().first?.attachedApp != nil })
    closing.stopAll()
    await adoption.value
    #expect(!closing.sessions.contains { $0.session.isHosted })
    #expect(await eventually { await app.held().isEmpty })
  }

  /// The connection lost mid-turn: nothing is sent and the footer says so until a new one is
  /// up, then the session carries on from where it was, each entry once.
  @Test func aLostConnectionReattachesFromWhereItWas() async throws {
    defer { cleanUp() }
    let app = app()
    let project = window(on: app)
    defer { project.stopAll() }
    let session = await start("go-stream", in: project)
    #expect(await eventually { says(session, "one") })

    host.stop()
    #expect(await eventually { session.isReconnecting })
    #expect(!session.canSend && !session.canQueue)
    session.send("go-lost")
    try host.start()
    #expect(await eventually { !session.isReconnecting })
    #expect(session.isHosted)
    try step("a")
    #expect(await eventually { says(session, "two") })
    try step("b")
    #expect(await eventually { says(session, "three") })
    for text in ["one", "two", "three"] {
      #expect(session.transcript.entries.count { $0.kind == .text(text) } == 1)
    }
    #expect(session.transcript.entries.count { $0.kind == .prompt("go-stream") } == 1)
    #expect(session.transcript.isRunning)
    #expect(sent("go-lost") == 0)
  }

  /// At launch, a window for each folder whose processes no app holds: one each, however
  /// many processes it has, and none for a process another app is attached to.
  @Test func windowsOpenForHeldSessions() async throws {
    defer { cleanUp() }
    let app = app()
    let client = try #require(await app.client())
    let other = folder.deletingLastPathComponent().appending(
      path: "other", directoryHint: .isDirectory)
    let taken = folder.deletingLastPathComponent().appending(
      path: "taken", directoryHint: .isDirectory)
    var ids: [String] = []
    for window in [folder, other, folder, taken] {
      let meta = SessionMeta(
        start: AgentStart(
          folder: window, environment: [:], executableOverride: fake, allowsBypass: false),
        windowFolder: window.path(percentEncoded: false), history: .none)
      ids += [
        try await client.spawn(
          AgentProcess.Configuration(
            executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
            currentDirectory: bin),
          meta: try JSONEncoder().encode(meta))
      ]
    }
    // An app holds the last one.
    _ = client.attach(try #require(ids.last), from: 0)
    #expect(await eventually { await app.held().contains { $0.attachedApp != nil } })

    var opened: [WindowRoute] = []
    let windows = HeldWindows(open: { opened.append($0) })
    await windows.list(from: app)
    #expect(opened.isEmpty)
    windows.windowAppeared()
    #expect(opened.count == 2)
    #expect(Set(opened) == [.project(folder), .project(other)])
    windows.windowAppeared()
    #expect(opened.count == 2)
  }
}

/// A task on the main actor every 10 ms, timing the longest gap between two of its turns:
/// how long anything else held the main actor.
@MainActor
private final class Ticker {
  private(set) var longest = Duration.zero
  private var ticking = true

  func run() async {
    var last = ContinuousClock.now
    while ticking {
      try? await Task.sleep(for: .milliseconds(10))
      let now = ContinuousClock.now
      longest = max(longest, now - last)
      last = now
    }
  }

  func stop() { ticking = false }
}
