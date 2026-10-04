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
  }

  public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var result: ToolResult?

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

    public init(content: String, isError: Bool) {
      self.content = content
      self.isError = isError
    }
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
  /// The session's title, from the newest `ai-title` in its history.
  public internal(set) var title: String?
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
      case .prompt, .tool, .notice: break scan
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

  public init() {}

  /// `running: false` for a prompt replayed from history, whose turn ended long ago.
  /// `context` labels what the editor attached (`EditorSelection.label`, several
  /// separated by commas).
  public mutating func addPrompt(_ text: String, context: String? = nil, running: Bool = true) {
    revision += 1
    promptCount += 1
    let id = "prompt#\(promptCount)"
    upsert(Entry(id: id, kind: .prompt(text), context: context))
    lastPromptID = id
    isRunning = running
    turnEnd = nil
  }

  mutating func addNotice(_ text: String, parent: String? = nil) {
    revision += 1
    noticeCount += 1
    upsert(Entry(id: "notice#\(noticeCount)", kind: .notice(text), parentToolUseID: parent))
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
  }

  public mutating func apply(_ message: StreamMessage) {
    revision += 1
    switch message {
    case .system(.initialized(let info)):
      session = info
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
          parent: assistant.parentToolUseID, replacing: true)
      }
      blockCount[assistant.messageID] = index + assistant.content.count
    case .streamEvent(let event, let parent):
      apply(event, parent: parent)
    case .user(let user):
      // Live, the CLI never echoes our prompts, so any text it writes as a user turn is a
      // note of its own: an interrupt, a background task finishing.
      for case .text(let text) in user.content {
        switch UserText.classify(text) {
        case .prompt(let note), .notice(let note): addNotice(note, parent: user.parentToolUseID)
        case .context, .hidden: break
        }
      }
      for case .toolResult(let id, let content, let isError) in user.content {
        guard let index = indexByID[id], case .tool(var call) = entries[index].kind else {
          continue
        }
        call.result = ToolResult(content: content, isError: isError)
        entries[index].kind = .tool(call)
      }
    case .controlRequest(let request):
      if case .canUseTool(let permission) = request.kind {
        pendingPermissions.append(
          PendingPermission(requestID: request.requestID, request: permission))
      }
    case .controlCancelRequest(let id):
      resolvePermission(requestID: id)
    case .result(let result):
      lastResult = result
      turnEnd = result.wasInterrupted ? .interrupted : result.isError ? .failed : .completed
      isRunning = false
      // A turn that ended cannot still be asking.
      pendingPermissions.removeAll()
    case .system, .controlResponse, .rateLimit, .unknown:
      break
    }
  }

  private mutating func apply(_ event: StreamEvent, parent: String?) {
    switch event {
    case .messageStart(let id):
      streamingMessage[parent] = id
    case .blockStart(let index, let block):
      guard let message = streamingMessage[parent] else { return }
      place(block, id: "\(message)#\(index)", parent: parent, replacing: false)
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
  private mutating func place(_ block: ContentBlock, id: String, parent: String?, replacing: Bool) {
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
    case .toolResult, .other:
      return
    }
    if let index = indexByID[key] ?? indexByID[id] {
      // The stream path made this entry; the whole block replaces it. Never with nothing:
      // a block start is empty by definition, and a thinking block can land whole with its
      // text withheld after its deltas showed some.
      if replacing && !Self.isEmptyText(kind) { entries[index].kind = kind }
    } else {
      upsert(Entry(id: key, kind: kind, parentToolUseID: parent))
    }
    indexByID[id] = indexByID[key]
  }

  private static func isEmptyText(_ kind: Kind) -> Bool {
    switch kind {
    case .text(let text), .thinking(let text): text.isEmpty
    case .prompt, .tool, .notice: false
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
