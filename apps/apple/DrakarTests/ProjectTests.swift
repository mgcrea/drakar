import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A project window's sessions")
struct ProjectTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-project-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func target(_ id: String, cwd: String? = nil) -> ResumeTarget {
    ResumeTarget(
      sessionID: id, cwd: cwd ?? folder.path(percentEncoded: false),
      file: folder.appending(path: "\(id).jsonl").path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
  }

  @Test func attachingPutsTheSessionOnTopAndSelectsIt() {
    let project = Project(folder: folder)
    let first = project.attach(target("a"))
    let second = project.attach(target("b"))
    #expect(project.sessions.map(\.id) == [second.id, first.id])
    #expect(project.selectedID == second.id)
  }

  /// One writer per transcript: attaching what is already here selects it.
  @Test func attachingTwiceSelectsTheOneAlreadyHere() {
    let project = Project(folder: folder)
    let first = project.attach(target("a"))
    _ = project.attach(target("b"))
    let again = project.attach(target("a"))
    #expect(again.id == first.id)
    #expect(project.sessions.count == 2)
    #expect(project.selectedID == first.id)
  }

  @Test func theAttachedListSurvivesARelaunch() throws {
    let project = Project(folder: folder)
    _ = project.attach(target("a"))
    _ = project.attach(target("b"))
    _ = project.newSession()  // no id yet: not restorable, and not stored
    project.select(project.sessions[1])  // b
    let stored = try JSONDecoder().decode(
      StoredProject.self, from: JSONEncoder().encode(project.stored))
    let restored = Project(folder: folder, restoring: stored)
    #expect(restored.sessions.map(\.sessionID) == ["b", "a"])
    #expect(restored.selected?.sessionID == "b")
    #expect(restored.sessions.allSatisfy { !$0.session.isProcessRunning })
  }

  @Test func aForkIsANewRowBesideTheOriginal() {
    let project = Project(folder: folder)
    let original = project.attach(target("a"), readOnly: true)
    let fork = project.fork(original)
    #expect(project.sessions.count == 2)
    #expect(fork.session.resuming?.forks == true)
    #expect(!fork.session.isReadOnly)
    #expect(original.session.isReadOnly)
  }

  @Test func theWindowIndexFindsASessionAndItsOwner() {
    let project = Project(folder: folder)
    let attached = project.attach(target("a"))
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    #expect(OpenSessions.shared.locate("a")?.1.id == attached.id)
    let sub = folder.appending(path: "sub").path(percentEncoded: false)
    #expect(
      OpenSessions.shared.ownerFolder(forCwd: sub)
        == ProjectPath.normalize(folder.path(percentEncoded: false)))
    #expect(OpenSessions.shared.ownerFolder(forCwd: "/elsewhere/x") == "/elsewhere/x")
  }

  @Test func pendingAttachmentsWaitForTheirWindow() {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    OpenSessions.shared.requestAttach(target("a"), in: path)
    #expect(OpenSessions.shared.takePending(for: path).map(\.sessionID) == ["a"])
    #expect(OpenSessions.shared.takePending(for: path).isEmpty)
  }

  @Test func aSessionLiveElsewhereIsReadOnlyAndWritableAgain() {
    let project = Project(folder: folder)
    let item = project.attach(target("a"))
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    OpenSessions.shared.liveChanged(["a"])
    #expect(item.session.isReadOnly)
    OpenSessions.shared.liveChanged([])
    #expect(!item.session.isReadOnly)
  }

  @Test func aRestoredRowLiveElsewhereIsReadOnly() {
    let stored = StoredProject(sessions: [target("a"), target("a"), target("b")], selected: "a")
    let project = Project(folder: folder, restoring: stored)
    #expect(project.sessions.map(\.sessionID) == ["a", "b"])
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    OpenSessions.shared.liveChanged(["b"])
    #expect(project.sessions.map(\.session.isReadOnly) == [false, true])
  }

  /// Every restored row has its title and gauge before it is shown, not only the selected
  /// one: they come from the transcript's end, read at restore.
  @Test func restoredRowsShowTheirTitleAndGaugeBeforeTheyAreShown() async throws {
    for (id, title) in [("a", "Title A"), ("b", "Title B")] {
      try Data(
        [
          #"{"type":"user","cwd":"/w","message":{"role":"user","content":"go"}}"#,
          #"{"type":"assistant","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":40000,"output_tokens":5}}}"#,
          #"{"type":"ai-title","aiTitle":"\#(title)"}"#,
        ].joined(separator: "\n").appending("\n").utf8
      ).write(to: folder.appending(path: "\(id).jsonl"))
    }
    let project = Project(
      folder: folder, restoring: StoredProject(sessions: [target("a"), target("b")], selected: "a"))
    let unshown = project.sessions[1]
    for _ in 0..<50 where unshown.displayTitle != "Title B" {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(project.sessions.map(\.displayTitle) == ["Title A", "Title B"])
    #expect(!unshown.session.hasLoadedHistory)
    #expect(unshown.gauge(accountModel: nil)?.used == 40_012)
    #expect(unshown.lastActivity != nil)
  }

  private func standIn(_ name: String, _ body: String) throws -> URL {
    let script = folder.appending(path: name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// A row waiting on a permission counts in the group's header.
  @Test func aWaitingRowCountsInTheHeader() async throws {
    let request =
      #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"make test"},"tool_use_id":"toolu_1"}}"#
    let project = Project(folder: folder)
    _ = project.newSession()
    let item = project.newSession()
    item.session.executableOverride = try standIn("claude", "echo '\(request)'\ncat > /dev/null")
    #expect(project.waitingCount == 0)
    item.session.send("go")
    for _ in 0..<50 where project.waitingCount == 0 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(project.waitingCount == 1)
    item.session.stop()
    #expect(project.waitingCount == 0)
  }

  /// A process that exits on an error says so in its row: "Stopped, exit 3".
  @Test func aFailedExitSaysItsStatus() async throws {
    let project = Project(folder: folder)
    let item = project.newSession()
    item.session.executableOverride = try standIn("claude", "read line\nexit 3")
    item.session.send("go")
    for _ in 0..<50 where !item.hasStopped {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(item.session.phase == .exited(status: 3))
    #expect(item.stopReason == "Stopped, exit 3")
  }

  /// A session running here is never flipped.
  @Test func aRowWithItsOwnProcessIsNeverFlipped() async throws {
    let fake = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat >> \"$0.stdin\"\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let file = folder.appending(path: "a.jsonl")
    try Data(
      #"{"type":"user","message":{"role":"user","content":"Earlier"}}"#.appending("\n").utf8
    ).write(to: file)
    let project = Project(folder: folder)
    let item = project.attach(target("a"))
    item.session.executableOverride = fake
    await item.session.loadHistory()
    item.session.send("hello")
    for _ in 0..<50 where !item.session.isProcessRunning {
      try await Task.sleep(for: .milliseconds(100))
    }
    defer { item.session.stop() }
    #expect(item.session.isProcessRunning)
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    OpenSessions.shared.liveChanged(["a"])
    #expect(!item.session.isReadOnly)
  }
}
