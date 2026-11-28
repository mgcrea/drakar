import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Marking ended and archived sessions to archive them together")
struct SummaryMarksTests {

  /// A window over a folder with `ids` ended there, Ended expanded: its rows in list order.
  private func project(ended ids: [String]) async throws -> (Project, [SessionSummary]) {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-summary-marks-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(folder: folder)
    let path = ProjectPath.normalize(folder)
    let account = ClaudeAccount(
      directory: folder.appending(path: "claude-config", directoryHint: .isDirectory),
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
    project.showsEnded = true
    try #require(project.groups.ended.count == ids.count)
    return (project, project.rows(of: .ended))
  }

  private func ids(_ rows: [SessionSummary]) -> [String] { rows.map(\.sessionID) }

  /// ⌘-click marks and unmarks, without opening the row.
  @Test func commandClickTogglesWithoutOpening() async throws {
    let (project, rows) = try await project(ended: ["a", "b", "c"])
    project.click(rows[0], in: .ended, .toggle)
    project.click(rows[2], in: .ended, .toggle)
    #expect(ids(project.markedSummaryRows) == ids([rows[0], rows[2]]))
    #expect(project.tabs.isEmpty)
    project.click(rows[0], in: .ended, .toggle)
    #expect(ids(project.markedSummaryRows) == ids([rows[2]]))
  }

  /// ⇧-click marks the rows from the last clicked to this one, in the list's order.
  @Test func shiftClickMarksTheRange() async throws {
    let (project, rows) = try await project(ended: ["a", "b", "c", "d"])
    project.click(rows[1], in: .ended, .plain)
    project.click(rows[3], in: .ended, .extend)
    #expect(ids(project.markedSummaryRows) == ids(Array(rows[1...3])))
  }

  /// The row in the preview is marked with the first ⌘-click, as the shown tab is.
  @Test func thePreviewedRowIsMarkedWithTheFirst() async throws {
    let (project, rows) = try await project(ended: ["a", "b", "c"])
    project.click(rows[0], in: .ended, .plain)
    project.openEnded(rows[0])
    project.click(rows[2], in: .ended, .toggle)
    #expect(ids(project.markedSummaryRows) == ids([rows[0], rows[2]]))
  }

  /// Archive N Sessions archives the marked rows alone and clears the marks; from Archived,
  /// it unarchives them.
  @Test func archivingTheMarkedRowsAndBack() async throws {
    let (project, rows) = try await project(ended: ["a", "b", "c"])
    project.click(rows[0], in: .ended, .toggle)
    project.click(rows[1], in: .ended, .toggle)
    #expect(project.archiveMarked())
    #expect(ids(project.listedGroups.ended) == ids([rows[2]]))
    #expect(Set(ids(project.archivedEnded)) == Set(ids(Array(rows[0...1]))))
    #expect(project.markedSummaries.isEmpty)
    #expect(!project.archiveMarked())

    project.showsArchived = true
    let archived = project.rows(of: .archived)
    for row in archived { project.click(row, in: .archived, .toggle) }
    #expect(project.archiveMarked())
    #expect(project.archivedEnded.isEmpty)
    #expect(project.listedGroups.ended.count == 3)
  }

  /// Marks stay in one section, and never beside the tabs' marks, which say where the
  /// composer sends.
  @Test func marksStayInOneSectionAndApartFromTabs() async throws {
    let (project, rows) = try await project(ended: ["a", "b", "c"])
    project.monitor.setArchived([rows[2]], to: true)
    project.showsArchived = true
    let ended = project.rows(of: .ended)
    let archived = try #require(project.rows(of: .archived).first)

    project.click(ended[0], in: .ended, .toggle)
    project.click(archived, in: .archived, .toggle)
    #expect(project.markedSection == .archived)
    #expect(ids(project.markedSummaryRows) == [archived.sessionID])

    let a = project.newSession()
    let b = project.newSession()
    project.select(a)
    project.click(b, .toggle)
    #expect(project.markedSummaries.isEmpty)
    #expect(project.marked == [a.id, b.id])

    project.click(ended[1], in: .ended, .toggle)
    #expect(project.marked.isEmpty)
    #expect(ids(project.markedSummaryRows) == [ended[1].sessionID])
    project.clearMarks()
    #expect(!project.hasMarks)
  }

  /// A plain click on an ended row opens it and leaves the tabs' marks, where the composer
  /// sends, as they were.
  @Test func aPlainClickKeepsTheTabsMarks() async throws {
    let (project, rows) = try await project(ended: ["a", "b"])
    let a = project.newSession()
    let b = project.newSession()
    project.select(a)
    project.click(b, .toggle)
    project.click(rows[0], in: .ended, .plain)
    #expect(project.marked == [a.id, b.id])
    #expect(project.markedSummaries.isEmpty)
  }

  /// A folded section's marks act on nothing: no row there can be seen to be marked.
  @Test func aFoldedSectionsMarksActOnNothing() async throws {
    let (project, rows) = try await project(ended: ["a", "b"])
    project.click(rows[0], in: .ended, .toggle)
    project.showsEnded = false
    #expect(project.markedSummaryRows.isEmpty)
    #expect(!project.archiveMarked())
    #expect(!project.hasMarks)
    #expect(project.listedGroups.ended.count == 2)
  }

  /// Archive All Ended takes every ended row, past the 20 listed too.
  @Test func archiveAllEndedTakesEveryRow() async throws {
    let (project, rows) = try await project(ended: (0..<22).map { "s\($0)" })
    project.click(rows[0], in: .ended, .toggle)
    project.archiveAllEnded()
    #expect(project.markedSummaries.isEmpty)
    #expect(project.listedGroups.ended.isEmpty)
    #expect(project.archivedEnded.count == 22)
  }
}
