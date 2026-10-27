import Foundation

/// What changed in a conversation, in no agent's words: how a `Transcript` learns what its
/// agent said. Each agent's translator turns its wire format into these
/// (`ClaudeTranslator`; Codex's in slice 2), so the transcript knows no wire format.
///
/// Items are addressed by their own id, never by "the current turn": Codex completes a
/// command its interrupted turn left running during a later turn (docs/codex-app-server.md).
/// What the person does (a prompt sent, a request answered, the process gone) stays the
/// transcript's own methods.
public enum AgentEvent: Sendable, Equatable {
  case sessionStarted(SessionInfo)
  /// A prompt the agent's record shows: a history line. `running` false for one whose turn
  /// ended long ago.
  case prompt(Prompt, running: Bool)
  /// How the newest turn ended is known, without the end-of-turn bookkeeping: Claude's
  /// history marks `stop_reason: end_turn` and has no result line.
  case turnOutcome(Transcript.TurnEnd)
  /// A turn begins, prompted or not: Claude Code answers a background task's notification
  /// in a turn of its own, with no prompt to say the session is at work.
  case turnStarted
  case turnEnded(TurnSummary)
  /// A text, a thinking block or a tool call begins: streaming follows.
  case itemStarted(Item)
  case itemDelta(id: String, Delta)
  /// The whole item. Never blanks text that streamed.
  case itemCompleted(Item)
  case toolResult(callID: String, Transcript.ToolResult)
  case note(Note)
  case permissionRequested(Transcript.PendingPermission)
  /// Also withdraws an elicitation with that id.
  case permissionWithdrawn(requestID: String)
  case elicitationRequested(Transcript.PendingElicitation)
  /// A main-thread request went out: what the prompt cache is reckoned from.
  case requestSent(at: Date)
  case usage(ContextSample)
  /// Nil: whatever was being retried is over.
  case retrying(APIRetry?)
  case compaction(Compaction)
  case todos([Todo])
  case agentTask(callID: String, AgentTaskUpdate)
  case queue(id: String, QueueChange)
  case title(Title)
  case historyMeta(HistoryMeta)

  public struct Item: Sendable, Equatable {
    public var id: String
    /// The subagent call it runs under; nil on the main thread.
    public var parent: String?
    public var kind: ItemKind

    public init(id: String, parent: String?, kind: ItemKind) {
      self.id = id
      self.parent = parent
      self.kind = kind
    }
  }

  /// What an agent's item can be. A prompt or a notice is never one: those keep the
  /// transcript's own bookkeeping.
  public enum ItemKind: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case tool(Transcript.ToolCall)

    /// The entry it becomes.
    public var transcriptKind: Transcript.Kind {
      switch self {
      case .text(let text): .text(text)
      case .thinking(let text): .thinking(text)
      case .tool(let call): .tool(call)
      }
    }
  }

  public enum Delta: Sendable, Equatable {
    case text(String)
    case thinking(String)
  }

  public struct Prompt: Sendable, Equatable {
    public var text: String
    public var context: String?
    public var attachments: [AttachmentPreview]

    public init(text: String, context: String? = nil, attachments: [AttachmentPreview] = []) {
      self.text = text
      self.context = context
      self.attachments = attachments
    }
  }

  public struct Note: Sendable, Equatable {
    public var text: String
    public var isFailure: Bool
    public var parent: String?

    public init(text: String, isFailure: Bool = false, parent: String? = nil) {
      self.text = text
      self.isFailure = isFailure
      self.parent = parent
    }
  }

  /// A main-thread request's tokens: the session's context.
  public struct ContextSample: Sendable, Equatable {
    /// What the prompt cache keys its anchor by: every block of one message repeats it.
    public var messageID: String
    public var usage: TokenUsage
    public var model: String?
    /// The model's context window, when the agent says it (Codex does, Claude does not).
    public var window: Int?
    /// When it arrived or was written; nil leaves the prompt cache as it was.
    public var at: Date?

    public init(
      messageID: String, usage: TokenUsage, model: String?, window: Int? = nil, at: Date?
    ) {
      self.messageID = messageID
      self.usage = usage
      self.model = model
      self.window = window
      self.at = at
    }
  }

  public enum Compaction: Sendable, Equatable {
    case started
    case stopped
    /// `at` nil leaves the prompt cache as it was.
    case finished(note: String, at: Date?)
  }

  public enum QueueChange: Sendable, Equatable {
    /// Taken into a turn, or joined the running one.
    case started
    case cancelled
    /// Refused or discarded, by the agent named.
    case dropped(agent: String)
  }

  public enum Title: Sendable, Equatable {
    case custom(String)
    case ai(String)
  }

  /// What a transcript file says of the session another process runs.
  public enum HistoryMeta: Sendable, Equatable {
    case writerVersion(String)
    case permissionMode(String)
    /// Nil when the newest reply names none (a model without effort).
    case effort(String?)
  }
}

/// A history counted in turns, as a Codex thread is: a turn opens with `turnStarted`, or in a
/// stored thread with its prompt, and ends once, with `turnEnded` live or `turnOutcome`
/// stored. Claude Code's live turns end with both, so they are not counted this way.
extension Array where Element == AgentEvent {
  /// The events up to and including the `count`th turn's end; for 0, those before the first
  /// turn opens.
  public func throughTurns(_ count: Int) -> [AgentEvent] {
    guard count > 0 else { return Array(prefix { !$0.opensTurn }) }
    var ended = 0
    for (index, event) in enumerated() where event.endsTurn {
      ended += 1
      if ended == count { return Array(self[...index]) }
    }
    return self
  }

  public var turnsEnded: Int { count { $0.endsTurn } }
}

extension AgentEvent {
  fileprivate var opensTurn: Bool {
    switch self {
    case .turnStarted, .prompt: true
    default: false
    }
  }

  fileprivate var endsTurn: Bool {
    switch self {
    case .turnEnded, .turnOutcome: true
    default: false
    }
  }
}

/// How a turn ended, as far as its agent said.
public struct TurnSummary: Sendable, Equatable {
  public var outcome: Transcript.TurnEnd
  /// Why it failed, when it did and the agent said.
  public var failureText: String?
  /// What it ended on, when the agent repeats it with the end.
  public var text: String?
  public var costUSD: Double?
  public var durationMS: Int?

  public init(
    outcome: Transcript.TurnEnd, failureText: String? = nil, text: String? = nil,
    costUSD: Double? = nil, durationMS: Int? = nil
  ) {
    self.outcome = outcome
    self.failureText = failureText
    self.text = text
    self.costUSD = costUSD
    self.durationMS = durationMS
  }
}

/// What became known of a subagent, by the call that started it. Nil fields say nothing.
public struct AgentTaskUpdate: Sendable, Equatable {
  /// The first word of it: its description wins over one guessed earlier.
  public var isStart = false
  public var description: String?
  public var isBackgrounded: Bool?
  public var status: String?
  public var summary: String?
  public var lastToolName: String?
  public var toolUses: Int?
  public var totalTokens: Int?
  public var durationMS: Int?
  /// What it was asked, forwarded from inside it.
  public var prompt: String?

  public init() {}
}
