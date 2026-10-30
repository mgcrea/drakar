import Foundation

/// A session's conversation, as its agent's events built it (`AgentEvent`): what the view
/// draws. It knows no wire format; each agent's translator does (`ClaudeTranslator`).
public struct Transcript: Sendable, Equatable {
  public struct Entry: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: Kind
    /// Non-nil inside a subagent, naming the `Task` call it runs under.
    public var parentToolUseID: String?
    /// On a prompt, what the editor attached to it: `notes.md:3–5`.
    public var context: String?
    /// On a prompt, the images and files sent with it.
    public var attachments: [AttachmentPreview] = []
    /// On a Claude Code prompt, the CLI's message uuid: the one Drakar sent it with, which its
    /// transcript line keeps; what a fork or a rewind from it names. A live Codex prompt
    /// carries the id Drakar sent it with; a Codex history prompt carries none.
    public var messageID: String?
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
    /// What it does, read once where it was made.
    public var kind: ToolKind
    public var result: ToolResult?
    /// On an `AskUserQuestion` its process never got the answer to, the answers a later
    /// prompt gave it (`UserQuestion.earlierAnswerPrompt`).
    public var earlierAnswers: [String: String]?

    public init(
      id: String, name: String, input: JSONValue, kind: ToolKind, result: ToolResult? = nil
    ) {
      self.id = id
      self.name = name
      self.input = input
      self.kind = kind
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

  /// An MCP server's question waiting for the person, with no deadline.
  public struct PendingElicitation: Sendable, Equatable, Identifiable {
    public var id: String { requestID }
    public var requestID: String
    public var elicitation: Elicitation
  }

  public private(set) var entries: [Entry] = []
  public private(set) var session: SessionInfo?
  public private(set) var pendingPermissions: [PendingPermission] = []
  /// In arrival order.
  public private(set) var pendingElicitations: [PendingElicitation] = []
  /// A permission or a question waits on the person: the turn cannot go on without them.
  public var isWaitingOnPerson: Bool { !pendingPermissions.isEmpty || !pendingElicitations.isEmpty }
  public var waitingCount: Int { pendingPermissions.count + pendingElicitations.count }
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
  /// The effort the newest reply ran at, from a transcript file; nil when it names none (a
  /// model without effort, such as Haiku).
  public internal(set) var historyEffort: String?
  /// The newest main-thread request's tokens: the session's context. Subagents' are theirs.
  public private(set) var contextUsage: TokenUsage?
  /// `message.model` of that request.
  public private(set) var contextModelID: String?
  /// How the newest turn ended, as its agent summed it up.
  public private(set) var lastTurn: TurnSummary?
  /// The model's context window, when the agent says it.
  public private(set) var contextWindow: Int?
  /// How long the API keeps what the main thread's requests cached.
  public internal(set) var promptCache = PromptCache()
  /// When the newest main-thread request was sent, as far as anything said: a prompt, or a
  /// user line such as a tool result. Spent by the message that answers it.
  var requestAt: Date?
  /// The newest prompt sent, wherever the turn after it has got to.
  public var lastPrompt: Entry? {
    lastPromptID.flatMap { indexByID[$0] }.map { entries[$0] }
  }
  /// Whether an entry with this id is in the transcript, a tool call's being its call's id.
  public func contains(entryID id: String) -> Bool { indexByID[id] != nil }
  /// The text the newest turn ended on, once it ended normally with nothing waiting: the
  /// main thread's last entry is text, and it and the text blocks of the same message
  /// before it make the closing text. Nil when it ended on a tool call or a note.
  public var closingText: ClosingText? {
    guard turnEnd == .completed, !isRunning, !isWaitingOnPerson else { return nil }
    var messageID: String?
    var parts: [String] = []
    scan: for entry in entries.reversed()
    where entry.parentToolUseID == nil && entry.id != Self.coldCacheNoteID {
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
  /// A request that failed and is about to be tried again, until anything else arrives.
  public private(set) var retry: APIRetry?
  /// From a `compacting` status until the compaction lands or the turn ends.
  public private(set) var isCompacting = false
  /// Bumped by every change, so a view can react to "something changed" without
  /// comparing the whole history.
  public private(set) var revision = 0

  private var indexByID: [String: Int] = [:]
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
        guard call.kind == .question else { return nil }
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
  /// separated by commas). `time` is when a running one was sent.
  public mutating func addPrompt(
    _ text: String, context: String? = nil, attachments: [AttachmentPreview] = [],
    uuid: String? = nil, running: Bool = true, at time: Date = .now
  ) {
    revision += 1
    if running { requestAt = time }
    if let index = unansweredQuestionIndex, case .tool(var call) = entries[index].kind,
      let answers = UserQuestion.earlierAnswers(
        in: text, questions: UserQuestion.list(call.input).map(\.question))
    {
      call.earlierAnswers = answers
      entries[index].kind = .tool(call)
    }
    promptCount += 1
    let id = "prompt#\(promptCount)"
    var entry = Entry(id: id, kind: .prompt(text), context: context)
    entry.attachments = attachments
    entry.messageID = uuid
    upsert(entry)
    lastPromptID = id
    isRunning = running
    turnEnd = nil
  }

  /// A note of the client's in the conversation, as the CLI's bracketed ones read.
  public mutating func addNotice(_ text: String, parent: String? = nil) {
    addNote(.notice(text), parent: parent)
  }

  /// The latest notice reading `text` reads `replacement` instead, where it stands; with
  /// none, `replacement` is added. A note that something later qualifies stays one note.
  public mutating func reviseNotice(_ text: String, to replacement: String) {
    guard let index = entries.lastIndex(where: { $0.kind == .notice(text) }) else {
      return addNotice(replacement)
    }
    revision += 1
    entries[index].kind = .notice(replacement)
  }

  private mutating func addNote(_ kind: Kind, parent: String? = nil) {
    revision += 1
    noticeCount += 1
    upsert(Entry(id: "notice#\(noticeCount)", kind: kind, parentToolUseID: parent))
  }

  /// After a history is read: a note that the prompt cache has likely gone cold, so the next
  /// message re-sends the whole conversation uncached, as the extension notes it on resume.
  /// The client's note rather than the conversation's, so the turn before it still ends on
  /// what it ended on. One at most.
  public mutating func noteColdCache(at now: Date = .now) {
    guard let note = promptCache.state(at: now).resumeNote else { return }
    revision += 1
    upsert(Entry(id: Self.coldCacheNoteID, kind: .notice(note)))
  }

  static let coldCacheNoteID = "notice#prompt-cache"

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

  /// Removes it and notes what became of it: answered, declined, cancelled or, for a link,
  /// opened. The note names the server and the question, never what the person entered.
  public mutating func resolveElicitation(requestID: String, with answer: ElicitationAnswer) {
    revision += 1
    guard let index = pendingElicitations.firstIndex(where: { $0.requestID == requestID })
    else { return }
    let elicitation = pendingElicitations.remove(at: index).elicitation
    addNotice(Self.elicitationNote(elicitation, answer: answer))
  }

  /// The CLI took the question back.
  private mutating func withdrawElicitation(requestID: String) {
    guard let index = pendingElicitations.firstIndex(where: { $0.requestID == requestID })
    else { return }
    let elicitation = pendingElicitations.remove(at: index).elicitation
    let server = Self.asker(elicitation)
    addNotice(
      elicitation.message.isEmpty
        ? String(localized: "\(server) withdrew its question")
        : String(localized: "\(server) withdrew its question: \(elicitation.message)"))
  }

  /// The newest tool call of `serverName`'s tools still without a result in the current turn
  /// (after the latest prompt), or nil: an earlier turn's call left without one was
  /// interrupted, and asks nothing. Claude Code names a server's tools
  /// `mcp__<server>__<tool>`, every character of the server's name outside `[A-Za-z0-9_-]`
  /// made `_`.
  public func elicitationAnchor(for serverName: String) -> String? {
    let prefix = "mcp__\(Self.toolNamePart(serverName))__"
    for entry in entries.reversed() {
      switch entry.kind {
      case .prompt: return nil
      case .tool(let call) where call.result == nil && call.name.hasPrefix(prefix): return call.id
      case .text, .thinking, .tool, .notice, .failure: continue
      }
    }
    return nil
  }

  /// Per UTF-16 unit, as the CLI's JavaScript replaces them.
  private static func toolNamePart(_ name: String) -> String {
    String(
      name.utf16.map { unit in
        guard let scalar = Unicode.Scalar(unit), scalar.isASCII,
          scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_"
            || scalar == "-"
        else { return "_" }
        return Character(scalar)
      })
  }

  /// The process died. Nothing is running any more and nothing can still be answered,
  /// whatever the last line said.
  public mutating func processExited() {
    revision += 1
    isRunning = false
    pendingPermissions.removeAll()
    pendingElicitations.removeAll()
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

  /// `time` is when the event arrived: what times thinking streamed live and a prompt taken
  /// from the queue.
  public mutating func apply(_ event: AgentEvent, at time: Date = .now) {
    revision += 1
    switch event {
    case .sessionStarted(let info):
      session = info
    case .prompt(let prompt, let running):
      addPrompt(
        prompt.text, context: prompt.context, attachments: prompt.attachments, uuid: prompt.uuid,
        running: running, at: time)
    case .turnOutcome(let end):
      turnEnd = end
    case .turnStarted:
      isRunning = true
      turnEnd = nil
    case .turnEnded(let summary):
      lastTurn = summary
      turnEnd = summary.outcome
      retry = nil
      isRunning = false
      isCompacting = false
      if let failure = summary.failureText, !endsSaying(failure) { addNote(.failure(failure)) }
      // A turn that ended cannot still be asking, nor thinking.
      pendingPermissions.removeAll()
      pendingElicitations.removeAll()
      stopThinking()
    case .itemStarted(let item):
      place(item, replacing: false, at: time)
    case .itemCompleted(let item):
      place(item, replacing: true, at: time)
    case .itemDelta(let id, let delta):
      guard let position = indexByID[id] else { return }
      switch (entries[position].kind, delta) {
      case (.text(let text), .text(let more)): entries[position].kind = .text(text + more)
      case (.thinking(let text), .thinking(let more)):
        entries[position].kind = .thinking(text + more)
      default: break
      }
    case .toolResult(let id, let result):
      guard let index = indexByID[id], case .tool(var call) = entries[index].kind else { return }
      call.result = result
      entries[index].kind = .tool(call)
    case .note(let note):
      addNote(note.isFailure ? .failure(note.text) : .notice(note.text), parent: note.parent)
    case .permissionRequested(let pending):
      pendingPermissions.append(pending)
    case .permissionWithdrawn(let id):
      resolvePermission(requestID: id)
      withdrawElicitation(requestID: id)
    case .elicitationRequested(let pending):
      pendingElicitations.append(pending)
    case .requestSent(let at):
      requestAt = at
    case .usage(let sample):
      contextUsage = sample.usage
      contextModelID = sample.model ?? contextModelID
      if let window = sample.window { contextWindow = window }
      if let at = sample.at {
        promptCache.record(
          messageID: sample.messageID, usage: sample.usage, at: at, requestAt: requestAt)
        requestAt = nil
      }
    case .retrying(let retry):
      self.retry = retry
    case .compaction(.started):
      isCompacting = true
    case .compaction(.stopped):
      isCompacting = false
    case .compaction(.finished(let note, let at)):
      isCompacting = false
      if let at { promptCache.compacted(at: at) }
      addNotice(note)
    case .todos(let todos):
      self.todos = todos
    case .agentTask(let call, let update):
      agentTasks[call, default: AgentTask()].apply(update)
    case .queue(let id, let change):
      guard let index = queuedPrompts.firstIndex(where: { $0.uuid == id }) else { return }
      let prompt = queuedPrompts.remove(at: index)
      switch change {
      case .started:
        addPrompt(
          prompt.text, context: prompt.context, attachments: prompt.attachments, uuid: prompt.uuid,
          at: time)
      case .cancelled:
        break
      case .dropped(let agent):
        addNotice(String(localized: "\(agent) did not take a queued message: \(prompt.text)"))
      }
    case .title(.custom(let title)):
      customTitle = title
    case .title(.ai(let title)):
      aiTitle = title
    case .historyMeta(.writerVersion(let version)):
      writerVersion = version
    case .historyMeta(.permissionMode(let mode)):
      historyPermissionMode = mode
    case .historyMeta(.effort(let effort)):
      historyEffort = effort
    }
  }

  /// Puts an item at its id. A tool call keeps a result that reached it first.
  private mutating func place(_ item: AgentEvent.Item, replacing: Bool, at time: Date) {
    var kind = item.kind.transcriptKind
    if case .tool(var call) = kind, let index = indexByID[item.id],
      case .tool(let existing) = entries[index].kind, call.result == nil
    {
      call.result = existing.result
      kind = .tool(call)
    }
    if let index = indexByID[item.id] {
      // A started item is empty by definition, and a thinking block can land whole with its
      // text withheld after its deltas showed some: never replace with nothing.
      if replacing && !Self.isEmptyText(kind) { entries[index].kind = kind }
      if replacing, let since = entries[index].thinkingSince {
        entries[index].thinkingSince = nil
        entries[index].thinkingDuration = time.timeIntervalSince(since)
        thinkingIDs.remove(item.id)
      }
    } else {
      var entry = Entry(id: item.id, kind: kind, parentToolUseID: item.parent)
      if !replacing, case .thinking = kind {
        entry.thinkingSince = time
        thinkingIDs.insert(item.id)
      }
      upsert(entry)
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

  /// What became of a question. Never what the person entered.
  static func elicitationNote(_ elicitation: Elicitation, answer: ElicitationAnswer) -> String {
    let server = asker(elicitation)
    if case .accept = answer, case .url(let url) = elicitation.content {
      let host = url.host() ?? url.absoluteString
      return String(localized: "Opened \(server)'s link to \(host)")
    }
    let question = elicitation.message
    return switch (answer, question.isEmpty) {
    case (.accept, false): String(localized: "Answered \(server)'s question: \(question)")
    case (.accept, true): String(localized: "Answered \(server)'s question")
    case (.decline, false): String(localized: "Declined \(server)'s question: \(question)")
    case (.decline, true): String(localized: "Declined \(server)'s question")
    case (.cancel, false): String(localized: "Cancelled \(server)'s question: \(question)")
    case (.cancel, true): String(localized: "Cancelled \(server)'s question")
    }
  }

  /// The server's name as the card shows it, which may start a note in lower case, as
  /// `linear` does; "an MCP server" for a request that named none.
  private static func asker(_ elicitation: Elicitation) -> String {
    elicitation.serverLabel.isEmpty
      ? String(localized: "an MCP server") : elicitation.serverLabel
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
    guard kind == .question else { return nil }
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
public struct QueuedPrompt: Codable, Sendable, Equatable, Identifiable {
  public var uuid: String
  public var text: String
  /// What the editor attached, labelled as on a prompt.
  public var context: String?
  public var attachments: [AttachmentPreview]

  public var id: String { uuid }

  public init(
    uuid: String, text: String, context: String? = nil, attachments: [AttachmentPreview] = []
  ) {
    self.uuid = uuid
    self.text = text
    self.context = context
    self.attachments = attachments
  }
}
