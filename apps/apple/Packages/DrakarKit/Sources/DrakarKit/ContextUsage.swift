import Foundation

/// The tokens one API request reported, from an `assistant` entry's `message.usage`.
public struct TokenUsage: Sendable, Equatable, Hashable {
  public var input: Int
  public var cacheCreation: Int
  public var cacheRead: Int
  public var output: Int
  /// How long what this request wrote stays cached, from `cache_creation`'s split: an hour
  /// when any of it went to the hour-long cache. Nil when it wrote nothing, or the split is
  /// missing.
  public var cacheWriteTTL: PromptCache.TTL?

  public init(
    input: Int, cacheCreation: Int, cacheRead: Int, output: Int,
    cacheWriteTTL: PromptCache.TTL? = nil
  ) {
    self.input = input
    self.cacheCreation = cacheCreation
    self.cacheRead = cacheRead
    self.output = output
    self.cacheWriteTTL = cacheWriteTTL
  }

  /// Nil unless all three input figures are there: a shape change that dropped one would
  /// otherwise read as a session with an empty context.
  public init?(_ json: JSONValue?) {
    guard let json, let input = json["input_tokens"]?.intValue,
      let creation = json["cache_creation_input_tokens"]?.intValue,
      let read = json["cache_read_input_tokens"]?.intValue
    else { return nil }
    let split = json["cache_creation"]
    let ttl: PromptCache.TTL? =
      if split?["ephemeral_1h_input_tokens"]?.intValue ?? 0 > 0 {
        .oneHour
      } else if split?["ephemeral_5m_input_tokens"]?.intValue ?? 0 > 0 {
        .fiveMinutes
      } else {
        nil
      }
    self.init(
      input: input, cacheCreation: creation, cacheRead: read,
      output: json["output_tokens"]?.intValue ?? 0, cacheWriteTTL: ttl)
  }

  /// The whole prompt, which is the context: fresh input, plus what this request wrote to
  /// the cache, plus what it read back. `input` alone is near zero on a warm turn.
  public var total: Int { input + cacheCreation + cacheRead }
}

/// How full a session's context was at its newest main-thread turn.
public struct ContextReading: Sendable, Equatable, Hashable {
  public var usage: TokenUsage
  /// `message.model`. Never carries `[1m]`, so it cannot say the window size on its own.
  public var modelID: String?
  public var at: Date?

  public init(usage: TokenUsage, modelID: String?, at: Date?) {
    self.usage = usage
    self.modelID = modelID
    self.at = at
  }

  public var total: Int { usage.total }
}

/// The end of a transcript file, where everything a session list wants sits: the newest
/// turn's usage, the model attachment, whether a tool call is unanswered. One read serves
/// all three (Armada's `TranscriptTitle.tail`).
public struct TranscriptTail: Sendable {
  /// The newest title sits a median 15KB from the end; 64KB finds it in 96 % of
  /// transcripts (Armada's measurement), and the newest usage is nearer still.
  public static let bytes = 64 * 1024

  public var data: Data
  /// True when the read did not start at byte zero, so its first line is a fragment.
  public var dropsFirstLine: Bool

  public init(data: Data, dropsFirstLine: Bool) {
    self.data = data
    self.dropsFirstLine = dropsFirstLine
  }

  /// The last `bytes` of a buffer already in memory (a mapped file).
  public init(suffixOf data: Data) {
    let start = max(data.startIndex, data.endIndex - Self.bytes)
    self.init(data: Data(data[start...]), dropsFirstLine: start > data.startIndex)
  }

  public static func read(_ url: URL) -> TranscriptTail? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return nil }
    return TranscriptTail(data: data, dropsFirstLine: start > 0)
  }

  private var newestFirst: JSONLines.NewestFirst {
    JSONLines.newestFirst(data, droppingFirstLine: dropsFirstLine)
  }

  public var newestReading: ContextReading? {
    for line in newestFirst {
      if let reading = Self.reading(line) { return reading }
    }
    return nil
  }

  /// The session's own `attachment`/`model` entry, the one place `[1m]` is written. Present
  /// in a minority of transcripts; absent is normal.
  public var newestModelID: String? {
    for line in newestFirst where line.range(of: Data(#""modelId""#.utf8)) != nil {
      guard let json = try? JSONValue.parse(line), json["type"]?.stringValue == "attachment",
        let attachment = json["attachment"], attachment["type"]?.stringValue == "model",
        let id = attachment["identity"]?["modelId"]?.stringValue, !id.isEmpty
      else { continue }
      return id
    }
    return nil
  }

  /// Whether the newest turn is an assistant's `tool_use` nobody answered: a long command,
  /// or a prompt nobody has answered. A guess, and the UI says so.
  public var isAwaitingToolResult: Bool { !unansweredToolCalls.isEmpty }

  /// The first question of an `AskUserQuestion` the newest turn called and nobody answered:
  /// a session elsewhere waiting on a choice, which its registry only calls waiting.
  public var pendingUserQuestion: String? {
    unansweredToolCalls.lazy.filter { $0["name"]?.stringValue == "AskUserQuestion" }
      .compactMap { UserQuestion.list($0["input"] ?? .null).first?.question }.first
  }

  /// The `tool_use` blocks of the newest main-thread message, when it is an assistant's.
  private var unansweredToolCalls: [JSONValue] {
    for line in newestFirst {
      guard let json = try? JSONValue.parse(line), json["isSidechain"]?.boolValue != true
      else { continue }
      switch json["type"]?.stringValue {
      case "assistant":
        return json["message"]?["content"]?.arrayValue?.filter {
          $0["type"]?.stringValue == "tool_use"
        } ?? []
      case "user": return []
      default: continue
      }
    }
    return []
  }

  /// The text the newest main-thread turn ended on, when its last message ended the turn
  /// (`end_turn`) and nothing was sent after it: what a row whose history is not read
  /// shows its ask from. Every block of a message is its own line, newest first here.
  public var closingText: ClosingText? {
    var messageID: String?
    var parts: [String] = []
    for line in newestFirst {
      guard let json = try? JSONValue.parse(line), json["isSidechain"]?.boolValue != true
      else { continue }
      switch json["type"]?.stringValue {
      case "user":
        if json["isMeta"]?.boolValue == true { continue }
        // Newer than any assistant line: the person answered, or interrupted.
        guard messageID != nil else { return nil }
        return Self.closing(messageID, parts)
      case "assistant":
        guard let message = json["message"], let id = message["id"]?.stringValue else {
          continue
        }
        if let messageID, id != messageID { return Self.closing(messageID, parts) }
        if messageID == nil {
          guard message["stop_reason"]?.stringValue == "end_turn",
            message["model"]?.stringValue != Self.syntheticModel
          else { return nil }
          messageID = id
        }
        for block in (message["content"]?.arrayValue ?? []).reversed()
        where block["type"]?.stringValue == "text" {
          if let text = block["text"]?.stringValue { parts.insert(text, at: 0) }
        }
      default: continue
      }
    }
    return Self.closing(messageID, parts)
  }

  private static func closing(_ messageID: String?, _ parts: [String]) -> ClosingText? {
    let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let messageID, !text.isEmpty else { return nil }
    return ClosingText(messageID: messageID, text: text)
  }

  /// `message.model` of a turn the CLI wrote itself rather than the API answered ("You've
  /// hit your session limit", an API error), with all-zero usage: never a context reading.
  public static let syntheticModel = "<synthetic>"

  static func reading(_ line: Data) -> ContextReading? {
    // Cheap reject first: most lines are not assistant turns.
    guard line.range(of: Data(#""usage""#.utf8)) != nil, let json = try? JSONValue.parse(line),
      json["type"]?.stringValue == "assistant", json["isSidechain"]?.boolValue != true,
      let message = json["message"], message["model"]?.stringValue != syntheticModel,
      let usage = TokenUsage(message["usage"])
    else { return nil }
    return ContextReading(
      usage: usage, modelID: message["model"]?.stringValue,
      at: ClaudeTranslator.timestamp(of: json))
  }
}

/// The answer to `get_context_usage`: the window the process runs with, and what fills it.
public struct ContextUsageReply: Sendable, Equatable {
  public struct Category: Sendable, Equatable {
    public var name: String
    public var tokens: Int
  }

  public var totalTokens: Int
  public var maxTokens: Int
  /// The categories that occupy the window, largest first: the remainder, the reserve and
  /// the deferred tools are left out, as Claude Code leaves them out of its own total.
  public var categories: [Category]

  static let excluded: Set<String> = ["Free space", "Autocompact buffer", "Compact buffer"]

  public init?(_ response: JSONValue?) {
    guard let response, let total = response["totalTokens"]?.intValue,
      let max = response["maxTokens"]?.intValue, max > 0
    else { return nil }
    totalTokens = total
    maxTokens = max
    categories = (response["categories"]?.arrayValue ?? []).compactMap { entry in
      guard let name = entry["name"]?.stringValue, let tokens = entry["tokens"]?.intValue,
        tokens > 0, !Self.excluded.contains(name), entry["isDeferred"]?.boolValue != true,
        entry["kind"]?.stringValue != "deferred", entry["kind"]?.stringValue != "free"
      else { return nil }
      return Category(name: name, tokens: tokens)
    }
    .sorted { $0.tokens > $1.tokens }
  }
}
