import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A Codex-featured backend over a `cat`: what the process echoes is read as Codex saying
/// its skills changed, once `fire()` writes a line to it.
@MainActor
private final class SkillsChangedBackend: AgentBackend {
  let notFoundMessage = "not found"
  var features: AgentFeatures { .codex }
  private var process: AgentProcess?

  func launch(_ start: AgentStart) -> AgentLaunch {
    AgentLaunch(
      configuration: .init(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: start.folder),
      executable: URL(filePath: "/bin/cat"), account: nil)
  }

  func started(_ process: AgentProcess, then first: AgentCommand?) throws {
    self.process = process
  }

  func receive(_ line: AgentProcess.Line, from process: AgentProcess, at time: Date)
    -> BackendOutput
  {
    BackendOutput(signals: [.skillsChanged])
  }

  func send(_ command: AgentCommand, to process: AgentProcess) throws -> String? { nil }

  func locateTarget(sessionID: String, cwd: String, in accounts: [ClaudeAccount])
    -> ResumeTarget?
  { nil }

  func fire() throws { try process?.send(.object(["ping": .bool(true)])) }
}

@MainActor
@Suite("Codex's skills, kept per folder")
struct CodexSkillsTests {
  final class Calls {
    var count = 0
    var forced: [Bool] = []
  }

  private let folder: URL
  private let deploy = SkillEntry(
    name: "deploy", description: "Deploy to staging",
    path: "/Users/me/project/.agents/skills/deploy/SKILL.md")

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-codex-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func settle(_ entry: CodexSkills) async throws {
    for _ in 0..<100 where entry.isLoading {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// An entry whose reads are counted, each answering `skills`.
  private func counted(_ entry: CodexSkills, _ skills: [SkillEntry] = []) -> Calls {
    let calls = Calls()
    entry.reader = { _, force in
      calls.count += 1
      calls.forced.append(force)
      return skills
    }
    return calls
  }

  @Test func loadsOnceIfNeeded() async throws {
    let entry = CodexSkills(folder: folder)
    let calls = counted(entry, [deploy])
    entry.loadIfNeeded()
    #expect(entry.isLoading)
    try await settle(entry)
    entry.loadIfNeeded()
    try await settle(entry)
    #expect(calls.count == 1)
    #expect(calls.forced == [false])
    #expect(entry.skills == [deploy])
    #expect(entry.hasLoaded)
    #expect(entry.problem == nil)
  }

  /// Retry and the pane's refresh ask Codex to read the files again.
  @Test func aForcedRefreshReloadsCodexsOwn() async throws {
    let entry = CodexSkills(folder: folder)
    let calls = counted(entry)
    entry.refresh(force: true)
    try await settle(entry)
    #expect(calls.forced == [true])
  }

  /// Refreshes asked while a read runs make one more read, forced if any of them was.
  @Test func refreshesAskedDuringAReadRunOnceAfterIt() async throws {
    let entry = CodexSkills(folder: folder)
    let calls = Calls()
    entry.reader = { _, force in
      calls.count += 1
      calls.forced.append(force)
      try? await Task.sleep(for: .milliseconds(100))
      return []
    }
    entry.refresh()
    entry.refresh()
    entry.refresh(force: true)
    entry.refresh()
    try await settle(entry)
    #expect(calls.forced == [false, true])
  }

  /// A failed first read says why, is not tried again on its own, and Retry tries again.
  @Test func aFailedReadSaysWhyAndWaitsForRetry() async throws {
    let entry = CodexSkills(folder: folder)
    let calls = Calls()
    entry.reader = { _, _ in
      calls.count += 1
      throw CodexOneShot.Failure(message: "Codex ended before it answered.")
    }
    entry.loadIfNeeded()
    try await settle(entry)
    #expect(entry.skills == nil)
    #expect(!entry.hasLoaded)
    #expect(entry.problem == "Couldn't read Codex's skills. Codex ended before it answered.")
    entry.refreshIfLoaded()
    try await Task.sleep(for: .milliseconds(100))
    try await settle(entry)
    #expect(calls.count == 1)
    entry.reader = { _, _ in [self.deploy] }
    entry.refresh(force: true)
    try await settle(entry)
    #expect(entry.skills == [deploy])
    #expect(entry.problem == nil)
  }

  /// A reload that fails keeps the list shown, and says why beside it.
  @Test func aFailedReloadKeepsTheLastList() async throws {
    let entry = CodexSkills(folder: folder)
    entry.reader = { _, _ in [self.deploy] }
    entry.refresh()
    try await settle(entry)
    entry.reader = { _, _ in throw CodexOneShot.Failure(message: "boom") }
    entry.refresh()
    try await settle(entry)
    #expect(entry.skills == [deploy])
    #expect(entry.problem == "Couldn't read Codex's skills. boom")
  }

  /// A change refreshes only a list something asked for.
  @Test func refreshIfLoadedLeavesAnUnloadedEntryAlone() async throws {
    let entry = CodexSkills(folder: folder)
    let calls = counted(entry)
    entry.refreshIfLoaded()
    try await settle(entry)
    #expect(calls.count == 0)
    entry.refresh()
    try await settle(entry)
    entry.refreshIfLoaded()
    try await settle(entry)
    #expect(calls.count == 2)
  }

  @Test func oneEntryPerFolder() {
    let store = CodexSkillStore()
    let first = store.skills(for: folder)
    #expect(store.skills(for: folder.appending(path: "")) === first)
    #expect(store.skills(for: folder.appending(path: "sub", directoryHint: .isDirectory)) !== first)
  }

  /// The read asks `skills/list` for the folder, forcing a reload when asked, and lists what
  /// it answers.
  @Test func readsSkillsListFromCodex() async throws {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    let script = folder.appending(path: "codex")
    func skill(_ name: String) -> String {
      #"{"name":"\#(name)","description":"d","path":"/\#(name)/SKILL.md","scope":"repo","enabled":true}"#
    }
    func reply(_ name: String) -> String {
      #"echo '{"id":'"$id"',"result":{"data":[{"cwd":"\#(path)","skills":[\#(skill(name))],"errors":[]}]}}'"#
    }
    try Data(
      """
      #!/bin/sh
      while read -r line; do
        id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9.]*\\).*/\\1/p')
        case "$line" in
          *'"initialize"'*) echo '{"id":'"$id"',"result":{}}' ;;
          *'"skills/list"'*'"cwds":["\(path)"],"forceReload":true'*) \(reply("forced")) ;;
          *'"skills/list"'*'"cwds":["\(path)"]}'*) \(reply("plain")) ;;
        esac
      done
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let configuration = CodexLaunch.configuration(
      executable: script, environment: [:], folder: folder)
    let plain = try await CodexSkills.read(
      folder: URL(filePath: path), force: false, configuration: configuration)
    #expect(plain.map(\.name) == ["plain"])
    #expect(plain.first?.path == "/plain/SKILL.md")
    let forced = try await CodexSkills.read(
      folder: URL(filePath: path), force: true, configuration: configuration)
    #expect(forced.map(\.name) == ["forced"])
  }

  /// Codex saying its skills changed reads the session's folder's list again.
  @Test func aSkillsChangeRefreshesTheFoldersList() async throws {
    let entry = CodexSkillStore.shared.skills(for: folder)
    let calls = counted(entry)
    entry.refresh()
    try await settle(entry)
    let backend = SkillsChangedBackend()
    let session = AgentSession(folder: folder, agent: .codex, backend: backend)
    defer { session.stop() }
    session.send("first")
    for _ in 0..<50 where !session.isProcessRunning {
      try await Task.sleep(for: .milliseconds(100))
    }
    try backend.fire()
    for _ in 0..<50 where calls.count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(calls.count == 2)
  }

  /// A change to the project's `.agents/skills` reads Codex's list again once settled, when
  /// it was read before.
  @Test func aSkillFileChangeRefreshesCodexsList() async throws {
    let project = Project(folder: folder)
    defer { project.stopAll() }
    project.capabilityDebounce = .milliseconds(100)
    let entry = CodexSkillStore.shared.skills(for: folder)
    let calls = counted(entry)
    entry.refresh()
    try await settle(entry)
    let skill = folder.appending(path: ".agents/skills/x", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data("---\nname: x\n---\n".utf8).write(to: skill.appending(path: "SKILL.md"))
    for _ in 0..<50 where calls.count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    try await settle(entry)
    #expect(calls.count == 2)
  }

  /// Where Codex finds a project's own skills.
  @Test func codexsSkillFoldersChangeTheLists() {
    #expect(Workspace.touchesCapabilities(["/p/.agents/skills/x/SKILL.md"], root: "/p"))
    #expect(Workspace.touchesCapabilities(["/p/.agents/skills"], root: "/p"))
    #expect(Workspace.touchesCapabilities(["/p/.codex/skills/x/SKILL.md"], root: "/p"))
    #expect(!Workspace.touchesCapabilities(["/p/.agents/notes.md"], root: "/p"))
    #expect(!Workspace.touchesCapabilities(["/p/.codex/config.toml"], root: "/p"))
  }

  /// A prompt naming a skill of the session's folder goes to Codex with its skill item.
  @Test func theBackendNamesASkillOfItsFolder() async throws {
    let entry = CodexSkillStore.shared.skills(for: folder)
    entry.reader = { _, _ in [self.deploy] }
    entry.refresh()
    try await settle(entry)
    let backend = CodexBackend()
    _ = backend.launch(
      AgentStart(
        folder: folder, resuming: nil, environment: ["PATH": "/nowhere"],
        executableOverride: URL(filePath: "/bin/cat"), model: nil, mode: .ask, effort: nil,
        allowsBypass: false, name: nil))
    // A `cat` stands in for the process: what the backend writes comes back as lines.
    let process = AgentProcess(
      .init(
        executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:],
        currentDirectory: folder))
    let stream = try process.start()
    // Ends the stream, and the test, should the turn never start.
    let deadline = Task {
      try? await Task.sleep(for: .seconds(5))
      process.terminate()
    }
    defer {
      deadline.cancel()
      process.terminate()
    }
    try backend.started(process, then: nil)
    func line(_ json: String) throws -> AgentProcess.Line {
      .json(try JSONValue.parse(Data(json.utf8)))
    }
    _ = backend.receive(try line(#"{"id":1,"result":{}}"#), from: process, at: .now)
    _ = try backend.send(
      .prompt(text: "/deploy now", context: [], uuid: "p-1", attachments: []), to: process)
    _ = backend.receive(
      try line(#"{"id":4,"result":{"thread":{"id":"t-1","cwd":"/p"},"model":"m"}}"#),
      from: process, at: .now)
    var input: JSONValue?
    reading: for await event in stream {
      guard case .lines(let lines) = event else { continue }
      for case .json(let json) in lines where json["method"] == .string("turn/start") {
        input = json["params"]?["input"]
        break reading
      }
    }
    #expect(
      input
        == .array([
          CodexInput.text("/deploy now"),
          .object([
            "type": .string("skill"), "name": .string("deploy"),
            "path": .string("/Users/me/project/.agents/skills/deploy/SKILL.md"),
          ]),
        ]))
  }
}
