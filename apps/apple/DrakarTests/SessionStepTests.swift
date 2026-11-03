import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Previous and Next Session, and the sidebar's arrow keys")
struct SessionStepTests {

  private func project() throws -> Project {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-step-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Project(folder: folder)
  }

  @Test func nextAndPreviousWalkTheListAndWrap() throws {
    let project = try project()
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()  // tabs: a, b, c, in the order made
    project.select(a)
    #expect(project.step(1, wrapping: true))
    #expect(project.selectedID == b.id)
    project.step(1, wrapping: true)
    #expect(project.selectedID == c.id)
    project.step(1, wrapping: true)
    #expect(project.selectedID == a.id)
    project.step(-1, wrapping: true)
    #expect(project.selectedID == c.id)
  }

  @Test func theArrowKeysStopAtTheEnds() throws {
    let project = try project()
    let a = project.newSession()
    _ = project.newSession()
    let c = project.newSession()
    project.select(a)
    project.step(-1, wrapping: false)
    #expect(project.selectedID == a.id)
    project.select(c)
    project.step(1, wrapping: false)
    #expect(project.selectedID == c.id)
  }

  @Test func theShownSessionsComposerTakesTheKeysOnlyWhenAsked() throws {
    let project = try project()
    let a = project.newSession()
    _ = project.newSession()
    project.select(a)
    project.step(1, wrapping: false, focusingComposer: false)
    #expect(!project.focusesComposer)
    let requests = a.focusRequest
    project.step(-1, wrapping: false)
    #expect(project.focusesComposer)
    #expect(a.focusRequest == requests + 1)
  }

  /// Previous and Next Session go round the tabs only: an ended session listed below them,
  /// though Ended is expanded, is the sidebar's to open.
  @Test func stepStaysInTheTabs() async throws {
    let project = try project()
    let path = ProjectPath.normalize(project.folder)
    let account = ClaudeAccount(
      directory: project.folder.appending(path: "claude-config", directoryHint: .isDirectory),
      isDefault: false)
    let transcripts = account.directory.appending(
      path: "projects/\(ProjectPath.encodedPrefixes(for: path)[0])", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try Data(#"{"type":"user","cwd":"\#(path)","message":{"role":"user","content":"go"}}"#.utf8)
      .write(to: transcripts.appending(path: "e1.jsonl"))
    let monitor = SessionMonitor(accounts: [account])
    await monitor.include(folder: path)
    project.monitor = monitor
    let a = project.newSession()
    let b = project.newSession()
    project.showsEnded = true
    try #require(project.groups.ended.map(\.sessionID) == ["e1"])
    #expect(project.selectedID == b.id)
    project.step(1, wrapping: true)
    #expect(project.selectedID == a.id)
    project.step(-1, wrapping: true)
    #expect(project.selectedID == b.id)
    project.step(1, wrapping: false)
    #expect(project.selectedID == b.id)
    #expect(!project.tabs.contains { $0.sessionID == "e1" })
  }

  @Test func anEmptyWindowHasNowhereToGo() throws {
    #expect(!(try project()).step(1, wrapping: true))
  }

  /// `project` listing an ended session for each id, read from a transcript each under an
  /// account of the test's own.
  private func ended(_ ids: [String], in project: Project) async throws {
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
    try #require(project.groups.ended.count == ids.count)
  }

  private func preview(in project: Project) -> [String?] {
    project.tabs.filter(\.isWatching).map(\.sessionID)
  }

  /// The sidebar's ↓ opens its first row in the preview tab, then the next in its place,
  /// the keys staying in the list; it stops at the ends, and ↑ goes back.
  @Test func theSidebarsArrowKeysGoThroughItsRowsInThePreview() async throws {
    let project = try project()
    let a = project.newSession()
    try await ended(["e1", "e2"], in: project)
    project.showsEnded = true
    let rows = project.listedEnded(project.groups).map(\.sessionID)
    #expect(project.stepSidebar(1))
    #expect(preview(in: project) == [rows[0]])
    #expect(project.selected?.sessionID == rows[0])
    #expect(!project.focusesComposer)
    #expect(project.stepSidebar(1))
    #expect(preview(in: project) == [rows[1]])
    #expect(project.tabs.count == 2)
    #expect(project.tabs.first?.id == a.id)
    #expect(!project.stepSidebar(1))
    #expect(preview(in: project) == [rows[1]])
    #expect(project.stepSidebar(-1))
    #expect(preview(in: project) == [rows[0]])
    #expect(!project.stepSidebar(-1))
  }

  /// With no row to go to, the sidebar's keys leave the tabs as they are: a folded Ended
  /// has none.
  @Test func theSidebarsArrowKeysLeaveTheTabsAlone() async throws {
    let project = try project()
    let a = project.newSession()
    _ = project.newSession()
    project.select(a)
    #expect(!project.stepSidebar(1))
    #expect(!project.stepSidebar(-1))
    try await ended(["e1"], in: project)
    project.showsEnded = false
    #expect(!project.stepSidebar(1))
    #expect(project.selectedID == a.id)
    #expect(project.tabs.count == 2)
  }
}
