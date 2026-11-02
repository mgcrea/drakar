import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// Who may take a runner's session on its own (remote sessions spec §5), and what a session
/// rebuilt from a runner process's meta is on the runner's own Drakar: one of that Mac's own.
/// No host: the hosted halves are in `ReattachTests` (a local host) and `RunnerHostTests`
/// (the Mac's side, through ssh). `ThisMac.name` is only read here.
@MainActor
@Suite("Who owns a runner's session")
struct RunnerOwnershipTests {
  private let scratch: URL
  private let folder: URL

  init() throws {
    scratch = FileManager.default.temporaryDirectory.appending(
      path: "drakar-ownership-\(UUID().uuidString)", directoryHint: .isDirectory)
    folder = scratch.appending(path: "project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func cleanUp() {
    try? FileManager.default.removeItem(at: scratch)
  }

  /// A runner session's meta as the Mac `owner` names wrote it, started by `origin`.
  private func meta(
    owner: String?, origin: String? = "Other Mac", sessionID: String? = nil,
    accountPick: ClaudeAccount? = nil, savedTarget: ResumeTarget? = nil
  ) -> SessionMeta {
    SessionMeta(
      start: AgentStart(
        folder: folder, environment: [:], allowsBypass: false, runner: "runner-id"),
      windowFolder: folder.path(percentEncoded: false), accountPick: accountPick,
      sessionID: sessionID, savedTarget: savedTarget, history: .none, runner: "runner-id",
      origin: origin, owner: owner)
  }

  private func held(_ meta: SessionMeta, attachedApp: Int32? = nil) throws -> HeldProcess {
    HeldProcess(
      id: UUID().uuidString, meta: try JSONEncoder().encode(meta), running: true,
      logLength: 0, attachedApp: attachedApp)
  }

  /// An account of the test's own: `projects` is what makes it one.
  private func account(_ name: String) throws -> ClaudeAccount {
    let directory = scratch.appending(path: ".claude-\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory.appending(path: "projects"), withIntermediateDirectories: true)
    return ClaudeAccount(directory: directory, isDefault: false)
  }

  @Test func theRuleTable() {
    let mac = "This Mac"
    let cases: [(owner: String?, onRunner: Bool, taken: Bool)] = [
      // Handed to the runner's own Drakar, or started there.
      (nil, false, true),
      (nil, true, false),
      // This Mac's own.
      (mac, false, false),
      (mac, true, true),
      // Another Mac's.
      ("Other Mac", false, false),
      ("Other Mac", true, false),
    ]
    for (owner, onRunner, taken) in cases {
      #expect(
        meta(owner: owner).mayBeTaken(by: mac, onRunner: onRunner) == taken,
        "owner \(owner ?? "none"), onRunner \(onRunner)")
    }
  }

  /// At the runner's own Drakar's launch, a process a Mac owns opens no window there, free
  /// or not: that Mac takes it back when it reconnects.
  @Test func heldWindowsSkipsAnotherMacsSessions() throws {
    defer { cleanUp() }
    #expect(HeldWindows.folders(of: [try held(meta(owner: "Other Mac"))]) == [])
    #expect(
      HeldWindows.folders(of: [try held(meta(owner: nil))])
        == [ProjectPath.normalize(folder.path(percentEncoded: false))])
  }

  /// The runner's host as this Mac reaches it owns, for its stale-relay wait, what its meta
  /// says this Mac owns; a local host owns nothing that way.
  @Test func aRunnerHostOwnsWhatThisMacOwns() throws {
    let runner = SessionHost(
      endpoint: .runner(RunnerSettings(name: "Studio", destination: "studio.local")))
    #expect(runner.ownsProcess(try held(meta(owner: ThisMac.name))))
    #expect(!runner.ownsProcess(try held(meta(owner: "Other \(ThisMac.name)"))))
    #expect(!runner.ownsProcess(try held(meta(owner: nil))))
    #expect(!SessionHost(endpoint: .local).ownsProcess(try held(meta(owner: ThisMac.name))))
  }

  /// A runner's process replayed by the runner's own Drakar, whose host is local, is a session
  /// of that Mac's (Ruling 12): not on a runner, and an account picked on the Mac that started
  /// it is dropped unless it is one of the runner's too. Reached as a runner, it is the
  /// runner's, as the Mac picked it.
  @Test func aRunnerProcessReplayedOnItsRunnerIsLocal() async throws {
    defer { cleanUp() }
    let own = try account("own")
    let theMacs = ClaudeAccount(
      directory: URL(filePath: "/Users/someone-else/.claude-work", directoryHint: .isDirectory),
      isDefault: false)

    let foreign = await AgentSession(
      replaying: [], meta: meta(owner: nil, accountPick: theMacs), accounts: { [own] })
    #expect(foreign.runner == nil)
    #expect(!foreign.isOnRunner)
    #expect(foreign.accountPick == nil)
    // Where it runs and whose it is stay as the meta says, for the Mac that started it.
    #expect(foreign.origin == "Other Mac")
    #expect(foreign.meta()?.runner == "runner-id")

    let shared = await AgentSession(
      replaying: [], meta: meta(owner: nil, accountPick: own), accounts: { [own] })
    #expect(shared.accountPick == own)
    #expect(!shared.isOnRunner)

    let onRunner = await AgentSession(
      replaying: [], meta: meta(owner: ThisMac.name, accountPick: theMacs),
      throughRunner: true, accounts: { [own] })
    #expect(onRunner.runner == "runner-id")
    #expect(onRunner.isOnRunner)
    #expect(onRunner.accountPick == theMacs)
  }

  /// A target the runner's own Drakar saved while it held the session is a runner path: the
  /// runner's replay resumes it, a Mac's never carries it.
  @Test func aRunnersSavedTargetStaysOnTheRunner() async throws {
    defer { cleanUp() }
    let file = scratch.appending(path: "s-1.jsonl")
    try Data().write(to: file)
    let saved = ResumeTarget(
      sessionID: "s-1", cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false),
      accountDirectory: scratch.path(percentEncoded: false), accountIsDefault: true)
    let held = meta(owner: ThisMac.name, savedTarget: saved)

    let local = await AgentSession(replaying: [], meta: held, accounts: { [] })
    #expect(local.resuming == saved)
    let onRunner = await AgentSession(
      replaying: [], meta: held, throughRunner: true, accounts: { [] })
    #expect(onRunner.resuming == nil)
    #expect(onRunner.savedTarget == nil)
  }

  /// On the runner's own Drakar, a session a Mac holds is shown read-only, following the
  /// transcript its process writes on the runner's disk, found by the id its meta gives; it
  /// says which Mac it belongs to, and drops an account of that Mac's.
  @Test func aSessionAMacOwnsIsFollowedOnTheRunner() async throws {
    defer { cleanUp() }
    let own = try account("own")
    let project = own.directory.appending(path: "projects/p", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let line = #"{"type":"user","message":{"role":"user","content":"from the Mac"}}"# + "\n"
    try Data(line.utf8).write(to: project.appending(path: "s-1.jsonl"))
    let theMacs = ClaudeAccount(
      directory: URL(filePath: "/Users/someone-else/.claude-work", directoryHint: .isDirectory),
      isDefault: false)
    let process = try held(
      meta(owner: "Other Mac", sessionID: "s-1", accountPick: theMacs), attachedApp: 4242)

    let session = try #require(await AgentSession(heldElsewhere: process, accounts: { [own] }))
    #expect(session.belongsTo == "Other Mac")
    #expect(session.heldElsewhere == process.id)
    #expect(session.isReadOnly)
    #expect(!session.isOnRunner)
    #expect(session.accountPick == nil)
    #expect(session.resuming?.sessionID == "s-1")
    #expect(
      session.transcript.entries.contains { $0.kind == .prompt("from the Mac") })
  }
}
