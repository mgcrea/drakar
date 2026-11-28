import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A turn that ends with a command still running in the background (session 493d9ee2's test
/// run): the session reads as waiting on it rather than idle, and what waits for the session
/// to be done (auto-close, a batch's slot, "Finished") waits for the task too.
@MainActor
@Suite("Background tasks")
struct BackgroundTaskSessionTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-background-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private static let lines = [
    #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-1","model":"m","permissionMode":"default"}"#,
    #"{"type":"assistant","message":{"id":"m-1","type":"message","role":"assistant","model":"m","content":[{"type":"tool_use","id":"gate","name":"Bash","input":{"command":"make test-all","description":"Run every suite","run_in_background":true}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-1"}"#,
    #"{"type":"system","subtype":"task_started","task_id":"b8fk67x74","tool_use_id":"gate","description":"Run every suite","is_backgrounded":true,"task_type":"local_bash","session_id":"s-1"}"#,
    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"gate","type":"tool_result","content":"Command running in background with ID: b8fk67x74."}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
    #"{"type":"assistant","message":{"id":"m-2","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"The gate is running. I will pick up when it finishes."}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-1"}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"The gate is running.","session_id":"s-1"}"#,
  ]
  private static let ended =
    #"{"type":"system","subtype":"task_notification","task_id":"b8fk67x74","tool_use_id":"gate","status":"completed","output_file":"/tmp/b8fk67x74.output","summary":"done","session_id":"s-1"}"#

  /// A stand-in `claude` that, once prompted, starts a background command and ends its turn,
  /// then, once `release` exists, reports the command ended, with no turn after.
  private func standIn(release: URL) throws -> URL {
    let script = folder.appending(path: "claude")
    let writes = Self.lines.map { "printf '%s\\n' '\($0)'\n" }.joined()
    try Data(
      """
      #!/bin/sh
      read -r line
      \(writes)while [ ! -e '\(release.path)' ]; do sleep 0.1; done
      printf '%s\\n' '\(Self.ended)'
      cat > /dev/null

      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  @Test func aTurnLeavingATaskRunningWaitsForIt() async throws {
    _ = await AgentSession.environment.value
    let project = Project(folder: folder)
    defer { project.stopAll() }
    let release = folder.appending(path: "release")
    let item = project.newSession(agent: .claude)
    item.session.executableOverride = try standIn(release: release)
    item.session.settleInterval = .milliseconds(200)
    item.session.send("run the gate")
    item.closesAfterTurn = true

    try await eventually { item.turnEndAwaitsTasks }
    #expect(!item.session.status.isRunning)
    #expect(item.session.status.isWorking)
    #expect(item.session.status.backgroundWork.map(\.description) == ["Run every suite"])
    #expect(RowState(item) == .background)
    #expect(TabStatus.of(item) == .background)
    #expect(project.runningCount == 1)
    // Closing now would stop the command: asked first, and the tab stays open.
    #expect(project.closeAsk(for: item) == .stopsTurn)
    #expect(project.sessions.contains { $0.id == item.id })

    try Data().write(to: release)
    try await eventually { !project.sessions.contains { $0.id == item.id } }
    // Auto-close took the tab once the command ended and no turn followed it.
    #expect(!project.sessions.contains { $0.id == item.id })
    #expect(!item.turnEndAwaitsTasks)
  }
}
