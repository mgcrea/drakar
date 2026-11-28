import Foundation

/// Antigravity's ACP notifications and requests (`agy acp`, docs/agy-acp.md) as agent events:
/// live lines through `translate`, `session/load`'s replayed updates through `history`.
public struct AgyTranslator: Sendable {
  public enum RecordedQuestionOutcome: Sendable, Equatable {
    case answered([String: String])
    case declined
    case interrupted
  }

  private enum OpenStream: Sendable, Equatable {
    case text(id: String, accumulated: String)
    case thinking(id: String, accumulated: String)
  }

  private struct PendingQuestionFallback: Sendable, Equatable {
    let callID: String
    let expected: String
    var buffered: String = ""
  }

  private var nextItemID = 1
  private var openStream: OpenStream?
  /// Tool calls already started in this translator, so `tool_call_update` updates rather than
  /// re-adding them and permission requests know their latest details.
  private var toolCalls: [String: Transcript.ToolCall] = [:]
  /// Holds the numbered-list fallback `agy acp` emits right after `ask_question` so it is
  /// suppressed when it matches, or flushed if real text arrives instead.
  private var pendingQuestionFallback: PendingQuestionFallback?
  /// Outcomes of `ask_question` prompts answered through `elicitation/create`, preserved so
  /// the subsequent `tool_call_update` (`status: "completed"`, no `rawOutput`) records them.
  private var questionOutcomes: [String: RecordedQuestionOutcome] = [:]
  /// Whether an `invoke_subagent` call is reported as a task too, for the agent map: live
  /// only, as Claude Code's tasks are, so a reloaded session lists no agents.
  private var reportsTasks = true

  public init() {}

  public mutating func recordQuestionOutcome(callID: String, outcome: RecordedQuestionOutcome) {
    questionOutcomes[callID] = outcome
  }

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
    var events: [AgentEvent] = []
    if let pending = pendingQuestionFallback {
      pendingQuestionFallback = nil
      let trimmed = pending.buffered.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, trimmed != pending.expected {
        let id = "agy-msg-\(nextItemID)"
        nextItemID += 1
        events.append(.itemCompleted(.init(id: id, parent: nil, kind: .text(pending.buffered))))
      }
    }
    guard let open = openStream else { return events }
    openStream = nil
    switch open {
    case .text(let id, let accumulated):
      events.append(.itemCompleted(.init(id: id, parent: nil, kind: .text(accumulated))))
    case .thinking(let id, let accumulated):
      events.append(.itemCompleted(.init(id: id, parent: nil, kind: .thinking(accumulated))))
    }
    return events
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

  /// Translates an `elicitation/create` request into a question prompt when it belongs to an
  /// `ask_question` call (or matches `agy`'s `q1`/`q1_other` question schema). Returns nil for
  /// generic MCP elicitations so `AgySession` falls back to `Elicitation`.
  public mutating func questionElicitation(id: AgyRPC.ID, params: JSONValue) -> (
    event: AgentEvent, prompt: AgyQuestionPrompt
  )? {
    let toolCallID = params["toolCallId"]?.stringValue
    let existing = toolCallID.flatMap { toolCalls[$0] }
    let schema = params["requestedSchema"] ?? .null

    let questions: [UserQuestion]
    let input: JSONValue
    if let existing, existing.kind == .question {
      let parsed = UserQuestion.list(existing.input)
      if !parsed.isEmpty {
        questions = parsed
        input = existing.input
      } else if let fromSchema = Self.questions(fromElicitationSchema: schema) {
        questions = fromSchema.questions
        input = fromSchema.input
      } else {
        return nil
      }
    } else if let fromSchema = Self.questions(fromElicitationSchema: schema) {
      questions = fromSchema.questions
      input = fromSchema.input
    } else {
      return nil
    }

    var request = PermissionRequest(
      toolName: "Question", displayName: String(localized: "Question"), input: input,
      description: params["message"]?.stringValue, toolUseID: toolCallID, kind: .question)
    request.requiresUserInteraction = true
    pendingQuestionFallback = nil
    let prompt = AgyQuestionPrompt(
      id: id, toolCallID: toolCallID, questions: questions,
      optionValues: Self.optionValues(fromElicitationSchema: schema, count: questions.count))
    return (.permissionRequested(.init(requestID: id.text, request: request)), prompt)
  }

  /// Folds `session/load`'s replayed `session/update` payloads into a finished conversation.
  public static func history(_ updates: [JSONValue]) -> [AgentEvent] {
    var translator = AgyTranslator()
    translator.reportsTasks = false
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
    if var pending = pendingQuestionFallback {
      pending.buffered += chunk
      let trimmed = pending.buffered.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || pending.expected.hasPrefix(trimmed) {
        pendingQuestionFallback = pending
        return []
      }
      pendingQuestionFallback = nil
      return appendText(pending.buffered)
    }
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
      if call.kind == .question, let outcome = questionOutcomes.removeValue(forKey: callID) {
        let result: Transcript.ToolResult =
          switch outcome {
          case .answered(let answers):
            .init(
              content: output
                ?? UserQuestion.formattedResult(
                  answers, order: UserQuestion.list(call.input).map(\.question)),
              isError: false, answers: answers)
          case .declined:
            .init(content: output ?? UserQuestion.declinedMessage, isError: true)
          case .interrupted:
            .init(content: output ?? "[Request interrupted by user]", isError: true)
          }
        events.append(.toolResult(callID: callID, result))
      } else {
        events.append(
          .toolResult(
            callID: callID,
            .init(content: output ?? (isError ? String(localized: "Failed") : ""), isError: isError)
          ))
      }
    } else if existing == nil {
      events.append(.itemStarted(.init(id: callID, parent: nil, kind: .tool(call))))
    } else {
      // Update input/kind in place if diffs or locations arrived on a `pending` update.
      events.append(.itemCompleted(.init(id: callID, parent: nil, kind: .tool(call))))
    }
    if reportsTasks, call.kind.isSubagent {
      events += subagentTask(call, isStart: existing == nil, status: status)
    }
    if !isTerminal, call.kind == .question,
      let expected = Self.questionFallbackText(for: call.input)
    {
      pendingQuestionFallback = PendingQuestionFallback(callID: callID, expected: expected)
    }
    return events
  }

  /// An `invoke_subagent` call as the task the agent map lists: started with the call, ended
  /// with it. ACP says nothing of a subagent's own work, so its card has only the call's.
  private func subagentTask(_ call: Transcript.ToolCall, isStart: Bool, status: String)
    -> [AgentEvent]
  {
    var update = AgentTaskUpdate()
    update.isStart = isStart
    update.isSubagent = true
    if case .subagent(let description?) = call.kind { update.description = description }
    switch status {
    case "completed": update.status = "completed"
    case "failed": update.status = "failed"
    default:
      guard isStart else { return [] }
      update.status = "running"
    }
    return [.agentTask(callID: call.id, update)]
  }

  /// The numbered markdown list `agy acp` emits right after `ask_question` so text-only clients
  /// can still answer it.
  private static func questionFallbackText(for input: JSONValue) -> String? {
    let questions = UserQuestion.list(input)
    guard !questions.isEmpty else { return nil }
    return questions.map { question in
      let options = question.options.enumerated().map { "- [\($0.offset + 1)] \($0.element.label)" }
      return ([question.question] + options).joined(separator: "\n")
    }
    .joined(separator: "\n\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func toolCall(from json: JSONValue, fallback: Transcript.ToolCall?)
    -> Transcript.ToolCall?
  {
    guard let callID = json["toolCallId"]?.stringValue ?? fallback?.id else { return nil }
    let rawName =
      json["name"]?.stringValue ?? json["_meta"]?["x.ai/tool"]?["name"]?.stringValue
      ?? fallback?.name ?? ""
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
    case "ask_question", "ask_user_question": "Question"
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
    case "ask_question", "ask_user_question":
      return .question
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

  /// Parses `agy`'s `q1`, `q1_other`, `q2`, ... elicitation schema into `UserQuestion`s when
  /// the preceding `ask_question` tool call was absent or lacked input.
  private static func questions(fromElicitationSchema schema: JSONValue) -> (
    questions: [UserQuestion], input: JSONValue
  )? {
    guard case .object(let properties) = schema["properties"] else { return nil }
    var questions: [UserQuestion] = []
    var rawQuestions: [JSONValue] = []
    var index = 1
    while let prop = properties["q\(index)"] {
      defer { index += 1 }
      guard let question = prop["title"]?.stringValue, !question.isEmpty else { continue }
      let multiSelect = prop["type"]?.stringValue == "array"
      let entries =
        multiSelect
        ? (prop["items"]?["anyOf"]?.arrayValue ?? prop["items"]?["oneOf"]?.arrayValue ?? [])
        : (prop["oneOf"]?.arrayValue ?? prop["anyOf"]?.arrayValue ?? [])
      let labels = entries.compactMap { $0["title"]?.stringValue ?? $0["const"]?.stringValue }
      let allowsOther = properties["q\(index)_other"] != nil
      questions.append(
        UserQuestion(
          question: question, header: nil,
          options: labels.map { UserQuestion.Option(label: $0, description: nil) },
          multiSelect: multiSelect, allowsOther: allowsOther))
      rawQuestions.append(
        .object([
          "question": .string(question),
          "options": .array(labels.map { .string($0) }),
          "is_multi_select": .bool(multiSelect),
          "isOther": .bool(allowsOther),
        ]))
    }
    guard !questions.isEmpty else { return nil }
    return (questions, .object(["questions": .array(rawQuestions)]))
  }

  private static func optionValues(fromElicitationSchema schema: JSONValue, count: Int) -> [[String:
    String]]
  {
    guard case .object(let properties) = schema["properties"] else {
      return Array(repeating: [:], count: count)
    }
    return (1...max(1, count)).prefix(count).map { index in
      guard let prop = properties["q\(index)"] else { return [:] }
      let entries =
        prop["type"]?.stringValue == "array"
        ? (prop["items"]?["anyOf"]?.arrayValue ?? prop["items"]?["oneOf"]?.arrayValue ?? [])
        : (prop["oneOf"]?.arrayValue ?? prop["anyOf"]?.arrayValue ?? [])
      var map: [String: String] = [:]
      for entry in entries {
        if let value = entry["const"]?.stringValue,
          let title = entry["title"]?.stringValue
        {
          map[title] = value
        }
      }
      return map
    }
  }
}

/// A pending Antigravity `ask_question` prompt received over ACP `elicitation/create`.
public struct AgyQuestionPrompt: Sendable, Equatable {
  public let id: AgyRPC.ID
  public let toolCallID: String?
  public let questions: [UserQuestion]
  /// Per-question map from option label to schema `const` value (`"1"`, `"2"`, …).
  public let optionValues: [[String: String]]

  public func response(for decision: PermissionDecision) -> (
    write: JSONValue, outcome: AgyTranslator.RecordedQuestionOutcome
  ) {
    switch decision {
    case .allow(let updatedInput, _):
      let answersInput = updatedInput["answers"]
      var answers: [String: String] = [:]
      var content: [String: JSONValue] = [:]
      for (index, question) in questions.enumerated() {
        let key = "q\(index + 1)"
        let otherKey = "\(key)_other"
        guard let answerStr = answersInput?[question.question]?.stringValue else { continue }
        answers[question.question] = answerStr
        let reading = question.reading(answerStr)
        let valuesByLabel = optionValues.indices.contains(index) ? optionValues[index] : [:]
        func wireValue(for label: String) -> String {
          if let mapped = valuesByLabel[label] { return mapped }
          if let idx = question.options.firstIndex(where: { $0.label == label }) {
            return String(idx + 1)
          }
          return label
        }
        if question.multiSelect {
          let picked = reading.picked.map(wireValue)
          if !picked.isEmpty { content[key] = .array(picked.map { .string($0) }) }
        } else if let first = reading.picked.first {
          content[key] = .string(wireValue(for: first))
        }
        if let typed = reading.other, !typed.isEmpty {
          content[otherKey] = .string(typed)
        }
      }
      return (
        AgyRPC.answer(
          id, result: .object(["action": .string("accept"), "content": .object(content)])),
        .answered(answers)
      )
    case .deny(_, let interrupt):
      return (
        AgyRPC.answer(
          id, result: .object(["action": .string(interrupt ? "cancel" : "decline")])),
        interrupt ? .interrupted : .declined
      )
    }
  }
}
