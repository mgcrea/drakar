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
  private var noticeCount = 0

  public init() {}

  public mutating func addPrompt(_ text: String) {
    revision += 1
    promptCount += 1
    upsert(Entry(id: "prompt#\(promptCount)", kind: .prompt(text)))
    isRunning = true
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
      for case .text(let text) in user.content where !text.isEmpty {
        noticeCount += 1
        upsert(
          Entry(
            id: "notice#\(noticeCount)", kind: .notice(text), parentToolUseID: user.parentToolUseID)
        )
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
