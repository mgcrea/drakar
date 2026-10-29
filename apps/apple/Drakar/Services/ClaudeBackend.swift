import DrakarKit
import Foundation

/// Claude Code over stream-json (docs/claude-stream-json.md): `ClaudeLaunch` and
/// `ClaudeCommand` for the start, `ClaudeTranslator` for what it writes, `ClientMessage` for
/// what it is sent.
final class ClaudeBackend: AgentBackend {
  /// The arguments the next start runs with (a model for a debug launch).
  var command = ClaudeCommand()
  /// The stream's, so a new one for each process.
  private var translator = ClaudeTranslator()
  /// The process's too: a replay's new backend counts from one, and reads the log's ids as
  /// its own only if they were counted the same way.
  private var requestCount = 0
  /// Task controls sent and not yet answered: request id to the task or call it names. Their
  /// ids are UUIDs, off `requestCount`, since they are never noted for a replay to count.
  private var taskRequests: [String: String] = [:]

  var notFoundMessage: String { ClaudeLaunch.notFound }
  let features = AgentFeatures.claude

  func launch(_ start: AgentStart) -> AgentLaunch {
    var command = command
    if let model = start.model, model != "default" { command.model = model }
    if let mode = start.mode, mode != .ask { command.permissionMode = mode.rawValue }
    command.effort = start.effort
    command.allowsBypass = start.allowsBypass
    if let resuming = start.resuming {
      command.resumeSessionID = resuming.sessionID
      command.forksSession = resuming.forks == true
      command.resumeSessionAt = resuming.resumeAt
    }
    command.name = start.name
    let launch = ClaudeLaunch.make(
      folder: start.folder, resuming: start.resuming, account: start.account,
      environment: start.environment, executableOverride: start.executableOverride)
    return AgentLaunch(
      configuration: launch.executable.map {
        .init(
          executable: $0, arguments: command.arguments, environment: launch.environment,
          currentDirectory: start.folder)
      },
      executable: launch.executable, account: launch.account)
  }

  func started(_ process: any ProcessTransport, then first: AgentCommand?) throws {
    translator = ClaudeTranslator()
    requestCount = 0
    taskRequests.removeAll()
    try process.send(.initialize(requestID: nextRequestID("init")))
    askAppliedSettings(process)
    if let first { try send(first, to: process) }
  }

  @discardableResult func send(_ command: AgentCommand, to process: any ProcessTransport) throws
    -> String?
  {
    let (message, id) = encode(command)
    try process.send(message)
    return id
  }

  private func encode(_ command: AgentCommand) -> (ClientMessage, String?) {
    switch command {
    case .prompt(let text, let context, let uuid, let attachments):
      return (
        .prompt(
          text, context: context.map(\.promptContext), uuid: uuid,
          attachments: attachments.map(\.block)), nil
      )
    case .answer(let id, let decision):
      return (.permission(requestID: id, decision), nil)
    case .answerElicitation(let id, let noted):
      return (.answerElicitation(requestID: id, noted.answer), nil)
    case .interrupt(let cancelQueued):
      return (.interrupt(requestID: nextRequestID("interrupt"), cancelQueued: cancelQueued), nil)
    case .cancelQueued(let uuid):
      return (.cancelQueued(requestID: nextRequestID("cancel"), uuid: uuid), nil)
    case .setMode(let mode):
      let id = nextRequestID("mode")
      return (.setPermissionMode(requestID: id, mode: mode), id)
    case .setModel(let model):
      let id = nextRequestID("model")
      return (.setModel(requestID: id, model: model), id)
    case .setEffort(let level):
      let id = nextRequestID("effort")
      return (.setEffort(requestID: id, level: level), id)
    case .rename(let title, let sessionID):
      return (
        .renameSession(requestID: nextRequestID("rename"), title: title, sessionID: sessionID), nil
      )
    case .stopTask(let taskID):
      let id = taskRequestID("stop", for: taskID)
      return (.stopTask(requestID: id, taskID: taskID), id)
    case .backgroundCall(let toolUseID):
      let id = taskRequestID("background", for: toolUseID)
      return (.backgroundCall(requestID: id, toolUseID: toolUseID), id)
    case .taskOutput(let taskID):
      let id = taskRequestID("output", for: taskID)
      return (.taskOutput(requestID: id, taskID: taskID), id)
    }
  }

  func receive(_ line: AgentProcess.Line, from process: any ProcessTransport, at time: Date)
    -> BackendOutput
  {
    let message = StreamMessage(line)
    var output = BackendOutput()
    switch message {
    case .rateLimit(let info):
      output.signals.append(.rateLimit(info))
    case .controlResponse(let response) where response.requestID.hasPrefix("init-"):
      if response.isSuccess {
        if let models = ModelOption.list(fromInitialize: response.response) {
          output.signals.append(.models(models))
        }
        if let mode = response.response?["current_permission_mode"]?.stringValue {
          output.signals.append(.modeAdopted(mode))
        }
        output.signals.append(.initialized(response.response))
      }
    case .controlResponse(let response)
    where ["mode-", "model-", "effort-"].contains(where: response.requestID.hasPrefix):
      if response.isSuccess {
        if let mode = response.response?["mode"]?.stringValue {
          output.signals.append(.modeAdopted(mode))
        }
        if !response.requestID.hasPrefix("mode-") { askAppliedSettings(process) }
      }
      output.signals.append(
        .changeAnswered(
          requestID: response.requestID,
          refusal: response.isSuccess
            ? nil : response.error ?? String(localized: "Claude Code refused the change.")))
      return output
    case .controlResponse(let response) where response.requestID.hasPrefix("settings-"):
      if response.isSuccess {
        output.signals.append(
          .settingsApplied(
            effort: EffortLevel.applied(fromSettings: response.response),
            model: ModelName.applied(fromSettings: response.response),
            autoModeDisabled: AutoMode.isDisabled(bySettings: response.response)))
      }
      return output
    case .controlResponse(let response) where response.requestID.hasPrefix("context-"):
      if response.isSuccess, let reply = ContextUsageReply(response.response) {
        output.signals.append(.contextReported(reply))
      }
      return output
    case .controlResponse(let response)
    where ["stop-", "background-", "output-"].contains(where: response.requestID.hasPrefix):
      // One never sent by this backend, or answered already, says nothing.
      guard let target = taskRequests.removeValue(forKey: response.requestID) else {
        return output
      }
      if response.requestID.hasPrefix("stop-") {
        output.signals.append(
          .taskStopAnswered(
            taskID: target, error: response.isSuccess ? nil : response.error ?? ""))
      } else if response.requestID.hasPrefix("background-") {
        output.signals.append(
          .backgroundAnswered(
            toolUseID: target,
            BackgroundOutcome(
              isSuccess: response.isSuccess, response: response.response, error: response.error)))
      } else {
        output.signals.append(
          .taskOutputAnswered(
            taskID: target, response.isSuccess ? TaskOutput(response.response) : nil))
      }
      return output
    case .system(.initialized(let info)):
      if let mode = info.permissionMode { output.signals.append(.modeAdopted(mode)) }
    case .system(.status(_, let mode?)):
      output.signals.append(.modeAdopted(mode))
    case .system(.commandsChanged(let commands)):
      output.signals.append(.commandsChanged(commands))
    case .controlRequest(let request):
      // Not `write`: a reply that cannot be written must not mark the session failed.
      if let reply = request.reply { try? process.send(reply) }
    case .commandLifecycle:
      output.signals.append(.queueChanged)
    case .result:
      // Not `write`: a failed context request must not mark the session failed.
      try? process.send(.contextUsage(requestID: nextRequestID("context")))
    default:
      break
    }
    output.events = translator.translate(message, at: time)
    return output
  }

  /// The transcript lands under whichever account the shell selected; look for it in each.
  func locateTarget(sessionID id: String, cwd: String, in accounts: [ClaudeAccount])
    -> ResumeTarget?
  {
    for account in accounts {
      let projects = account.directory.appending(path: "projects")
      let folders =
        (try? FileManager.default.contentsOfDirectory(atPath: projects.path(percentEncoded: false)))
        ?? []
      for name in folders {
        let file = projects.appending(path: "\(name)/\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
          continue
        }
        return ResumeTarget(
          sessionID: id, cwd: cwd, file: file.path(percentEncoded: false),
          accountDirectory: account.directory.path(percentEncoded: false),
          accountIsDefault: account.isDefault)
      }
    }
    return nil
  }

  /// What the process applies now: asked after its start and after each model or effort
  /// change, since a model without effort (Haiku) applies none.
  private func askAppliedSettings(_ process: any ProcessTransport) {
    try? process.send(.getSettings(requestID: nextRequestID("settings")))
  }

  private func taskRequestID(_ prefix: String, for target: String) -> String {
    let id = "\(prefix)-\(UUID().uuidString)"
    taskRequests[id] = target
    return id
  }

  private func nextRequestID(_ prefix: String) -> String {
    requestCount += 1
    return "\(prefix)-\(requestCount)"
  }
}
