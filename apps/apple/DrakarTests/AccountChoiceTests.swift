import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Which account a new session starts under: the folder's pick, then Settings, then the
/// shell's. Each test runs against its own scratch defaults suite, scoped to the test's task.
@MainActor
@Suite("The account a folder picks")
struct AccountChoiceTests {

  private let root: URL
  private let project: URL
  private let picked: URL
  private let settings: URL
  private let suite = "drakar-tests-\(UUID().uuidString)"
  private let defaults: UserDefaults

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-choice-\(UUID().uuidString)", directoryHint: .isDirectory)
    project = root.appending(path: "project", directoryHint: .isDirectory)
    picked = root.appending(path: ".claude-picked", directoryHint: .isDirectory)
    settings = root.appending(path: ".claude-settings", directoryHint: .isDirectory)
    for folder in [project, picked, settings] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  private func cleanUp() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  /// `body` with this test's defaults as `ClaudeChoice`'s.
  private func choosing<T>(_ body: () throws -> T) rethrows -> T {
    try ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  private func setSettingsAccount() {
    defaults.set(
      settings.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
  }

  private func pickPicked(for folder: URL) {
    ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: folder)
  }

  @Test func theFolderPickBeatsSettings() {
    defer { cleanUp() }
    setSettingsAccount()
    choosing { pickPicked(for: project) }
    #expect(choosing { ClaudeChoice.account(forNewSessionIn: project) }?.name == "picked")
  }

  @Test func aFolderNeverPickedFollowsSettings() {
    defer { cleanUp() }
    setSettingsAccount()
    #expect(choosing { ClaudeChoice.account(forNewSessionIn: project) }?.name == "settings")
  }

  @Test func nothingPickedLeavesItToTheShell() {
    defer { cleanUp() }
    #expect(choosing { ClaudeChoice.account(forNewSessionIn: project) } == nil)
  }

  /// The directory may come back: the pick is skipped, not forgotten.
  @Test func aPickWhoseDirectoryIsGoneFallsThroughAndIsKept() throws {
    defer { cleanUp() }
    setSettingsAccount()
    choosing { pickPicked(for: project) }
    try FileManager.default.removeItem(at: picked)
    #expect(choosing { ClaudeChoice.account(forNewSessionIn: project) }?.name == "settings")
    try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
    #expect(choosing { ClaudeChoice.account(forNewSessionIn: project) }?.name == "picked")
  }

  @Test func aFolderIsTheSameWithOrWithoutItsTrailingSlash() {
    defer { cleanUp() }
    let bare = URL(filePath: String(project.path(percentEncoded: false).dropLast()))
    choosing { pickPicked(for: bare) }
    #expect(choosing { ClaudeChoice.pickedAccount(for: project) }?.name == "picked")
  }

  /// A stand-in CLI that writes the `CLAUDE_CONFIG_DIR` it was started with.
  private func accountWriter() throws -> URL {
    let fake = root.appending(path: "claude")
    try Data(
      "#!/bin/sh\nprintf '%s' \"$CLAUDE_CONFIG_DIR\" > \"$0.account\"\ncat > /dev/null\n".utf8
    ).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  /// What `accountWriter` wrote, once it has.
  private func writtenAccount(_ fake: URL) async throws -> String? {
    let written = fake.appendingPathExtension("account")
    for _ in 0..<50 {
      if let directory = try? String(contentsOf: written, encoding: .utf8) { return directory }
      try await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  /// The pick is read when the process starts, not when the row was made.
  @Test func aSessionCreatedBeforeThePickStartsOnIt() async throws {
    defer { cleanUp() }
    let fake = try accountWriter()
    let session = AgentSession(folder: project)
    session.executableOverride = fake
    choosing { pickPicked(for: project) }
    await ClaudeChoice.$testSuite.withValue(suite) { await session.spawn() }
    defer { session.stop() }

    #expect(
      try await writtenAccount(fake) == String(picked.path(percentEncoded: false).dropLast()))
    #expect(session.account?.name == "picked")
  }

  /// An account given to the session (Run in Each Subfolder's) beats the folder's pick, and
  /// is named before the session starts.
  @Test func aSessionGivenAnAccountStartsOnIt() async throws {
    defer { cleanUp() }
    let fake = try accountWriter()
    let given = ClaudeChoice.account(at: settings.path(percentEncoded: false))
    let session = AgentSession(folder: project, account: given)
    session.executableOverride = fake
    choosing { pickPicked(for: project) }
    #expect(session.effectiveAccount?.name == "settings")
    await ClaudeChoice.$testSuite.withValue(suite) { await session.spawn() }
    defer { session.stop() }

    #expect(
      try await writtenAccount(fake) == String(settings.path(percentEncoded: false).dropLast()))
    #expect(session.account?.name == "settings")
  }

  /// A resumed session not yet started is on the account that wrote it; a new one has none
  /// until it starts, and runs on the window's.
  @Test func aSessionNamesItsAccountBeforeItStarts() {
    defer { cleanUp() }
    let target = ResumeTarget(
      sessionID: "s", cwd: project.path(percentEncoded: false),
      file: project.appending(path: "s.jsonl").path(percentEncoded: false),
      accountDirectory: String(picked.path(percentEncoded: false).dropLast()),
      accountIsDefault: false)
    #expect(AgentSession(folder: project, resuming: target).effectiveAccount?.name == "picked")
    #expect(AgentSession(folder: project).effectiveAccount == nil)
  }
}
