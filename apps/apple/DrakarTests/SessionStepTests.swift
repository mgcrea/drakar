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

  @Test func anEmptyWindowHasNowhereToGo() throws {
    #expect(!(try project()).step(1, wrapping: true))
  }
}
