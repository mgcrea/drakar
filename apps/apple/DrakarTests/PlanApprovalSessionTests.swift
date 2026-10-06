import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Each of the plan's three choices, as it reaches a stand-in `claude` that asks with
/// `ExitPlanMode` and records its stdin.
@MainActor
@Suite("Answering a plan")
struct PlanApprovalSessionTests {

  private let folder: URL
  private let script: URL
  private var stdin: URL { script.appendingPathExtension("stdin") }

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-plan-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    script = folder.appending(path: "claude")
    let request =
      ##"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Add hello.txt"},"tool_use_id":"t1","requires_user_interaction":true}}"##
    try Data("#!/bin/sh\nprintf '%s\\n' '\(request)'\ncat >> \"$0.stdin\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  }

  /// A session waiting on the plan.
  private func asked() async throws -> (AgentSession, Transcript.PendingPermission) {
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.send("Plan it")
    for _ in 0..<50 where session.transcript.pendingPermissions.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    let pending = try #require(session.transcript.pendingPermissions.first)
    #expect(pending.request.isPlan)
    return (session, pending)
  }

  /// What was sent about the plan, once the line answering `p1` has arrived.
  private func answerLines() async throws -> [String] {
    for _ in 0..<50 {
      let lines = ((try? String(contentsOf: stdin, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
      if lines.contains(where: { $0.contains(#""request_id":"p1""#) }) {
        // The mode switches and the answers; not what any start sends (`get_settings`…).
        return lines.filter {
          $0.contains("set_permission_mode") || $0.contains(#""type":"control_response""#)
        }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("no answer reached the stand-in")
    return []
  }

  /// The mode goes first, then the plan runs as written.
  @Test func autoAcceptSwitchesTheModeThenAllows() async throws {
    let (session, pending) = try await asked()
    defer { session.stop() }
    session.approvePlan(pending, editsManually: false, autoMode: false)
    let lines = try await answerLines()
    #expect(lines.count == 2)
    #expect(lines.first?.contains(#""mode":"acceptEdits""#) == true)
    #expect(lines.last?.contains(#""behavior":"allow""#) == true)
    #expect(lines.last?.contains("updatedPermissions") == false)
    #expect(session.transcript.pendingPermissions.isEmpty)
  }

  @Test func autoModeWhenTheModelTakesIt() async throws {
    let (session, pending) = try await asked()
    defer { session.stop() }
    session.approvePlan(pending, editsManually: false, autoMode: true)
    #expect(try await answerLines().first?.contains(#""mode":"auto""#) == true)
  }

  @Test func manualEditsLeavePlanModeForTheDefault() async throws {
    let (session, pending) = try await asked()
    defer { session.stop() }
    session.approvePlan(pending, editsManually: true, autoMode: true)
    let lines = try await answerLines()
    #expect(lines.count == 1)
    #expect(lines.first?.contains(#""mode":"default","type":"setMode""#) == true)
  }

  @Test func keepingOnPlanningWithoutFeedbackEndsTheTurn() async throws {
    let (session, pending) = try await asked()
    defer { session.stop() }
    session.answer(pending, PlanApproval.keepPlanning(feedback: ""))
    let lines = try await answerLines()
    #expect(lines.first?.contains(#""interrupt":true"#) == true)
  }
}
