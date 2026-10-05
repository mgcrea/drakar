import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Running a skill from the inspector")
struct SkillRunTests {

  private let folder: URL
  private let check = SkillEntry(name: "check", description: "Fix it")
  private let audit = SkillEntry(
    name: "marketing:seo-audit", description: "Audit", argumentHint: "<url or topic>")

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn() throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// A skill that takes nothing goes at once, in a new session on top.
  @Test func aSkillWithoutArgumentsIsSentInANewSession() throws {
    let project = Project(folder: folder)
    project.executableOverride = try standIn()
    let first = project.newSession()
    project.run(check, in: .newSession)
    defer { project.stopAll() }
    #expect(project.sessions.count == 2)
    let item = try #require(project.selected)
    #expect(item.id != first.id)
    #expect(item.displayTitle == "/check")
    #expect(item.session.transcript.isRunning)
  }

  /// One that takes arguments waits in the composer, with what it takes shown.
  @Test func aSkillWithArgumentsWaitsInTheComposer() throws {
    let project = Project(folder: folder)
    project.run(audit, in: .newSession)
    let item = try #require(project.selected)
    #expect(item.draft == "/marketing:seo-audit ")
    #expect(item.composerHint == "<url or topic>")
    #expect(item.focusRequest == 1)
    #expect(!item.session.isProcessRunning)
    #expect(item.session.transcript.entries.isEmpty)
  }

  /// The hint stays while arguments are typed after the name, and goes once the name is
  /// edited away.
  @Test func theHintFollowsTheName() throws {
    let project = Project(folder: folder)
    project.run(audit, in: .newSession)
    let item = try #require(project.selected)
    item.draft = "/marketing:seo-audit example.com"
    #expect(item.composerHint == "<url or topic>")
    item.draft = "/marketing:seo-aud"
    #expect(item.composerHint == nil)
  }

  /// In the current session a draft already typed is kept, after the name.
  @Test func theCurrentSessionKeepsItsDraft() throws {
    let project = Project(folder: folder)
    let item = project.newSession()
    item.draft = "the login page"
    project.run(audit, in: .current)
    #expect(project.sessions.count == 1)
    #expect(item.draft == "/marketing:seo-audit the login page")
    #expect(item.composerHint == "<url or topic>")
  }

  /// A session that cannot take a prompt cannot take a skill: refused, not queued.
  @Test func aReadOnlySessionCannotRunOne() throws {
    let project = Project(folder: folder)
    let item = project.newSession()
    item.session.isReadOnly = true
    #expect(!project.canRun(in: .current))
    #expect(project.canRun(in: .newSession))
    project.run(audit, in: .current)
    #expect(item.draft.isEmpty)
    #expect(project.sessions.count == 1)
  }

  @Test func aSessionMidTurnCannotRunOne() async throws {
    let project = Project(folder: folder)
    project.executableOverride = try standIn()
    let item = project.newSession()
    item.session.send("working")
    defer { project.stopAll() }
    #expect(item.session.transcript.isRunning)
    #expect(!project.canRun(in: .current))
  }
}
