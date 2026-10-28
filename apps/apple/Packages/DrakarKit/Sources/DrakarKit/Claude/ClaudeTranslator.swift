import Foundation

/// Claude Code's stream-json, and its transcript files, as agent events: the only place that
/// knows the protocol's quirks (docs/claude-stream-json.md).
///
/// - the CLI sends one `assistant` line **per content block**, every one carrying the same
///   message id, so the n-th line for an id is block n of that message, keyed `<id>#<n>`;
/// - under `--include-partial-messages` the same block also arrives as a
///   `content_block_start` and its deltas, *before* its `assistant` line, under the same key;
/// - a tool call is keyed by its own id, so that its result, in another message, finds it;
/// - the CLI does not echo the user's prompt live: the session adds it.
///
/// One per process, and one per transcript file read: its state is the stream's.
public struct ClaudeTranslator: Sendable {
  /// Blocks seen per assistant message, which is how a per-block `assistant` line learns
  /// its index.
  private var blockCount: [String: Int] = [:]
  /// The message a stream event belongs to, per subagent (nil key: the main thread).
  private var streamingMessage: [String?: String] = [:]
  /// A streamed block's position key, for a tool call keyed by its own id.
  private var toolAtPosition: [String: String] = [:]
  /// `task_updated` names only the task; this finds its call.
  private var agentCallByTask: [String: String] = [:]

  /// Whether `history(_:)` keeps `isSidechain` lines: a subagent's own transcript is all
  /// sidechain, a session's keeps its subagents' lines out.
  private let includesSidechains: Bool

  public init(includesSidechains: Bool = false) {
    self.includesSidechains = includesSidechains
  }

  /// `time` is when the line arrived or was written; nil for a history line that says not.
  public mutating func translate(_ message: StreamMessage, at time: Date?) -> [AgentEvent] {
    var events: [AgentEvent] = []
    switch message {
    case .system(.apiRetry), .rateLimit, .controlResponse: break
    default: events.append(.retrying(nil))
    }
    switch message {
    case .system(.initialized(let info)):
      // Every turn opens with one, including the turn a fork's notification starts with no
      // prompt (2.1.308).
      events += [.sessionStarted(info), .turnStarted]
    case .system(.apiRetry(let retry)):
      events.append(.retrying(retry))
    case .system(.status(let status, _)):
      events.append(.compaction(status == "compacting" ? .started : .stopped))
    case .system(.compacted(let trigger, let preTokens)):
      events.append(
        .compaction(
          .finished(
            note: Transcript.compactionNote(trigger: trigger, preTokens: preTokens), at: time)))
    case .system(.notification(let text, let isError)):
      events.append(.note(.init(text: text, isFailure: isError)))
    case .system(.elicitationComplete(let server, _)):
      events.append(
        .note(.init(text: String(localized: "\(server) finished the step in the browser"))))
    case .system(.task(let event)):
      if let call = event.toolUseID { agentCallByTask[event.taskID] = call }
      if let call = event.toolUseID ?? agentCallByTask[event.taskID] {
        events.append(.agentTask(callID: call, event.update))
      }
    case .assistant(let assistant):
      events += translate(assistant, at: time)
    case .streamEvent(let event, let parent):
      events += translate(event, parent: parent)
    case .user(let user):
      events += translate(user, at: time)
    case .controlRequest(let request):
      switch request.kind {
      case .canUseTool(let permission):
        events.append(
          .permissionRequested(.init(requestID: request.requestID, request: permission)))
      case .elicitation(let elicitation):
        events.append(
          .elicitationRequested(.init(requestID: request.requestID, elicitation: elicitation)))
      case .other: break
      }
    case .controlCancelRequest(let id):
      events.append(.permissionWithdrawn(requestID: id))
    case .commandLifecycle(let uuid, let state):
      switch state {
      case "started": events.append(.queue(id: uuid, .started))
      case "cancelled": events.append(.queue(id: uuid, .cancelled))
      case "discarded", "refused": events.append(.queue(id: uuid, .dropped(agent: "Claude Code")))
      default: break
      }
    case .result(let result):
      events.append(
        .turnEnded(
          TurnSummary(
            outcome: result.wasInterrupted ? .interrupted : result.isError ? .failed : .completed,
            failureText: result.failureText, text: result.text, costUSD: result.totalCostUSD,
            durationMS: result.durationMS)))
    case .system, .controlResponse, .rateLimit, .unknown:
      break
    }
    return events
  }

  private mutating func translate(_ assistant: AssistantMessage, at time: Date?) -> [AgentEvent] {
    var events: [AgentEvent] = []
    // A `<synthetic>` turn ("You've hit your session limit", an API error) is written by
    // the CLI, not the API: its usage is all zeros and says nothing of the context.
    if assistant.parentToolUseID == nil, assistant.model != TranscriptTail.syntheticModel,
      let usage = assistant.usage
    {
      events.append(
        .usage(
          .init(messageID: assistant.messageID, usage: usage, model: assistant.model, at: time)))
    }
    if assistant.parentToolUseID == nil, assistant.stopReason == "end_turn" {
      events.append(.turnOutcome(.completed))
    }
    let index = blockCount[assistant.messageID, default: 0]
    for (offset, block) in assistant.content.enumerated() {
      let position = "\(assistant.messageID)#\(index + offset)"
      guard let item = item(block, position: position, parent: assistant.parentToolUseID) else {
        continue
      }
      events.append(.itemCompleted(item))
      // Whole, not from a block start, whose input is still empty.
      if assistant.parentToolUseID == nil, case .tool(let call) = item.kind, call.kind == .todos {
        events.append(.todos(TodoList.todos(call.input)))
      }
    }
    blockCount[assistant.messageID] = index + assistant.content.count
    return events
  }

  private mutating func translate(_ event: StreamEvent, parent: String?) -> [AgentEvent] {
    switch event {
    case .messageStart(let id):
      streamingMessage[parent] = id
    case .blockStart(let index, let block):
      guard let message = streamingMessage[parent],
        let item = item(block, position: "\(message)#\(index)", parent: parent)
      else { return [] }
      return [.itemStarted(item)]
    case .blockDelta(let index, let delta):
      guard let message = streamingMessage[parent] else { return [] }
      let position = "\(message)#\(index)"
      let id = toolAtPosition[position] ?? position
      switch delta {
      case .text(let text): return [.itemDelta(id: id, .text(text))]
      case .thinking(let text): return [.itemDelta(id: id, .thinking(text))]
      default: return []  // tool input fragments only parse whole; the `assistant` line brings it
      }
    case .messageStop:
      streamingMessage[parent] = nil
    case .blockStop, .messageDelta, .other:
      break
    }
    return []
  }

  private func translate(_ user: UserMessage, at time: Date?) -> [AgentEvent] {
    var events: [AgentEvent] = []
    if user.parentToolUseID == nil, let time { events.append(.requestSent(at: time)) }
    // Live, the CLI never echoes our prompts, so any text it writes as a user turn is a note
    // of its own: an interrupt, a background task finishing. Not the text it writes for the
    // model, which the history leaves out too.
    for case .text(let text) in user.content where !user.isSynthetic {
      switch UserText.classify(text) {
      // A subagent's prompt, forwarded from inside it: the card's, not a note.
      case .prompt(let prompt) where user.parentToolUseID != nil:
        var update = AgentTaskUpdate()
        update.prompt = prompt
        events.append(.agentTask(callID: user.parentToolUseID!, update))
      case .prompt(let note), .notice(let note):
        events.append(.note(.init(text: note, parent: user.parentToolUseID)))
      case .context, .hidden: break
      }
    }
    let results = user.content.filter {
      if case .toolResult = $0 { return true }
      return false
    }
    for case .toolResult(let id, let content, let isError) in results {
      events.append(
        .toolResult(
          callID: id,
          .init(
            content: content, isError: isError,
            answers: results.count == 1 ? user.questionAnswers : nil,
            agentReport: results.count == 1 ? user.agentReport : nil)))
    }
    return events
  }

  /// A block as an item at `position`; a tool call at its own id. Nil for what is not one.
  private mutating func item(_ block: ContentBlock, position: String, parent: String?)
    -> AgentEvent.Item?
  {
    switch block {
    case .text(let text): return .init(id: position, parent: parent, kind: .text(text))
    case .thinking(let text): return .init(id: position, parent: parent, kind: .thinking(text))
    case .toolUse(let id, let name, let input):
      toolAtPosition[position] = id
      return .init(
        id: id, parent: parent,
        kind: .tool(
          .init(id: id, name: name, input: input, kind: ClaudeTools.kind(name: name, input: input)))
      )
    case .toolResult, .other: return nil
    }
  }
}

extension ClaudeTranslator {
  /// When a transcript line was written.
  public static func timestamp(of json: JSONValue) -> Date? {
    json["timestamp"]?.stringValue.flatMap {
      try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)
    }
  }

  /// One transcript-file line (`<config>/projects/<encoded cwd>/<session id>.jsonl`).
  /// Unknown entry types (attachments, snapshots, cost records) say nothing, and nor do
  /// subagent sidechains unless `includesSidechains`.
  public mutating func history(_ json: JSONValue) -> [AgentEvent] {
    guard includesSidechains || json["isSidechain"]?.boolValue != true else { return [] }
    var events: [AgentEvent] = []
    if let version = json["version"]?.stringValue, !version.isEmpty {
      events.append(.historyMeta(.writerVersion(version)))
    }
    let time = Self.timestamp(of: json)
    switch json["type"]?.stringValue {
    case "ai-title":
      if let title = json["aiTitle"]?.stringValue, !title.isEmpty {
        events.append(.title(.ai(title)))
      }
    case "custom-title":
      if let title = json["customTitle"]?.stringValue, !title.isEmpty {
        events.append(.title(.custom(title)))
      }
    case "assistant":
      events.append(.historyMeta(.effort(json["effort"]?.stringValue)))
      if let message = try? StreamMessage(json: json) { events += translate(message, at: time) }
    case "user":
      if json["isMeta"]?.boolValue == true { return events }
      if let time { events.append(.requestSent(at: time)) }
      if let mode = json["permissionMode"]?.stringValue {
        events.append(.historyMeta(.permissionMode(mode)))
      }
      if json["isCompactSummary"]?.boolValue == true {
        events.append(
          .compaction(
            .finished(note: String(localized: "Earlier conversation compacted"), at: time)))
        return events
      }
      guard case .user(let user)? = try? StreamMessage(json: json) else { return events }
      var prompt: [String] = []
      var context: [String] = []
      for case .text(let text) in user.content {
        switch UserText.classify(text) {
        case .prompt(let part): prompt.append(part)
        case .notice(let note):
          events.append(.note(.init(text: note, parent: user.parentToolUseID)))
        case .context(let label): context.append(label)
        case .hidden: break
        }
      }
      if !prompt.isEmpty || !user.attachments.isEmpty {
        events.append(
          .prompt(
            .init(
              text: prompt.joined(separator: "\n\n"),
              context: context.isEmpty ? nil : context.joined(separator: ", "),
              attachments: user.attachments),
            running: false))
      }
      // Tool results go through the live path, which pairs them with their calls.
      let results = user.content.filter {
        if case .toolResult = $0 { return true }
        return false
      }
      if !results.isEmpty {
        var resultsOnly = user
        resultsOnly.content = results
        events += translate(.user(resultsOnly), at: time)
      }
    default:
      break
    }
    return events
  }
}

extension StreamMessage {
  /// A line as stream-json; one that is not (no JSON, or no `type`) is kept, not dropped.
  public init(_ line: AgentProcess.Line) {
    switch line {
    case .json(let json):
      self = (try? StreamMessage(json: json)) ?? .unknown(type: "invalid-line", raw: json)
    case .invalid(let text):
      self = .unknown(type: "invalid-line", raw: .string(text))
    }
  }
}
