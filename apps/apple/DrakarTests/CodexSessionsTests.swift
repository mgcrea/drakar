import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A Codex-featured backend over a `cat`: what the process echoes is read as `.unusable`,
/// once `fire()` writes a line to it.
@MainActor
private final class UnusableBackend: AgentBackend {
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
    BackendOutput(signals: [.unusable("Not signed in")])
  }

  func send(_ command: AgentCommand, to process: AgentProcess) throws -> String? { nil }

  func locateTarget(sessionID: String, cwd: String, in accounts: [ClaudeAccount])
    -> ResumeTarget?
  { nil }

  func fire() throws { try process?.send(.object(["ping": .bool(true)])) }
}

@MainActor
@Suite("Codex sessions in a project")
struct CodexSessionsTests {
  private let folder = FileManager.default.temporaryDirectory

  @Test func aSessionTakesItsAgentFromItsTarget() {
    let target = ResumeTarget(
      sessionID: "t-1", cwd: folder.path(percentEncoded: false), file: "", accountDirectory: "/h",
      accountIsDefault: true, agent: .codex)
    #expect(AgentSession(folder: folder, resuming: target).agent == .codex)
    #expect(AgentSession(folder: folder).agent == .claude)
    #expect(AgentSession(folder: folder, agent: .codex).backend is CodexBackend)
  }

  @Test func newSessionStartsTheAgentAsked() {
    let project = Project(folder: folder)
    #expect(project.newSession(agent: .codex).session.agent == .codex)
    #expect(project.newSession(agent: .claude).session.agent == .claude)
  }

  @Test func settingsDefaultsAreClaudesOnly() {
    ClaudeChoice.$testSuite.withValue("codex-sessions-\(UUID())") {
      ClaudeChoice.defaults.set("claude-opus-5-5", forKey: PreferenceKey.defaultModel)
      ClaudeChoice.defaults.set("high", forKey: PreferenceKey.defaultEffort)
      ClaudeChoice.defaults.set("acceptEdits", forKey: PreferenceKey.defaultMode)
      let codex = AgentSession(folder: folder, agent: .codex)
      #expect(codex.pickedModel == nil)
      #expect(codex.shownEffort == nil)
      #expect(codex.startingMode == nil)
      let claude = AgentSession(folder: folder, agent: .claude)
      #expect(claude.pickedModel == "claude-opus-5-5")
    }
  }

  @Test func aCodexSessionCannotFork() {
    let project = Project(folder: folder)
    let item = project.newSession(agent: .codex)
    item.session.relocate(
      to: ResumeTarget(
        sessionID: "t-1", cwd: folder.path(percentEncoded: false), file: "",
        accountDirectory: "/h", accountIsDefault: true, agent: .codex))
    #expect(!project.canFork(item))
  }

  /// A Codex target's account is a placeholder, never a Claude account to look up.
  @Test func aCodexSessionHasNoClaudeAccount() {
    let target = ResumeTarget(
      sessionID: "t-1", cwd: folder.path(percentEncoded: false), file: "", accountDirectory: "/h",
      accountIsDefault: true, agent: .codex)
    #expect(AgentSession(folder: folder, resuming: target).effectiveAccount == nil)
    var claude = target
    claude.agent = nil
    #expect(AgentSession(folder: folder, resuming: claude).effectiveAccount != nil)
  }

  /// Review Focus 5, the history half: a restored Codex session whose history cannot be read
  /// opens with a note and stays sendable.
  @Test func anUnreadableHistoryLeavesANoteAndTheSessionUsable() async {
    let target = ResumeTarget(
      sessionID: "t-1", cwd: folder.path(percentEncoded: false), file: "", accountDirectory: "/h",
      accountIsDefault: true, agent: .codex)
    let session = AgentSession(folder: folder, resuming: target)
    session.executableOverride = URL(filePath: "/nonexistent/codex")
    await session.loadHistory()
    #expect(session.hasLoadedHistory)
    #expect(session.canSend)
    #expect(
      session.transcript.entries.contains {
        if case .notice(let text) = $0.kind { text.contains("history") } else { false }
      })
  }

  /// An `.unusable` signal ends the session as an exit does: the process gone, the queue
  /// emptied, the reason in `phase`, and the window told it stopped.
  @Test func anUnusableSignalStopsTheSessionAndSaysSo() async throws {
    let backend = UnusableBackend()
    let session = AgentSession(folder: folder, agent: .codex, backend: backend)
    var stopped = 0
    session.onStopped = { stopped += 1 }
    session.send("first")
    for _ in 0..<50 where !session.isProcessRunning {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.isProcessRunning)
    // The first prompt is in the conversation once; only one sent mid-turn is queued.
    #expect(session.transcript.entries.filter { $0.kind == .prompt("first") }.count == 1)
    #expect(session.transcript.queuedPrompts.isEmpty)
    session.send("second")
    #expect(session.transcript.queuedPrompts.map(\.text) == ["second"])
    #expect(!session.transcript.entries.contains { $0.kind == .prompt("second") })

    try backend.fire()
    for _ in 0..<50 where session.phase != .failed("Not signed in") {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.phase == .failed("Not signed in"))
    #expect(!session.isProcessRunning)
    #expect(session.transcript.queuedPrompts.isEmpty)
    #expect(stopped == 1)
  }
}
