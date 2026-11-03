import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The tab strip over the session pane (session tabs spec, The strip): what a tab's mark
/// says, that a tab redraws only when what it shows changes, and closing several at once.
@MainActor
@Suite("Session tabs")
struct SessionTabTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-sessiontabs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A stand-in `claude` named `name` that writes `lines` once prompted, then waits.
  private func standIn(_ name: String, writing lines: String...) throws -> URL {
    let script = folder.appending(path: name)
    let writes = lines.map { "printf '%s\\n' '\($0)'\n" }.joined()
    try Data("#!/bin/sh\nread -r line\n\(writes)cat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private static let initLine =
    #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-1","model":"m","permissionMode":"default"}"#
  private static let saysOne =
    #"{"type":"assistant","message":{"id":"m-1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"one"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-1"}"#
  private static let callsLs =
    #"{"type":"assistant","message":{"id":"m-ls","type":"message","role":"assistant","model":"m","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-1"}"#
  private static let asksLs =
    #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}"#

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  @Test func statusPrefersWhatNeedsYou() async throws {
    _ = await AgentSession.environment.value
    let project = Project(folder: folder)
    defer { project.stopAll() }

    let fresh = project.newSession(agent: .claude)
    #expect(TabStatus.of(fresh) == .none)
    fresh.isUnread = true
    #expect(TabStatus.of(fresh) == .unread)

    let working = project.newSession(agent: .claude)
    working.session.executableOverride = try standIn(
      "claude-working", writing: Self.initLine, Self.saysOne)
    working.session.send("go")
    try await eventually { working.session.status.hasEntries && working.session.status.isRunning }
    try #require(working.session.status.isRunning)
    working.isUnread = true
    #expect(TabStatus.of(working) == .working)

    let asking = project.newSession(agent: .claude)
    asking.session.executableOverride = try standIn(
      "claude-asking", writing: Self.initLine, Self.callsLs, Self.asksLs)
    asking.session.send("go")
    try await eventually { asking.session.status.isWaitingOnPerson }
    try #require(asking.session.status.pendingPermissions.map(\.requestID) == ["req-1"])
    #expect(asking.session.status.isRunning)
    #expect(TabStatus.of(asking) == .needsYou)
  }

  @Test func aTabIsEqualWhateverItsClosures() {
    var selected = 0
    var closed = 0
    let one = SessionTab(
      title: "Fix the build", status: .working, agent: .claude, isSelected: true,
      isMarked: false, isPreview: false, tooltip: "Working", select: { selected += 1 },
      close: { closed += 1 })
    let other = SessionTab(
      title: "Fix the build", status: .working, agent: .claude, isSelected: true,
      isMarked: false, isPreview: false, tooltip: "Working", select: {}, close: {})
    #expect(one == other)
    let finished = SessionTab(
      title: "Fix the build", status: .unread, agent: .claude, isSelected: true,
      isMarked: false, isPreview: false, tooltip: "Working", select: {}, close: {})
    #expect(one != finished)
    #expect(selected == 0 && closed == 0)
  }

  @Test func closeOthersKeepsTheOneAndAnyThatWouldAsk() {
    let project = Project(folder: folder)
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    c.draft = "x"
    project.select(b)
    project.closeOthers(than: a)
    #expect(project.tabs.map(\.id) == [a.id, c.id])
    // The shown tab closed: the one kept is shown, not a neighbour on its way out.
    #expect(project.selectedID == a.id)
  }

  @Test func closeToTheRight() {
    let project = Project(folder: folder)
    let a = project.newSession()
    _ = project.newSession()
    _ = project.newSession()
    project.closeToTheRight(of: a)
    #expect(project.tabs.map(\.id) == [a.id])
    #expect(project.selectedID == a.id)
  }

  /// A tab dropped on another takes its place, whichever way it moved; what is not one of
  /// the window's tabs is not taken.
  @Test func aTabDroppedOnAnotherTakesItsPlace() {
    let project = Project(folder: folder)
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    #expect(SessionTabStrip.drop([a.id.uuidString], onto: c, in: project))
    #expect(project.tabs.map(\.id) == [b.id, c.id, a.id])
    #expect(SessionTabStrip.drop([a.id.uuidString], onto: b, in: project))
    #expect(project.tabs.map(\.id) == [a.id, b.id, c.id])
    #expect(SessionTabStrip.drop([a.id.uuidString], onto: nil, in: project))
    #expect(project.tabs.map(\.id) == [b.id, c.id, a.id])
    #expect(!SessionTabStrip.drop(["some text"], onto: b, in: project))
    #expect(!SessionTabStrip.drop([UUID().uuidString], onto: b, in: project))
    #expect(project.tabs.map(\.id) == [b.id, c.id, a.id])
  }

  /// The tabs share the strip down to their narrowest, then the strip scrolls.
  @Test func tabsShrinkToTheirNarrowest() {
    #expect(SessionTabStrip.tabWidth(in: 1000, count: 2) == 220)
    #expect(SessionTabStrip.tabWidth(in: 600, count: 4) < 150)
    #expect(SessionTabStrip.tabWidth(in: 600, count: 4) > 120)
    #expect(SessionTabStrip.tabWidth(in: 600, count: 20) == 120)
  }
}
