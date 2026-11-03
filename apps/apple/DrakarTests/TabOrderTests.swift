import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Tab order and the preview tab")
struct TabOrderTests {

  private func project() throws -> Project {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-tabs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Project(folder: folder)
  }

  /// `project` listing an ended session for each id, newest last, read from a transcript each
  /// under an account of the test's own.
  private func ended(_ ids: [String], in project: Project) async throws -> [SessionSummary] {
    let path = ProjectPath.normalize(project.folder)
    let account = ClaudeAccount(
      directory: project.folder.appending(path: "claude-config", directoryHint: .isDirectory),
      isDefault: false)
    let transcripts = account.directory.appending(
      path: "projects/\(ProjectPath.encodedPrefixes(for: path)[0])", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    for id in ids {
      try Data(#"{"type":"user","cwd":"\#(path)","message":{"role":"user","content":"go"}}"#.utf8)
        .write(to: transcripts.appending(path: "\(id).jsonl"))
    }
    let monitor = SessionMonitor(accounts: [account])
    await monitor.include(folder: path)
    project.monitor = monitor
    let summaries = ids.compactMap { id in project.groups.ended.first { $0.sessionID == id } }
    try #require(summaries.count == ids.count)
    return summaries
  }

  @Test func aNewSessionOpensRightOfTheSelectedTab() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    #expect(project.tabs.map(\.id) == [a.id, b.id, c.id])
    project.select(a)
    let d = project.newSession()
    #expect(project.tabs.map(\.id) == [a.id, d.id, b.id, c.id])
    #expect(project.selectedID == d.id)
  }

  @Test func aNewSessionNotShownStillOpensRightOfTheSelectedTab() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    project.select(a)
    let c = project.newSession(select: false)
    #expect(project.tabs.map(\.id) == [a.id, c.id, b.id])
    #expect(project.selectedID == a.id)
  }

  @Test func closingTheSelectedTabShowsItsNeighbour() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    project.select(b)
    project.remove(b)
    #expect(project.selectedID == c.id)
    project.select(c)
    project.remove(c)
    #expect(project.selectedID == a.id)
    project.remove(a)
    #expect(project.selectedID == nil)
  }

  @Test func closingTheFirstTabShowsTheOneRightOfIt() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    _ = project.newSession()
    _ = project.newSession()
    project.select(a)
    project.closeTab(a)
    #expect(project.selectedID == b.id)
  }

  /// The neighbour shown in a closed tab's place is read, as a click on it would leave it,
  /// whether one tab closes or the marked ones do.
  @Test func theNeighbourShownInAClosedTabsPlaceIsRead() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    let d = project.newSession()
    project.select(a)
    b.isUnread = true
    project.closeTab(a)
    #expect(project.selectedID == b.id)
    #expect(!b.isUnread)

    d.isUnread = true
    project.click(b, .plain)
    project.click(c, .toggle)
    project.closeMarked()
    #expect(project.selectedID == d.id)
    #expect(!d.isUnread)
  }

  @Test func closingATabNotShownKeepsTheSelection() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    project.select(a)
    #expect(project.neighbour(of: a)?.id == b.id)
    #expect(project.neighbour(of: b)?.id == a.id)
    project.closeTab(b)
    #expect(project.selectedID == a.id)
    #expect(project.neighbour(of: a) == nil)
  }

  @Test func aSecondPreviewReplacesTheFirst() async throws {
    let project = try project()
    let summaries = try await ended(["e1", "e2"], in: project)
    project.openEnded(summaries[0])
    project.openEnded(summaries[1])
    #expect(project.tabs.filter(\.isWatching).map(\.sessionID) == ["e2"])
    #expect(project.tabs.map(\.sessionID) == ["e2"])
    #expect(project.selected?.sessionID == "e2")
  }

  @Test func theNextPreviewTakesTheShownPreviewsPlace() async throws {
    let project = try project()
    let summaries = try await ended(["e1", "e2"], in: project)
    let a = project.newSession()
    let b = project.newSession()
    project.select(a)
    project.openEnded(summaries[0])
    project.openEnded(summaries[1])
    #expect(project.tabs.map(\.id).first == a.id)
    #expect(project.tabs.map(\.sessionID).dropFirst().first == "e2")
    #expect(project.tabs.last?.id == b.id)
    #expect(project.tabs.count == 3)
  }

  @Test func aPreviewWithADraftIsKeptAsATab() async throws {
    let project = try project()
    let summaries = try await ended(["e1", "e2"], in: project)
    project.openEnded(summaries[0])
    let p = try #require(project.selected)
    p.draft = "half"
    project.openEnded(summaries[1])
    #expect(!p.isWatching)
    #expect(project.tabs.contains { $0.id == p.id })
    #expect(project.tabs.filter(\.isWatching).map(\.sessionID) == ["e2"])
  }

  @Test func aPreviewWithAttachmentsIsKeptAsATab() async throws {
    let project = try project()
    let summaries = try await ended(["e1", "e2"], in: project)
    project.openEnded(summaries[0])
    let p = try #require(project.selected)
    let note = project.folder.appending(path: "note.txt")
    try Data("a note".utf8).write(to: note)
    p.attachments = [try Attachment.file(at: note)]
    project.openEnded(summaries[1])
    #expect(!p.isWatching)
    #expect(project.tabs.contains { $0.id == p.id })
  }

  @Test func takingUpAPreviewKeepsItsPlace() async throws {
    let project = try project()
    let summaries = try await ended(["e1"], in: project)
    let a = project.newSession()
    project.openEnded(summaries[0])
    let p = try #require(project.selected)
    let b = project.newSession()
    #expect(project.tabs.map(\.id) == [a.id, p.id, b.id])
    #expect(p.isWatching)
    // The prompt's take-over, not the runner's async one an async test would pick.
    let takeOver: (ProjectSession) -> Void = project.takeOver
    takeOver(p)
    #expect(!p.isWatching)
    #expect(project.tabs.map(\.id) == [a.id, p.id, b.id])
  }

  @Test func promotingAPreviewTakesItOver() async throws {
    let project = try project()
    let summaries = try await ended(["e1"], in: project)
    project.openEnded(summaries[0])
    let p = try #require(project.selected)
    project.promote(p)
    #expect(!p.isWatching)
    #expect(project.held.map(\.id) == [p.id])
  }

  @Test func moveTabReorders() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    project.moveTab(c.id, to: 0)
    #expect(project.tabs.map(\.id) == [c.id, a.id, b.id])
    #expect(project.selectedID == c.id)
    project.moveTab(c.id, to: 99)
    #expect(project.tabs.map(\.id) == [a.id, b.id, c.id])
    project.moveTab(a.id, to: -3)
    #expect(project.tabs.map(\.id) == [a.id, b.id, c.id])
    project.moveTab(UUID(), to: 0)
    #expect(project.tabs.map(\.id) == [a.id, b.id, c.id])
    #expect(project.selectedID == c.id)
  }

  /// The shown tab among those removed: the nearest left standing right of it is shown,
  /// else the nearest left of it.
  @Test func closingTheMarkedShowsTheNearestTabLeftStanding() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    let d = project.newSession()
    let e = project.newSession()
    let f = project.newSession()
    project.click(c, .plain)
    project.click(d, .toggle)
    project.closeMarked()
    #expect(project.tabs.map(\.id) == [a.id, b.id, e.id, f.id])
    #expect(project.selectedID == e.id)
    project.click(f, .plain)
    project.click(e, .toggle)
    project.closeMarked()
    #expect(project.tabs.map(\.id) == [a.id, b.id])
    #expect(project.selectedID == b.id)
  }

  /// Next Session Needing You goes through the tabs in their order from the one shown, the
  /// preview among them.
  @Test func theNextTabNeedingYouIsRightOfTheShownPreview() async throws {
    let project = try project()
    let summaries = try await ended(["e1"], in: project)
    let a = project.newSession()
    let b = project.newSession()
    project.select(a)
    project.openEnded(summaries[0])
    let p = try #require(project.selected)
    #expect(project.tabs.map(\.id) == [a.id, p.id, b.id])
    a.isUnread = true
    b.isUnread = true
    #expect(project.nextNeedingAttention()?.item?.id == b.id)
    project.moveTab(a.id, to: 2)
    #expect(project.nextNeedingAttention()?.item?.id == b.id)
    project.moveTab(b.id, to: 0)
    #expect(project.nextNeedingAttention()?.item?.id == a.id)
  }

  /// The preview is not the window's own: ⌘-clicking it marks nothing, and a ⇧ range across
  /// it passes over it.
  @Test func thePreviewIsNeverMarked() async throws {
    let project = try project()
    let summaries = try await ended(["e1"], in: project)
    let a = project.newSession()
    let b = project.newSession()
    project.select(a)
    project.openEnded(summaries[0])
    let p = try #require(project.selected)
    #expect(project.tabs.map(\.id) == [a.id, p.id, b.id])
    project.click(p, .toggle)
    #expect(project.marked.isEmpty)
    project.click(a, .toggle)
    #expect(project.marked == [a.id])
    project.click(p, .toggle)
    #expect(project.marked == [a.id])
    project.click(p, .extend)
    #expect(project.marked == [a.id])
    project.click(b, .extend)
    #expect(project.marked == [a.id, b.id])
  }
}
