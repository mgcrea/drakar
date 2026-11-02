import Foundation

extension Transcript {
  /// What is read about a session from outside its own transcript: its row, its window's
  /// counts, Home, attention and keep-awake. It changes with what the session is doing, not
  /// with each token, so a reader of it is not redrawn while text streams in.
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
    return status
  }
}
