import Foundation

/// Compacting a long conversation shortly before its prompt cache expires, while the cache
/// still makes the summary cheap, so the next message an hour on re-sends the summary rather
/// than the whole conversation uncached.
///
/// Claude Code does this itself (`idleCompaction`, 2.1.316) only for a session it takes to be
/// attended: a terminal's, or one whose entrypoint is on its list (`claude-vscode`,
/// `claude-desktop`…). Drakar's run as `sdk-cli`, which is not, so Drakar does it for them,
/// by the CLI's rules: an hour's cache only, at 90 % of it, auto-compact on, and a context
/// of at least the floor.
public enum IdleCompaction {
  /// How far into the cache's hour it is due: the CLI's 0.9, six minutes before expiry.
  static let share = 0.9
  /// Later than this past its time (a Mac asleep through it), and the cache may have gone:
  /// the CLI's 60 s.
  static let lateness: TimeInterval = 60
  static let defaultFloor = 200_000
  static let lowestFloor = 100_000

  /// When the session is due to compact; nil unless its newest request cached for an hour,
  /// and since the last compaction.
  public static func due(_ cache: PromptCache) -> Date? {
    guard cache.compactedAt == nil, cache.ttl == .oneHour, let anchor = cache.anchor else {
      return nil
    }
    return anchor.addingTimeInterval(PromptCache.TTL.oneHour.duration * share)
  }

  /// The smallest context worth compacting, as the CLI reads it: 200k, or
  /// `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS`, never under 100k.
  public static func floor(environment: [String: String]) -> Int {
    let set = environment["CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS"].flatMap { Int($0) }
    return max(lowestFloor, set ?? defaultFloor)
  }

  public enum Refusal: Sendable, Equatable {
    case autoCompactOff, early, lapsed, small
  }

  /// Why a session due at `due` should not compact at `now`; nil when it should.
  /// `contextTokens` is its newest request's, nil when unknown.
  public static func refusal(
    at now: Date, due: Date, contextTokens: Int?, autoCompacts: Bool, floor: Int
  ) -> Refusal? {
    if !autoCompacts { return .autoCompactOff }
    if now < due { return .early }
    if now.timeIntervalSince(due) > lateness { return .lapsed }
    if (contextTokens ?? 0) < floor { return .small }
    return nil
  }
}

/// A compaction Drakar starts, idle or asked for, with the command Settings runs before it
/// (`/distill`): what to send now, and what at the end of each turn it sent.
public struct CompactionRun: Sendable, Equatable {
  public static let compact = "/compact"

  /// Sent before compacting; nil for none.
  public let first: String?
  /// Started by the timer rather than the person, who is likely away.
  public let isIdle: Bool
  private var compacting: Bool

  /// A blank `first` is none.
  public init(first: String?, idle: Bool) {
    let trimmed = first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.first = trimmed.isEmpty ? nil : trimmed
    isIdle = idle
    compacting = self.first == nil
  }

  /// What to send now.
  public var prompt: String { compacting ? Self.compact : first ?? Self.compact }

  /// The command first is what was sent last.
  public var isRunningFirst: Bool { !compacting }

  /// The turn sent ended: what to send next, or nil when the run is over. A first turn that
  /// stopped to ask the person (`asked`) ends it: they came back to answer, and what comes
  /// next is theirs to say.
  public mutating func turnEnded(asked: Bool) -> String? {
    guard !compacting, !asked else { return nil }
    compacting = true
    return Self.compact
  }
}
