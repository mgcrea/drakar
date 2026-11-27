import Foundation

/// Antigravity's ACP notifications and requests (`agy acp`, docs/agy-acp.md) as agent events:
/// live lines through `translate`, `session/load`'s replayed updates through `history`.
public struct AgyTranslator: Sendable {
  private enum OpenStream: Sendable, Equatable {
    case text(id: String, accumulated: String)
    case thinking(id: String, accumulated: String)
  }

  private var nextItemID = 1
  private var openStream: OpenStream?
  /// Tool calls already started in this translator, so `tool_call_update` updates rather than
  /// re-adding them and permission requests know their latest details.
  private var toolCalls: [String: Transcript.ToolCall] = [:]

  public init() {}

  /// Translates one ACP `session/update` payload (its `params["update"]` object).
  public mutating func translate(update: JSONValue) -> [AgentEvent] {
    guard let kind = update["sessionUpdate"]?.stringValue else { return [] }
    switch kind {
    case "agent_message_chunk":
      guard let chunk = Self.chunkText(update["content"]), !chunk.isEmpty else { return [] }
      return appendText(chunk)
    case "agent_thought_chunk":
      guard let chunk = Self.chunkText(update["content"]), !chunk.isEmpty else { return [] }
      return appendThinking(chunk)
    case "tool_call", "tool_call_update":
      var events = finishOpenStream()
      events += translateToolCall(update)
      return events
    case "usage_update":
      guard let used = update["used"]?.intValue else { return [] }
      let window = update["size"]?.intValue
      return [
        .usage(
          .init(
            messageID: "agy-usage-\(nextItemID)",
            usage: TokenUsage(input: used, cacheCreation: 0, cacheRead: 0, output: 0),
            model: nil, window: window, at: nil))
      ]
    case "session_info_update":
      if let title = update["title"]?.stringValue, !title.isEmpty {
        return [.title(.ai(title))]
      }
      return []
    case "plan":
      let entries = update["entries"]?.arrayValue ?? []
      let todos: [Todo] = entries.compactMap { entry in
        guard let content = entry["content"]?.stringValue, !content.isEmpty else { return nil }
        let status: Todo.Status =
          switch entry["status"]?.stringValue {
          case "in_progress": .inProgress
          case "completed": .completed
          default: .pending
          }
        return Todo(content: content, activeForm: nil, status: status)
      }
      return todos.isEmpty ? [] : [.todos(todos)]
    default:
      return []
    }
  }

  /// Closes any open streaming text or thinking item (at turn end, or before a tool call).
  public mutating func finishOpenStream() -> [AgentEvent] {
    guard let open = openStream else { return [] }
    openStream = nil
    switch open {
    case .text(let id, let accumulated):
      return [.itemCompleted(.init(id: id, parent: nil, kind: .text(accumulated)))]
    case .thinking(let id, let accumulated):
      return [.itemCompleted(.init(id: id, parent: nil, kind: .thinking(accumulated)))]
    }
  }

  /// Translates a `session/request_permission` server request into a pending permission event.
  public mutating func permission(id: AgyRPC.ID, params: JSONValue) -> [AgentEvent] {
    let toolCall = params["toolCall"] ?? .null
    let options = (params["options"]?.arrayValue ?? []).compactMap(AgyPolicy.Option.init)
    let callID = toolCall["toolCallId"]?.stringValue
    let existing = callID.flatMap { toolCalls[$0] }
    let parsed = Self.toolCall(from: toolCall, fallback: existing)
    let name = parsed?.name ?? toolCall["name"]?.stringValue ?? String(localized: "Tool")
    let input = parsed?.input ?? toolCall["rawInput"] ?? toolCall["args"] ?? .object([:])
    let kind = parsed?.kind ?? .other
    let description =
      toolCall["args"]?["toolSummary"]?.stringValue
      ?? toolCall["rawInput"]?["toolSummary"]?.stringValue
    var request = PermissionRequest(
      toolName: name, displayName: Self.displayName(for: name), input: input,
      description: description, toolUseID: callID, kind: kind)
    request.suggestions = AgyPolicy.suggestions(from: options)
    return [.permissionRequested(.init(requestID: id.text, request: request))]
  }

  /// Folds `session/load`'s replayed `session/update` payloads into a finished conversation.
  public static func history(_ updates: [JSONValue]) -> [AgentEvent] {
    var translator = AgyTranslator()
    var events: [AgentEvent] = []
    var pendingUserBlocks: [JSONValue] = []
    var hasTurn = false

    func flushUser() {
      guard !pendingUserBlocks.isEmpty else { return }
      events += translator.finishOpenStream()
      if hasTurn { events.append(.turnOutcome(.completed)) }
      events.append(.prompt(prompt(from: pendingUserBlocks), running: false))
      pendingUserBlocks = []
      hasTurn = true
    }

    for update in updates {
      guard let kind = update["sessionUpdate"]?.stringValue else { continue }
      if kind == "user_message_chunk" {
        if let content = update["content"] { pendingUserBlocks.append(content) }
        continue
      }
      flushUser()
      events += translator.translate(update: update)
    }
    flushUser()
    events += translator.finishOpenStream()
    if hasTurn { events.append(.turnOutcome(.completed)) }
    return events
  }

  /// Parses replayed user content blocks back into a prompt, extracting editor context labels
  /// and `<attachment>` previews.
  private static func prompt(from blocks: [JSONValue]) -> AgentEvent.Prompt {
    var texts: [String] = []
    var labels: [String] = []
    var attachments: [AttachmentPreview] = []
    for block in blocks {
      switch block["type"]?.stringValue {
      case "text":
        let text = block["text"]?.stringValue ?? ""
        if let label = EditorSelection.label(context: text) {
          labels.append(label)
        } else if text.hasPrefix("<attachment name=\"") {
          let name = text.dropFirst("<attachment name=\"".count).prefix { $0 != "\"" }
          attachments.append(AttachmentPreview(kind: .text, name: String(name), thumbnail: nil))
        } else if !text.isEmpty {
          texts.append(text)
        }
      case "image":
        attachments.append(AttachmentPreview(kind: .image, name: nil, thumbnail: nil))
      default:
        break
      }
    }
    return AgentEvent.Prompt(
      text: texts.joined(separator: "\n\n"),
      context: labels.isEmpty ? nil : labels.joined(separator: ", "),
      attachments: attachments)
  }

  private mutating func appendText(_ chunk: String) -> [AgentEvent] {
    if case .text(let id, let accumulated) = openStream {
      openStream = .text(id: id, accumulated: accumulated + chunk)
      return [.itemDelta(id: id, .text(chunk))]
    }
    var events = finishOpenStream()
    let id = "agy-msg-\(nextItemID)"
    nextItemID += 1
    openStream = .text(id: id, accumulated: chunk)
    events.append(.itemStarted(.init(id: id, parent: nil, kind: .text(""))))
    events.append(.itemDelta(id: id, .text(chunk)))
    return events
  }

  private mutating func appendThinking(_ chunk: String) -> [AgentEvent] {
    if case .thinking(let id, let accumulated) = openStream {
      openStream = .thinking(id: id, accumulated: accumulated + chunk)
      return [.itemDelta(id: id, .thinking(chunk))]
    }
    var events = finishOpenStream()
    let id = "agy-think-\(nextItemID)"
    nextItemID += 1
    openStream = .thinking(id: id, accumulated: chunk)
    events.append(.itemStarted(.init(id: id, parent: nil, kind: .thinking(""))))
    events.append(.itemDelta(id: id, .thinking(chunk)))
    return events
  }

  private mutating func translateToolCall(_ update: JSONValue) -> [AgentEvent] {
    guard let callID = update["toolCallId"]?.stringValue, !callID.isEmpty else { return [] }
    let status = update["status"]?.stringValue ?? "in_progress"
    let isTerminal = status == "completed" || status == "failed"
    let existing = toolCalls[callID]
    guard let call = Self.toolCall(from: update, fallback: existing) else { return [] }
    toolCalls[callID] = call

    var events: [AgentEvent] = []
    if isTerminal {
      events.append(.itemCompleted(.init(id: callID, parent: nil, kind: .tool(call))))
      let output = Self.toolOutput(from: update)
      let exitCode = update["rawOutput"]?["exit_code"]?.intValue
      let isError = status == "failed" || (exitCode != nil && exitCode != 0)
      events.append(
        .toolResult(
          callID: callID,
          .init(content: output ?? (isError ? String(localized: "Failed") : ""), isError: isError)))
    } else if existing == nil {
      events.append(.itemStarted(.init(id: callID, parent: nil, kind: .tool(call))))
    } else {
      // Update input/kind in place if diffs or locations arrived on a `pending` update.
      events.append(.itemCompleted(.init(id: callID, parent: nil, kind: .tool(call))))
    }
    return events
  }

  private static func toolCall(from json: JSONValue, fallback: Transcript.ToolCall?)
    -> Transcript.ToolCall?
  {
    guard let callID = json["toolCallId"]?.stringValue ?? fallback?.id else { return nil }
    let rawName = json["name"]?.stringValue ?? fallback?.name ?? ""
    let input = json["rawInput"] ?? json["args"] ?? fallback?.input ?? .object([:])
    let acpKind = json["kind"]?.stringValue
    let title = json["title"]?.stringValue
    let locations = json["locations"]?.arrayValue ?? []
    let firstLocation = locations.first?["path"]?.stringValue
    let content = json["content"]?.arrayValue ?? []

    let name = displayName(for: rawName) ?? (rawName.isEmpty ? (fallback?.name ?? "Tool") : rawName)
    let kind = Self.toolKind(
      rawName: rawName, acpKind: acpKind, title: title, input: input,
      firstLocation: firstLocation, content: content, fallback: fallback?.kind)
    return Transcript.ToolCall(id: callID, name: name, input: input, kind: kind)
  }

  private static func displayName(for rawName: String) -> String? {
    switch rawName {
    case "run_command": "Shell"
    case "read_file": "Read"
    case "edit_file": "Edit"
    case "write_file": "Write"
    case "grep_search": "Grep"
    case "find_by_name": "Find"
    case "search_web": "Web Search"
    case "invoke_subagent": "Subagent"
    case "call_mcp_tool": "MCP Tool"
    default: rawName.isEmpty ? nil : rawName
    }
  }

  private static func toolKind(
    rawName: String, acpKind: String?, title: String?, input: JSONValue,
    firstLocation: String?, content: [JSONValue], fallback: ToolKind?
  ) -> ToolKind {
    // Diff blocks in ACP `content` carry full old/new text for edits and writes.
    let diffEdits = Self.fileEdits(fromContent: content)
    if let first = diffEdits.first {
      return .fileChange(path: first.path, edits: diffEdits)
    }
    switch rawName {
    case "run_command":
      let cmd = input["CommandLine"]?.stringValue ?? title ?? ""
      return .shell(command: cmd)
    case "read_file":
      let path = input["Path"]?.stringValue ?? firstLocation ?? title ?? ""
      return .read(path: path)
    case "edit_file":
      let path = input["Path"]?.stringValue ?? firstLocation ?? title ?? ""
      if let old = input["Target"]?.stringValue, let new = input["Replacement"]?.stringValue {
        return .fileChange(
          path: path, edits: [FileEdit(path: path, change: .replace(old: old, new: new))])
      }
      return .fileChange(path: path, edits: [])
    case "write_file":
      let path = input["Path"]?.stringValue ?? firstLocation ?? title ?? ""
      if let text = input["Content"]?.stringValue {
        return .fileChange(path: path, edits: [FileEdit(path: path, change: .write(content: text))])
      }
      return .fileChange(path: path, edits: [])
    case "grep_search":
      return .search(pattern: input["Query"]?.stringValue ?? title ?? "")
    case "find_by_name":
      return .search(pattern: input["Pattern"]?.stringValue ?? title ?? "")
    case "search_web":
      return .web(input["query"]?.stringValue ?? title ?? "")
    case "invoke_subagent":
      return .subagent(description: input["Role"]?.stringValue ?? title)
    case "call_mcp_tool":
      return .mcp(
        server: input["ServerName"]?.stringValue ?? "",
        tool: input["ToolName"]?.stringValue ?? "")
    default:
      break
    }

    switch acpKind {
    case "execute":
      return .shell(command: input["CommandLine"]?.stringValue ?? title ?? "")
    case "read":
      return .read(path: firstLocation ?? input["Path"]?.stringValue ?? title ?? "")
    case "search":
      return .search(pattern: title ?? "")
    case "edit":
      let path = firstLocation ?? input["Path"]?.stringValue ?? title ?? ""
      return .fileChange(path: path, edits: [])
    case "fetch":
      return .web(title ?? "")
    default:
      return fallback ?? .other
    }
  }

  /// Extracts `FileEdit`s from ACP `content` blocks of `type == "diff"`.
  static func fileEdits(fromContent content: [JSONValue]) -> [FileEdit] {
    content.compactMap { entry in
      guard entry["type"]?.stringValue == "diff",
        let path = entry["path"]?.stringValue,
        let newText = entry["newText"]?.stringValue
      else { return nil }
      if let oldText = entry["oldText"]?.stringValue {
        return FileEdit(path: path, change: .replace(old: oldText, new: newText))
      }
      return FileEdit(path: path, change: .write(content: newText))
    }
  }

  private static func toolOutput(from update: JSONValue) -> String? {
    if let output = update["rawOutput"]?["output"]?.stringValue { return output }
    let texts: [String] = (update["content"]?.arrayValue ?? []).compactMap { entry in
      guard entry["type"]?.stringValue == "content",
        let inner = entry["content"],
        inner["type"]?.stringValue == "text"
      else { return nil }
      return inner["text"]?.stringValue
    }
    if !texts.isEmpty { return texts.joined(separator: "\n") }
    if let raw = update["rawOutput"], raw != .null, raw != .object([:]) {
      return raw.stringValue ?? raw.prettyPrinted
    }
    return nil
  }

  private static func chunkText(_ content: JSONValue?) -> String? {
    guard let content else { return nil }
    if let text = content.stringValue { return text }
    return content["text"]?.stringValue
  }
}
