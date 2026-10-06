import Foundation

/// One line Drakar writes to Claude Code's stdin under `--input-format stream-json`.
public enum ClientMessage: Sendable, Equatable {
  /// First, before any prompt. The answer is a `control_response` carrying the slash
  /// commands, skills and models.
  case initialize(requestID: String)
  /// A user turn. `context` blocks go ahead of the text, as the extension's chat sends
  /// the open file or the selection (`EditorSelection.promptContext`).
  case prompt(String, context: [String] = [])
  /// The answer to a `can_use_tool` request.
  case permission(requestID: String, PermissionDecision)
  /// Stop the turn in progress. Sent by the VS Code extension; not yet exercised against
  /// the CLI here (`docs/claude-stream-json.md`).
  case interrupt(requestID: String)
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

  public var json: JSONValue {
    switch self {
    case .initialize(let id):
      Self.controlRequest(id, ["subtype": .string("initialize"), "hooks": .null])
    case .prompt(let text, let context):
      .object([
        "type": .string("user"),
        "session_id": .string(""),
        "parent_tool_use_id": .null,
        "message": .object([
          "role": .string("user"),
          "content": context.isEmpty
            ? .string(text)
            : .array(
              (context + [text]).map { .object(["type": .string("text"), "text": .string($0)]) }),
        ]),
      ])
    case .permission(let id, let decision):
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("success"),
          "request_id": .string(id),
          "response": decision.json,
        ]),
      ])
    case .interrupt(let id):
      Self.controlRequest(id, ["subtype": .string("interrupt")])
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
    }
  }

  public func line() throws -> Data {
    try json.line()
  }

  private static func controlRequest(_ id: String, _ request: [String: JSONValue]) -> JSONValue {
    .object([
      "type": .string("control_request"),
      "request_id": .string(id),
      "request": .object(request),
    ])
  }
}

public enum PermissionDecision: Sendable, Equatable {
  /// Run the tool. `updatedInput` is the input to run it with: the request's own, or one
  /// the user edited. `updatedPermissions` carries any of the request's suggestions the
  /// user chose ("always allow"), passed back as they arrived.
  case allow(updatedInput: JSONValue, updatedPermissions: [JSONValue] = [])
  /// Refuse, with the reason the model is told.
  case deny(message: String)

  var json: JSONValue {
    switch self {
    case .allow(let input, let permissions):
      var object: [String: JSONValue] = ["behavior": .string("allow"), "updatedInput": input]
      if !permissions.isEmpty { object["updatedPermissions"] = .array(permissions) }
      return .object(object)
    case .deny(let message):
      return .object(["behavior": .string("deny"), "message": .string(message)])
    }
  }
}
