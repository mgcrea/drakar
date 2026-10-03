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
