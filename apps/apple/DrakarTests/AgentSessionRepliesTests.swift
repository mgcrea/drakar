import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A request from the CLI that only the client can answer is answered, so that the turn
/// never waits on it: against a stand-in `claude` that writes one, then records its stdin.
@MainActor
@Suite("A session answers the CLI's own requests")
struct AgentSessionRepliesTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-replies-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A stand-in that writes `lines` on start, then appends whatever it is sent to its stdin
  /// file.
  private func standIn(writing lines: String...) throws -> URL {
    let script = folder.appending(path: "claude")
    let writes = lines.map { "printf '%s\\n' '\($0)'\n" }.joined()
    try Data("#!/bin/sh\n\(writes)cat >> \"$0.stdin\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func sentLine(to script: URL, containing marker: String) async throws -> String? {
    let stdin = script.appendingPathExtension("stdin")
    for _ in 0..<50 {
      let text = (try? String(contentsOf: stdin, encoding: .utf8)) ?? ""
      if let line = text.split(separator: "\n").map(String.init).first(where: {
        $0.contains(marker)
      }) {
        return line
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private static let question =
    #"{"type":"control_request","request_id":"e1","request":{"subtype":"elicitation","mcp_server_name":"linear","message":"Which team?","mode":"form","requested_schema":{"type":"object","properties":{"team":{"type":"string"}}}}}"#

  /// What the stand-in was sent so far, a line each.
  private func sentLines(to script: URL) -> [String] {
    let stdin = script.appendingPathExtension("stdin")
    let text = (try? String(contentsOf: stdin, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// A session sent a prompt, once the stand-in's question waits on it.
  private func waitingSession(
    onRequested: (() -> Void)? = nil
  ) async throws -> (AgentSession, URL) {
    let script = try standIn(writing: Self.question)
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.onPermissionRequested = onRequested
    session.send("hello")
    for _ in 0..<50 where session.transcript.pendingElicitations.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    return (session, script)
  }

  @Test func anElicitationWaitsForThePerson() async throws {
    var requested = 0
    let (session, script) = try await waitingSession { requested += 1 }
    defer { session.stop() }
    #expect(session.transcript.pendingElicitations.map(\.requestID) == ["e1"])
    #expect(session.isAtWork)
    // A process on a pipe has no host to log the answer.
    #expect(!session.isHosted)
    #expect(!session.hostLogsAnswersInFull)
    #expect(requested == 1)
    try await Task.sleep(for: .seconds(1))
    #expect(!sentLines(to: script).contains { $0.contains(#""request_id":"e1""#) })
  }

  @Test func anAnsweredElicitationGoesBack() async throws {
    let (session, script) = try await waitingSession()
    defer { session.stop() }
    var replied = 0
    session.onReplied = { replied += 1 }
    let pending = try #require(session.transcript.pendingElicitations.first)
    session.answer(pending, .accept(["team": .string("core")]))
    let reply = try await sentLine(to: script, containing: #""request_id":"e1""#)
    #expect(reply?.contains(#""action":"accept""#) == true)
    #expect(reply?.contains(#""team":"core""#) == true)
    #expect(session.transcript.pendingElicitations.isEmpty)
    #expect(replied == 1)
  }

  @Test func anInterruptCancelsTheQuestion() async throws {
    let (session, script) = try await waitingSession()
    defer { session.stop() }
    #expect(session.transcript.pendingElicitations.count == 1)
    session.interrupt()
    _ = try await sentLine(to: script, containing: #""subtype":"interrupt""#)
    let lines = sentLines(to: script)
    let cancel = try #require(lines.firstIndex { $0.contains(#""request_id":"e1""#) })
    let interrupt = try #require(lines.firstIndex { $0.contains(#""subtype":"interrupt""#) })
    #expect(lines[cancel].contains(#""action":"cancel""#))
    #expect(cancel < interrupt)
    #expect(session.transcript.pendingElicitations.isEmpty)
  }

  @Test func aRequestItCannotServeIsRefused() async throws {
    let script = try standIn(
      writing:
        #"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback","callback_id":"c"}}"#
    )
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.send("hello")
    defer { session.stop() }
    let reply = try await sentLine(to: script, containing: #""request_id":"h1""#)
    #expect(reply?.contains(#""subtype":"error""#) == true)
  }

  // MARK: Asking its process

  private static let rulesReply =
    #"{\"state\":{\"rules\":[{\"behavior\":\"allow\",\"source\":\"localSettings\",\"rule\":\"Bash(npm run test:*)\",\"editability\":\"persistent\"}],\"workspaceDirectories\":[],\"managedOnly\":false}}"#

  /// A stand-in `claude` that answers each `list_permission_rules` with `rulesReply`, or with
  /// nothing when `answers` is false, then ends 50 ms after it was asked when `exits`.
  /// Every line it is sent goes to `$0.stdin`.
  private func askedSession(answers: Bool = true, exits: Bool = false) throws -> (
    AgentSession, URL
  ) {
    let fake = folder.appending(path: "claude")
    let reply =
      answers
      ? #"id=${line#*\"request_id\":\"}; id=${id%%\"*}; printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":\#(Self.rulesReply)}}""#
      : ":"
    let script = """
      #!/bin/sh
      while read -r line; do
        printf '%s\\n' "$line" >> "$0.stdin"
        case "$line" in
          *'"list_permission_rules"'*)
            \(reply)
            \(exits ? "sleep 0.05; exit 0" : ":")
            ;;
        esac
      done

      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let session = AgentSession(folder: folder)
    session.executableOverride = fake
    session.accounts = { [] }
    session.makeTransport = { AgentProcess($0) }
    return (session, fake)
  }

  @Test func listsRulesFromItsProcess() async throws {
    let (session, _) = try askedSession()
    defer { session.stop() }
    await session.spawn()
    #expect(session.hasLiveRules)
    let rules = PermissionRulesState(rules: [
      PermissionRule(
        behavior: .allow, source: "localSettings", rule: "Bash(npm run test:*)",
        editability: .persistent)
    ])
    #expect(await session.listPermissionRules() == .listed(rules))
  }

  /// The wait ends with the process, not with the timeout.
  @Test func aProcessEndEndsTheWait() async throws {
    let (session, fake) = try askedSession(answers: false, exits: true)
    defer { session.stop() }
    session.controlReplyTimeout = .seconds(5)
    await session.spawn()
    let started = ContinuousClock.now
    #expect(await session.listPermissionRules() == nil)
    #expect(ContinuousClock.now - started < .seconds(4))
    #expect(sentLines(to: fake).contains { $0.contains(#""list_permission_rules""#) })
  }

  /// The Permissions tab and the Session menu redraw when the process starts and when it is
  /// stopped: the process itself is not observed.
  @Test func aProcessStartingAndStoppingIsObserved() async throws {
    let (session, _) = try askedSession()
    defer { session.stop() }
    let started = ObservedFlag()
    withObservationTracking {
      _ = session.hasLiveRules
    } onChange: {
      started.value = true
    }
    await session.spawn()
    #expect(session.hasLiveRules)
    #expect(started.value)
    let stopped = ObservedFlag()
    withObservationTracking {
      _ = session.hasLiveRules
    } onChange: {
      stopped.value = true
    }
    session.stop()
    #expect(!session.hasLiveRules)
    #expect(stopped.value)
  }

  /// As a process that ends by itself: the tab stops asking it.
  @Test func aProcessEndingIsObserved() async throws {
    let (session, _) = try askedSession(exits: true)
    defer { session.stop() }
    await session.spawn()
    let ended = ObservedFlag()
    withObservationTracking {
      _ = session.hasLiveRules
    } onChange: {
      ended.value = true
    }
    _ = await session.listPermissionRules()
    for _ in 0..<100 where session.phase == .ready {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!session.hasLiveRules)
    #expect(ended.value)
  }

  @Test func noProcessNoAsk() async throws {
    let (session, fake) = try askedSession()
    defer { session.stop() }
    #expect(!session.hasLiveRules)
    #expect(await session.listPermissionRules() == nil)
    #expect(await session.readPlan() == nil)
    #expect(sentLines(to: fake).isEmpty)
  }

  /// An "always allow" adds rules, which the Permissions tab reads again; a plain allow does
  /// not.
  @Test func anAlwaysAllowBumpsTheRevision() async throws {
    let asking = { (id: String) in
      #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_\#(id)"}}"#
    }
    let script = try standIn(writing: asking("p1"), asking("p2"))
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.send("hello")
    defer { session.stop() }
    for _ in 0..<50 where session.transcript.pendingPermissions.count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    let pending = session.transcript.pendingPermissions
    try #require(pending.count == 2)
    let input = JSONValue.object(["command": .string("ls")])
    session.answer(pending[0], .allow(updatedInput: input, updatedPermissions: []))
    #expect(session.rulesRevision == 0)
    let always = JSONValue.object([
      "type": .string("addRules"),
      "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("ls")])]),
      "behavior": .string("allow"), "destination": .string("session"),
    ])
    session.answer(pending[1], .allow(updatedInput: input, updatedPermissions: [always]))
    #expect(session.rulesRevision == 1)
  }
}

/// Set from an observation callback, which may not capture a variable.
private final class ObservedFlag: @unchecked Sendable {
  var value = false
}
