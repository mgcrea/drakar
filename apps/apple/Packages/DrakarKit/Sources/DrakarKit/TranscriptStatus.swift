import Foundation

extension Transcript {
  /// What is read about a session outside its transcript view: its row, its window's counts,
  /// Home, attention, keep-awake, and the pane around the transcript (composer, panels,
  /// footer, pills). It changes with what the session is doing, not with each token, so a
  /// reader of it is not redrawn while text streams in.
  public struct Status: Sendable, Equatable {
    public var session: SessionInfo?
    public var title: String?
    /// The first prompt's opening 80 characters: the row's name before there is a title.
    public var firstPrompt: String?
    public var hasEntries = false
    public var isRunning = false
    public var pendingPermissions: [PendingPermission] = []
    public var pendingElicitations: [PendingElicitation] = []
    /// What the newest turn ended on; nil while it runs and while anything waits.
    public var closingText: ClosingText?
    public var pauses = 0
    /// The newest main-thread request's tokens and model, for the context gauge.
    public var contextUsage: TokenUsage?
    public var contextModelID: String?
    /// The newest todo list the main thread wrote.
    public var todos: [Todo]?
    /// The question the conversation ended on, unanswered: its card answers it.
    public var unansweredQuestion: ToolCall?
    /// The first `AskUserQuestion` waiting has its call in the transcript, so its card answers
    /// it rather than the composer's place.
    public var choiceHasCard = false
    /// The call whose card answers the first MCP server's question waiting, when the
    /// transcript draws one on the main thread.
    public var elicitationAnchor: String?
    /// For the session's footer and pills.
    public var promptCache = PromptCache()
    public var historyPermissionMode: String?
    public var historyEffort: String?
    public var writerVersion: String?
    public var lastTurn: TurnSummary?

    public init() {}

    public var isWaitingOnPerson: Bool {
      !pendingPermissions.isEmpty || !pendingElicitations.isEmpty
    }
  }

  /// Cheap enough to take after every change: each part is stored or kept as entries
  /// arrive, and the closing text is only looked for once a turn has ended, from the end.
  public var status: Status {
    var status = Status()
    status.session = session
    status.title = title
    status.hasEntries = !entries.isEmpty
    if let index = firstPromptIndex, case .prompt(let text) = entries[index].kind {
      status.firstPrompt = String(text.prefix(80))
    }
    status.isRunning = isRunning
    status.pendingPermissions = pendingPermissions
    status.pendingElicitations = pendingElicitations
    status.closingText = closingText
    status.pauses = pauses
    status.contextUsage = contextUsage
    status.contextModelID = contextModelID
    status.todos = todos
    status.unansweredQuestion = unansweredQuestion
    if let id = pendingPermissions.first(where: { $0.request.isChoice })?.request.toolUseID {
      status.choiceHasCard = contains(entryID: id)
    }
    // A scan back to the last prompt, so only while a question waits, when nothing streams.
    status.elicitationAnchor = pendingElicitations.first.flatMap {
      elicitationCard(for: $0.elicitation)
    }
    status.promptCache = promptCache
    status.historyPermissionMode = historyPermissionMode
    status.historyEffort = historyEffort
    status.writerVersion = writerVersion
    status.lastTurn = lastTurn
    return status
  }
}
