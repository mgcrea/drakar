import DrakarKit
import Foundation

/// Codex over `codex app-server` (docs/codex-app-server.md): `CodexSession` decides what is
/// written and what it means; this writes it to the process and says it in the session's
/// signals.
final class CodexBackend: AgentBackend {
  let features = AgentFeatures.codex
  private var session: CodexSession?
  /// Where the thread's files are, once it runs: what reopening the window resumes.
  private var threadPath: String?
  private var codexHome: String?
  /// The session's folder: the skills a prompt can name are its own.
  private var folder: URL?

  var notFoundMessage: String { CodexLaunch.notFound }

  func launch(_ start: AgentStart) -> AgentLaunch {
    let executable = start.executableOverride ?? CodexLaunch.locate(path: start.environment["PATH"])
    folder = start.folder
    // A new process starts afresh: a stopped session resumes its thread on its first prompt.
    session = CodexSession(
      cwd: start.folder.path(percentEncoded: false), resuming: start.resuming?.sessionID,
      mode: start.mode ?? .ask, model: start.model == "default" ? nil : start.model,
      effort: start.effort, version: CodexLaunch.appVersion, name: start.name)
    return AgentLaunch(
      configuration: executable.map {
        CodexLaunch.configuration(
          executable: $0, environment: start.environment, folder: start.folder)
      },
      executable: executable, account: nil)
  }

  func started(_ process: any ProcessTransport, then first: AgentCommand?) throws {
    guard var session else { return }
    var writes = session.start().writes
    if let first, let command = self.command(first) { writes += session.send(command).writes }
    self.session = session
    for line in writes { try process.send(line) }
  }

  @discardableResult func send(_ command: AgentCommand, to process: any ProcessTransport) throws
    -> String?
  {
    guard var session, let command = self.command(command) else { return nil }
    let step = session.send(command)
    self.session = session
    for line in step.writes { try process.send(line) }
    // Picks take with the next turn and are never refused: nothing to wait for.
    return nil
  }

  func receive(_ line: AgentProcess.Line, from process: any ProcessTransport, at time: Date)
    -> BackendOutput
  {
    guard case .json(let json) = line, var session else { return BackendOutput() }
    let step = session.receive(json, at: time)
    self.session = session
    // Not `write`: an answer that cannot be written must not mark the session failed.
    for line in step.writes { try? process.send(line) }
    var output = BackendOutput(events: step.events)
    for signal in step.signals {
      switch signal {
      case .models(let models): output.signals.append(.models(models))
      case .modeAdopted(let mode): output.signals.append(.modeAdopted(mode))
      case .unusable(let message): output.signals.append(.unusable(message))
      case .skillsChanged: output.signals.append(.skillsChanged)
      case .thread(_, let path, let home):
        threadPath = path
        codexHome = home
      }
    }
    // A queued prompt taken, steered in or dropped: the session may owe the window its turn end.
    if step.events.contains(where: { if case .queue = $0 { true } else { false } }) {
      output.signals.append(.queueChanged)
    }
    return output
  }

  /// The thread is its own target: no disk search.
  func locateTarget(sessionID id: String, cwd: String, in accounts: [ClaudeAccount])
    -> ResumeTarget?
  {
    ResumeTarget(
      sessionID: id, cwd: cwd, file: threadPath ?? "",
      accountDirectory: codexHome
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        .path(percentEncoded: false),
      accountIsDefault: true, agent: .codex)
  }

  /// `command` in the session's words; nil for what Codex cannot do (take back a steer). A
  /// prompt can name one of the folder's skills, as last listed.
  private func command(_ command: AgentCommand) -> CodexSession.Command? {
    switch command {
    case .prompt(let text, let context, let uuid, let attachments):
      .prompt(
        input: CodexInput.make(
          text: text, context: context, attachments: attachments,
          skills: folder.flatMap { CodexSkillStore.shared.skills(for: $0).skills } ?? []),
        uuid: uuid)
    case .answer(let id, let decision): .answer(requestID: id, decision: decision)
    // Codex raises no MCP server question yet, so there is none to answer.
    case .answerElicitation: nil
    case .interrupt(let cancelQueued): cancelQueued ? .interrupt : .interruptKeepingQueued
    case .cancelQueued: nil
    case .setMode(let raw): PermissionMode(rawValue: raw).map { .setMode($0) }
    case .setModel(let model): .setModel(model)
    case .setEffort(let level): .setEffort(level)
    case .rename(let title, _): .rename(title)
    // `features.controlsTasks` is false: nothing offers them.
    case .stopTask, .backgroundCall, .taskOutput: nil
    }
  }
}
