import DrakarKit
import Foundation

/// Antigravity over `agy acp` (docs/agy-acp.md): `AgySession` decides what is written and
/// what it means; this writes it to the process and translates its signals for `AgentSession`.
final class AgyBackend: AgentBackend {
  let features: AgentFeatures
  private let agent: AgentKind

  init(agent: AgentKind = .agy) {
    self.agent = agent
    features = agent.features
  }
  private var session: AgySession?
  private var folder: URL?

  var notFoundMessage: String {
    agent == .grok
      ? String(localized: "Grok Build was not found. Install the grok CLI, then send again.")
      : AgyLaunch.notFound
  }

  func launch(_ start: AgentStart) -> AgentLaunch {
    let executable =
      start.executableOverride
      ?? AgyLaunch.locate(path: start.environment["PATH"], binary: agent.rawValue)
    folder = start.folder
    session = AgySession(
      cwd: start.folder.path(percentEncoded: false),
      resuming: start.resuming?.sessionID,
      mode: agent == .grok ? nil : start.mode,
      model: start.model == "default" ? nil : start.model,
      effort: start.effort,
      version: AgyLaunch.appVersion, isGrok: agent == .grok)
    return AgentLaunch(
      configuration: executable.map {
        AgyLaunch.configuration(
          executable: $0, environment: start.environment, folder: start.folder, agent: agent)
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
    return step.requestID
  }

  func receive(_ line: AgentProcess.Line, from process: any ProcessTransport, at time: Date)
    -> BackendOutput
  {
    guard case .json(let json) = line, var session else { return BackendOutput() }
    let step = session.receive(json, at: time)
    self.session = session
    for line in step.writes { try? process.send(line) }
    var output = BackendOutput(events: step.events)
    for signal in step.signals {
      switch signal {
      case .models(let models):
        output.signals.append(.models(models))
      case .session:
        break
      case .modeAdopted(let mode):
        output.signals.append(.modeAdopted(mode))
      case .settingsApplied(let effort, let model):
        output.signals.append(
          .settingsApplied(effort: effort, model: model, autoModeDisabled: false))
      case .commands(let entries):
        if agent == .agy, let folder { AgySkillStore.shared.skills(for: folder).record(entries) }
      case .changeAnswered(let requestID, let refusal):
        output.signals.append(.changeAnswered(requestID: requestID, refusal: refusal))
      case .unusable(let message):
        output.signals.append(.unusable(message))
      }
    }
    if step.events.contains(where: { if case .queue = $0 { true } else { false } }) {
      output.signals.append(.queueChanged)
    }
    return output
  }

  func locateTarget(sessionID id: String, cwd: String, in accounts: [ClaudeAccount])
    -> ResumeTarget?
  {
    let agyHome = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: agent == .grok ? ".grok" : ".gemini/antigravity-cli")
      .path(percentEncoded: false)
    return ResumeTarget(
      sessionID: id, cwd: cwd, file: "", accountDirectory: agyHome,
      accountIsDefault: true, agent: agent)
  }

  private func command(_ command: AgentCommand) -> AgySession.Command? {
    switch command {
    case .prompt(let text, let context, let uuid, let attachments):
      .prompt(
        input: AgyInput.make(text: text, context: context, attachments: attachments), uuid: uuid)
    case .answer(let id, let decision):
      .answer(requestID: id, decision: decision)
    case .answerElicitation:
      nil
    case .interrupt(let cancelQueued):
      .interrupt(cancelQueued: cancelQueued)
    case .cancelQueued(let uuid):
      .cancelQueued(uuid: uuid)
    case .setMode(let raw):
      (agent == .grok ? nil : PermissionMode(rawValue: raw)).map { .setMode($0) }
    case .setModel(let model):
      .setModel(model)
    case .setEffort(let level):
      .setEffort(level)
    case .rename:
      nil
    case .stopTask, .backgroundCall, .taskOutput, .rewindFiles, .listPermissionRules, .getPlan,
      .readServers, .reconnectServer:
      nil
    }
  }
}
