import DrakarKit
import Foundation
import MCPKit

// The tools that start, steer or answer a session: listed only while Settings › MCP Server ›
// Allow writes is on, each gated `.requiresWrites`.

/// What answering an MCP server's form does, as `drakar_answer_question` takes it.
enum ElicitationAction: String, CaseIterable {
  case accept, decline, cancel
}

extension Tools {

  /// The tools that start, steer or answer a session, which a gateway in front of this server
  /// (Bastion) holds back while its own write switch is off: every tool gated
  /// `.requiresWrites`, in table order. A test keeps the two the same.
  public static let writeTools = [
    "drakar_start_session", "drakar_send_message", "drakar_interrupt", "drakar_end_session",
    "drakar_answer_question", "drakar_answer_permission",
  ]

  /// The write tools, added after the reads in the order `writeTools` lists them.
  static func addWriteTools(to table: inout ToolTable, source: some SessionSource) {
    addStartSession(to: &table, source: source)
    addSendMessage(to: &table, source: source)
    addInterrupt(to: &table, source: source)
    addEndSession(to: &table, source: source)
    addAnswerQuestion(to: &table, source: source)
    addAnswerPermission(to: &table, source: source)
  }

  private static func addStartSession(to table: inout ToolTable, source: some SessionSource) {
    table.add(
      MCPTool(
        name: "drakar_start_session",
        description:
          "Start a session in a project folder and send it its first prompt. It opens in the "
          + "folder's project window without taking the keyboard: a window already open gets "
          + "a tab it does not switch to, and a window opened for it stays behind. Returns "
          + "once the session has an id, with its row as drakar_list_sessions gives it. "
          + "drakar_list_projects lists the folders and the runner.",
        properties: [
          "folder": [
            "type": "string",
            "description":
              "The project's folder: an absolute path (~/ is the home folder), the runner's own for a runner session.",
          ],
          "runner": [
            "type": "string",
            "description":
              "The runner's name, to start it on the runner; left out or \"this-mac\", on this Mac.",
          ],
          "prompt": ["type": "string", "description": "The first message."],
          "agent": [
            "type": "string",
            "enum": .array(Agent.allCases.map { .string($0.rawValue) }),
            "description":
              "The CLI that runs it; left out, the one Drakar's Settings pick. A runner session is always Claude Code.",
          ],
          "model": [
            "type": "string", "description": "The model to run; left out, the agent's default.",
          ],
        ],
        required: ["folder", "prompt"],
        gate: .requiresWrites,
        annotations: .mutating(destructive: false, idempotent: false))
    ) { arguments in
      let folder = try Arguments.requiredString(arguments["folder"], name: "folder")
      guard folder.hasPrefix("/") || folder.hasPrefix("~/") || folder == "~" else {
        throw SessionError("folder must be an absolute path, starting with / or ~/.")
      }
      // "this-mac" names this Mac, as drakar_list_sessions's runner filter takes it.
      let runner = try Arguments.string(arguments["runner"], name: "runner")
        .flatMap { matches(nil, runner: $0) ? nil : $0 }
      let prompt = try Arguments.requiredString(arguments["prompt"], name: "prompt")
      let agent = try Arguments.choice(arguments["agent"], name: "agent", as: Agent.self)
      if runner != nil, agent == .codex {
        throw SessionError(
          "A runner's sessions are Claude Code's: leave agent out or pass \"claude\".")
      }
      let model = try Arguments.string(arguments["model"], name: "model")
      if let refusal = await source.workRefusal() { throw SessionError(refusal) }

      let id = try await source.start(
        StartRequest(folder: folder, runner: runner, prompt: prompt, agent: agent, model: model))
      // Started and gone again before it could be read: the id is still the answer.
      let session = await source.detail(of: id).map { Encoding.row($0.row) } ?? ["id": .string(id)]
      return .answer("Started \(id) in \(folder).", ["session": session])
    }
  }

  private static func addSendMessage(to table: inout ToolTable, source: some SessionSource) {
    table.add(
      MCPTool(
        name: "drakar_send_message",
        description:
          "Send a session a message, as its composer does: now when it can take one, queued "
          + "behind the running turn when one runs. A session held in the background is taken "
          + "back into its project's window first, and an ended one resumed there, without "
          + "taking the keyboard. Refused when the session is read-only, or held by another "
          + "Drakar or runs elsewhere. Returns outcome: sent or queued.",
        properties: [
          "session": sessionArgument,
          "text": ["type": "string", "description": "The message."],
        ],
        required: ["session", "text"],
        gate: .requiresWrites,
        annotations: .mutating(destructive: false, idempotent: false))
    ) { arguments in
      let id = try await Arguments.session(arguments["session"], in: source)
      let text = try Arguments.requiredString(arguments["text"], name: "text")
      if let refusal = await source.workRefusal() { throw SessionError(refusal) }
      let outcome = try await source.send(to: id, text: text)
      let lede =
        outcome == .queued ? "Queued for \(id), behind its running turn." : "Sent to \(id)."
      return .answer(lede, ["outcome": .string(outcome.rawValue)])
    }
  }

  private static func addInterrupt(to table: inout ToolTable, source: some SessionSource) {
    table.add(
      MCPTool(
        name: "drakar_interrupt",
        description:
          "End a session's running turn, as Escape does. Messages queued behind it stay "
          + "queued.",
        properties: ["session": sessionArgument],
        required: ["session"],
        gate: .requiresWrites,
        annotations: .mutating(destructive: true, idempotent: true))
    ) { arguments in
      let id = try await Arguments.session(arguments["session"], in: source)
      try await source.interrupt(id)
      return .answer("Interrupted \(id).", ["ok": true])
    }
  }

  private static func addEndSession(to table: inout ToolTable, source: some SessionSource) {
    table.add(
      MCPTool(
        name: "drakar_end_session",
        description:
          "End a session, as End Session does: its process stops and its row stays, and a "
          + "later drakar_send_message resumes it (a runner session starts anew). A runner "
          + "session ends on the runner. Refused for a session held by another Drakar or "
          + "running elsewhere.",
        properties: ["session": sessionArgument],
        required: ["session"],
        gate: .requiresWrites,
        annotations: .mutating(destructive: true, idempotent: true))
    ) { arguments in
      let id = try await Arguments.session(arguments["session"], in: source)
      try await source.end(id)
      return .answer("Ended \(id).", ["ok": true])
    }
  }

  private static func addAnswerQuestion(to table: inout ToolTable, source: some SessionSource) {
    table.add(
      MCPTool(
        name: "drakar_answer_question",
        description:
          "Answer a question a session is waiting on, by its requestId from "
          + "drakar_needs_attention or drakar_get_session. A question (AskUserQuestion) takes "
          + "answers: every question's text to the label chosen, or to text of your own; "
          + "several labels of a multiSelect question joined with \", \". An MCP server's form "
          + "(an elicitation) takes action, and content with the form's values on accept; one "
          + "that asks the person to open a link can be declined or cancelled, not accepted. A "
          + "permission prompt is answered with drakar_answer_permission instead.",
        properties: [
          "session": sessionArgument,
          "request_id": ["type": "string", "description": "The request's requestId."],
          "answers": [
            "type": "object", "additionalProperties": ["type": "string"],
            "description": "For a question: each question's text to its answer.",
          ],
          "action": [
            "type": "string",
            "enum": .array(ElicitationAction.allCases.map { .string($0.rawValue) }),
            "description":
              "For a form: accept with content, decline, or cancel (dismiss without a choice).",
          ],
          "content": [
            "type": "object",
            "description": "For a form accepted: each field's key to its value.",
          ],
        ],
        required: ["session", "request_id"],
        gate: .requiresWrites,
        annotations: .mutating(destructive: false, idempotent: false))
    ) { arguments in
      let id = try await Arguments.session(arguments["session"], in: source)
      let requestID = try Arguments.requiredString(arguments["request_id"], name: "request_id")
      let (item, named) = try await pending(requestID, of: id, in: source)
      switch item {
      case .permission(_, let permission):
        guard permission.isChoice else {
          throw SessionError(
            "Request \(requestID) is a permission prompt: use drakar_answer_permission.")
        }
        // The input sent back is the request's own with the answers added, built here and
        // never taken from the caller, as the question panel answers.
        let answers = try questionAnswers(arguments["answers"], to: permission)
        try await source.answer(
          id, requestID: named,
          with: .allow(updatedInput: UserQuestion.answering(permission.input, with: answers)))
      case .elicitation(_, let elicitation):
        let answer = try elicitationAnswer(
          arguments["action"], content: arguments["content"], to: elicitation)
        try await source.answer(id, requestID: named, with: answer)
      }
      return .answer("Answered \(requestID).", ["ok": true])
    }
  }

  /// `value` read as an answer to every question `request` asks, as the question panel
  /// answers only once each has one. A question it does not ask is refused, so a typo is not
  /// sent as an unanswered question.
  static func questionAnswers(_ value: MCPKit.JSONValue?, to request: PermissionRequest) throws
    -> [String: String]
  {
    let asked = UserQuestion.list(request.input).map(\.question)
    let list = asked.map { "\"\($0)\"" }.joined(separator: ", ")
    guard let value, !value.isNull else {
      throw SessionError("Give answers: each question's text to its answer. It asks \(list).")
    }
    guard let fields = value.objectValue else {
      throw SessionError("answers must be an object of each question's text to its answer.")
    }
    var answers: [String: String] = [:]
    for (question, answer) in fields.sorted(by: { $0.key < $1.key }) {
      guard asked.contains(question) else {
        throw SessionError("The request does not ask \"\(question)\". It asks \(list).")
      }
      guard let text = try Arguments.string(answer, name: "Each answer") else {
        throw SessionError("The answer to \"\(question)\" is empty.")
      }
      answers[question] = text
    }
    let unanswered = asked.filter { answers[$0] == nil }
    guard unanswered.isEmpty else {
      throw SessionError(
        "Answer every question: "
          + unanswered.map { "\"\($0)\"" }.joined(separator: ", ") + " has no answer.")
    }
    return answers
  }

  /// The request `requestID` (a `RequestID` as the tools give it out) that session `id`
  /// waits on, or a refusal saying it is not waiting any more: none by that raw id, or one
  /// asking something else than the request the caller read, as a Codex id reused by a
  /// later process does. An id without its fingerprint is refused the same way.
  static func pending(_ requestID: String, of id: String, in source: some SessionSource)
    async throws -> (PendingItem, RequestID)
  {
    guard let detail = await source.detail(of: id) else { throw SessionIDs.unknown(id) }
    guard let request = RequestID(parsing: requestID),
      let pending = detail.pending.first(where: request.names)
    else {
      throw SessionError.noLongerWaiting(requestID)
    }
    return (pending, request)
  }

  /// An elicitation's answer from `action` and, on accept, `content` (the form's values). Only
  /// a form is accepted, as its card accepts only a form: a link is the person's to open, and
  /// a request Drakar cannot show can only be declined.
  static func elicitationAnswer(
    _ action: MCPKit.JSONValue?, content: MCPKit.JSONValue?, to elicitation: Elicitation
  ) throws -> ElicitationAnswer {
    guard let action = try Arguments.choice(action, name: "action", as: ElicitationAction.self)
    else {
      throw SessionError("Give action: accept, decline or cancel.")
    }
    switch action {
    case .decline: return .decline
    case .cancel: return .cancel
    case .accept:
      switch elicitation.content {
      case .form: break
      case .url, .nonWebLink:
        throw SessionError(
          "This asks the person to open a link; an agent can decline or cancel it, not accept it.")
      case .unsupported:
        throw SessionError(
          "Drakar cannot show this request, so it can be declined or cancelled, not accepted.")
      }
      guard let content, !content.isNull else {
        throw SessionError("Accepting this form needs its values in content.")
      }
      guard let fields = content.objectValue else {
        throw SessionError("content must be an object of the form's field keys to their values.")
      }
      return .accept(fields.mapValues(JSONBridge.drakar))
    }
  }

  // MARK: - Permissions

  private static func addAnswerPermission(to table: inout ToolTable, source: some SessionSource) {
    table.add(
      MCPTool(
        name: "drakar_answer_permission",
        description:
          "Allow or deny a tool call a session is waiting on, by its requestId from "
          + "drakar_needs_attention or drakar_get_session. The call runs with the input it "
          + "asked for. always applies some of the request's own suggestions, by index: only "
          + "those it lists, each lasting no longer than the session. A plan (ExitPlanMode) "
          + "allowed runs with every edit still asking; denied, it keeps planning, message "
          + "being what to change. Needs Let agents answer permission prompts in Drakar's "
          + "Settings › MCP Server. A question or an MCP server's form is answered with "
          + "drakar_answer_question instead.",
        properties: [
          "session": sessionArgument,
          "request_id": ["type": "string", "description": "The request's requestId."],
          "decision": [
            "type": "string",
            "enum": .array(PermissionAnswer.Verdict.allCases.map { .string($0.rawValue) }),
          ],
          "message": [
            "type": "string",
            "description": "On deny, the reason the session's model is told.",
          ],
          "interrupt": [
            "type": "boolean", "default": false,
            "description": "On deny, end the session's turn too.",
          ],
          "always": [
            "type": "array", "items": ["type": "integer", "minimum": 0],
            "description":
              "On allow, the indices of the request's suggestions to apply for the session.",
          ],
        ],
        required: ["session", "request_id", "decision"],
        gate: .requiresWrites,
        annotations: .mutating(destructive: false, idempotent: false))
    ) { arguments in
      guard await source.permissionsAllowed() else {
        throw SessionError(
          "Answering permission prompts is off. The person can turn on \"Let agents answer "
            + "permission prompts\" in Drakar's Settings › MCP Server.")
      }
      let id = try await Arguments.session(arguments["session"], in: source)
      let requestID = try Arguments.requiredString(arguments["request_id"], name: "request_id")
      guard
        let verdict = try Arguments.choice(
          arguments["decision"], name: "decision", as: PermissionAnswer.Verdict.self)
      else {
        throw SessionError("Give decision: allow or deny.")
      }
      let message = try Arguments.string(arguments["message"], name: "message")
      let interrupt = try Arguments.bool(arguments["interrupt"], name: "interrupt") ?? false
      let always = try indices(arguments["always"], name: "always")

      let (item, named) = try await pending(requestID, of: id, in: source)
      guard case .permission(_, let request) = item else {
        throw SessionError(
          "Request \(requestID) is an MCP server's form: use drakar_answer_question.")
      }
      let decision = try PermissionAnswer.decision(
        for: request, verdict: verdict, message: message, interrupt: interrupt, always: always)
      try await source.answer(id, requestID: named, with: decision)
      return .answer(
        "\(verdict == .allow ? "Allowed" : "Denied") \(requestID).", ["ok": true])
    }
  }

  /// A list of whole numbers; empty when absent or null.
  static func indices(_ value: MCPKit.JSONValue?, name: String) throws -> [Int] {
    guard let value, !value.isNull else { return [] }
    guard let items = value.arrayValue else {
      throw SessionError("\(name) must be a list of suggestion indices.")
    }
    return try items.map { item in
      guard let index = try Arguments.int(item, name: name) else {
        throw SessionError("\(name) must be a list of suggestion indices.")
      }
      return index
    }
  }
}
