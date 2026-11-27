import Foundation

/// One Antigravity session over `agy acp` (docs/agy-acp.md), with no process: each command
/// given and each line read returns what to write, what the conversation shows, and what the
/// session learns. `AgyBackend` (the app) writes the lines; tests drive this directly.
///
/// One process, one ACP session: `initialize` first, then `session/new` (or `session/resume`
/// when resuming) on the first prompt. Mid-turn prompts are queued client-side so they can be
/// cancelled individually, dropped by Stop, or run next after Esc or turn completion.
public struct AgySession: Sendable {
  public enum Command: Sendable, Equatable {
    case prompt(input: JSONValue, uuid: String)
    case answer(requestID: String, decision: PermissionDecision)
    case answerElicitation(requestID: String, answer: ElicitationAnswer)
    /// Stop: cancels the running turn and drops queued prompts.
    case interrupt(cancelQueued: Bool)
    case cancelQueued(uuid: String)
    case setMode(PermissionMode)
    case setModel(String)
    case setEffort(String)
  }

  public enum Signal: Sendable, Equatable {
    case models([ModelOption])
    case session(id: String)
    case modeAdopted(String)
    case settingsApplied(effort: String?, model: String?)
    case commands([SkillEntry])
    case changeAnswered(requestID: String, refusal: String?)
    case unusable(String)
  }

  public struct Step: Sendable, Equatable {
    public var writes: [JSONValue] = []
    public var events: [AgentEvent] = []
    public var signals: [Signal] = []
    /// The RPC request id for a live `setMode`, `setModel`, or `setEffort` call.
    public var requestID: String?

    public init() {}
  }

  public static func initializeParams(version: String) -> JSONValue {
    .object([
      "protocolVersion": .number(1),
      "clientCapabilities": .object([
        "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
        "terminal": .bool(false),
        "elicitation": .object(["form": .object([:])]),
      ]),
      "clientInfo": .object([
        "name": .string("drakar"),
        "version": .string(version),
      ]),
    ])
  }

  public static let notSignedIn = String(
    localized: "Antigravity isn't signed in. Run `agy` in a terminal to sign in, then send again.")
  public static let noSession = String(localized: "Antigravity opened no session. Send again.")

  private enum Call: Sendable {
    case initialize
    case openSession
    case prompt
    case setMode(PermissionMode)
    case setConfig
    case initialConfig
  }

  private struct Waiting: Sendable {
    var input: JSONValue
    var uuid: String
  }

  private struct Approval: Sendable {
    var id: AgyRPC.ID
    var options: [AgyPolicy.Option]
  }

  private let isGrok: Bool
  private var name: String { isGrok ? "Grok" : "Antigravity" }
  private let cwd: String
  private let version: String
  private var sessionID: String?
  private var agentVersion: String?
  private var isInitialized = false
  private var isSessionReady = false
  private var isOpeningSession = false
  private var isTurnRunning = false
  private var cancelsWhenStarted = false
  private var calls = AgyRPC.Calls<Call>()
  private var translator = AgyTranslator()
  private var knownModels: [ModelOption] = []
  /// Prompts sent before the session opened.
  private var beforeSession: [Waiting] = []
  /// Prompts queued behind a running turn, oldest first.
  private var queued: [Waiting] = []
  /// Pending `session/request_permission` requests by their text id.
  private var approvals: [String: Approval] = [:]
  /// Pending `ask_question` prompts arrived via `elicitation/create`, by their text id.
  private var questionPrompts: [String: AgyQuestionPrompt] = [:]
  /// Pending generic MCP `elicitation/create` requests, by their text id.
  private var elicitations: [String: AgyRPC.ID] = [:]
  private var mode: PermissionMode
  private var explicitMode: Bool
  private var model: String?
  private var effort: String?

  public init(
    cwd: String, resuming: String?, mode: PermissionMode?, model: String?, effort: String?,
    version: String, isGrok: Bool = false
  ) {
    self.isGrok = isGrok
    self.cwd = cwd
    self.sessionID = resuming
    self.mode = mode ?? .ask
    self.explicitMode = mode != nil
    self.model = model
    self.effort = effort
    self.version = version
  }

  public mutating func start() -> Step {
    var step = Step()
    let (_, msg) = calls.make(
      "initialize", Self.initializeParams(version: version), for: .initialize)
    step.writes.append(msg)
    return step
  }

  public mutating func send(_ command: Command) -> Step {
    var step = Step()
    switch command {
    case .prompt(let input, let uuid):
      let prompt = Waiting(input: input, uuid: uuid)
      guard isSessionReady else {
        beforeSession.append(prompt)
        if isInitialized, !isOpeningSession { step.writes.append(openSession()) }
        break
      }
      if isTurnRunning {
        queued.append(prompt)
      } else {
        step.writes.append(startPrompt(prompt))
      }

    case .answer(let requestID, let decision):
      if let prompt = questionPrompts.removeValue(forKey: requestID) {
        let (write, outcome) = prompt.response(for: decision)
        if let callID = prompt.toolCallID {
          translator.recordQuestionOutcome(callID: callID, outcome: outcome)
        }
        step.writes.append(write)
      } else if let approval = approvals.removeValue(forKey: requestID) {
        step.writes.append(
          AgyRPC.answer(approval.id, result: AgyPolicy.result(decision, options: approval.options)))
      }

    case .answerElicitation(let requestID, let answer):
      guard let rpcID = elicitations.removeValue(forKey: requestID) else { break }
      step.writes.append(AgyRPC.answer(rpcID, result: answer.json))

    case .interrupt(let cancelQueued):
      for key in approvals.keys.sorted() {
        if let approval = approvals[key] {
          step.writes.append(AgyRPC.answer(approval.id, result: AgyPolicy.cancelled))
          step.events.append(.permissionWithdrawn(requestID: key))
        }
      }
      approvals.removeAll()
      for key in questionPrompts.keys.sorted() {
        if let prompt = questionPrompts[key] {
          if let callID = prompt.toolCallID {
            translator.recordQuestionOutcome(callID: callID, outcome: .interrupted)
          }
          step.writes.append(
            AgyRPC.answer(prompt.id, result: .object(["action": .string("cancel")])))
          step.events.append(.permissionWithdrawn(requestID: key))
        }
      }
      questionPrompts.removeAll()
      for key in elicitations.keys.sorted() {
        if let rpcID = elicitations[key] {
          step.writes.append(
            AgyRPC.answer(rpcID, result: .object(["action": .string("cancel")])))
          step.events.append(.permissionWithdrawn(requestID: key))
        }
      }
      elicitations.removeAll()
      if cancelQueued {
        for item in queued { step.events.append(.queue(id: item.uuid, .cancelled)) }
        queued.removeAll()
        if !isSessionReady, beforeSession.count > 1 {
          for item in beforeSession.dropFirst() {
            step.events.append(.queue(id: item.uuid, .cancelled))
          }
          beforeSession = Array(beforeSession.prefix(1))
        }
      }
      if isTurnRunning, let sid = sessionID {
        step.writes.append(
          AgyRPC.notification("session/cancel", params: .object(["sessionId": .string(sid)])))
      } else if !beforeSession.isEmpty {
        cancelsWhenStarted = true
      }

    case .cancelQueued(let uuid):
      if let idx = queued.firstIndex(where: { $0.uuid == uuid }) {
        queued.remove(at: idx)
        step.events.append(.queue(id: uuid, .cancelled))
      } else if let idx = beforeSession.firstIndex(where: { $0.uuid == uuid }), idx > 0 {
        beforeSession.remove(at: idx)
        step.events.append(.queue(id: uuid, .cancelled))
      }

    case .setMode(let newMode):
      mode = newMode
      explicitMode = true
      if AgyPolicy.letsThrough(in: newMode) {
        for key in approvals.keys.sorted() {
          guard let approval = approvals.removeValue(forKey: key) else { continue }
          step.writes.append(
            AgyRPC.answer(approval.id, result: AgyPolicy.allowOnce(options: approval.options)))
          step.events.append(.permissionWithdrawn(requestID: key))
        }
      }
      if isSessionReady, let sid = sessionID {
        let (id, msg) = calls.make(
          "session/set_mode",
          .object(["sessionId": .string(sid), "modeId": .string(modeID(newMode))]),
          for: .setMode(newMode))
        step.writes.append(msg)
        step.requestID = id
      }

    case .setModel(let newModel):
      model = newModel
      if isSessionReady, let sid = sessionID {
        let (id, msg) = calls.make(
          "session/set_config_option",
          .object([
            "sessionId": .string(sid),
            "configId": .string("model"),
            "value": .string(newModel),
          ]),
          for: .setConfig)
        step.writes.append(msg)
        step.requestID = id
      }

    case .setEffort(let newEffort):
      effort = newEffort
      if isSessionReady, let sid = sessionID {
        let (id, msg) = calls.make(
          "session/set_config_option",
          .object([
            "sessionId": .string(sid),
            "configId": .string(isGrok ? "reasoning_effort" : "thought_level"),
            "value": .string(newEffort),
          ]),
          for: .setConfig)
        step.writes.append(msg)
        step.requestID = id
      }
    }
    return step
  }

  public mutating func receive(_ message: JSONValue, at time: Date?) -> Step {
    var step = Step()
    guard let line = AgyRPC.Line(message) else { return step }
    switch line {
    case .response(let id, let result):
      if let call = calls.take(id) { answered(call, id: id.text, result: result, into: &step) }

    case .failure(let id, _, let text):
      if let call = calls.take(id) { failed(call, id: id.text, message: text, into: &step) }

    case .request(let id, let method, let params):
      if method == "session/request_permission" {
        let options = (params["options"]?.arrayValue ?? []).compactMap(AgyPolicy.Option.init)
        if AgyPolicy.letsThrough(in: mode) {
          step.writes.append(AgyRPC.answer(id, result: AgyPolicy.allowOnce(options: options)))
        } else {
          approvals[id.text] = Approval(id: id, options: options)
          step.events += translator.permission(id: id, params: params)
        }
      } else if method == "elicitation/create" {
        // Questions and elicitations always ask the person, even when Bypass is active.
        if let (event, prompt) = translator.questionElicitation(id: id, params: params) {
          questionPrompts[id.text] = prompt
          step.events.append(event)
        } else {
          elicitations[id.text] = id
          let elicitation =
            Elicitation(acpRequest: params)
            ?? Elicitation(
              serverName: "", displayName: nil, message: "", elicitationID: nil, title: nil,
              description: nil, content: .unsupported)
          step.events.append(
            .elicitationRequested(.init(requestID: id.text, elicitation: elicitation)))
        }
      } else {
        step.writes.append(AgyRPC.refusal(id, message: "Drakar does not answer \(method)."))
        step.events.append(
          .note(
            .init(
              text: String(
                localized:
                  "\(name) asked for something Drakar can't answer yet (\(method)), so it was refused."
              ))))
      }

    case .notification(let method, let params):
      guard method == "session/update", let update = params["update"] else { break }
      // Ignore updates for another session if one ever arrives.
      if let sid = params["sessionId"]?.stringValue, let mine = sessionID, sid != mine { break }
      notified(update: update, into: &step)
    }
    return step
  }

  private mutating func answered(
    _ call: Call, id requestID: String, result: JSONValue, into step: inout Step
  ) {
    switch call {
    case .initialize:
      isInitialized = true
      agentVersion =
        result["agentInfo"]?["version"]?.stringValue
        ?? result["_meta"]?["agentVersion"]?.stringValue
      if !beforeSession.isEmpty, !isOpeningSession { step.writes.append(openSession()) }

    case .openSession:
      isOpeningSession = false
      guard let sid = result["sessionId"]?.stringValue ?? sessionID, !sid.isEmpty else {
        failOpen(isGrok ? "Grok opened no session. Send again." : Self.noSession, into: &step)
        return
      }
      sessionID = sid
      isSessionReady = true

      let snap = AgyModels.snapshot(from: result)
      if !snap.models.isEmpty {
        knownModels = snap.models
        step.signals.append(.models(snap.models))
      }

      let adoptedMode: PermissionMode = explicitMode ? mode : (snap.currentMode ?? mode)
      mode = adoptedMode
      let activeModel = model ?? snap.currentModel
      let activeEffort = effort ?? snap.currentEffort

      step.events.append(
        .sessionStarted(
          SessionInfo(
            sessionID: sid, cwd: cwd, model: activeModel,
            permissionMode: adoptedMode.rawValue, agentVersion: agentVersion)))
      step.signals += [
        .session(id: sid),
        .modeAdopted(adoptedMode.rawValue),
        .settingsApplied(effort: activeEffort, model: activeModel),
      ]

      // Apply any picks chosen before the session opened if they differ from what the server set.
      if let pickedModel = model, pickedModel != snap.currentModel {
        let (_, msg) = calls.make(
          "session/set_config_option",
          .object([
            "sessionId": .string(sid), "configId": .string("model"),
            "value": .string(pickedModel),
          ]),
          for: .initialConfig)
        step.writes.append(msg)
      }
      if let pickedEffort = effort, pickedEffort != snap.currentEffort {
        let (_, msg) = calls.make(
          "session/set_config_option",
          .object([
            "sessionId": .string(sid),
            "configId": .string(isGrok ? "reasoning_effort" : "thought_level"),
            "value": .string(pickedEffort),
          ]),
          for: .initialConfig)
        step.writes.append(msg)
      }
      if explicitMode, modeID(adoptedMode) != snap.currentMode.map(modeID) {
        let (_, msg) = calls.make(
          "session/set_mode",
          .object(["sessionId": .string(sid), "modeId": .string(modeID(adoptedMode))]),
          for: .initialConfig)
        step.writes.append(msg)
      }

      let waiting = beforeSession
      beforeSession = []
      guard let first = waiting.first else { return }
      queued += waiting.dropFirst()
      if cancelsWhenStarted {
        cancelsWhenStarted = false
        step.events.append(.turnEnded(TurnSummary(outcome: .interrupted)))
        drainNextQueued(into: &step)
        return
      }
      step.writes.append(startPrompt(first))

    case .prompt:
      isTurnRunning = false
      approvals.removeAll()
      questionPrompts.removeAll()
      elicitations.removeAll()
      step.events += translator.finishOpenStream()
      let stopReason = result["stopReason"]?.stringValue
      let outcome: Transcript.TurnEnd =
        switch stopReason {
        case "cancelled": .interrupted
        case "refusal": .failed
        default: .completed
        }
      let failureText =
        stopReason == "refusal"
        ? String(localized: "\(name) refused this request.") : nil
      step.events.append(.turnEnded(TurnSummary(outcome: outcome, failureText: failureText)))
      drainNextQueued(into: &step)

    case .setMode(let target):
      step.signals.append(.modeAdopted(target.rawValue))
      step.signals.append(.changeAnswered(requestID: requestID, refusal: nil))

    case .setConfig:
      applyConfigOptions(result["configOptions"]?.arrayValue, into: &step)
      step.signals.append(.changeAnswered(requestID: requestID, refusal: nil))

    case .initialConfig:
      applyConfigOptions(result["configOptions"]?.arrayValue, into: &step)
    }
  }

  private mutating func failed(
    _ call: Call, id requestID: String, message: String, into step: inout Step
  ) {
    switch call {
    case .initialize:
      step.signals.append(.unusable(message))
    case .openSession:
      failOpen(message, into: &step)
    case .prompt:
      isTurnRunning = false
      approvals.removeAll()
      questionPrompts.removeAll()
      elicitations.removeAll()
      step.events += translator.finishOpenStream()
      let text = message.isEmpty ? String(localized: "\(name) failed.") : message
      step.events.append(.turnEnded(TurnSummary(outcome: .failed, failureText: text)))
      drainNextQueued(into: &step)
    case .setMode, .setConfig:
      let refusal = message.isEmpty ? String(localized: "\(name) refused the change.") : message
      step.signals.append(.changeAnswered(requestID: requestID, refusal: refusal))
    case .initialConfig:
      break
    }
  }

  private mutating func failOpen(_ message: String, into step: inout Step) {
    isOpeningSession = false
    cancelsWhenStarted = false
    let lower = message.lowercased()
    if lower.contains("auth") || lower.contains("sign in") || lower.contains("login")
      || lower.contains("unauthorized")
    {
      beforeSession = []
      step.signals.append(
        .unusable(isGrok ? "Run grok in a terminal to sign in, then send again." : Self.notSignedIn)
      )
      return
    }
    let waiting = beforeSession
    beforeSession = []
    guard !waiting.isEmpty else { return }
    step.events.append(.turnEnded(TurnSummary(outcome: .failed, failureText: message)))
    step.events += waiting.dropFirst().map {
      AgentEvent.queue(id: $0.uuid, .dropped(agent: name))
    }
  }

  private mutating func notified(update: JSONValue, into step: inout Step) {
    switch update["sessionUpdate"]?.stringValue {
    case "available_commands_update":
      if let commands = AgyInput.commands(from: update) {
        step.signals.append(.commands(commands))
      }
    case "config_option_update":
      applyConfigOptions(update["configOptions"]?.arrayValue, into: &step)
    case "current_mode_update":
      if let raw = update["currentModeId"]?.stringValue,
        let parsed = permissionMode(from: raw),
        mode != .bypass
      {
        mode = parsed
        step.signals.append(.modeAdopted(parsed.rawValue))
      }
    default:
      step.events += translator.translate(update: update)
    }
  }

  private mutating func applyConfigOptions(_ options: [JSONValue]?, into step: inout Step) {
    guard let options, !options.isEmpty else { return }
    let snap = AgyModels.updated(configOptions: options, merging: knownModels)
    if !snap.models.isEmpty {
      knownModels = snap.models
      step.signals.append(.models(snap.models))
    }
    if snap.currentModel != nil || snap.currentEffort != nil {
      step.signals.append(.settingsApplied(effort: snap.currentEffort, model: snap.currentModel))
    }
    if let currentMode = snap.currentMode, mode != .bypass {
      mode = currentMode
      step.signals.append(.modeAdopted(currentMode.rawValue))
    }
  }

  private func modeID(_ mode: PermissionMode) -> String {
    isGrok ? GrokPolicy.modeID(mode) : AgyPolicy.modeID(mode)
  }

  private func permissionMode(from raw: String) -> PermissionMode? {
    isGrok ? GrokPolicy.permissionMode(from: raw) : AgyPolicy.permissionMode(from: raw)
  }

  private mutating func drainNextQueued(into step: inout Step) {
    guard !queued.isEmpty else { return }
    let next = queued.removeFirst()
    step.events.append(.queue(id: next.uuid, .started))
    step.writes.append(startPrompt(next))
  }

  private mutating func openSession() -> JSONValue {
    isOpeningSession = true
    if let sid = sessionID {
      let (_, msg) = calls.make(
        "session/resume",
        .object([
          "sessionId": .string(sid),
          "cwd": .string(cwd),
          "mcpServers": .array([]),
        ]),
        for: .openSession)
      return msg
    }
    let (_, msg) = calls.make(
      "session/new",
      .object([
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ]),
      for: .openSession)
    return msg
  }

  private mutating func startPrompt(_ prompt: Waiting) -> JSONValue {
    isTurnRunning = true
    let (_, msg) = calls.make(
      "session/prompt",
      .object([
        "sessionId": .string(sessionID ?? ""),
        "prompt": prompt.input,
      ]),
      for: .prompt)
    return msg
  }
}
