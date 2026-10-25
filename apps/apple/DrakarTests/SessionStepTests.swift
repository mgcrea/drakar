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
    let c = project.newSession()
    let b = project.newSession()
    let a = project.newSession()  // rows: a, b, c; a selected
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
    let c = project.newSession()
    _ = project.newSession()
    let a = project.newSession()
    project.step(-1, wrapping: false)
    #expect(project.selectedID == a.id)
    project.select(c)
    project.step(1, wrapping: false)
    #expect(project.selectedID == c.id)
  }

  @Test func theShownSessionsComposerTakesTheKeysOnlyWhenAsked() throws {
    let project = try project()
    _ = project.newSession()
    let a = project.newSession()
    project.step(1, wrapping: false, focusingComposer: false)
    #expect(!project.focusesComposer)
    let requests = a.focusRequest
    project.step(-1, wrapping: false)
    #expect(project.focusesComposer)
    #expect(a.focusRequest == requests + 1)
  }

  /// The arrow keys onto an ended session keep the keys in the list, as onto a held row.
  @Test func theArrowKeysKeepTheKeysOnAnEndedRow() async throws {
    let project = try project()
    let path = ProjectPath.normalize(project.folder.path(percentEncoded: false))
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
    _ = project.newSession()
    project.showsEnded = true
    try #require(project.groups.ended.map(\.sessionID) == ["e1"])
    project.step(1, wrapping: false, focusingComposer: false)
    #expect(project.selected?.sessionID == "e1")
    #expect(!project.focusesComposer)
  }

  @Test func anEmptyWindowHasNowhereToGo() throws {
    #expect(!(try project()).step(1, wrapping: true))
  }
}
