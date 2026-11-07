import DrakarKit
import DrakarMCP
import Foundation
import Testing

@testable import Drakar

/// What the MCP server's writes do in the app: each goes through the call the window's own
/// control makes, to sessions run by a stand-in `claude`, in windows registered in an
/// `OpenSessions` of the test's own. No window is opened: the source's opener is none, so a
/// write that would open one is refused, as before any window has appeared.
@MainActor
@Suite("The MCP server's writes", .serialized)
struct SessionMCPWritesTests {
  private let defaults: UserDefaults

  init() {
    defaults = UserDefaults(suiteName: "drakar-mcp-writes-\(UUID().uuidString)")!
    AttentionChoice.defaults = UserDefaults(suiteName: "drakar-tests-\(UUID().uuidString)")!
  }

  private static func initLine(_ id: String) -> String {
    #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":""#
      + id + #"","model":"m","permissionMode":"default"}"#
  }

  private static let done = [
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Done."}]}}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#,
  ]
  private static let permission =
    #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch a.txt"},"tool_use_id":"toolu_1"}}"#

  private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A stand-in `claude` that says these lines once started, then keeps what it is sent in
  /// `<itself>.stdin`.
  private func fake(_ lines: [String]) throws -> URL {
    let fake = try folder().appending(path: "claude")
    let script =
      "#!/bin/sh\n" + lines.map { "echo '\($0)'" }.joined(separator: "\n")
      + "\ncat >> \"$0.stdin\"\n"
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  /// A window's session, prompted, once its stand-in has said `lines` after its init and
  /// `until` holds.
  private func session(
    _ id: String, _ lines: [String], in project: Project,
    until: (AgentSession) -> Bool = { _ in true }
  ) async throws -> (ProjectSession, stdin: URL) {
    let item = project.newSession(agent: .claude)
    let fake = try fake([Self.initLine(id)] + lines)
    item.session.executableOverride = fake
    item.session.send("Build it")
    for _ in 0..<100 where item.sessionID == nil || !until(item.session) {
      try await Task.sleep(for: .milliseconds(50))
    }
    return (item, fake.appendingPathExtension("stdin"))
  }

  /// The control responses the stand-in has received for `requestID`, once at least one has.
  private func responses(to requestID: String, in stdin: URL) async throws -> [String] {
    for _ in 0..<50 {
      let lines = ((try? String(contentsOf: stdin, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
        .filter {
          $0.contains(#""type":"control_response""#)
            && $0.contains(#""request_id":"\#(requestID)""#)
        }
      if !lines.isEmpty { return lines }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("no answer reached the stand-in")
    return []
  }

  /// One window, registered in an `OpenSessions` of the test's own.
  private func window() throws -> (Project, OpenSessions, UUID) {
    let project = Project(folder: try folder())
    let open = OpenSessions()
    let window = UUID()
    open.register(project, window: window)
    return (project, open, window)
  }

  private func source(
    _ open: OpenSessions, monitor: SessionMonitor = SessionMonitor()
  ) -> SessionMCPSource {
    let source = SessionMCPSource(defaults: defaults, openSessions: open, monitor: monitor)
    source.listHosts = { HostListings() }
    source.runnerHost = { nil }
    source.openWindow = { nil }
    return source
  }

  // MARK: - Start

  /// The project's window is open: the session is a new tab, the tab shown stays shown, and
  /// the call returns the session's id once it has one.
  @Test func startInOpenProjectDoesNotSwitchTab() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let shown = project.newSession(agent: .claude)
    project.executableOverride = try fake([Self.initLine("s-new")])

    let id = try await source(open).start(
      StartRequest(
        folder: project.folder.path(percentEncoded: false), prompt: "Write the tests",
        agent: .claude))

    #expect(id == "s-new")
    #expect(project.selectedID == shown.id)
    #expect(project.sessions.count == 2)
    let started = try #require(project.sessions.first { $0.sessionID == "s-new" })
    #expect(started.session.status.firstPrompt == "Write the tests")
  }

  /// A runner out of reach, or none by that name: refused before any window or row is made.
  @Test func startUnreachableRunnerLeavesNoRow() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let shown = project.newSession(agent: .claude)
    let settings = RunnerSettings(name: "eva", destination: "eva.local")
    RunnerSettings.write(settings, to: defaults)
    let source = source(open)
    let host = SessionHost(endpoint: .runner(settings), keptIn: defaults)
    defer { host.close() }
    source.runnerHost = { host }

    await #expect(throws: SessionError("eva can't be reached: it isn't connected.")) {
      try await source.start(StartRequest(folder: "~/Projects/x", runner: "Eva", prompt: "Hi"))
    }
    await #expect(throws: SessionError("No runner named ada is set up.")) {
      try await source.start(StartRequest(folder: "/w/x", runner: "ada", prompt: "Hi"))
    }
    #expect(project.sessions.map(\.id) == [shown.id])
    #expect(open.projects.count == 1)
  }

  /// This Mac's folder must be one.
  @Test func startInAMissingFolderRefused() async throws {
    let missing = "/nonexistent-\(UUID().uuidString)"
    await #expect(throws: SessionError("There is no folder at \(missing) on this Mac.")) {
      try await source(OpenSessions()).start(StartRequest(folder: missing, prompt: "Hi"))
    }
  }

  // MARK: - Send

  @Test func sendQueuesMidTurn() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let (item, _) = try await session("s-busy", [], in: project) { $0.status.isRunning }
    #expect(item.session.status.isRunning)

    let outcome = try await source(open).send(to: "s-busy", text: "Next")
    #expect(outcome == .queued)
    #expect(item.session.transcript.queuedPrompts.map(\.text) == ["Next"])
  }

  @Test func sendSendsWhenIdle() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let (item, stdin) = try await session("s-idle", Self.done, in: project) {
      $0.transcript.turnEnd != nil
    }

    let outcome = try await source(open).send(to: "s-idle", text: "And the docs")
    #expect(outcome == .sent)
    #expect(item.session.status.isRunning)
    for _ in 0..<50
    where !((try? String(contentsOf: stdin, encoding: .utf8)) ?? "").contains("And the docs") {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(((try? String(contentsOf: stdin, encoding: .utf8)) ?? "").contains("And the docs"))
  }

  /// A runner's row kept from before its connection dropped is refused with the runner's
  /// reason; no take-back is tried.
  @Test func sendToAnUnreachableRunnerRowRefused() async throws {
    var meta = SessionMeta(
      start: AgentStart(
        folder: URL(filePath: "/w/drakar"), environment: [:], executableOverride: nil,
        allowsBypass: false),
      windowFolder: "/w/drakar", history: .none)
    meta.sessionID = "s-runner"
    meta.owner = ThisMac.name
    let held = HeldProcess(
      id: "h1", meta: try JSONEncoder().encode(meta), running: true, logLength: 0)
    let source = source(OpenSessions())
    source.listHosts = {
      HostListings(
        local: [], runner: .init(id: "r1", name: "eva", held: [held], isConnected: false))
    }

    await #expect(
      throws: SessionError("s-runner is on eva, which can't be reached: it isn't connected.")
    ) {
      try await source.send(to: "s-runner", text: "Hi")
    }
  }

  // MARK: - Ended and elsewhere

  /// An ended session is resumed by a message (here, refused only for want of a window to
  /// open), and refused an interrupt or an end; one live in a terminal is only followed.
  @Test func endedAndElsewhereSessions() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "mcp-writes-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    let registry = account.directory.appending(path: "sessions")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    for id in ["s-else", "s-old"] {
      let lines = [
        #"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#,
        #"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Gone."}]}}"#,
      ]
      try Data(lines.joined(separator: "\n").appending("\n").utf8)
        .write(to: projects.appending(path: "\(id).jsonl"))
    }
    let json =
      #"{"pid":\#(getpid()),"sessionId":"s-else","cwd":"/w/drakar","entrypoint":"cli","status":"busy"}"#
    try Data(json.utf8).write(to: registry.appending(path: "\(getpid()).json"))
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    defer { monitor.stop() }
    for _ in 0..<40 where monitor.liveIDs.isEmpty || monitor.all.count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    let source = source(OpenSessions(), monitor: monitor)

    await #expect(throws: SessionError("s-old has ended. drakar_send_message resumes it.")) {
      try await source.interrupt("s-old")
    }
    await #expect(throws: SessionError("s-old has ended. drakar_send_message resumes it.")) {
      try await source.end("s-old")
    }
    await #expect(throws: SessionError("Open a Drakar window once, then try again.")) {
      _ = try await source.send(to: "s-old", text: "Again")
    }
    await #expect(throws: SessionError("s-else runs in a terminal; Drakar only follows it.")) {
      _ = try await source.send(to: "s-else", text: "Hi")
    }
    await #expect(throws: SessionError("s-else runs in a terminal; Drakar only follows it.")) {
      try await source.end("s-else")
    }
  }

  // MARK: - Answers, interrupt, end

  @Test func answerPermissionReachesSession() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let (item, stdin) = try await session("s-perm", [Self.permission], in: project) {
      !$0.status.pendingPermissions.isEmpty
    }
    let pending = try #require(item.session.status.pendingPermissions.first)

    try await source(open).answer(
      "s-perm", requestID: "r1", with: .allow(updatedInput: pending.request.input))

    let lines = try await responses(to: "r1", in: stdin)
    #expect(lines.count == 1)
    #expect(lines.first?.contains(#""behavior":"allow""#) == true)
    #expect(item.session.status.pendingPermissions.isEmpty)
  }

  /// The person, or another call, answered first: the second answer is refused, and only one
  /// reaches the session.
  @Test func answerAlreadyAnswered() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let (item, stdin) = try await session("s-twice", [Self.permission], in: project) {
      !$0.status.pendingPermissions.isEmpty
    }
    let pending = try #require(item.session.status.pendingPermissions.first)
    let source = source(open)

    try await source.answer(
      "s-twice", requestID: "r1", with: .allow(updatedInput: pending.request.input))
    await #expect(throws: SessionError.noLongerWaiting("r1")) {
      try await source.answer(
        "s-twice", requestID: "r1", with: .deny(message: "No", interrupt: false))
    }

    #expect(try await responses(to: "r1", in: stdin).count == 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await responses(to: "r1", in: stdin).count == 1)
  }

  /// With Next After Replying on, the person's reply to the tab shown moves the window on;
  /// an agent's, through the MCP server, leaves the tab shown where it is.
  @Test func anAgentsReplyDoesNotMoveTheWindowOn() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    project.movesOnAfterReply = true
    let (other, _) = try await session("s-other", UrgencyTests.asking, in: project) {
      $0.transcript.turnEnd != nil
    }
    let (shown, _) = try await session("s-shown", [Self.permission], in: project) {
      !$0.status.pendingPermissions.isEmpty
    }
    project.select(shown)
    #expect(other.urgency == .question)
    let pending = try #require(shown.session.status.pendingPermissions.first)

    try await source(open).answer(
      "s-shown", requestID: "r1", with: .allow(updatedInput: pending.request.input))
    try await Task.sleep(for: .milliseconds(200))
    #expect(project.selectedID == shown.id)
  }

  @Test func interruptKeepsTheQueue() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let (_, stdin) = try await session("s-stop", [], in: project) { $0.status.isRunning }
    let source = source(open)

    try await source.interrupt("s-stop")

    var sent = ""
    for _ in 0..<50 where !sent.contains(#""subtype":"interrupt""#) {
      try await Task.sleep(for: .milliseconds(100))
      sent = (try? String(contentsOf: stdin, encoding: .utf8)) ?? ""
    }
    let line = sent.split(separator: "\n").first { $0.contains(#""subtype":"interrupt""#) }
    #expect(line != nil)
    #expect(line?.contains("cancel") != true)
  }

  @Test func endKeepsRow() async throws {
    let (project, open, window) = try window()
    defer {
      project.stopAll()
      open.unregister(window: window)
    }
    let (item, _) = try await session("s-end", Self.done, in: project) {
      $0.transcript.turnEnd != nil
    }

    try await source(open).end("s-end")

    #expect(project.sessions.contains { $0 === item })
    #expect(item.session.isProcessRunning == false)
    await #expect(throws: SessionError("Build it has no turn running.")) {
      try await source(open).interrupt("s-end")
    }
  }
}
