import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Moving on to the next session after a reply", .serialized)
struct NextAfterReplyTests {
  init() {
    // An empty scratch suite: every switch reads as its default, whatever the person set.
    AttentionChoice.defaults = UserDefaults(suiteName: "drakar-tests-\(UUID().uuidString)")!
  }

  private let folder: URL = {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-next-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }()

  /// A stand-in `claude` that answers the first prompt with these lines and then waits.
  private func fake(_ name: String, _ lines: [String]) throws -> URL {
    let fake = folder.appending(path: name)
    let script =
      "#!/bin/sh\n" + lines.map { "echo '\($0)'" }.joined(separator: "\n") + "\ncat > /dev/null\n"
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  /// A row of `project` that ran a turn ending on `lines`.
  private func row(
    in project: Project, _ name: String, _ lines: [String]
  ) async throws -> ProjectSession {
    let item = project.newSession()
    item.session.executableOverride = try fake(name, lines)
    item.session.send("Build it")
    for _ in 0..<50
    where item.session.transcript.turnEnd == nil
      && item.session.transcript.pendingPermissions.isEmpty
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    return item
  }

  /// Lets the move, which waits for the composer that sent to finish, happen.
  private func settle(_ project: Project, from item: ProjectSession) async throws {
    for _ in 0..<20 where project.selectedID == item.id {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test func aReplyToTheShownSessionShowsTheNextThatWantsThePerson() async throws {
    let project = Project(folder: folder)
    project.movesOnAfterReply = true
    let b = try await row(in: project, "b", UrgencyTests.asking)
    let a = try await row(in: project, "a", UrgencyTests.asking)
    project.select(a)
    #expect(a.urgency == .question)
    a.session.send("Yes")
    try await settle(project, from: a)
    #expect(project.selectedID == b.id)
    project.stopAll()
  }

  @Test func answeringAChoiceMovesOnToo() async throws {
    let project = Project(folder: folder)
    project.movesOnAfterReply = true
    let b = try await row(in: project, "b", UrgencyTests.asking)
    let a = try await row(in: project, "a", UrgencyTests.choosing)
    project.select(a)
    let pending = try #require(a.session.transcript.pendingPermissions.first)
    a.session.answer(pending, .deny(message: UserQuestion.declinedMessage))
    try await settle(project, from: a)
    #expect(project.selectedID == b.id)
    project.stopAll()
  }

  @Test func dismissingMovesOnToo() async throws {
    let project = Project(folder: folder)
    project.movesOnAfterReply = true
    let b = try await row(in: project, "b", UrgencyTests.asking)
    let a = try await row(in: project, "a", UrgencyTests.offering)
    project.select(a)
    project.dismissSelected()
    try await settle(project, from: a)
    #expect(project.selectedID == b.id)
    project.stopAll()
  }

  @Test func aPromptToTheMarkedRowsStays() async throws {
    let project = Project(folder: folder)
    project.movesOnAfterReply = true
    _ = try await row(in: project, "c", UrgencyTests.asking)
    let b = try await row(in: project, "b", UrgencyTests.asking)
    let a = try await row(in: project, "a", UrgencyTests.asking)
    project.select(a)
    project.click(b, .toggle)
    #expect(project.sendsToMarked)
    project.broadcast("Yes", context: [], attachments: [])
    try await settle(project, from: a)
    #expect(project.selectedID == a.id)
    project.stopAll()
  }

  @Test func offTheShownSessionStays() async throws {
    let project = Project(folder: folder)
    _ = try await row(in: project, "b", UrgencyTests.asking)
    let a = try await row(in: project, "a", UrgencyTests.asking)
    project.select(a)
    a.session.send("Yes")
    try await settle(project, from: a)
    #expect(project.selectedID == a.id)
    project.stopAll()
  }

  @Test func withNothingElseWaitingTheShownSessionStays() async throws {
    let project = Project(folder: folder)
    project.movesOnAfterReply = true
    let a = try await row(in: project, "a", UrgencyTests.asking)
    project.select(a)
    a.session.send("Yes")
    try await settle(project, from: a)
    #expect(project.selectedID == a.id)
    project.stopAll()
  }

  /// A first prompt starts a session; it answers nothing.
  @Test func aNewSessionsFirstPromptStays() async throws {
    let project = Project(folder: folder)
    project.movesOnAfterReply = true
    _ = try await row(in: project, "b", UrgencyTests.asking)
    let a = project.newSession()
    a.session.executableOverride = try fake("a", [])
    a.session.send("Build it")
    try await settle(project, from: a)
    #expect(project.selectedID == a.id)
    project.stopAll()
  }

  @Test func theSwitchIsKeptWithTheWindow() throws {
    let project = Project(folder: folder)
    #expect(!project.movesOnAfterReply)
    #expect(project.stored.movesOnAfterReply == nil)
    project.movesOnAfterReply = true
    let stored = project.stored
    #expect(stored.movesOnAfterReply == true)
    #expect(!stored.isEmpty)
    #expect(Project(folder: folder, restoring: stored).movesOnAfterReply)
  }
}
