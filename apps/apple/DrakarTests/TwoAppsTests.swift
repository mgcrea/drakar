import DrakarKit
import Foundation
import Synchronization
import Testing

@testable import Drakar

/// Two Drakars on one session host, and a host of an older protocol (spec §4, §5): a process
/// another app holds is shown read-only and left to it until it lets go, then taken back as
/// a relaunch takes one back. App B reaches the host through a relay that notes what it
/// asks, so that what it never sends can be checked. Serialized: `SessionHost.testDirectory`
/// is one for the app.
@MainActor
@Suite("Two apps on one host", .serialized, .timeLimit(.minutes(2)))
struct TwoAppsTests {
  private let host: LocalHost
  private let folder: URL
  private let bin: URL
  private let fake: URL
  private var received: URL { fake.appendingPathExtension("stdin") }

  init() throws {
    host = try LocalHost()
    let scratch = FileManager.default.temporaryDirectory.appending(
      path: "drakar-two-apps-\(UUID().uuidString)", directoryHint: .isDirectory)
    folder = scratch.appending(path: "project", directoryHint: .isDirectory)
    bin = scratch.appending(path: "bin", directoryHint: .isDirectory)
    for directory in [folder, bin] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    fake = bin.appending(path: "claude")
    try Data(Self.script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  /// The session it resumes, if any, is the one it says it is. `go-stream` says one, then
  /// two and three a step apart, each step waiting for a file the test writes.
  private static let script = """
    #!/bin/sh
    sid="s-$$"
    previous=""
    for argument in "$@"; do
      [ "$previous" = "--resume" ] && sid="$argument"
      case "$argument" in --resume=*) sid="${argument#--resume=}";; esac
      previous="$argument"
    done
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
    esac
    while read -r line; do log "$line"; done

    """

  private func cleanUp() {
    host.close()
    SessionHost.testDirectory = nil
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  /// An app reaching the host in `directory`. Its helper starts nothing.
  private func app(in directory: URL) -> SessionHost {
    SessionHost.testDirectory = directory
    return SessionHost(cooldown: .milliseconds(100), helper: URL(filePath: "/usr/bin/true"))
  }

  private func window(on app: SessionHost) -> Project {
    let project = Project(folder: folder)
    project.executableOverride = fake
    project.sessionHost = app
    return project
  }

  /// A Claude Code session with a transcript that holds one prompt, `before`.
  private func transcript(_ id: String) throws -> ResumeTarget {
    let file = bin.appending(path: "\(id).jsonl")
    try Data(Self.userLine("before").utf8).write(to: file)
    return ResumeTarget(
      sessionID: id, cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false), accountDirectory: bin.path(percentEncoded: false),
      accountIsDefault: true)
  }

  private static func userLine(_ text: String) -> String {
    #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"# + "\n"
  }

  /// `target` resumed in `project`, sent `prompt`.
  private func resume(_ target: ResumeTarget, _ prompt: String, in project: Project) async
    -> AgentSession
  {
    _ = await AgentSession.environment.value
    let session = project.attach(target).session
    session.accounts = { [] }
    session.send(prompt)
    return session
  }

  /// A process spawned straight in the host with `meta`, and an app of its own attached to
  /// it, which lets it go by closing.
  private func held(_ meta: SessionMeta) async throws -> (owner: HostClient, id: String) {
    let owner = try HostClient.connect(socket: try HostWire.socket(in: host.directory))
    let id = try await owner.spawn(
      AgentProcess.Configuration(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: bin),
      meta: try JSONEncoder().encode(meta))
    _ = owner.attach(id, from: 0)
    return (owner, id)
  }

  private func meta(history: HistoryMark, savedTarget: ResumeTarget? = nil) -> SessionMeta {
    SessionMeta(
      start: AgentStart(
        folder: folder, resuming: savedTarget, environment: [:], executableOverride: fake,
        allowsBypass: false),
      windowFolder: folder.path(percentEncoded: false), savedTarget: savedTarget,
      history: history)
  }

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

  private func says(_ session: AgentSession, _ text: String) -> Bool {
    session.transcript.entries.contains { $0.kind == .text(text) }
  }

  private func prompts(_ session: AgentSession) -> [String] {
    session.transcript.entries.compactMap {
      if case .prompt(let text) = $0.kind { text } else { nil }
    }
  }

  /// The lines the stand-ins were sent that hold `text`.
  private func sent(_ text: String) -> Int {
    let log = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
    return log.split(separator: "\n").count { $0.contains(text) }
  }

  /// Shown read-only, sending nothing and starting nothing: what a row of another app's
  /// process is until it is let go.
  private func expectLeftAlone(_ session: AgentSession) {
    #expect(session.isReadOnly)
    #expect(session.heldElsewhere != nil)
    #expect(!session.canSend && !session.canQueue)
    #expect(!session.isProcessRunning)
    if case .failed(let message) = session.phase { Issue.record("failed: \(message)") }
  }

  /// A launch beside a running app leaves that app's sessions with it: the row follows the
  /// transcript, and nothing but `hello` and `list` goes to the host for it.
  @Test func aLaunchLeavesAnotherAppsSessionsAlone() async throws {
    defer { cleanUp() }
    let a = app(in: host.directory)
    let first = window(on: a)
    defer { first.stopAll() }
    let target = try transcript("t-1")
    let live = await resume(target, "go-stream", in: first)
    #expect(await eventually { says(live, "one") })
    #expect(live.isHosted)

    let relay = try Relay(to: host.directory)
    defer { relay.close() }
    let b = app(in: relay.directory)
    let second = window(on: b)
    defer { second.stopAll() }
    await second.takeBackHeld().value
    #expect(second.sessions.count == 1)
    let row = try #require(second.sessions.first)
    expectLeftAlone(row.session)
    #expect(prompts(row.session) == ["before"])

    // Followed as another process writes it.
    let handle = try FileHandle(forWritingTo: URL(filePath: target.file))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(Self.userLine("written elsewhere").utf8))
    try handle.close()
    row.session.catchUp()
    #expect(prompts(row.session) == ["before", "written elsewhere"])
    // The registry not listing it changes nothing: the host says who holds it.
    let windowID = UUID()
    OpenSessions.shared.register(second, window: windowID)
    OpenSessions.shared.liveChanged([])
    OpenSessions.shared.unregister(window: windowID)
    expectLeftAlone(row.session)

    row.session.send("from b")
    await row.session.spawn()
    try await Task.sleep(for: .milliseconds(300))
    #expect(sent("from b") == 0)
    #expect(!row.session.isProcessRunning)
    #expect(await a.held().count == 1)
    #expect(await a.held().first?.attachedApp != nil)
    #expect(live.isHosted && live.isProcessRunning)
    #expect(relay.asked.allSatisfy { $0 == .hello || $0 == .list }, "\(relay.asked)")
    #expect(relay.asked.contains(.list))
  }

  /// Once the other app lets go of it, the row takes the process back: live, its transcript
  /// whole, each entry once, in the same row.
  @Test func releasedBringsItBack() async throws {
    defer { cleanUp() }
    let a = app(in: host.directory)
    let first = window(on: a)
    defer { first.stopAll() }
    let live = await resume(try transcript("t-2"), "go-stream", in: first)
    #expect(await eventually { says(live, "one") })

    let relay = try Relay(to: host.directory)
    defer { relay.close() }
    let b = app(in: relay.directory)
    let second = window(on: b)
    defer { second.stopAll() }
    await second.takeBackHeld().value
    let row = try #require(second.sessions.first)
    expectLeftAlone(row.session)
    row.draft = "half typed"

    let before = live.transcript.entries
    // A quits: what it had at work is let go, then its connection ends.
    (live.process as? HostedProcess)?.detach()
    await a.client()?.close()
    #expect(await eventually { second.sessions.first?.session.isHosted == true })
    #expect(second.sessions.count == 1)
    let back = try #require(second.sessions.first)
    #expect(back.draft == "half typed")
    let session = back.session
    #expect(!session.isReadOnly)
    #expect(session.heldElsewhere == nil)
    #expect(session.canQueue)
    #expect(Array(session.transcript.entries.prefix(before.count)) == before)

    try step("a")
    #expect(await eventually { says(session, "two") })
    try step("b")
    #expect(await eventually { says(session, "three") })
    for text in ["one", "two", "three"] {
      #expect(session.transcript.entries.count { $0.kind == .text(text) } == 1)
    }
    #expect(prompts(session) == ["before", "go-stream"])
    #expect(sent("go-stream") == 1)
    #expect(relay.asked.count { $0 == .attach } == 1)
  }

  /// A process another window of the same app holds is that window's: no read-only row for
  /// it elsewhere in the app.
  @Test func anotherWindowOfThisAppIsNotAnotherApp() async throws {
    defer { cleanUp() }
    let a = app(in: host.directory)
    let first = window(on: a)
    defer { first.stopAll() }
    let windowID = UUID()
    OpenSessions.shared.register(first, window: windowID)
    defer { OpenSessions.shared.unregister(window: windowID) }
    let live = await resume(try transcript("t-3"), "go-stream", in: first)
    #expect(await eventually { says(live, "one") })

    let second = window(on: a)
    defer { second.stopAll() }
    await second.takeBackHeld().value
    #expect(second.sessions.isEmpty)
  }

  /// When an app lets go, one row takes the process back, once: of two windows of one app,
  /// only one asks; another app asking too is refused by the host, and its row stays as it
  /// was, not failed.
  @Test func aReleasedProcessGoesToOneWindow() async throws {
    defer { cleanUp() }
    let (owner, id) = try await held(meta(history: .none))
    let relay = try Relay(to: host.directory)
    defer { relay.close() }
    let b = app(in: relay.directory)
    let c = app(in: host.directory)
    let windows = [window(on: b), window(on: b), window(on: c)]
    defer { for window in windows { window.stopAll() } }
    for window in windows { await window.takeBackHeld().value }
    let rows = windows.compactMap(\.sessions.first)
    #expect(rows.count == 3)
    for row in rows { expectLeftAlone(row.session) }

    owner.close()
    #expect(
      await eventually { windows.count { $0.sessions.first?.session.isHosted == true } == 1 })
    try await Task.sleep(for: .milliseconds(500))
    let hosted = windows.filter { $0.sessions.first?.session.isHosted == true }
    #expect(hosted.count == 1)
    for window in windows where window !== hosted.first {
      #expect(window.sessions.count == 1)
      if let session = window.sessions.first?.session { expectLeftAlone(session) }
    }
    #expect(relay.asked.count { $0 == .attach } <= 1)
    #expect(await c.held().first { $0.id == id }?.attachedApp != nil)
  }

  /// Codex has no file to follow: the row shows the thread up to the process, then says
  /// where the rest runs, and can't send.
  @Test func aCodexSessionElsewhereSaysSo() async throws {
    defer { cleanUp() }
    let (owner, _) = try await held(meta(history: .codexTurns(0)))
    defer { owner.close() }
    let relay = try Relay(to: host.directory)
    defer { relay.close() }
    let b = app(in: relay.directory)
    let second = window(on: b)
    defer { second.stopAll() }
    await second.takeBackHeld().value
    let row = try #require(second.sessions.first)
    #expect(row.session.agent == .codex)
    expectLeftAlone(row.session)
    let note = Transcript.Kind.notice("Running in another Drakar window.")
    #expect(row.session.transcript.entries.last?.kind == note)

    row.session.send("from b")
    await row.session.spawn()
    try await Task.sleep(for: .milliseconds(300))
    #expect(!row.session.isProcessRunning)
    #expect(await b.held().count == 1)
    #expect(relay.asked.allSatisfy { $0 == .hello || $0 == .list }, "\(relay.asked)")
  }

  /// The other app ends the session as it would any: the host forgets the process and says
  /// so, and the row here becomes the session to resume, which sends, its draft kept.
  @Test func aSessionTheOtherAppEndsCanBeResumedHere() async throws {
    defer { cleanUp() }
    let a = app(in: host.directory)
    let first = window(on: a)
    defer { first.stopAll() }
    let live = await resume(try transcript("t-5"), "go-stream", in: first)
    #expect(await eventually { says(live, "one") })

    let b = app(in: host.directory)
    let second = window(on: b)
    defer { second.stopAll() }
    await second.takeBackHeld().value
    let row = try #require(second.sessions.first)
    expectLeftAlone(row.session)
    row.draft = "half typed"

    live.stop()
    #expect(await eventually { second.sessions.first?.session.heldElsewhere == nil })
    #expect(await eventually { await a.held().isEmpty })
    #expect(second.sessions.count == 1)
    let back = try #require(second.sessions.first)
    let session = back.session
    #expect(back.draft == "half typed")
    #expect(!session.isReadOnly && !session.isOutOfReach)
    #expect(!session.isProcessRunning)
    #expect(session.resuming?.sessionID == "t-5")
    #expect(prompts(session) == ["before"])
    session.send("go-after")
    #expect(await eventually { sent("go-after") == 1 })
  }

  /// The same for Codex, whose row then shows its thread as resuming it would.
  @Test func aCodexSessionTheOtherAppEndsCanBeResumedHere() async throws {
    defer { cleanUp() }
    let thread = ResumeTarget(
      sessionID: "thr-1", cwd: folder.path(percentEncoded: false), file: "",
      accountDirectory: bin.path(percentEncoded: false), accountIsDefault: true, agent: .codex)
    let (owner, id) = try await held(meta(history: .codexTurns(0), savedTarget: thread))
    defer { owner.close() }
    let b = app(in: host.directory)
    let second = window(on: b)
    // Its history is read from a CLI that fails at once.
    second.executableOverride = URL(filePath: "/usr/bin/false")
    defer { second.stopAll() }
    await second.takeBackHeld().value
    let row = try #require(second.sessions.first)
    expectLeftAlone(row.session)

    let events = owner.attach(id, from: 0)
    try owner.send(.terminate(id: id))
    for await event in events {
      if case .exited = event { break }
    }
    try owner.send(.acknowledge(id: id))
    #expect(await eventually { second.sessions.first?.session.heldElsewhere == nil })
    let session = try #require(second.sessions.first?.session)
    #expect(session.agent == .codex)
    #expect(session.resuming?.sessionID == "thr-1")
    #expect(!session.isReadOnly)
    #expect(await eventually { session.canSend })
  }

  /// A `released` sent while this app had no connection is not lost: the next connection
  /// settles the row, here by taking the process back.
  @Test func aReleaseMissedWhileAwayIsNotLost() async throws {
    defer { cleanUp() }
    let a = app(in: host.directory)
    let first = window(on: a)
    defer { first.stopAll() }
    let live = await resume(try transcript("t-6"), "go-stream", in: first)
    #expect(await eventually { says(live, "one") })

    let relay = try Relay(to: host.directory)
    defer { relay.close() }
    let b = app(in: relay.directory)
    let second = window(on: b)
    defer { second.stopAll() }
    await second.takeBackHeld().value
    let row = try #require(second.sessions.first)
    expectLeftAlone(row.session)

    relay.dropConnections()
    #expect(await eventually { !b.isAvailable })
    (live.process as? HostedProcess)?.detach()
    #expect(await eventually { await a.held().first?.attachedApp == nil })
    try await Task.sleep(for: .milliseconds(200))
    expectLeftAlone(row.session)

    _ = await b.client()
    #expect(await eventually { second.sessions.first?.session.isHosted == true })
    let session = try #require(second.sessions.first?.session)
    #expect(says(session, "one"))
    #expect(second.sessions.count == 1)
  }

  /// Only the sessions this app's own rows run in the host are its own: another Drakar's,
  /// started there after this window opened, is live elsewhere here, and the row this window
  /// kept for it goes read-only, while the window's own hosted session runs on.
  @Test func onlyThisAppsOwnHostedSessionsAreItsOwn() async throws {
    defer { cleanUp() }
    let b = app(in: host.directory)
    let target = try transcript("t-7")
    let second = Project(folder: folder, restoring: StoredProject(sessions: [target]))
    second.executableOverride = fake
    second.sessionHost = b
    let windowID = UUID()
    OpenSessions.shared.register(second, window: windowID)
    defer {
      OpenSessions.shared.unregister(window: windowID)
      second.stopAll()
    }
    await second.takeBackHeld().value
    let kept = try #require(second.session(withID: "t-7"))
    let own = await resume(try transcript("t-8"), "go-stream", in: second)
    #expect(await eventually { says(own, "one") })
    #expect(own.isHosted)

    let a = app(in: host.directory)
    let first = window(on: a)
    defer { first.stopAll() }
    let theirs = await resume(target, "go-stream", in: first)
    #expect(await eventually { says(theirs, "one") })

    #expect(OpenSessions.shared.hostedHere.contains("t-8"))
    #expect(!OpenSessions.shared.hostedHere.contains("t-7"))
    // What the registry read then gives: theirs, not ours.
    let registry: Set<String> = ["t-7", "t-8"]
    OpenSessions.shared.liveChanged(registry.subtracting(OpenSessions.shared.hostedHere))
    #expect(kept.session.isReadOnly)
    #expect(!own.isReadOnly && own.isHosted && own.isProcessRunning)
  }

  /// A host of an older protocol is only said hello to and listed: what it holds is shown
  /// read-only, though no app is attached to it, and never attached.
  @Test func anOlderHostIsReadOnly() async throws {
    defer { cleanUp() }
    let target = try transcript("t-old")
    let older = try OlderHost(
      holding: HeldProcess(
        id: "old-1", meta: try JSONEncoder().encode(meta(history: .none, savedTarget: target)),
        running: true, logLength: 0))
    defer { older.close() }
    let b = app(in: older.directory)
    let second = window(on: b)
    defer { second.stopAll() }
    await second.takeBackHeld().value
    #expect(second.sessions.count == 1)
    let row = try #require(second.sessions.first)
    expectLeftAlone(row.session)
    #expect(prompts(row.session) == ["before"])

    row.session.send("from b")
    await row.session.spawn()
    try await Task.sleep(for: .milliseconds(300))
    #expect(sent("from b") == 0)
    #expect(!row.session.isProcessRunning)
    #expect(older.asked.allSatisfy { $0 == .hello || $0 == .list }, "\(older.asked)")
    #expect(older.asked.contains(.list))
    // An older host's pid is never one whose processes are this app's own.
    #expect(b.hostPID == nil)
  }

  /// A new hosted session has no id until `system/init`. A registry read before it lists the
  /// row's own process, and the row learning its id must read the registries again, or the
  /// next window to register takes the row for another app's and stops it mid-turn.
  @Test func aHostedSessionThatLearnsItsIdIsNotAnotherAppsSession() async throws {
    defer { cleanUp() }
    let account = ClaudeAccount(
      directory: bin.appending(path: "account", directoryHint: .isDirectory), isDefault: true)
    let registry = account.directory.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    let slow = bin.appending(path: "slow")
    let script = """
      #!/bin/sh
      sid="s-new-$$"
      printf '{"pid":%s,"sessionId":"%s"}' "$$" "$sid" > "\(registry.path(percentEncoded: false))/$$.json"
      while read -r line; do
        case "$line" in *'"type":"user"'*) break;; esac
      done
      while [ ! -f "$0.init" ]; do sleep 0.02; done
      printf '%s\\n' '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"'"$sid"'","model":"m","permissionMode":"default"}'
      while read -r line; do :; done

      """
    try Data(script.utf8).write(to: slow)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)

    // The test process is the host here: what it spawned is a hosted process.
    let monitor = SessionMonitor.shared
    let (accounts, hostPID) = (monitor.accounts, SessionHost.shared.hostPID)
    // Started first: its account discovery would replace the account set after.
    await monitor.start()
    monitor.accounts = [account]
    SessionHost.shared.hostPID = getpid()
    defer {
      monitor.accounts = accounts
      SessionHost.shared.hostPID = hostPID
    }

    let a = app(in: host.directory)
    let project = Project(folder: folder)
    project.executableOverride = slow
    project.sessionHost = a
    defer { project.stopAll() }
    let windowID = UUID()
    OpenSessions.shared.register(project, window: windowID)
    defer { OpenSessions.shared.unregister(window: windowID) }
    let session = project.newSession(agent: .claude, folder: folder).session
    session.accounts = { [] }
    session.send("go")
    #expect(await eventually { session.isHosted && session.isProcessRunning })
    #expect(session.sessionID == nil)
    // The registry is read with the process listed, its row not knowing its id yet.
    #expect(
      await eventually {
        ((try? FileManager.default.contentsOfDirectory(atPath: registry.path)) ?? []).count == 1
      })
    monitor.hostedChanged()
    #expect(monitor.liveIDs.contains { $0.hasPrefix("s-new-") })

    try Data().write(to: slow.appendingPathExtension("init"))
    #expect(await eventually { session.sessionID != nil })
    // Another window opens: the registries as last read decide what it takes for elsewhere.
    let other = UUID()
    OpenSessions.shared.register(Project(folder: folder), window: other)
    defer { OpenSessions.shared.unregister(window: other) }
    #expect(!session.isReadOnly)
    #expect(session.isProcessRunning)
  }
}

// MARK: - Stand-ins on the socket

/// What a request is, without what it carries: for checking what an app asked.
private enum Asked: Equatable {
  case hello, list, spawn, attach, write, note, closeInput, terminate, setMeta, acknowledge
  case detach

  init(_ request: HostRequest) {
    self =
      switch request {
      case .hello: .hello
      case .list: .list
      case .spawn: .spawn
      case .attach: .attach
      case .write: .write
      case .note: .note
      case .closeInput: .closeInput
      case .terminate: .terminate
      case .setMeta: .setMeta
      case .acknowledge: .acknowledge
      case .detach: .detach
      }
  }
}

/// A request line as an app frames it.
private struct Frame: Decodable {
  var id: Int
  var request: HostRequest
}

/// What the stand-ins were asked, in order.
private final class Notes: Sendable {
  private let list = Mutex<[Asked]>([])

  func append(_ asked: Asked) { list.withLock { $0.append(asked) } }

  var all: [Asked] { list.withLock { $0 } }
}

/// A socket in a short directory of its own whose connections are each carried to the host
/// in `upstream`, every request noted on the way.
private final class Relay: Sendable {
  let directory: URL
  private let server: LineServer
  private let notes = Notes()

  init(to upstream: URL) throws {
    directory = try LineServer.directory()
    let target = try HostWire.socket(in: upstream).path(percentEncoded: false)
    let notes = notes
    server = try LineServer(at: HostWire.socket(in: directory)) { app, open in
      guard let host = RawSocket.connected(to: target) else { return nil }
      open.add(host)
      RawSocket.pump(host, in: open, ended: { open.shutDown(app) }) { chunk in
        _ = RawSocket.write(chunk, to: app)
      }
      return (
        host,
        { line in
          if let frame = try? JSONDecoder().decode(Frame.self, from: line) {
            notes.append(Asked(frame.request))
          }
          _ = RawSocket.write(line + Data([0x0A]), to: host)
        }
      )
    }
  }

  var asked: [Asked] { notes.all }

  /// Ends every connection carried so far, as a host lost would; new ones are taken.
  func dropConnections() {
    server.dropConnections()
  }

  func close() {
    server.close()
    try? FileManager.default.removeItem(at: directory)
  }
}

/// A host of protocol 0 holding `held`: it answers `hello` and `list`, and refuses the rest.
private final class OlderHost: Sendable {
  let directory: URL
  private let server: LineServer
  private let notes = Notes()

  private struct Answer: Encodable {
    var to: Int
    var events: [HostEvent]
  }

  init(holding held: HeldProcess) throws {
    directory = try LineServer.directory()
    let notes = notes
    server = try LineServer(at: HostWire.socket(in: directory, major: 0)) { app, _ in
      (
        nil,
        { line in
          guard let frame = try? JSONDecoder().decode(Frame.self, from: line) else { return }
          notes.append(Asked(frame.request))
          let event: HostEvent =
            switch frame.request {
            case .hello: .welcome(protocol: 0, hostVersion: "0.1", pid: getpid())
            case .list: .listed([held])
            default: .refused(reason: "unknown request")
            }
          guard let answer = try? JSONEncoder().encode(Answer(to: frame.id, events: [event]))
          else { return }
          _ = RawSocket.write(answer + Data([0x0A]), to: app)
        }
      )
    }
  }

  var asked: [Asked] { notes.all }

  func close() {
    server.close()
    try? FileManager.default.removeItem(at: directory)
  }
}

/// The descriptors the stand-ins hold open. Each is closed under the lock by the thread
/// reading it, so a shutdown here never reaches a number reused meanwhile.
private final class Descriptors: Sendable {
  private let state = Mutex<(stopped: Bool, open: Set<Int32>)>((false, []))

  var isStopped: Bool { state.withLock { $0.stopped } }

  func add(_ fd: Int32) { state.withLock { _ = $0.open.insert(fd) } }

  func shutDown(_ fd: Int32) {
    state.withLock { if $0.open.contains(fd) { _ = shutdown(fd, SHUT_RDWR) } }
  }

  func closed(_ fd: Int32) {
    state.withLock { state in
      if state.open.remove(fd) != nil { _ = Darwin.close(fd) }
    }
  }

  func shutDownAll() {
    state.withLock { state in
      for fd in state.open { shutdown(fd, SHUT_RDWR) }
    }
  }

  func stop() {
    state.withLock { $0.stopped = true }
    shutDownAll()
  }
}

/// A Unix socket taking connections on a thread of its own and handing each line read on
/// one to what `accepted` made for it, which may open a descriptor of its own to end with it.
private final class LineServer: Sendable {
  typealias Accepted =
    @Sendable (_ app: Int32, _ open: Descriptors) -> (
      own: Int32?, line: @Sendable (Data) -> Void
    )?

  private let path: String
  private let open = Descriptors()

  /// A short directory under `/tmp`: `sun_path` holds 104 bytes.
  static func directory() throws -> URL {
    let directory = URL(
      fileURLWithPath: "/tmp/dh-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
  }

  init(at socket: URL, _ accepted: @escaping Accepted) throws {
    path = socket.path(percentEncoded: false)
    guard let listener = RawSocket.listening(at: path) else { throw POSIXError(.EADDRINUSE) }
    let open = open
    Thread.detachNewThread {
      while !open.isStopped {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 50) > 0 else { continue }
        let app = accept(listener, nil, nil)
        guard app >= 0 else { continue }
        RawSocket.noSignals(app)
        open.add(app)
        guard let (own, line) = accepted(app, open) else {
          open.closed(app)
          continue
        }
        RawSocket.pump(app, in: open, ended: { if let own { open.shutDown(own) } }) { chunk in
          for each in RawSocket.lines(chunk, app) { line(each) }
        }
      }
      Darwin.close(listener)
    }
  }

  func dropConnections() {
    open.shutDownAll()
  }

  func close() {
    open.stop()
    unlink(path)
  }
}

/// The few socket calls the stand-ins need, on plain descriptors.
private enum RawSocket {
  static func listening(at path: String) -> Int32? {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 16) == 0 else {
      close(fd)
      return nil
    }
    return fd
  }

  static func connected(to path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard withAddress(path, { connect(fd, $0, $1) }) == 0 else {
      close(fd)
      return nil
    }
    noSignals(fd)
    return fd
  }

  /// A write to a peer gone fails rather than raising SIGPIPE.
  static func noSignals(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  static func write(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let count = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return false }
        sent += count
      }
      return true
    }
  }

  /// What `fd` reads, as it comes, on a thread of its own until it ends; then it is closed.
  static func pump(
    _ fd: Int32, in open: Descriptors, ended: @escaping @Sendable () -> Void,
    _ chunk: @escaping @Sendable (Data) -> Void
  ) {
    Thread.detachNewThread {
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while true {
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        chunk(Data(buffer[0..<count]))
      }
      open.closed(fd)
      ended()
    }
  }

  /// The lines `chunk` ends, after what earlier chunks on `fd` left unended.
  private static let pending = Mutex<[Int32: Data]>([:])

  static func lines(_ chunk: Data, _ fd: Int32) -> [Data] {
    pending.withLock { pending in
      var data = pending[fd, default: Data()] + chunk
      var lines: [Data] = []
      while let end = data.firstIndex(of: 0x0A) {
        lines.append(Data(data[data.startIndex..<end]))
        data.removeSubrange(data.startIndex...end)
      }
      pending[fd] = data
      return lines
    }
  }

  private static func withAddress(
    _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
  ) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }
}
