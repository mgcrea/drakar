import Foundation

/// A session's conversation, folded out of the stream one message at a time.
///
/// What the view draws, and the only place that knows the protocol's quirks:
///
/// - the CLI sends one `assistant` line **per content block**, every one carrying the same
///   message id, so the n-th line for an id is block n of that message;
/// - under `--include-partial-messages` the same block also arrives as a `content_block_start`
///   and its deltas, *before* its `assistant` line, so both paths address one entry, keyed
///   `<message id>#<block index>`, and the whole block replaces the streamed text when it lands;
/// - a tool call and its result arrive in different messages and meet by `tool_use_id`;
/// - the CLI does not echo the user's prompt, so `addPrompt` puts it in.
public struct Transcript: Sendable, Equatable {
  public struct Entry: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: Kind
    /// Non-nil inside a subagent, naming the `Task` call it runs under.
    public var parentToolUseID: String?
    /// On a prompt, what the editor attached to it: `notes.md:3–5`.
    public var context: String?
    /// On thinking streaming live, when its block started; nil once it landed or its turn ended.
    public var thinkingSince: Date?
    /// On thinking streamed live, how long it took from its block start to the whole block
    /// landing. Nil for thinking that landed whole, which history always does: nothing says
    /// when it began.
    public var thinkingDuration: TimeInterval?

    /// On a prompt, its first line with text: what a glance at it needs.
    public var headline: String? {
      guard case .prompt(let text) = kind else { return nil }
      return text.split(whereSeparator: \.isNewline).lazy
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
    }
  }

  public enum Kind: Sendable, Equatable {
    case prompt(String)
    case text(String)
    case thinking(String)
    case tool(ToolCall)
    /// Text the CLI writes as a user turn, such as `[Request interrupted by user]`.
    case notice(String)
    /// Why a turn failed, or a note the CLI colours as an error.
    case failure(String)
  }

  public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var result: ToolResult?
    /// On an `AskUserQuestion` its process never got the answer to, the answers a later
    /// prompt gave it (`UserQuestion.earlierAnswerPrompt`).
    public var earlierAnswers: [String: String]?

    public init(id: String, name: String, input: JSONValue, result: ToolResult? = nil) {
      self.id = id
      self.name = name
      self.input = input
      self.result = result
    }
  }

  public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool
    /// An answered `AskUserQuestion`'s answers, by question, from the structured result.
    public var answers: [String: String]?
    /// An `Agent` call's report, from the structured result.
    public var agentReport: AgentReport?

    public init(
      content: String, isError: Bool, answers: [String: String]? = nil,
      agentReport: AgentReport? = nil
    ) {
      self.content = content
      self.isError = isError
      self.answers = answers
      self.agentReport = agentReport
    }
  }

  /// What became of an `AskUserQuestion` call, read from its result as the extension reads it.
  public enum QuestionOutcome: Sendable, Equatable {
    /// No result yet: asked now, or asked by a process that ended before an answer.
    case waiting
    /// By question; empty when the result says answered but names nothing readable.
    case answered([String: String])
    case declined(reason: String?)
    /// Allowed without answers, or interrupted.
    case unanswered
    /// The process went away while it asked.
    case sessionEnded
    /// A result none of the above, such as an input the tool refused.
    case other
  }

  /// How the newest turn ended.
  public enum TurnEnd: Sendable, Equatable {
    case completed, failed, interrupted
  }

  /// A `can_use_tool` request waiting for the user.
  public struct PendingPermission: Sendable, Equatable, Identifiable {
    public var id: String { requestID }
    public var requestID: String
    public var request: PermissionRequest
  }

  public private(set) var entries: [Entry] = []
  public private(set) var session: SessionInfo?
  public private(set) var pendingPermissions: [PendingPermission] = []
  public private(set) var lastResult: TurnResult?
  /// How the newest turn ended; nil while it runs, before any turn, and after a prompt.
  /// Live, from its `result`; in history, which has none, from `stop_reason: end_turn`.
  public private(set) var turnEnd: TurnEnd?
  /// The session's title: the newest name it was given (`custom-title`), or else the newest
  /// `ai-title`, which never replaces a name. The CLI and the extension read it the same way.
  public var title: String? { customTitle ?? aiTitle }
  public internal(set) var customTitle: String?
  public internal(set) var aiTitle: String?
  /// The Claude Code version that wrote the newest history line: the session's, when another
  /// process runs it and no `system/init` says so.
  public internal(set) var writerVersion: String?
  /// The mode the newest prompt line was sent in, from a transcript file: what a session
  /// another process runs is in.
  public internal(set) var historyPermissionMode: String?
  /// The newest main-thread request's tokens: the session's context. Subagents' are theirs.
  public private(set) var contextUsage: TokenUsage?
  /// `message.model` of that request.
  public private(set) var contextModelID: String?
  /// The newest prompt sent, wherever the turn after it has got to.
  public var lastPrompt: Entry? {
    lastPromptID.flatMap { indexByID[$0] }.map { entries[$0] }
  }
  /// The text the newest turn ended on, once it ended normally with nothing waiting: the
  /// main thread's last entry is text, and it and the text blocks of the same message
  /// before it make the closing text. Nil when it ended on a tool call or a note.
  public var closingText: ClosingText? {
    guard turnEnd == .completed, !isRunning, pendingPermissions.isEmpty else { return nil }
    var messageID: String?
    var parts: [String] = []
    scan: for entry in entries.reversed() where entry.parentToolUseID == nil {
      switch entry.kind {
      case .thinking: continue
      case .text(let text):
        let id = Self.messageID(ofEntry: entry.id)
        if let messageID, id != messageID { break scan }
        messageID = id
        parts.insert(text, at: 0)
      case .prompt, .tool, .notice, .failure: break scan
      }
    }
    let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let messageID, !text.isEmpty else { return nil }
    return ClosingText(messageID: messageID, text: text)
  }

  /// A block's entry is keyed `<message id>#<block index>`.
  static func messageID(ofEntry id: String) -> String {
    String(id[..<(id.lastIndex(of: "#") ?? id.endIndex)])
  }
  /// True from a prompt until its `result`.
  public private(set) var isRunning = false
  /// Prompts sent while a turn ran, oldest first, until the CLI takes each into a turn
  /// (`command_lifecycle` `started`), where it joins the conversation, or drops it.
  public private(set) var queuedPrompts: [QueuedPrompt] = []
  /// The newest list the main thread's `TodoWrite` wrote.
  public private(set) var todos: [Todo]?
  /// Subagents, by the `Agent` call that started each.
  public private(set) var agentTasks: [String: AgentTask] = [:]
  /// `task_updated` names only the task; this finds its call.
  private var agentCallByTask: [String: String] = [:]
  /// A request that failed and is about to be tried again, until anything else arrives.
  public private(set) var retry: APIRetry?
  /// From a `compacting` status until the compaction lands or the turn ends.
  public private(set) var isCompacting = false
  /// Bumped by every change, so a view can react to "something changed" without
  /// comparing the whole history.
  public private(set) var revision = 0

  private var indexByID: [String: Int] = [:]
  /// Blocks seen per assistant message, which is how a per-block `assistant` line learns
  /// its index.
  private var blockCount: [String: Int] = [:]
  /// The message a stream event belongs to, per subagent (nil key: the main thread).
  private var streamingMessage: [String?: String] = [:]
  private var promptCount = 0
  private var lastPromptID: String?
  private var noticeCount = 0
  /// The entries thinking now, so the end of a turn can stop them without a scan.
  private var thinkingIDs: Set<String> = []

  public init() {}

  /// The `AskUserQuestion` the conversation ends on, still asking: its process ended before
  /// an answer, and nothing came after it. Answered by a prompt from then on.
  public var unansweredQuestion: ToolCall? {
    unansweredQuestionIndex.flatMap { index in
      if case .tool(let call) = entries[index].kind { return call }
      return nil
    }
  }

  private var unansweredQuestionIndex: Int? {
    for index in entries.indices.reversed() where entries[index].parentToolUseID == nil {
      switch entries[index].kind {
      case .thinking, .notice, .failure: continue
      case .tool(let call):
        guard call.name == UserQuestion.toolName else { return nil }
        switch call.questionOutcome {
        case .waiting?, .sessionEnded?: return index
        default: return nil
        }
      case .prompt, .text: return nil
      }
    }
    return nil
  }

  /// `running: false` for a prompt replayed from history, whose turn ended long ago.
  /// `context` labels what the editor attached (`EditorSelection.label`, several
  /// separated by commas).
  public mutating func addPrompt(_ text: String, context: String? = nil, running: Bool = true) {
    revision += 1
    if let index = unansweredQuestionIndex, case .tool(var call) = entries[index].kind,
      let answers = UserQuestion.earlierAnswers(
        in: text, questions: UserQuestion.list(call.input).map(\.question))
    {
      call.earlierAnswers = answers
      entries[index].kind = .tool(call)
    }
    promptCount += 1
    let id = "prompt#\(promptCount)"
    upsert(Entry(id: id, kind: .prompt(text), context: context))
    lastPromptID = id
    isRunning = running
    turnEnd = nil
  }

  mutating func addNotice(_ text: String, parent: String? = nil) {
    addNote(.notice(text), parent: parent)
  }

  private mutating func addNote(_ kind: Kind, parent: String? = nil) {
    revision += 1
    noticeCount += 1
    upsert(Entry(id: "notice#\(noticeCount)", kind: kind, parentToolUseID: parent))
  }

  /// A prompt sent while a turn runs: shown apart until the CLI picks it up.
  public mutating func queue(_ prompt: QueuedPrompt) {
    revision += 1
    queuedPrompts.append(prompt)
  }

  /// Call after answering a permission request, so it leaves the pending list.
  public mutating func resolvePermission(requestID: String) {
    revision += 1
    pendingPermissions.removeAll { $0.requestID == requestID }
  }

  /// The process died. Nothing is running any more and nothing can still be answered,
  /// whatever the last line said.
  public mutating func processExited() {
    revision += 1
    isRunning = false
    pendingPermissions.removeAll()
    stopThinking()
    // What waited behind its turn will never run.
    if !queuedPrompts.isEmpty {
      let count = queuedPrompts.count
      queuedPrompts.removeAll()
      addNotice(
        count == 1
          ? String(localized: "1 queued message was not sent")
          : String(localized: "\(count) queued messages were not sent"))
    }
    // Its subagents went with it; no notification will say so.
    for (call, task) in agentTasks where task.status == .running {
      agentTasks[call]?.status = .ended("session ended")
    }
  }

  /// `time` is when the line arrived, which times thinking streamed live.
  public mutating func apply(_ message: StreamMessage, at time: Date = .now) {
    revision += 1
    switch message {
    case .system(.apiRetry), .rateLimit, .controlResponse: break
    default: retry = nil
    }
    switch message {
    case .system(.initialized(let info)):
      session = info
    case .system(.apiRetry(let retry)):
      self.retry = retry
    case .system(.status(let status, _)):
      isCompacting = status == "compacting"
    case .system(.compacted(let trigger, let preTokens)):
      isCompacting = false
      addNotice(Self.compactionNote(trigger: trigger, preTokens: preTokens))
    case .system(.notification(let text, let isError)):
      addNote(isError ? .failure(text) : .notice(text))
    case .system(.task(let event)):
      if let call = event.toolUseID { agentCallByTask[event.taskID] = call }
      if let call = event.toolUseID ?? agentCallByTask[event.taskID] {
        agentTasks[call, default: AgentTask()].apply(event)
      }
    case .assistant(let assistant):
      // A `<synthetic>` turn ("You've hit your session limit", an API error) is written by
      // the CLI, not the API: its usage is all zeros and says nothing of the context.
      if assistant.parentToolUseID == nil, assistant.model != TranscriptTail.syntheticModel,
        let usage = assistant.usage
      {
        contextUsage = usage
        contextModelID = assistant.model ?? contextModelID
      }
      if assistant.parentToolUseID == nil, assistant.stopReason == "end_turn" {
        turnEnd = .completed
      }
      let index = blockCount[assistant.messageID, default: 0]
      for (offset, block) in assistant.content.enumerated() {
        place(
          block, id: "\(assistant.messageID)#\(index + offset)",
          parent: assistant.parentToolUseID, replacing: true, at: time)
      }
      blockCount[assistant.messageID] = index + assistant.content.count
    case .streamEvent(let event, let parent):
      apply(event, parent: parent, at: time)
    case .user(let user):
      // Live, the CLI never echoes our prompts, so any text it writes as a user turn is a
      // note of its own: an interrupt, a background task finishing.
      for case .text(let text) in user.content {
        switch UserText.classify(text) {
        // A subagent's prompt, forwarded from inside it: the card's, not a note.
        case .prompt(let prompt) where user.parentToolUseID != nil:
          agentTasks[user.parentToolUseID!, default: AgentTask()].prompt = prompt
        case .prompt(let note), .notice(let note): addNotice(note, parent: user.parentToolUseID)
        case .context, .hidden: break
        }
      }
      let results = user.content.filter {
        if case .toolResult = $0 { return true }
        return false
      }
      for case .toolResult(let id, let content, let isError) in results {
        guard let index = indexByID[id], case .tool(var call) = entries[index].kind else {
          continue
        }
        call.result = ToolResult(
          content: content, isError: isError,
          answers: results.count == 1 ? user.questionAnswers : nil,
          agentReport: results.count == 1 ? user.agentReport : nil)
        entries[index].kind = .tool(call)
      }
    case .controlRequest(let request):
      switch request.kind {
      case .canUseTool(let permission):
        pendingPermissions.append(
          PendingPermission(requestID: request.requestID, request: permission))
      case .elicitation(let server, let question):
        addNotice(Self.declinedQuestionNote(server: server, question: question))
      case .other: break
      }
    case .controlCancelRequest(let id):
      resolvePermission(requestID: id)
    case .commandLifecycle(let uuid, let state):
      guard let index = queuedPrompts.firstIndex(where: { $0.uuid == uuid }) else { break }
      switch state {
      case "started":
        let prompt = queuedPrompts.remove(at: index)
        addPrompt(prompt.text, context: prompt.context)
      case "cancelled":
        queuedPrompts.remove(at: index)
      case "discarded", "refused":
        let prompt = queuedPrompts.remove(at: index)
        addNotice(String(localized: "Claude Code did not take a queued message: \(prompt.text)"))
      default: break
      }
    case .result(let result):
      lastResult = result
      turnEnd = result.wasInterrupted ? .interrupted : result.isError ? .failed : .completed
      isRunning = false
      isCompacting = false
      if let failure = result.failureText, !endsSaying(failure) { addNote(.failure(failure)) }
      // A turn that ended cannot still be asking, nor thinking.
      pendingPermissions.removeAll()
      stopThinking()
    case .system, .controlResponse, .rateLimit, .unknown:
      break
    }
  }

  /// The main thread's newest text already says `failure`: an API error the CLI wrote as
  /// its own assistant turn before the result repeating it.
  private func endsSaying(_ failure: String) -> Bool {
    for entry in entries.reversed() where entry.parentToolUseID == nil {
      switch entry.kind {
      case .thinking: continue
      case .text(let text): return text.contains(failure)
      default: return false
      }
    }
    return false
  }

  static func compactionNote(trigger: String?, preTokens: Int?) -> String {
    let tokens = preTokens.map { $0.formatted(.number.notation(.compactName)) }
    return switch (trigger, tokens) {
    case (let trigger?, let tokens?):
      String(localized: "Conversation compacted (\(trigger), \(tokens) tokens before)")
    case (nil, let tokens?): String(localized: "Conversation compacted (\(tokens) tokens before)")
    case (let trigger?, nil): String(localized: "Conversation compacted (\(trigger))")
    case (nil, nil): String(localized: "Conversation compacted")
    }
  }

  static func declinedQuestionNote(server: String?, question: String?) -> String {
    let asker = server ?? String(localized: "An MCP server")
    let note = String(
      localized: "\(asker) asked a question Drakar cannot show yet, so it was declined")
    guard let question, !question.isEmpty else { return note }
    return "\(note): \(question)"
  }

  private mutating func apply(_ event: StreamEvent, parent: String?, at time: Date) {
    switch event {
    case .messageStart(let id):
      streamingMessage[parent] = id
    case .blockStart(let index, let block):
      guard let message = streamingMessage[parent] else { return }
      place(block, id: "\(message)#\(index)", parent: parent, replacing: false, at: time)
    case .blockDelta(let index, let delta):
      guard let message = streamingMessage[parent],
        let position = indexByID["\(message)#\(index)"]
      else { return }
      switch (entries[position].kind, delta) {
      case (.text(let text), .text(let more)): entries[position].kind = .text(text + more)
      case (.thinking(let text), .thinking(let more)):
        entries[position].kind = .thinking(text + more)
      default: break  // tool input fragments only parse whole; the `assistant` line brings it
      }
    case .messageStop:
      streamingMessage[parent] = nil
    case .blockStop, .messageDelta, .other:
      break
    }
  }

  /// Puts a block at `id`. A tool call is keyed by its own id rather than its position, so
  /// that its result can find it; the position key is aliased to it for the stream path.
  private mutating func place(
    _ block: ContentBlock, id: String, parent: String?, replacing: Bool, at time: Date
  ) {
    let kind: Kind
    var key = id
    switch block {
    case .text(let text): kind = .text(text)
    case .thinking(let text): kind = .thinking(text)
    case .toolUse(let toolID, let name, let input):
      key = toolID
      var call = ToolCall(id: toolID, name: name, input: input)
      if let index = indexByID[toolID], case .tool(let existing) = entries[index].kind {
        call.result = existing.result
      }
      kind = .tool(call)
      // Whole, not from a block start, whose input is still empty.
      if replacing, parent == nil, name == TodoList.toolName { todos = TodoList.todos(input) }
    case .toolResult, .other:
      return
    }
    if let index = indexByID[key] ?? indexByID[id] {
      // The stream path made this entry; the whole block replaces it. Never with nothing:
      // a block start is empty by definition, and a thinking block can land whole with its
      // text withheld after its deltas showed some.
      if replacing && !Self.isEmptyText(kind) { entries[index].kind = kind }
      if replacing, let since = entries[index].thinkingSince {
        entries[index].thinkingSince = nil
        entries[index].thinkingDuration = time.timeIntervalSince(since)
        thinkingIDs.remove(key)
      }
    } else {
      var entry = Entry(id: key, kind: kind, parentToolUseID: parent)
      if !replacing, case .thinking = kind {
        entry.thinkingSince = time
        thinkingIDs.insert(key)
      }
      upsert(entry)
    }
    indexByID[id] = indexByID[key]
  }

  /// Thinking whose block never landed did not finish: it has no duration.
  private mutating func stopThinking() {
    for id in thinkingIDs {
      if let index = indexByID[id] { entries[index].thinkingSince = nil }
    }
    thinkingIDs.removeAll()
  }

  private static func isEmptyText(_ kind: Kind) -> Bool {
    switch kind {
    case .text(let text), .thinking(let text): text.isEmpty
    case .prompt, .tool, .notice, .failure: false
    }
  }

  private mutating func upsert(_ entry: Entry) {
    if let index = indexByID[entry.id] {
      entries[index] = entry
    } else {
      indexByID[entry.id] = entries.count
      entries.append(entry)
    }
  }
}

extension Transcript.ToolCall {
  /// What became of it, for an `AskUserQuestion`; nil for any other tool.
  public var questionOutcome: Transcript.QuestionOutcome? {
    guard name == UserQuestion.toolName else { return nil }
    if let earlierAnswers { return .answered(earlierAnswers) }
    guard let result else { return .waiting }
    let text = result.content
    if result.isError {
      if Self.sessionEndedPrefixes.contains(where: text.hasPrefix) { return .sessionEnded }
      if text.hasPrefix("[Request interrupted by user") { return .unanswered }
      if text.hasPrefix(UserQuestion.declinedPrefix) {
        let reason = text.range(of: UserQuestion.declinedReasonMarker).map {
          String(text[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return .declined(reason: reason?.isEmpty == false ? reason : nil)
      }
      // Drakar's own Skip said so before it sent the extension's words.
      if text == "The user chose not to answer." { return .declined(reason: nil) }
      return .other
    }
    if text == UserQuestion.unansweredMessage { return .unanswered }
    guard UserQuestion.answeredPrefixes.contains(where: text.hasPrefix) else { return .other }
    return .answered(
      result.answers
        ?? UserQuestion.answers(
          inResult: text, questions: UserQuestion.list(input).map(\.question)) ?? [:])
  }

  /// A result written for a call whose process went away while it asked: the stream closed
  /// under the permission request, or a resume found the call without a result.
  static let sessionEndedPrefixes = [
    "Tool permission request failed", "[Tool call interrupted",
    "[Tool call result not in this copy",
  ]
}

/// A prompt sent while a turn ran, by the `uuid` it was sent with.
public struct QueuedPrompt: Sendable, Equatable, Identifiable {
  public var uuid: String
  public var text: String
  /// What the editor attached, labelled as on a prompt.
  public var context: String?

  public var id: String { uuid }

  public init(uuid: String, text: String, context: String? = nil) {
    self.uuid = uuid
    self.text = text
    self.context = context
  }
}
