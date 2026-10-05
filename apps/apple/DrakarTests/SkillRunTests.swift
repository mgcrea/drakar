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

  private func settle(_ entry: Capabilities) async throws {
    for _ in 0..<100 where entry.isLoading {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// A window marks what a new reading brought; running the skill, or hiding the inspector,
  /// clears it.
  @Test func marksFollowTheLists() async throws {
    let project = Project(folder: folder)
    let entry = project.capabilities
    entry.probe = { _, _ in
      ProbeOutcome(capabilities: ProjectCapabilities(skills: [], mcpServers: []))
    }
    entry.refresh()
    try await settle(entry)
    #expect(project.capabilityMarks.isEmpty)
    entry.probe = { _, _ in
      ProbeOutcome(
        capabilities: ProjectCapabilities(
          skills: [self.audit], mcpServers: [MCPServerEntry(name: "github", status: .failed)]))
    }
    entry.refresh()
    try await settle(entry)
    #expect(project.capabilityMarks.skills == [audit.name])
    #expect(project.capabilityMarks.servers == ["github"])
    project.run(audit, in: .newSession)
    #expect(project.capabilityMarks.skills.isEmpty)
    project.unmarkServer("github")
    #expect(project.capabilityMarks.isEmpty)
  }

  /// A worktree is another checkout: its session does not speak for the project's list.
  @Test func onlyTheProjectsOwnFolderSpeaksForIt() {
    let project = Project(folder: folder)
    let worktree = ClaudeSession(
      folder: folder.appending(path: ".claude/worktrees/x", directoryHint: .isDirectory))
    #expect(!project.speaksForProject(worktree))
  }

  /// A session started in the project's folder, under the window's account, brings its
  /// skills to the inspector.
  @Test func aSessionsInitializeReplyRefreshesTheSkills() async throws {
    let reply =
      #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[{"name":"fresh","description":"","argumentHint":""}]}}}"#
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\nread line\necho '\(reply)'\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let project = Project(folder: folder)
    project.executableOverride = script
    let item = project.newSession()
    defer { project.stopAll() }
    await item.session.spawn()
    for _ in 0..<50 where project.capabilities.lists.skills == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(project.speaksForProject(item.session))
    #expect(project.capabilities.lists.skills?.map(\.name) == ["fresh"])
  }

  /// The last window on a folder closing takes its probe with it.
  @Test func closingTheWindowCancelsItsProbe() async throws {
    let project = Project(folder: folder)
    let entry = project.capabilities
    entry.probe = { _, _ in
      try? await Task.sleep(for: .seconds(5))
      return ProbeOutcome()
    }
    entry.refresh()
    #expect(entry.isLoading)
    project.stopAll()
    #expect(!entry.isLoading)
  }

  /// The window moving to another account takes the old account's probe with it.
  @Test func anAccountChangeCancelsTheOldProbe() throws {
    let other = folder.appending(path: ".claude-other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    ClaudeChoice.$testSuite.withValue(suite) {
      let project = Project(folder: folder)
      let old = project.capabilities
      old.probe = { _, _ in
        try? await Task.sleep(for: .seconds(5))
        return ProbeOutcome()
      }
      old.refresh()
      #expect(old.isLoading)
      let account = ClaudeChoice.account(at: other.path(percentEncoded: false))
      // The entry the window moves to answers at once, so no real `claude` is started.
      CapabilityStore.shared.capabilities(for: folder, account: account).probe = { _, _ in
        ProbeOutcome()
      }
      ClaudeChoice.pick(account, for: folder)
      project.accountMayHaveChanged()
      #expect(project.capabilities !== old)
      #expect(project.capabilities.account == account)
      #expect(!old.isLoading)
      project.stopAll()
    }
  }

  /// A change to the project's `.claude/skills` reads the lists again, once, after the
  /// changes settle.
  @Test func aSkillFileChangeRefreshesOnceSettled() async throws {
    let project = Project(folder: folder)
    project.capabilityDebounce = .milliseconds(100)
    let entry = project.capabilities
    let calls = CapabilityStoreTests.Calls()
    entry.probe = { _, _ in
      calls.count += 1
      return ProbeOutcome(capabilities: ProjectCapabilities(skills: [], mcpServers: []))
    }
    entry.refresh()
    try await settle(entry)
    let skill = folder.appending(path: ".claude/skills/x", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data("---\nname: x\n---\n".utf8).write(to: skill.appending(path: "SKILL.md"))
    for _ in 0..<50 where calls.count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    try await settle(entry)
    #expect(calls.count == 2)
  }
}
