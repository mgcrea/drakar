import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Marking several sessions and sending to them")
struct SessionMarksTests {
  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-marks-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A stand-in CLI that reads forever: a prompt sent leaves its turn running.
  private func standIn() throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// Four sessions, listed top to bottom as returned; the first shown.
  private func project(_ count: Int = 4) throws -> (Project, [ProjectSession]) {
    let project = Project(folder: folder)
    project.executableOverride = try standIn()
    for _ in 0..<count { project.newSession() }
    let items = project.listedHeld
    project.select(items[0])
    return (project, items)
  }

  /// Until each has its process: a start runs after `send` returns.
  private func started(_ items: [ProjectSession]) async throws {
    for _ in 0..<100 where items.contains(where: { !$0.session.isProcessRunning }) {
      try await Task.sleep(for: .milliseconds(20))
    }
    let all = items.allSatisfy { $0.session.isProcessRunning }
    try #require(all)
  }

  private func prompts(_ item: ProjectSession) -> [String] {
    item.session.transcript.entries.compactMap {
      if case .prompt(let text) = $0.kind { text } else { nil }
    }
  }

  /// ⌘-click marks the shown session with the one clicked, without showing it; again takes
  /// it out.
  @Test func commandClickToggles() throws {
    let (project, items) = try project()
    project.click(items[2], .toggle)
    #expect(project.marked == [items[0].id, items[2].id])
    #expect(project.selectedID == items[0].id)
    project.click(items[2], .toggle)
    #expect(project.marked == [items[0].id])
    #expect(!project.sendsToMarked)
  }

  /// ⇧-click marks every row from the last clicked to this one, in the list's order.
  @Test func shiftClickMarksTheRange() throws {
    let (project, items) = try project()
    project.click(items[1], .plain)
    project.click(items[3], .extend)
    #expect(project.markedSessions.map(\.id) == items[1...3].map(\.id))
    #expect(project.sendsToMarked)
  }

  /// A plain click shows the row and clears the marks.
  @Test func plainClickClears() throws {
    let (project, items) = try project()
    project.click(items[2], .toggle)
    project.click(items[3], .plain)
    #expect(project.marked.isEmpty)
    #expect(project.selectedID == items[3].id)
  }

  /// Mark All takes every held row; Clear takes them all off.
  @Test func markAllAndClear() throws {
    let (project, items) = try project()
    project.markAll()
    #expect(project.markedSessions.map(\.id) == items.map(\.id))
    project.clearMarks()
    #expect(project.marked.isEmpty)
  }

  /// A session removed from the window leaves the marks.
  @Test func removingDropsTheMark() throws {
    let (project, items) = try project()
    project.markAll()
    project.remove(items[1])
    #expect(!project.marked.contains(items[1].id))
    #expect(project.markedSessions.count == 3)
  }

  /// One prompt to each marked session: sent to an idle one, queued in a running one,
  /// skipped where it can't go; the marks stay for the next.
  @Test func broadcastSendsQueuesAndSkips() async throws {
    let (project, items) = try project(3)
    defer { project.stopAll() }
    items[0].session.send("first")
    try await started([items[0]])
    items[2].session.isReadOnly = true
    project.markAll()
    let result = project.broadcast("/compact", context: [], attachments: [])
    #expect(result.sent == 2)
    #expect(result.skipped == 1)
    #expect(items[0].session.transcript.queuedPrompts.map(\.text) == ["/compact"])
    #expect(prompts(items[1]) == ["/compact"])
    #expect(prompts(items[2]).isEmpty)
    #expect(project.marked.count == 3)
    #expect(project.lastBroadcast == BroadcastResult(sent: 2, skipped: 1))
  }

  /// A PDF goes only where the agent reads one: a marked Codex session is skipped rather than
  /// sent a prompt whose document Codex never gets.
  @Test func aPDFSkipsASessionWhoseAgentCannotReadIt() throws {
    let (project, items) = try project(1)
    let codex = project.newSession(agent: .codex)
    defer { project.stopAll() }
    let file = folder.appending(path: "brief.pdf")
    try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: file)
    let pdf = try Attachment.file(at: file)
    project.markAll()
    let result = project.broadcast("Summarize this", context: [], attachments: [pdf])
    #expect(result == BroadcastResult(sent: 1, skipped: 1))
    #expect(prompts(items[0]) == ["Summarize this"])
    #expect(prompts(codex).isEmpty)
  }

  /// With a watched session shown, ⌘-click marks only the row clicked: a watched row isn't
  /// one of the window's own, which are all the marks ever cover.
  @Test func commandClickWithAWatchedSessionShownMarksOnlyTheRow() throws {
    let (project, items) = try project(2)
    defer { project.stopAll() }
    _ = project.attach(
      ResumeTarget(
        sessionID: "w", cwd: folder.path(percentEncoded: false),
        file: folder.appending(path: "w.jsonl").path(percentEncoded: false),
        accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false),
      watching: true, readOnly: true)
    project.click(items[1], .toggle)
    #expect(project.marked == [items[1].id])
  }

  /// A ⇧-click whose last clicked row was removed since starts from the row shown.
  @Test func shiftClickAfterTheAnchorWentStartsFromTheShownRow() throws {
    let (project, items) = try project(4)
    defer { project.stopAll() }
    project.click(items[0], .plain)
    project.remove(items[0])
    project.select(items[1])  // the arrow keys show a row without clicking it
    project.click(items[3], .extend)
    #expect(project.marked == [items[1].id, items[2].id, items[3].id])
  }

  /// A new click forgets what the last broadcast said.
  @Test func aClickForgetsTheLastBroadcast() throws {
    let (project, items) = try project(2)
    defer { project.stopAll() }
    project.markAll()
    _ = project.broadcast("hello", context: [], attachments: [])
    project.click(items[1], .plain)
    #expect(project.lastBroadcast == nil)
  }

  /// Stop ends each marked session's process; Remove takes them all out of the window.
  @Test func stopAndRemoveTheMarked() async throws {
    let (project, items) = try project(3)
    defer { project.stopAll() }
    for item in items { item.session.send("go") }
    try await started(items)
    project.click(items[0], .plain)
    project.click(items[1], .extend)
    project.stopMarked()
    #expect(!items[0].session.isProcessRunning)
    #expect(!items[1].session.isProcessRunning)
    #expect(items[2].session.isProcessRunning)
    project.removeMarked()
    #expect(project.sessions.map(\.id) == [items[2].id])
    #expect(project.marked.isEmpty)
  }

  /// The composer's chip: how many the prompt goes to, then what the last one did; none for
  /// fewer than two.
  @Test func theChipSaysWhereThePromptGoes() async throws {
    let (project, items) = try project(3)
    defer { project.stopAll() }
    #expect(project.broadcastLabel == nil)
    project.markAll()
    #expect(project.broadcastLabel == "To 3 sessions")
    items[2].session.isReadOnly = true
    project.broadcast("hi", context: [], attachments: [])
    #expect(project.broadcastLabel == "Sent to 2 · 1 skipped")
    items[2].session.isReadOnly = false
    project.click(items[0], .toggle)
    #expect(project.broadcastLabel == "To 2 sessions")
  }
}
