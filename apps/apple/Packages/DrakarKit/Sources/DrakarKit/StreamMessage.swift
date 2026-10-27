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
  /// Where a prompt sent with a `uuid` has got to: `queued`, `started` once the CLI takes
  /// it into a turn, `completed`, or `cancelled`, `discarded`, `refused`.
  case commandLifecycle(commandUUID: String, state: String)
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
      case "command_lifecycle":
        json["command_uuid"]?.stringValue.flatMap { id in
          json["state"]?.stringValue.map { .commandLifecycle(commandUUID: id, state: $0) }
        }
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
  /// `requesting` before each API call; `permissionMode` set when the mode changed, by a
  /// `set_permission_mode` or the CLI itself.
  case status(String?, permissionMode: String?)
  /// The conversation was summarised to free context: `auto` or `manual` (`/compact`), and
  /// how many tokens it held before.
  case compacted(trigger: String?, preTokens: Int?)
  /// A request failed and will be tried again.
  case apiRetry(APIRetry)
  /// A note the CLI shows its own user, such as fast mode being turned off; `isError` when
  /// it is coloured as one.
  case notification(text: String, isError: Bool)
  /// A subagent started, worked, changed status or ended.
  case task(TaskEvent)
  /// The commands and skills changed mid-session (a plugin or skill reloaded): the new
  /// `commands` list, shaped as `initialize`'s.
  case commandsChanged(JSONValue)
  /// An MCP server says the step a URL elicitation sent the person to is done, before its
  /// tool's result (2.1.311, `Fixture.elicitation`).
  case elicitationComplete(serverName: String, elicitationID: String?)
  case other(subtype: String, raw: JSONValue)

  init?(_ json: JSONValue) {
    guard let subtype = json["subtype"]?.stringValue else { return nil }
    switch subtype {
    case "init":
      guard let info = SessionInfo(json) else { return nil }
      self = .initialized(info)
    case "status":
      self = .status(
        json["status"]?.stringValue, permissionMode: json["permissionMode"]?.stringValue)
    case "compact_boundary":
      let metadata = json["compact_metadata"]
      self = .compacted(
        trigger: metadata?["trigger"]?.stringValue, preTokens: metadata?["pre_tokens"]?.intValue)
    case "api_retry":
      self = .apiRetry(
        APIRetry(
          attempt: json["attempt"]?.intValue, maxRetries: json["max_retries"]?.intValue,
          delayMS: json["retry_delay_ms"]?.intValue))
    case "notification":
      guard let text = json["text"]?.stringValue else { return nil }
      self = .notification(text: text, isError: json["color"]?.stringValue == "error")
    case "commands_changed":
      guard let commands = json["commands"] else { return nil }
      self = .commandsChanged(commands)
    case "elicitation_complete":
      guard let server = json["mcp_server_name"]?.stringValue else { return nil }
      self = .elicitationComplete(
        serverName: server, elicitationID: json["elicitation_id"]?.stringValue)
    case _ where TaskEvent.Kind(rawValue: subtype) != nil:
      guard let event = TaskEvent(json, subtype: subtype) else { return nil }
      self = .task(event)
    default: self = .other(subtype: subtype, raw: json)
    }
  }
}

/// `system/api_retry`: which attempt is next, of how many, after how long.
public struct APIRetry: Sendable, Equatable {
  public var attempt: Int?
  public var maxRetries: Int?
  public var delayMS: Int?

  public init(attempt: Int?, maxRetries: Int?, delayMS: Int?) {
    self.attempt = attempt
    self.maxRetries = maxRetries
    self.delayMS = delayMS
  }
}

/// What `system/init` says about the session that just started.
public struct SessionInfo: Sendable, Equatable {
  public var sessionID: String
  public var cwd: String?
  public var model: String?
  public var permissionMode: String?
  /// The version of the agent's CLI that runs the session: `claude_code_version` for Claude Code.
  public var agentVersion: String?
  /// `none` for a subscription login, else where the API key came from.
  public var apiKeySource: String?
  public var tools: [String]

  public init(
    sessionID: String, cwd: String? = nil, model: String? = nil, permissionMode: String? = nil,
    agentVersion: String? = nil, apiKeySource: String? = nil, tools: [String] = []
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.model = model
    self.permissionMode = permissionMode
    self.agentVersion = agentVersion
    self.apiKeySource = apiKeySource
    self.tools = tools
  }

  init?(_ json: JSONValue) {
    guard let sessionID = json["session_id"]?.stringValue else { return nil }
    self.sessionID = sessionID
    cwd = json["cwd"]?.stringValue
    model = json["model"]?.stringValue
    permissionMode = json["permissionMode"]?.stringValue
    agentVersion = json["claude_code_version"]?.stringValue
    apiKeySource = json["apiKeySource"]?.stringValue
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
  /// The `answers` of the structured result beside a lone tool result, which only
  /// `AskUserQuestion`'s has: `tool_use_result` on the stream, `toolUseResult` in a
  /// transcript. Kept alone, since a `Read`'s holds the whole file.
  public var questionAnswers: [String: String]?
  /// An `Agent` call's report, from the same structured result.
  public var agentReport: AgentReport?
  /// The images and documents sent with a prompt, as a transcript file keeps them.
  public var attachments: [AttachmentPreview]
  /// Written by the CLI for the model, not by the person: a skill's text after its `Skill`
  /// call. The stream's `isSynthetic` is the transcript file's `isMeta`.
  public var isSynthetic: Bool

  init?(_ json: JSONValue) {
    guard let message = json["message"] else { return nil }
    content = ContentBlock.list(message["content"])
    attachments = (message["content"]?.arrayValue ?? []).compactMap(AttachmentPreview.init)
    parentToolUseID = json["parent_tool_use_id"]?.stringValue
    isSynthetic = json["isSynthetic"]?.boolValue == true
    let structured = json["tool_use_result"] ?? json["toolUseResult"]
    agentReport = AgentReport(structured)
    if case .object(let answers)? = structured?["answers"] {
      let strings = answers.compactMapValues(\.stringValue).filter { !$0.value.isEmpty }
      questionAnswers = strings.isEmpty ? nil : strings
    }
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
  /// the user's own doing and must not be shown as a failure. `aborted_streaming` while the
  /// model wrote, `aborted_tools` while a tool ran: the CLI counts both as aborted.
  public var wasInterrupted: Bool {
    terminalReason == "aborted_streaming" || terminalReason == "aborted_tools"
  }
  /// Why an `error_*` turn failed, such as "Reached maximum number of turns (3)". A failed
  /// `success` (an API error) says it in `text` instead.
  public var errors: [String]

  /// What to tell the person about a turn that failed; nil for one that did not, or that
  /// they interrupted.
  public var failureText: String? {
    guard isError, !wasInterrupted else { return nil }
    let reason = errors.isEmpty ? (text ?? "") : errors.joined(separator: "\n")
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? String(localized: "The turn failed (\(subtype)).") : trimmed
  }

  init?(_ json: JSONValue) {
    guard let subtype = json["subtype"]?.stringValue else { return nil }
    self.subtype = subtype
    isError = json["is_error"]?.boolValue ?? (subtype != "success")
    sessionID = json["session_id"]?.stringValue
    errors = json["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
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
    /// An MCP server asking the person something. Sent whatever the client registered, and
    /// waited on with no deadline.
    case elicitation(Elicitation)
    /// Requests the CLI sends only to a client that registered for them in `initialize`
    /// (hooks, SDK MCP servers, dialog kinds), which Drakar does not.
    case other(subtype: String, raw: JSONValue)
  }

  /// What goes back without asking the person: anything Drakar cannot serve is refused as
  /// the SDK refuses it, so that the CLI never waits on a request nobody will answer. Nil
  /// for a permission and an elicitation, which are the person's.
  public var reply: ClientMessage? {
    switch kind {
    case .canUseTool, .elicitation: nil
    case .other(let subtype, _):
      .refuse(requestID: requestID, error: "Unsupported control request subtype: \(subtype)")
    }
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
    case "elicitation":
      // One with nothing to show still waits, as a question that can only be declined.
      kind = .elicitation(
        Elicitation(claudeRequest: request)
          ?? Elicitation(
            serverName: "", displayName: nil, message: "", elicitationID: nil, title: nil,
            description: nil, content: .unsupported))
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
  /// Set on a request only the person can answer, such as `AskUserQuestion`'s.
  public var requiresUserInteraction: Bool
  /// The call it asks about, which is also its transcript entry's id.
  public var toolUseID: String?
  /// What the call does, read once from its name and input.
  public var kind: ToolKind
  /// An `AskUserQuestion` waiting on a choice, not a tool waiting on permission.
  public var isChoice: Bool { kind == .question }

  public init(
    toolName: String, displayName: String? = nil, input: JSONValue, description: String? = nil,
    toolUseID: String?, kind: ToolKind
  ) {
    self.toolName = toolName
    self.displayName = displayName
    self.input = input
    self.description = description
    suggestions = []
    blockedPath = nil
    requiresUserInteraction = false
    self.toolUseID = toolUseID
    self.kind = kind
  }

  init?(_ request: JSONValue) {
    guard let toolName = request["tool_name"]?.stringValue else { return nil }
    self.toolName = toolName
    displayName = request["display_name"]?.stringValue
    input = request["input"] ?? .object([:])
    description = request["description"]?.stringValue
    suggestions = request["permission_suggestions"]?.arrayValue ?? []
    blockedPath = request["blocked_path"]?.stringValue
    requiresUserInteraction = request["requires_user_interaction"]?.boolValue ?? false
    toolUseID = request["tool_use_id"]?.stringValue
    kind = ClaudeTools.kind(name: toolName, input: input)
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
