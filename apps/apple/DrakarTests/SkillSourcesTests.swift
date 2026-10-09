import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Clones from a repository made in the test, by a `file://` address; `git` runs with no
/// system or global configuration, so the person's signing and hooks never reach it.
@MainActor
@Suite("Skills installed from git")
struct SkillSourcesTests {
  private let root: URL
  private let home: URL
  private let account: URL
  private let origin: URL
  private let trash: URL

  init() throws {
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-skill-sources-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    account = home.appending(path: ".claude-test", directoryHint: .isDirectory)
    origin = root.appending(path: "origin/skills-repo", directoryHint: .isDirectory)
    trash = root.appending(path: "trash", directoryHint: .isDirectory)
    for folder in [account, origin, trash] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private var environment: [String: String] {
    [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": home.skillPath,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
    ]
  }

  private var places: SkillPlaces { SkillPlaces(account: account, home: home, project: nil) }

  private var sources: SkillSources {
    let environment = environment
    return SkillSources(root: places.sources, environment: { environment })
  }

  private var actions: SkillActions {
    let trash = trash
    return SkillActions(
      places: places,
      files: SkillFileSystem(moveToTrash: { item in
        try FileManager.default.moveItem(
          at: item, to: trash.appending(path: item.lastPathComponent))
      }))
  }

  private var address: String { "file://" + origin.skillPath }

  private func git(_ arguments: [String]) async throws {
    let executable = try #require(GitRunner.locate(path: environment["PATH"]))
    let result = try await GitRunner.run(
      executable, ["-C", origin.skillPath] + arguments, environment: environment,
      timeout: .seconds(30))
    try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.errors)")
  }

  private func skill(_ name: String, description: String = "") throws {
    let folder = origin.appending(path: "skills/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: \(name)\ndescription: \(description)\n---\n".utf8).write(
      to: folder.appending(path: "SKILL.md"))
  }

  private func commit(_ message: String) async throws {
    try await git(["add", "-A"])
    try await git([
      "-c", "user.name=Drakar", "-c", "user.email=tests@drakar.invalid", "-c",
      "commit.gpgsign=false", "commit", "-q", "-m", message,
    ])
  }

  private func makeOrigin() async throws {
    try skill("one")
    try skill("two")
    try await git(["init", "-q", "-b", "main"])
    try await commit("Two skills")
  }

  private func rows() -> [SkillRecord] {
    SkillInventory.merge(
      scan: ClaudeSkillScan.scan(account: account, project: nil).skills, claude: nil, codex: nil)
  }

  @Test func clonesOnceAndLinksTheChosenSkills() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    #expect(clone.skillPath == places.sources.appending(path: "local/origin/skills-repo").skillPath)
    let found = SkillFolderSearch.skills(in: clone, depth: 4)
    #expect(found.map(\.lastPathComponent) == ["one", "two"])
    try actions.install([found[0]], place: .user, agents: [.claude, .codex], method: .link)
    let linked = SkillPath.real(account.appending(path: "skills/one").skillPath)
    #expect(linked == found[0].skillPath)
    #expect(places.clone(containing: linked)?.skillPath == clone.skillPath)
  }

  /// An address cloned before is pulled, not cloned again.
  @Test func fetchingAgainPullsTheClone() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    try skill("three")
    try await commit("A third")
    #expect(try await sources.fetch(address).skillPath == clone.skillPath)
    #expect(
      FileManager.default.fileExists(
        atPath: clone.appending(path: "skills/three/SKILL.md").skillPath))
  }

  @Test func updatePullsTheCloneASkillCameFrom() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    try actions.install(
      [clone.appending(path: "skills/one", directoryHint: .isDirectory)], place: .user,
      agents: [.claude], method: .link)
    let record = try #require(rows().first { $0.name == "one" })
    try skill("one", description: "Better.")
    try await commit("A better one")
    try await sources.update(record)
    let text = try String(
      contentsOf: clone.appending(path: "skills/one/SKILL.md"), encoding: .utf8)
    #expect(text.contains("Better."))
  }

  /// Review focus: the clone stays when its last link goes; another project may use it.
  @Test func theCloneStaysAfterItsLastLink() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    try actions.install(
      SkillFolderSearch.skills(in: clone, depth: 4), place: .user, agents: [.claude],
      method: .link)
    for name in ["one", "two"] {
      let record = try #require(rows().first { $0.name == name })
      try actions.delete(try actions.deletePlan(for: record))
    }
    #expect(rows().isEmpty)
    #expect(FileManager.default.fileExists(atPath: clone.appending(path: "skills/one").skillPath))
    #expect(try FileManager.default.contentsOfDirectory(atPath: trash.skillPath).isEmpty)
  }

  @Test func gitsOwnWordsSayWhatFailed() async throws {
    defer { cleanUp() }
    let missing = "file://" + root.appending(path: "nowhere/repo").skillPath
    let error = await #expect(throws: SkillActionError.self) {
      try await sources.fetch(missing)
    }
    #expect(error?.message.contains("fatal") == true)
  }

  @Test func withoutGitItSaysSo() async throws {
    defer { cleanUp() }
    let sources = SkillSources(root: places.sources, environment: { ["PATH": "/nowhere"] })
    let error = await #expect(throws: SkillActionError.self) {
      try await sources.fetch("https://github.com/me/skills")
    }
    #expect(error?.message == "Git was not found. Install the Xcode command line tools.")
  }

  @Test func anAddressGitCannotCloneIsRefused() async throws {
    defer { cleanUp() }
    let error = await #expect(throws: SkillActionError.self) {
      try await sources.fetch("skills please")
    }
    #expect(error?.message.contains("is not a git URL") == true)
  }

  /// Timed off the main actor, which other suites can keep busy for seconds.
  private nonisolated static func timedSleep() async throws -> (GitRunner.Output, Duration) {
    let started = ContinuousClock.now
    let result = try await GitRunner.run(
      URL(filePath: "/bin/sleep"), ["5"], environment: [:], timeout: .milliseconds(200))
    return (result, ContinuousClock.now - started)
  }

  @Test func aGitThatHangsIsStopped() async throws {
    defer { cleanUp() }
    let (result, took) = try await Self.timedSleep()
    #expect(took < .seconds(4))
    #expect(result.timedOut)
    #expect(result.status != 0)
  }

  /// Review focus: a git that ignores the stop, and a process it started that holds the pipes
  /// after it, do not hold the call: it returns after the grace.
  private nonisolated static func timedDescendant() async throws -> (GitRunner.Output, Duration) {
    let started = ContinuousClock.now
    let result = try await GitRunner.run(
      URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; sleep 8 & sleep 8"], environment: [:],
      timeout: .milliseconds(200))
    return (result, ContinuousClock.now - started)
  }

  @Test func aStoppedGitsChildDoesNotHoldTheCall() async throws {
    defer { cleanUp() }
    let (result, took) = try await Self.timedDescendant()
    #expect(took > .seconds(1))
    #expect(took < .seconds(6))
    #expect(result.timedOut)
  }

  /// Cancelling the caller stops git.
  @Test func cancellingStopsGit() async throws {
    defer { cleanUp() }
    let started = ContinuousClock.now
    let running = Task.detached {
      try await GitRunner.run(
        URL(filePath: "/bin/sleep"), ["8"], environment: [:], timeout: .seconds(60))
    }
    try await Task.sleep(for: .milliseconds(200))
    running.cancel()
    let result = try await running.value
    #expect(ContinuousClock.now - started < .seconds(6))
    #expect(!result.timedOut)
    #expect(result.status != 0)
  }

  /// git never waits on a prompt nobody sees; a value the shell already sets stays.
  @Test func gitIsKeptFromAsking() {
    let environment = SkillSources.gitEnvironment(["PATH": "/usr/bin"])
    #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(environment["GIT_SSH_COMMAND"] == "ssh -o BatchMode=yes")
    #expect(environment["PATH"] == "/usr/bin")
    let mine = SkillSources.gitEnvironment(["GIT_SSH_COMMAND": "ssh -i key"])
    #expect(mine["GIT_SSH_COMMAND"] == "ssh -i key")
  }

  /// Review focus: one repository however it is spelled; a local one only by its path.
  @Test func aRepositorySpelledAnotherWayIsTheSame() {
    for (stored, address) in [
      ("https://github.com/me/skills", "git@github.com:me/skills.git"),
      ("https://github.com/me/skills.git", "https://GitHub.com/me/skills/"),
      ("file:///Users/me/src/skills", "file:///Users/me/src/skills/"),
      ("odd origin", "odd origin"),
    ] {
      #expect(SkillSources.isSameRepository(stored, address), "\(stored) \(address)")
    }
    for (stored, address) in [
      ("https://github.com/me/skills", "https://github.com/you/skills"),
      ("file:///Users/me/a/skills", "file:///Users/me/b/skills"),
      ("file:///Users/me/src/skills", "https://local/src/skills"),
      ("odd origin", "https://github.com/me/skills"),
    ] {
      #expect(!SkillSources.isSameRepository(stored, address), "\(stored) \(address)")
    }
  }

  /// The clone of an address spelled another way is pulled, not refused.
  @Test func anAddressSpelledAnotherWayReusesTheClone() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    #expect(try await sources.fetch(address + "/").skillPath == clone.skillPath)
  }

  @Test func anAddressThatLooksLikeAnOptionIsRefusedWithoutRunningGit() async throws {
    defer { cleanUp() }
    let sources = SkillSources(root: places.sources, environment: { ["PATH": "/nowhere"] })
    for address in ["--upload-pack=x@h:o/r", "ext::sh -c x@h:o/r"] {
      let error = await #expect(throws: SkillActionError.self) {
        try await sources.fetch(address)
      }
      #expect(error?.message.contains("is not a git URL") == true)
    }
  }

  @Test func anotherRepositoryAtTheSameFolderIsNotReused() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    let other = root.appending(path: "other/origin/skills-repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let executable = try #require(GitRunner.locate(path: environment["PATH"]))
    let made = try await GitRunner.run(
      executable, ["init", "-q", other.skillPath], environment: environment, timeout: .seconds(30))
    try #require(made.status == 0)
    let error = await #expect(throws: SkillActionError.self) {
      try await sources.fetch("file://" + other.skillPath)
    }
    #expect(error?.message.contains("A different repository is already cloned") == true)
    #expect(
      FileManager.default.fileExists(atPath: clone.appending(path: "skills/one/SKILL.md").skillPath)
    )
  }

  @Test func aFailedPullSaysWhyAndLeavesTheCloneAlone() async throws {
    defer { cleanUp() }
    try await makeOrigin()
    let clone = try await sources.fetch(address)
    let file = clone.appending(path: "skills/one/SKILL.md")
    try Data("mine\n".utf8).write(to: file)
    try skill("one", description: "Theirs.")
    try await commit("Changed upstream")
    let error = await #expect(throws: SkillActionError.self) { try await sources.fetch(address) }
    #expect(error?.message.isEmpty == false)
    #expect(try String(contentsOf: file, encoding: .utf8) == "mine\n")
  }
}
