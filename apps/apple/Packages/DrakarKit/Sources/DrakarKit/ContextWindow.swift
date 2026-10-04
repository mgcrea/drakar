import Foundation

/// How big a session's context window is, and where that answer came from.
///
/// Nothing on disk states it, and `message.model` reads `claude-opus-5` for a 200k session
/// and a 1M one alike (Armada, `docs/claude-code-sessions.md`). A process Drakar owns says
/// it exactly (`get_context_usage`); for the rest, the best source available answers and
/// carries its provenance for the tooltip.
public struct ContextWindow: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    /// `maxTokens` from the process's own `get_context_usage`. Exact.
    case reported
    /// The session's `system/init` model or its `attachment`/`model` entry. Exact.
    case sessionModel(String)
    /// The account's configured model: right until the session runs `/model`.
    case accountDefault(String)
    /// `message.model`, which never carries the variant.
    case assumed(String)
    case unknown
    /// The session already used more than the other sources allowed.
    case observed

    public var explanation: String {
      switch self {
      case .reported: String(localized: "Reported by the session.")
      case .sessionModel(let id): String(localized: "This session runs \(id).")
      case .accountDefault(let id):
        String(
          localized:
            "Assumed from this account's model, \(id). A session that changed model with /model may have another window."
        )
      case .assumed(let id):
        String(
          localized:
            "Assumed from \(id). Claude Code does not record the window size, and the model it records does not tell a 1M session from a 200k one."
        )
      case .unknown: String(localized: "No model recorded; the usual window size.")
      case .observed:
        String(
          localized:
            "This session has used more than its model's usual window, so its window is larger.")
      }
    }
  }

  public var limit: Int
  public var source: Source

  public init(limit: Int, source: Source) {
    self.limit = limit
    self.source = source
  }

  public static let standardLimit = 200_000
  public static let extendedLimit = 1_000_000

  /// `[1m]` is the only thing in an id that changes the answer today; this fails open to
  /// the common case rather than keeping a table of ids.
  public static func limit(forModelID id: String) -> Int {
    id.contains("[1m]") ? extendedLimit : standardLimit
  }

  public static func resolve(
    sessionModelID: String?, accountModelID: String?, messageModelID: String?, observedTotal: Int
  ) -> ContextWindow {
    let window: ContextWindow =
      if let id = sessionModelID {
        ContextWindow(limit: limit(forModelID: id), source: .sessionModel(id))
      } else if let id = accountModelID {
        ContextWindow(limit: limit(forModelID: id), source: .accountDefault(id))
      } else if let id = messageModelID {
        ContextWindow(limit: limit(forModelID: id), source: .assumed(id))
      } else {
        ContextWindow(limit: standardLimit, source: .unknown)
      }
    guard observedTotal > window.limit else { return window }
    return ContextWindow(limit: max(extendedLimit, observedTotal), source: .observed)
  }

  /// The `model` in an account's `settings.json` (`opus[1m]`), or nil.
  public static func accountModelID(_ account: ClaudeAccount) -> String? {
    let file = account.directory.appending(path: "settings.json")
    guard let data = try? Data(contentsOf: file), let json = try? JSONValue.parse(data),
      let model = json["model"]?.stringValue, !model.isEmpty
    else { return nil }
    return model
  }
}

/// What the sidebar's gauge draws: how much of the window a session's context fills.
public struct ContextGauge: Sendable, Equatable {
  public enum Level: Sendable, Equatable {
    case normal
    /// From 75 %.
    case high
    /// From 90 %.
    case critical
  }

  public var used: Int
  public var window: ContextWindow

  public init(used: Int, window: ContextWindow) {
    self.used = used
    self.window = window
  }

  public var fraction: Double { min(Double(used) / Double(max(window.limit, 1)), 1) }

  public var level: Level {
    fraction >= 0.9 ? .critical : fraction >= 0.75 ? .high : .normal
  }

  /// A gauge from whatever is known, best source first: a reported limit, the session's own
  /// model (`system/init`, then its attachment), the account's, the message's.
  public static func make(
    usage: TokenUsage?, reportedLimit: Int?, initModelID: String?, attachmentModelID: String?,
    accountModelID: String?, messageModelID: String?
  ) -> ContextGauge? {
    guard let usage else { return nil }
    let window =
      reportedLimit.map { ContextWindow(limit: $0, source: .reported) }
      ?? ContextWindow.resolve(
        sessionModelID: initModelID ?? attachmentModelID, accountModelID: accountModelID,
        messageModelID: messageModelID, observedTotal: usage.total)
    return ContextGauge(used: usage.total, window: window)
  }
}
