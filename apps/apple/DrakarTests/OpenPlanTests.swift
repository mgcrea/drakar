import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Session > Open Plan against a stand-in `claude` that answers `get_plan` with what its
/// `.reply` file holds, or with nothing when there is none.
@MainActor
@Suite("Opening the session's plan")
struct OpenPlanTests {

  private let folder: URL
  private let fake: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-open-plan-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    let script = #"""
      #!/bin/sh
      while read -r line; do
        case "$line" in
          *'"get_plan"'*)
            [ -f "$0.reply" ] || continue
            id=${line#*\"request_id\":\"}; id=${id%%\"*}
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\n' "$id" "$(cat "$0.reply")"
            ;;
        esac
      done

      """#
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  /// A project showing a Claude Code session whose process answers `get_plan` with `reply`,
  /// waited for up to `timeout`: long, so a stalled main actor fails no answered read.
  private func project(answering reply: String?, timeout: Duration = .seconds(5)) async throws -> (
    Project, ProjectSession
  ) {
    if let reply {
      try Data(reply.utf8).write(to: fake.appendingPathExtension("reply"))
    }
    let project = Project(folder: folder)
    let item = project.newSession(agent: .claude)
    item.session.executableOverride = fake
    item.session.accounts = { [] }
    item.session.makeTransport = { AgentProcess($0) }
    item.session.controlReplyTimeout = timeout
    await item.session.spawn()
    #expect(project.canOpenPlanSelected)
    return (project, item)
  }

  private func lastNotice(_ item: ProjectSession) -> String? {
    item.session.transcript.entries.reversed().lazy.compactMap {
      if case .notice(let text) = $0.kind { text } else { nil }
    }.first
  }

  /// The plan lives under the account's `plans/`, outside the project's folder.
  @Test func opensAnExistingPlan() async throws {
    let plan = FileManager.default.temporaryDirectory.appending(
      path: "drakar-plans-\(UUID().uuidString)/plan.md")
    try FileManager.default.createDirectory(
      at: plan.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: plan.deletingLastPathComponent()) }
    try Data("# P".utf8).write(to: plan)
    let path = plan.path(percentEncoded: false)
    let (project, item) = try await project(
      answering: ##"{"exists":true,"content":"# P","path":"\##(path)"}"##)
    defer { item.session.stop() }
    await project.openPlanSelected()
    let active = try #require(project.workspace.active)
    #expect(active.path == FileTree.normalized(plan.standardized.path(percentEncoded: false)))
    #expect(project.workspace.documents.count == 1)
    #expect(lastNotice(item) == nil)
    // Claude plans again; opening it again shows the new plan, not the tab's old text.
    try Data("# P2".utf8).write(to: plan)
    await project.openPlanSelected()
    #expect(project.workspace.active === active)
    #expect(active.storage.string == "# P2")
  }

  @Test func noPlanSaysSo() async throws {
    let (project, item) = try await project(answering: #"{"exists":false}"#)
    defer { item.session.stop() }
    await project.openPlanSelected()
    #expect(lastNotice(item) == "No plan in this session yet.")
    #expect(project.workspace.documents.isEmpty)
  }

  @Test func aFailedReadSaysSo() async throws {
    let (project, item) = try await project(answering: nil, timeout: .milliseconds(300))
    defer { item.session.stop() }
    await project.openPlanSelected()
    #expect(lastNotice(item) == "Couldn't read the plan.")
    #expect(project.workspace.documents.isEmpty)
  }

  /// A connection that keeps frames server-side leaves the path out: nothing to open.
  @Test func existsWithoutPathSaysNoPlan() async throws {
    let (project, item) = try await project(answering: ##"{"exists":true,"content":"# P"}"##)
    defer { item.session.stop() }
    await project.openPlanSelected()
    #expect(lastNotice(item) == "No plan in this session yet.")
    #expect(project.workspace.documents.isEmpty)
  }

  /// Nothing is asked of a session with no process.
  @Test func noProcessCannotOpen() {
    let project = Project(folder: folder)
    _ = project.newSession(agent: .claude)
    #expect(!project.canOpenPlanSelected)
  }
}
