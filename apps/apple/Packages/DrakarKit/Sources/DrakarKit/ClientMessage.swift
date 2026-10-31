import Foundation

/// One line Drakar writes to Claude Code's stdin under `--input-format stream-json`.
public enum ClientMessage: Sendable, Equatable {
  /// First, before any prompt. The answer is a `control_response` carrying the slash
  /// commands, skills and models.
  case initialize(requestID: String)
  /// A user turn. `context` blocks go ahead of the text, as the extension's chat sends
  /// the open file or the selection (`EditorSelection.promptContext`). A `uuid` makes the
  /// CLI report where the prompt has got to (`command_lifecycle`), and names it to cancel.
  /// `attachments` (`Attachment.block`) go between the context and the text.
  case prompt(
    String, context: [String] = [], uuid: String? = nil, attachments: [JSONValue] = [])
  /// The answer to a `can_use_tool` request.
  case permission(requestID: String, PermissionDecision)
  /// Stop the turn in progress; with `cancelQueued`, drop the prompts waiting behind it too.
  case interrupt(requestID: String, cancelQueued: Bool = false)
  /// Take back a prompt sent while a turn ran, before the CLI picks it up. Answered with
  /// `{"cancelled": true}`, and a `cancelled` lifecycle line.
  case cancelQueued(requestID: String, uuid: String)
  /// The process's own account of its context: the window size, exact, and its breakdown.
  case contextUsage(requestID: String)
  /// Every MCP server the process would connect, with its status and tools. Answered before
  /// any prompt (docs/claude-stream-json.md, "Skills and MCP status").
  case mcpStatus(requestID: String)
  /// Switch the running session's model to `model` (a `value` of `initialize`'s `models`),
  /// from its next request. Answered with an empty success.
  case setModel(requestID: String, model: String)
  /// Switch the running session's permission mode; answered with `{"mode": …}`, then a
  /// `status` line. Bypass is refused unless the process started able to take it.
  case setPermissionMode(requestID: String, mode: String)
  /// Switch the running session's effort, as a flag setting: the process's alone, never
  /// written to `settings.json`. Answered with an empty success, a level the model does not
  /// take included (docs/claude-stream-json.md, "Effort").
  case setEffort(requestID: String, level: String)
  /// The process's settings; `applied` says the model and effort it runs with.
  case getSettings(requestID: String)
  /// Names the session as `/rename` does: the process appends the `custom-title` line and
  /// keeps the name for its own later writes (docs/claude-stream-json.md, "Session titles").
  case renameSession(requestID: String, title: String, sessionID: String)
  /// The person's answer to an `elicitation`, which the CLI passes to the server unchanged.
  case answerElicitation(requestID: String, ElicitationAnswer)
  /// Stop a running task: a shell, a Monitor or a subagent. Answered with an empty success,
  /// even for a task that has ended or never was (docs/claude-stream-json.md, "Task
  /// controls").
  case stopTask(requestID: String, taskID: String)
  /// Move a foreground tool call to the background, as Ctrl+B does. Answered with
  /// `{"backgrounded": …}`, or an error when the session has background tasks turned off
  /// (`BackgroundOutcome`).
  case backgroundCall(requestID: String, toolUseID: String)
  /// A shell or Monitor task's output so far, its tail when long (`TaskOutput`).
  case taskOutput(requestID: String, taskID: String)
  /// Put back the files as they were before the prompt `userMessageID` (the uuid it was sent
  /// with), or with `dryRun` only list them. Answered at once, starting no turn
  /// (`RewindResult`; docs/claude-stream-json.md, "Rewind").
  case rewindFiles(requestID: String, userMessageID: String, dryRun: Bool)
  /// Every permission rule the process applies, with where each came from and whether the
  /// edit command can remove it (`PermissionRulesState`).
  case listPermissionRules(requestID: String)
  /// The session's plan: `{exists: false}`, or its text and file (`PlanReply`). It never
  /// creates one.
  case getPlan(requestID: String)
  /// The answer to a request Drakar cannot serve, so that the CLI stops waiting on it.
  case refuse(requestID: String, error: String)

  public var json: JSONValue {
    switch self {
    case .initialize(let id):
      Self.controlRequest(id, ["subtype": .string("initialize"), "hooks": .null])
    case .prompt(let text, let context, let uuid, let attachments):
      .object(
        [
          "type": .string("user"),
          "session_id": .string(""),
          "parent_tool_use_id": .null,
          "message": .object([
            "role": .string("user"),
            "content": Self.content(text, context: context, attachments: attachments),
          ]),
        ].merging(uuid.map { ["uuid": .string($0)] } ?? [:]) { first, _ in first })
    case .permission(let id, let decision):
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("success"),
          "request_id": .string(id),
          "response": decision.json,
        ]),
      ])
    case .interrupt(let id, let cancelQueued):
      Self.controlRequest(
        id,
        ["subtype": .string("interrupt")].merging(
          cancelQueued ? ["cancel_queued": .bool(true)] : [:]
        ) { first, _ in first })
    case .cancelQueued(let id, let uuid):
      Self.controlRequest(
        id, ["subtype": .string("cancel_async_message"), "message_uuid": .string(uuid)])
    case .contextUsage(let id):
      // `summary`, not `full`: `full` counts each category through `count_tokens`.
      Self.controlRequest(
        id, ["subtype": .string("get_context_usage"), "detail": .string("summary")])
    case .mcpStatus(let id):
      Self.controlRequest(id, ["subtype": .string("mcp_status")])
    case .setModel(let id, let model):
      Self.controlRequest(id, ["subtype": .string("set_model"), "model": .string(model)])
    case .setPermissionMode(let id, let mode):
      Self.controlRequest(
        id, ["subtype": .string("set_permission_mode"), "mode": .string(mode)])
    case .setEffort(let id, let level):
      Self.controlRequest(
        id,
        [
          "subtype": .string("apply_flag_settings"),
          "settings": .object(["effortLevel": .string(level)]),
        ])
    case .getSettings(let id):
      Self.controlRequest(id, ["subtype": .string("get_settings")])
    case .renameSession(let id, let title, let sessionID):
      // `source: host` as the extension sends it.
      Self.controlRequest(
        id,
        [
          "subtype": .string("rename_session"), "title": .string(title),
          "source": .string("host"), "session_id": .string(sessionID),
        ])
    case .answerElicitation(let id, let answer):
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("success"),
          "request_id": .string(id),
          "response": answer.json,
        ]),
      ])
    case .stopTask(let id, let taskID):
      Self.controlRequest(id, ["subtype": .string("stop_task"), "task_id": .string(taskID)])
    case .backgroundCall(let id, let toolUseID):
      Self.controlRequest(
        id, ["subtype": .string("background_tasks"), "tool_use_id": .string(toolUseID)])
    case .taskOutput(let id, let taskID):
      Self.controlRequest(
        id, ["subtype": .string("get_task_output"), "task_id": .string(taskID)])
    case .rewindFiles(let id, let userMessageID, let dryRun):
      Self.controlRequest(
        id,
        [
          "subtype": .string("rewind_files"), "user_message_id": .string(userMessageID),
          "dry_run": .bool(dryRun),
        ])
    case .listPermissionRules(let id):
      Self.controlRequest(id, ["subtype": .string("list_permission_rules")])
    case .getPlan(let id):
      Self.controlRequest(id, ["subtype": .string("get_plan")])
    case .refuse(let id, let error):
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("error"), "request_id": .string(id), "error": .string(error),
        ]),
      ])
    }
  }

  public func line() throws -> Data {
    try json.line()
  }

  /// What a log keeps of `line()` when it may not keep all of it: an accepted form's values
  /// each `"<redacted>"`, its keys kept (the server's schema names them, not the person).
  /// Nil for a line that holds nothing the person typed, which a log keeps as it is.
  public func redactedLine() throws -> Data? {
    guard case .answerElicitation(let id, .accept(let content?)) = self else { return nil }
    let redacted = content.mapValues { _ in JSONValue.string("<redacted>") }
    return try Self.answerElicitation(requestID: id, .accept(redacted)).line()
  }

  /// A bare string for text alone; else blocks, the text last. A prompt of attachments alone
  /// has no text block, as the extension sends it.
  private static func content(_ text: String, context: [String], attachments: [JSONValue])
    -> JSONValue
  {
    guard !context.isEmpty || !attachments.isEmpty else { return .string(text) }
    let textBlocks = { (text: String) -> JSONValue in
      .object(["type": .string("text"), "text": .string(text)])
    }
    var blocks = context.map(textBlocks) + attachments
    if !text.isEmpty || !context.isEmpty { blocks.append(textBlocks(text)) }
    return .array(blocks)
  }

  private static func controlRequest(_ id: String, _ request: [String: JSONValue]) -> JSONValue {
    .object([
      "type": .string("control_request"),
      "request_id": .string(id),
      "request": .object(request),
    ])
  }
}

/// What the person did with an MCP server's question: `{action, content?}`.
public enum ElicitationAnswer: Sendable, Equatable {
  /// The form's values; nil for a link, opened.
  case accept([String: JSONValue]?)
  case decline
  /// Dismissed without a choice, as an interrupt does.
  case cancel

  var json: JSONValue {
    switch self {
    case .accept(let content?):
      .object(["action": .string("accept"), "content": .object(content)])
    case .accept(nil): .object(["action": .string("accept")])
    case .decline: .object(["action": .string("decline")])
    case .cancel: .object(["action": .string("cancel")])
    }
  }
}

public enum PermissionDecision: Codable, Sendable, Equatable {
  /// Run the tool. `updatedInput` is the input to run it with: the request's own, or one
  /// the user edited. `updatedPermissions` carries any of the request's suggestions the
  /// user chose ("always allow"), passed back as they arrived.
  case allow(updatedInput: JSONValue, updatedPermissions: [JSONValue] = [])
  /// Refuse, with the reason the model is told. `interrupt` ends the turn as well, as the
  /// extension's plain "No" does.
  case deny(message: String, interrupt: Bool = false)

  var json: JSONValue {
    switch self {
    case .allow(let input, let permissions):
      var object: [String: JSONValue] = ["behavior": .string("allow"), "updatedInput": input]
      if !permissions.isEmpty { object["updatedPermissions"] = .array(permissions) }
      return .object(object)
    case .deny(let message, let interrupt):
      var object: [String: JSONValue] = ["behavior": .string("deny"), "message": .string(message)]
      if interrupt { object["interrupt"] = .bool(true) }
      return .object(object)
    }
  }
}
