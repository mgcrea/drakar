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
}
