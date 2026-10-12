import Foundation

/// One Codex session over `codex app-server` (docs/codex-app-server.md), with no process: each
/// command given and each line read returns what to write, what the conversation shows and
/// what the session learns. `CodexBackend` (the app) writes the lines; tests read them.
///
/// One process, one thread: the thread is started, or resumed with its settings passed again,
/// on the first prompt, and every turn after runs on it. Nothing is sent before `initialize`
/// is answered. A prompt sent while a turn runs is steered into it, named by the uuid Codex
/// echoes when it takes it; one an interrupt cut short is dropped at the turn's end, or, after
/// `interruptKeepingQueued`, sent again as the next turn.
public struct CodexSession: Sendable {
  public enum Command: Sendable, Equatable {
    /// `input` as `CodexInput.make` builds it; `uuid` names it in the transcript's queue.
    case prompt(input: JSONValue, uuid: String)
    case answer(requestID: String, decision: PermissionDecision)
    /// Stop: the turn ends, and what was queued behind it with it.
    case interrupt
    /// Esc, as in the extension: the turn ends, and what was queued runs next.
    case interruptKeepingQueued
    /// Picks: Codex takes them with the next turn, and keeps them for the turns after. A
    /// mode's approvals apply at once: what it lets through is accepted here meanwhile.
    case setMode(PermissionMode)
    case setModel(String)
    case setEffort(String)
    case rename(String)
  }

  public enum Signal: Sendable, Equatable {
    case models([ModelOption])
    /// The thread runs: `path` its rollout file, `codexHome` where Codex keeps its files.
    case thread(id: String, path: String?, codexHome: String?)
    case modeAdopted(String)
    /// Nothing can go through: not signed in, or the thread is another process's.
    case unusable(String)
    /// Codex's skills changed (`skills/changed`): a list read before is stale.
    case skillsChanged
  }

  public struct Step: Sendable, Equatable {
    public var writes: [JSONValue] = []
    public var events: [AgentEvent] = []
    public var signals: [Signal] = []

    public init() {}
  }

  /// `initialize`'s params, for a session and for a short-lived process: Drakar by name, the
  /// stable API, and no MCP startup burst (222 lines in one probe).
  public static func initializeParams(version: String) -> JSONValue {
    .object([
      "clientInfo": .object([
        "name": .string("drakar"), "title": .string("Drakar"), "version": .string(version),
      ]),
      "capabilities": .object([
        "experimentalApi": .bool(false),
        "optOutNotificationMethods": .array([.string("mcpServer/startupStatus/updated")]),
      ]),
    ])
  }

  public static let notSignedIn = String(
    localized: "Codex isn't signed in. Run `codex login` in a terminal, then send again.")
  public static let heldElsewhere = String(
    localized: "This thread is open in another Codex process. Close it there, then send again.")
  public static let noThread = String(localized: "Codex opened no thread. Send again.")

  private enum Call: Sendable {
    case initialize, account, models, thread, turnStart
    case steer(uuid: String, input: JSONValue, turn: String)
    case other
  }

  private enum Turn: Sendable, Equatable {
    case idle
    /// `turn/start` went; Codex has not said the id.
    case starting
    case running(String)
  }

  private struct Approval: Sendable {
    var id: CodexRPC.ID
    var method: String
  }

  private struct Waiting: Sendable {
    var input: JSONValue
    var uuid: String
  }

  private let cwd: String
  private let version: String
  private var threadID: String?
  private var isInitialized = false
  private var isThreadReady = false
  private var isOpeningThread = false
  private var codexHome: String?
  private var calls = CodexRPC.Calls<Call>()
  private var translator = CodexTranslator()
  private var turn = Turn.idle
  /// Prompts sent before the thread ran, oldest first.
  private var beforeThread: [Waiting] = []
  /// Prompts sent while a turn was starting, steered once it has an id.
  private var beforeTurnID: [Waiting] = []
  /// Stop was pressed while the thread was opening or a turn starting: the turn is
  /// interrupted once it has an id.
  private var interruptsWhenStarted = false
  /// The interrupt was Esc's: what was queued starts the next turn once this one ends.
  private var keepsQueued = false
  /// Prompts held back from a turn being interrupted, for the next.
  private var held: [Waiting] = []
  /// Steered prompts Codex has not echoed yet.
  private var steered: [Waiting] = []
  /// A steer Codex took into the running turn, and nothing the model did since: an interrupt
  /// leaves it in the thread unanswered. Codex 0.162 takes a steer at once, 0.160 only at the
  /// model's next step.
  private var steerAwaitsAnswer = false
  /// Steers already reported dropped or sent again: a late answer to them changes nothing.
  private var reportedDropped: Set<String> = []
  /// Approval requests waiting, by the id the transcript knows them by.
  private var approvals: [String: Approval] = [:]
  private var mode: PermissionMode
  private var model: String?
  private var effort: String?
  /// A name given before the thread ran, sent once it does.
  private var pendingName: String?

  /// `resuming` is the thread to resume; nil starts one. `model` and `effort` nil leave
  /// Codex's own (`config.toml`). `name` names the thread once it runs.
  public init(
    cwd: String, resuming: String?, mode: PermissionMode, model: String?, effort: String?,
    version: String, name: String? = nil
  ) {
    self.cwd = cwd
    threadID = resuming
    self.mode = mode
    self.model = model
    self.effort = effort
    self.version = version
    pendingName = name
  }

  public mutating func start() -> Step {
    var step = Step()
    step.writes.append(
      calls.make("initialize", Self.initializeParams(version: version), for: .initialize))
    return step
  }

  public mutating func send(_ command: Command) -> Step {
    var step = Step()
    switch command {
    case .prompt(let input, let uuid):
      let prompt = Waiting(input: input, uuid: uuid)
      guard isThreadReady else {
        beforeThread.append(prompt)
        if isInitialized, !isOpeningThread { step.writes.append(openThread()) }
        break
      }
      if let write = place(prompt) { step.writes.append(write) }
    case .answer(let requestID, let decision):
      guard let approval = approvals.removeValue(forKey: requestID) else { break }
      step.writes.append(
        CodexRPC.answer(approval.id, result: .object(["decision": CodexPolicy.decision(decision)])))
    case .interrupt, .interruptKeepingQueued:
      keepsQueued = command == .interruptKeepingQueued
      for key in approvals.keys.sorted() {
        if let approval = approvals[key] {
          step.writes.append(
            CodexRPC.answer(approval.id, result: .object(["decision": .string("cancel")])))
        }
      }
      approvals.removeAll()
      switch turn {
      case .running(let id): step.writes.append(interrupt(id))
      case .starting: interruptsWhenStarted = true
      case .idle: if !beforeThread.isEmpty { interruptsWhenStarted = true }
      }
    case .setMode(let mode):
      self.mode = mode
      for key in approvals.keys.sorted() {
        guard let approval = approvals[key], CodexPolicy.letsThrough(approval.method, in: mode)
        else { continue }
        approvals[key] = nil
        step.writes.append(Self.accept(approval.id))
        step.events.append(.permissionWithdrawn(requestID: key))
      }
    case .setModel(let model):
      self.model = model
    case .setEffort(let effort):
      self.effort = effort
    case .rename(let name):
      pendingName = name
      if isThreadReady { sendPendingName(into: &step) }
    }
    return step
  }

  public mutating func receive(_ message: JSONValue, at time: Date?) -> Step {
    var step = Step()
    guard let line = CodexRPC.Line(message) else { return step }
    switch line {
    case .response(let id, let result):
      if let call = calls.take(id) { answered(call, result: result, into: &step) }
    case .failure(let id, let text):
      if let call = calls.take(id) { failed(call, message: text, into: &step) }
    case .request(let id, let method, _):
      if method == "item/commandExecution/requestApproval"
        || method == "item/fileChange/requestApproval"
      {
        if CodexPolicy.letsThrough(method, in: mode) {
          step.writes.append(Self.accept(id))
        } else {
          approvals[id.text] = Approval(id: id, method: method)
          step.events += translator.translate(message, at: time)
        }
      } else {
        step.writes.append(CodexRPC.refusal(id, message: "Drakar does not answer \(method)."))
        step.events.append(
          .note(
            .init(
              text: String(
                localized:
                  "Codex asked for something Drakar can't answer yet (\(method)), so it was refused."
              ))))
      }
    case .notification(let method, let params):
      let endsTurn = notified(method, params: params, into: &step)
      step.events += translator.translate(message, at: time)
      if endsTurn {
        // A completed turn leaves in-flight steers to their own answers; one that was cut
        // short took them down with it, unless Esc cut it: they start the next turn.
        let status = params["turn"]?["status"]?.stringValue
        var again = held
        if status == "interrupted" || status == "failed" {
          if keepsQueued {
            again += steered
            // Taken but never answered: a turn with no input of its own has the model answer
            // it, where sending it again would say it twice.
            if again.isEmpty, steerAwaitsAnswer {
              again.append(Waiting(input: .array([]), uuid: UUID().uuidString.lowercased()))
            }
          } else {
            step.events += steered.map { AgentEvent.queue(id: $0.uuid, .dropped(agent: "Codex")) }
          }
          reportedDropped.formUnion(steered.map(\.uuid))
          steered = []
        }
        keepsQueued = false
        steerAwaitsAnswer = false
        held = []
        for prompt in again {
          if let write = place(prompt) { step.writes.append(write) }
        }
      }
    }
    return step
  }

  private mutating func answered(_ call: Call, result: JSONValue, into step: inout Step) {
    switch call {
    case .initialize:
      isInitialized = true
      codexHome = result["codexHome"]?.stringValue
      step.writes += [
        CodexRPC.notification("initialized"),
        calls.make("account/read", .object([:]), for: .account),
        calls.make("model/list", .object([:]), for: .models),
      ]
      if !beforeThread.isEmpty, !isOpeningThread { step.writes.append(openThread()) }
    case .account:
      // Signed in or not, `requiresOpenaiAuth` is true: not signed in is no account
      // (verified 2026-10-07).
      if result["account"] == nil || result["account"] == .null {
        step.signals.append(.unusable(Self.notSignedIn))
      }
    case .models:
      step.signals.append(.models(CodexModels.list(result)))
    case .thread:
      let thread = result["thread"] ?? .null
      guard let id = thread["id"]?.stringValue else {
        return threadFailed(Self.noThread, into: &step)
      }
      isOpeningThread = false
      threadID = id
      isThreadReady = true
      step.events.append(
        .sessionStarted(
          SessionInfo(
            sessionID: id, cwd: thread["cwd"]?.stringValue ?? cwd,
            model: result["model"]?.stringValue ?? thread["model"]?.stringValue,
            agentVersion: thread["cliVersion"]?.stringValue)))
      step.signals += [
        .thread(id: id, path: thread["path"]?.stringValue, codexHome: codexHome),
        .modeAdopted(mode.rawValue),
      ]
      // A name given meanwhile replaces the thread's own, which is not shown over it.
      if pendingName != nil {
        sendPendingName(into: &step)
      } else if let name = thread["name"]?.stringValue, !name.isEmpty {
        step.events.append(.title(.custom(name)))
      }
      let waiting = beforeThread
      beforeThread = []
      guard let first = waiting.first else { return }
      step.writes.append(startTurn(first))
      beforeTurnID += waiting.dropFirst()
    case .turnStart:
      if let id = result["turn"]?["id"]?.stringValue { turnStarted(id, into: &step) }
    case .steer, .other:
      break
    }
  }

  private mutating func failed(_ call: Call, message: String, into step: inout Step) {
    switch call {
    case .initialize:
      step.signals.append(.unusable(message))
    case .thread:
      threadFailed(message, into: &step)
    case .turnStart:
      turn = .idle
      interruptsWhenStarted = false
      step.events.append(.turnEnded(TurnSummary(outcome: .failed, failureText: message)))
      step.events += beforeTurnID.map { AgentEvent.queue(id: $0.uuid, .dropped(agent: "Codex")) }
      beforeTurnID = []
    case .steer(let uuid, let input, let steeredTurn):
      steered.removeAll { $0.uuid == uuid }
      if reportedDropped.remove(uuid) != nil { break }
      if message.contains("no active turn") {
        // The turn ended between the prompt and the steer: it starts the next one.
        if turn == .running(steeredTurn) { turn = .idle }
        if let write = place(Waiting(input: input, uuid: uuid)) { step.writes.append(write) }
      } else {
        step.events.append(.queue(id: uuid, .dropped(agent: "Codex")))
      }
    case .account, .models, .other:
      break
    }
  }

  /// The thread did not open: the prompts waiting for it end, the first as a failed turn.
  private mutating func threadFailed(_ message: String, into step: inout Step) {
    isOpeningThread = false
    interruptsWhenStarted = false
    let waiting = beforeThread
    beforeThread = []
    if message.contains("active writer") {
      step.signals.append(.unusable(Self.heldElsewhere))
      return
    }
    guard !waiting.isEmpty else { return }
    step.events.append(.turnEnded(TurnSummary(outcome: .failed, failureText: message)))
    step.events += waiting.dropFirst().map {
      AgentEvent.queue(id: $0.uuid, .dropped(agent: "Codex"))
    }
  }

  /// The session's bookkeeping for a notification; true when it ended the running turn.
  private mutating func notified(_ method: String, params: JSONValue, into step: inout Step)
    -> Bool
  {
    switch method {
    case "turn/started":
      if let id = params["turn"]?["id"]?.stringValue { turnStarted(id, into: &step) }
    case "turn/completed":
      let id = params["turn"]?["id"]?.stringValue
      if case .running(let current) = turn, let id, id != current { return false }
      if turn == .starting { return false }
      turn = .idle
      approvals.removeAll()
      return true
    case "thread/name/updated":
      if let name = params["threadName"]?.stringValue, !name.isEmpty {
        step.events.append(.title(.custom(name)))
      }
    case "skills/changed":
      step.signals.append(.skillsChanged)
    case "serverRequest/resolved":
      if let id = CodexRPC.ID(params["requestId"]) { approvals[id.text] = nil }
    case "item/started":
      if params["item"]?["type"] == .string("userMessage"),
        let client = params["item"]?["clientId"]?.stringValue
      {
        if steered.contains(where: { $0.uuid == client }) { steerAwaitsAnswer = true }
        steered.removeAll { $0.uuid == client }
      } else {
        steerAwaitsAnswer = false
      }
    default:
      break
    }
    return false
  }

  /// The turn has its id, from `turn/start`'s answer or `turn/started`, whichever comes
  /// first: what waited for it goes now, or, when Stop was pressed meanwhile, is dropped (Esc:
  /// held for the next turn) and the turn interrupted.
  private mutating func turnStarted(_ id: String, into step: inout Step) {
    guard turn != .running(id) else { return }
    turn = .running(id)
    let waiting = beforeTurnID
    beforeTurnID = []
    guard interruptsWhenStarted else {
      step.writes += waiting.map { steer($0, into: id) }
      return
    }
    interruptsWhenStarted = false
    if keepsQueued {
      held += waiting
    } else {
      step.events += waiting.map { AgentEvent.queue(id: $0.uuid, .dropped(agent: "Codex")) }
    }
    step.writes.append(interrupt(id))
  }

  /// What to write to run `prompt` now: a turn of its own, a steer into the running turn, or
  /// nothing yet when the turn has no id.
  private mutating func place(_ prompt: Waiting) -> JSONValue? {
    switch turn {
    case .idle: return startTurn(prompt)
    case .starting:
      beforeTurnID.append(prompt)
      return nil
    case .running(let id): return steer(prompt, into: id)
    }
  }

  private static func accept(_ id: CodexRPC.ID) -> JSONValue {
    CodexRPC.answer(id, result: .object(["decision": .string("accept")]))
  }

  private mutating func sendPendingName(into step: inout Step) {
    guard let name = pendingName, let threadID else { return }
    pendingName = nil
    step.writes.append(
      calls.make(
        "thread/name/set",
        .object(["threadId": .string(threadID), "name": .string(name)]), for: .other))
  }

  private mutating func openThread() -> JSONValue {
    isOpeningThread = true
    var params = CodexPolicy.threadSettings(mode)
    params["cwd"] = .string(cwd)
    if let model { params["model"] = .string(model) }
    guard let threadID else { return calls.make("thread/start", .object(params), for: .thread) }
    params["threadId"] = .string(threadID)
    params["excludeTurns"] = .bool(true)
    return calls.make("thread/resume", .object(params), for: .thread)
  }

  private mutating func startTurn(_ prompt: Waiting) -> JSONValue {
    turn = .starting
    var params = CodexPolicy.turnSettings(mode)
    params["threadId"] = .string(threadID ?? "")
    params["input"] = prompt.input
    params["clientUserMessageId"] = .string(prompt.uuid)
    if let model { params["model"] = .string(model) }
    if let effort { params["effort"] = .string(effort) }
    return calls.make("turn/start", .object(params), for: .turnStart)
  }

  private mutating func steer(_ prompt: Waiting, into turn: String) -> JSONValue {
    steered.append(prompt)
    return calls.make(
      "turn/steer",
      .object([
        "threadId": .string(threadID ?? ""), "expectedTurnId": .string(turn),
        "input": prompt.input, "clientUserMessageId": .string(prompt.uuid),
      ]), for: .steer(uuid: prompt.uuid, input: prompt.input, turn: turn))
  }

  private mutating func interrupt(_ turn: String) -> JSONValue {
    calls.make(
      "turn/interrupt",
      .object(["threadId": .string(threadID ?? ""), "turnId": .string(turn)]), for: .other)
  }
}
