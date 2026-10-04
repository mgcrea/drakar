import Foundation

/// One line Claude Code writes on stdout under `--output-format stream-json`.
///
/// Decoding is lenient by design (`docs/claude-stream-json.md`): a line with an unknown
/// `type`, or a known type missing a field this decoder relies on, becomes `.unknown` with
/// the raw value attached instead of throwing. Only a line that is not JSON at all, or has
/// no `type`, throws.
public enum StreamMessage: Sendable, Equatable {
  case system(SystemEvent)
  /// One content block of an assistant message. The CLI emits one `assistant` line per
  /// block, all sharing `messageID`; `Transcript` merges them.
  case assistant(AssistantMessage)
  /// Tool results, written back as a user turn.
  case user(UserMessage)
  /// A raw Messages API stream event, only under `--include-partial-messages`.
  case streamEvent(StreamEvent, parentToolUseID: String?)
  case result(TurnResult)
  case controlRequest(ControlRequest)
  case controlResponse(ControlResponse)
  /// The CLI withdrew a request it sent, typically a `can_use_tool` it no longer needs.
  case controlCancelRequest(requestID: String)
  case rateLimit(JSONValue)
  case unknown(type: String, raw: JSONValue)

  public init(line: Data) throws {
    try self.init(json: JSONValue.parse(line))
  }

  public init(json: JSONValue) throws {
    guard let type = json["type"]?.stringValue else { throw StreamMessageError.missingType }
    let decoded: StreamMessage? =
      switch type {
      case "system": SystemEvent(json).map(StreamMessage.system)
      case "assistant": AssistantMessage(json).map(StreamMessage.assistant)
      case "user": UserMessage(json).map(StreamMessage.user)
      case "stream_event":
        json["event"].flatMap(StreamEvent.init).map {
          .streamEvent($0, parentToolUseID: json["parent_tool_use_id"]?.stringValue)
        }
      case "result": TurnResult(json).map(StreamMessage.result)
      case "control_request": ControlRequest(json).map(StreamMessage.controlRequest)
      case "control_response": ControlResponse(json).map(StreamMessage.controlResponse)
      case "control_cancel_request":
        json["request_id"]?.stringValue.map { .controlCancelRequest(requestID: $0) }
      case "rate_limit_event": .rateLimit(json["rate_limit_info"] ?? .null)
      default: nil
      }
    self = decoded ?? .unknown(type: type, raw: json)
  }
}

public enum StreamMessageError: Error, Equatable {
  case missingType
}

// MARK: - system

public enum SystemEvent: Sendable, Equatable {
  case initialized(SessionInfo)
  /// `requesting` before each API call.
  case status(String?)
  case other(subtype: String, raw: JSONValue)

  init?(_ json: JSONValue) {
    guard let subtype = json["subtype"]?.stringValue else { return nil }
    switch subtype {
    case "init":
      guard let info = SessionInfo(json) else { return nil }
      self = .initialized(info)
    case "status": self = .status(json["status"]?.stringValue)
    default: self = .other(subtype: subtype, raw: json)
    }
  }
}

/// What `system/init` says about the session that just started.
public struct SessionInfo: Sendable, Equatable {
  public var sessionID: String
  public var cwd: String?
  public var model: String?
  public var permissionMode: String?
  public var claudeCodeVersion: String?
  public var tools: [String]

  init?(_ json: JSONValue) {
    guard let sessionID = json["session_id"]?.stringValue else { return nil }
    self.sessionID = sessionID
    cwd = json["cwd"]?.stringValue
    model = json["model"]?.stringValue
    permissionMode = json["permissionMode"]?.stringValue
    claudeCodeVersion = json["claude_code_version"]?.stringValue
    tools = json["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }
}

// MARK: - assistant and user

public struct AssistantMessage: Sendable, Equatable {
  public var messageID: String
  public var model: String?
  public var content: [ContentBlock]
  /// Non-nil when a subagent wrote this, naming the `Task` tool call it runs under.
  public var parentToolUseID: String?
  /// The request's tokens. Every block of one message repeats the same object.
  public var usage: TokenUsage?
  /// `end_turn` on a message that ended the turn, `tool_use` on one that calls a tool.
  /// Transcript files repeat it on every block line; the live stream may leave it null.
  public var stopReason: String?

  init?(_ json: JSONValue) {
    guard let message = json["message"], let id = message["id"]?.stringValue else { return nil }
    messageID = id
    model = message["model"]?.stringValue
    content = ContentBlock.list(message["content"])
    parentToolUseID = json["parent_tool_use_id"]?.stringValue
    usage = TokenUsage(message["usage"])
    stopReason = message["stop_reason"]?.stringValue
  }
}

public struct UserMessage: Sendable, Equatable {
  public var content: [ContentBlock]
  public var parentToolUseID: String?

  init?(_ json: JSONValue) {
    guard let message = json["message"] else { return nil }
    content = ContentBlock.list(message["content"])
    parentToolUseID = json["parent_tool_use_id"]?.stringValue
  }
}

public enum ContentBlock: Sendable, Equatable {
  case text(String)
  /// Often empty: the CLI may send only the signature and a summary elsewhere.
  case thinking(String)
  case toolUse(id: String, name: String, input: JSONValue)
  case toolResult(toolUseID: String, content: String, isError: Bool)
  case other(type: String)

  /// Message content is either a bare string or an array of blocks.
  static func list(_ json: JSONValue?) -> [ContentBlock] {
    switch json {
    case .string(let text): [.text(text)]
    case .array(let blocks): blocks.compactMap(ContentBlock.init)
    default: []
    }
  }

  init?(_ json: JSONValue) {
    guard let type = json["type"]?.stringValue else { return nil }
    switch type {
    case "text": self = .text(json["text"]?.stringValue ?? "")
    case "thinking": self = .thinking(json["thinking"]?.stringValue ?? "")
    case "tool_use":
      guard let id = json["id"]?.stringValue, let name = json["name"]?.stringValue else {
        return nil
      }
      self = .toolUse(id: id, name: name, input: json["input"] ?? .object([:]))
    case "tool_result":
      guard let id = json["tool_use_id"]?.stringValue else { return nil }
      self = .toolResult(
        toolUseID: id, content: Self.flattenedText(json["content"]),
        isError: json["is_error"]?.boolValue ?? false)
    default: self = .other(type: type)
    }
  }

  /// A tool result's content is a string, or an array of text (and image) blocks.
  private static func flattenedText(_ json: JSONValue?) -> String {
    switch json {
    case .string(let text): text
    case .array(let blocks): blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    default: ""
    }
  }
}

// MARK: - stream events

public enum StreamEvent: Sendable, Equatable {
  case messageStart(messageID: String)
  case blockStart(index: Int, block: ContentBlock)
  case blockDelta(index: Int, delta: Delta)
  case blockStop(index: Int)
  case messageDelta(stopReason: String?)
  case messageStop
  case other(type: String)

  public enum Delta: Sendable, Equatable {
    case text(String)
    case thinking(String)
    /// A fragment of a tool call's input; only the concatenation of all of them parses.
    case inputJSON(String)
    case signature
    case other(type: String)
  }

  init?(_ json: JSONValue) {
    guard let type = json["type"]?.stringValue else { return nil }
    switch type {
    case "message_start":
      guard let id = json["message"]?["id"]?.stringValue else { return nil }
      self = .messageStart(messageID: id)
    case "content_block_start":
      guard let index = json["index"]?.intValue,
        let block = json["content_block"].flatMap(ContentBlock.init)
      else { return nil }
      self = .blockStart(index: index, block: block)
    case "content_block_delta":
      guard let index = json["index"]?.intValue, let delta = json["delta"],
        let deltaType = delta["type"]?.stringValue
      else { return nil }
      let decoded: Delta =
        switch deltaType {
        case "text_delta": .text(delta["text"]?.stringValue ?? "")
        case "thinking_delta": .thinking(delta["thinking"]?.stringValue ?? "")
        case "input_json_delta": .inputJSON(delta["partial_json"]?.stringValue ?? "")
        case "signature_delta": .signature
        default: .other(type: deltaType)
        }
      self = .blockDelta(index: index, delta: decoded)
    case "content_block_stop":
      guard let index = json["index"]?.intValue else { return nil }
      self = .blockStop(index: index)
    case "message_delta":
      self = .messageDelta(stopReason: json["delta"]?["stop_reason"]?.stringValue)
    case "message_stop": self = .messageStop
    default: self = .other(type: type)
    }
  }
}

// MARK: - result

/// The end of a turn. The process stays alive for the next prompt.
public struct TurnResult: Sendable, Equatable {
  /// `success`, or an error subtype such as `error_max_turns`.
  public var subtype: String
  public var isError: Bool
  public var sessionID: String?
  public var text: String?
  public var totalCostUSD: Double?
  public var durationMS: Int?
  public var numTurns: Int?
  public var stopReason: String?
  /// Why the turn ended: `completed`, or `aborted_streaming` after an interrupt.
  public var terminalReason: String?

  /// An interrupt ends the turn as `error_during_execution` with `is_error: true`; it is
  /// the user's own doing and must not be shown as a failure.
  public var wasInterrupted: Bool { terminalReason == "aborted_streaming" }

  init?(_ json: JSONValue) {
    guard let subtype = json["subtype"]?.stringValue else { return nil }
    self.subtype = subtype
    isError = json["is_error"]?.boolValue ?? (subtype != "success")
    sessionID = json["session_id"]?.stringValue
    text = json["result"]?.stringValue
    totalCostUSD = json["total_cost_usd"]?.numberValue
    durationMS = json["duration_ms"]?.intValue
    numTurns = json["num_turns"]?.intValue
    stopReason = json["stop_reason"]?.stringValue
    terminalReason = json["terminal_reason"]?.stringValue
  }
}

// MARK: - control

/// A request from the CLI that must be answered on stdin, or the turn waits forever.
public struct ControlRequest: Sendable, Equatable {
  public var requestID: String
  public var kind: Kind

  public enum Kind: Sendable, Equatable {
    case canUseTool(PermissionRequest)
    case other(subtype: String, raw: JSONValue)
  }

  init?(_ json: JSONValue) {
    guard let id = json["request_id"]?.stringValue, let request = json["request"],
      let subtype = request["subtype"]?.stringValue
    else { return nil }
    requestID = id
    switch subtype {
    case "can_use_tool":
      guard let permission = PermissionRequest(request) else { return nil }
      kind = .canUseTool(permission)
    default: kind = .other(subtype: subtype, raw: request)
    }
  }
}

/// "May I run this?" Sent only under `--permission-prompt-tool stdio`, and only for what
/// the user's settings do not already allow.
public struct PermissionRequest: Sendable, Equatable {
  public var toolName: String
  public var displayName: String?
  public var input: JSONValue
  public var description: String?
  /// Ready-made "always allow" answers (`addRules`, `addDirectories`, `setMode`), passed
  /// back as `updatedPermissions` when the user picks one.
  public var suggestions: [JSONValue]
  public var blockedPath: String?

  init?(_ request: JSONValue) {
    guard let toolName = request["tool_name"]?.stringValue else { return nil }
    self.toolName = toolName
    displayName = request["display_name"]?.stringValue
    input = request["input"] ?? .object([:])
    description = request["description"]?.stringValue
    suggestions = request["permission_suggestions"]?.arrayValue ?? []
    blockedPath = request["blocked_path"]?.stringValue
  }
}

/// The CLI's answer to a request we sent, `initialize` first among them.
public struct ControlResponse: Sendable, Equatable {
  public var requestID: String
  public var isSuccess: Bool
  public var response: JSONValue?
  public var error: String?

  init?(_ json: JSONValue) {
    guard let body = json["response"], let id = body["request_id"]?.stringValue else {
      return nil
    }
    requestID = id
    isSuccess = body["subtype"]?.stringValue == "success"
    response = body["response"]
    error = body["error"]?.stringValue
  }
}
