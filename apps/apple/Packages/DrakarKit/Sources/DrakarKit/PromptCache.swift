import Foundation

/// How long the API keeps what a session's requests cached, reckoned as the VS Code
/// extension reckons it (2.1.289): from when the request behind the newest main-thread
/// message was sent, for as long as that message wrote to the cache for, an hour or five
/// minutes. A guess from the client's side, and worded as one: the API says nothing of it
/// between requests.
public struct PromptCache: Sendable, Equatable {
  public enum TTL: Sendable, Equatable, Hashable {
    case fiveMinutes, oneHour

    public var duration: TimeInterval {
      switch self {
      case .fiveMinutes: 5 * 60
      case .oneHour: 60 * 60
      }
    }
  }

  public enum State: Sendable, Equatable {
    /// Nothing said anything of the cache yet, or the newest request neither read nor wrote it.
    case unknown
    case warm(minutesLeft: Int)
    /// `recacheTokens` is what the newest request sent, which the next one sends again.
    case expired(idle: TimeInterval, recacheTokens: Int?)
    /// The conversation was compacted since: what was cached is not what it now sends.
    case compacted
  }

  /// The message the anchor was placed for: every block of one message is its own line.
  var messageID: String?
  /// When the request behind that message was sent.
  public private(set) var anchor: Date?
  public private(set) var ttl: TTL?
  var recacheTokens: Int?
  var compactedAt: Date?

  public init() {}

  public func state(at now: Date) -> State {
    if compactedAt != nil { return .compacted }
    guard let anchor, let ttl else { return .unknown }
    // Never more than the whole TTL, should the anchor be ahead of this clock.
    let left = min(ttl.duration, anchor.addingTimeInterval(ttl.duration).timeIntervalSince(now))
    guard left <= 0 else { return .warm(minutesLeft: Int((left / 60).rounded(.up))) }
    return .expired(idle: now.timeIntervalSince(anchor), recacheTokens: recacheTokens)
  }

  /// A main-thread message the API answered, `time` when it arrived or was written, and
  /// `requestAt` when the request it answers was sent, if known.
  mutating func record(messageID id: String, usage: TokenUsage, at time: Date, requestAt: Date?) {
    let sameMessage = id == messageID
    if !sameMessage || anchor == nil {
      anchor = requestAt.flatMap { $0 <= time ? $0 : nil } ?? time
    }
    // Only a newer message reached the conversation as it was after a compaction.
    if !sameMessage, let compactedAt, time > compactedAt { self.compactedAt = nil }
    messageID = id
    ttl = usage.cacheRead + usage.cacheCreation > 0 ? usage.cacheWriteTTL ?? ttl : nil
    let tokens = usage.total
    recacheTokens = tokens > 0 ? tokens : nil
  }

  mutating func compacted(at time: Date) {
    compactedAt = time
  }

  /// `12m`, `1h 5m`, `2d 3h`: whole minutes, as the extension writes an idle time.
  public static func idle(_ interval: TimeInterval) -> String {
    let minutes = max(0, Int((interval / 60).rounded(.down)))
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h \(minutes % 60)m" }
    return "\(hours / 24)d \(hours % 24)h"
  }

  /// `120k`, `1.3M`, as the extension writes a token count.
  static func tokens(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1000 { return "\(Int((Double(count) / 1000).rounded()))k" }
    return "\(count)"
  }
}

extension PromptCache.State {
  /// The sentence the footer's indicator explains itself with; nil when there is none.
  public var help: String? {
    switch self {
    case .unknown: nil
    case .warm(let minutes): String(localized: "Prompt cache warm, about \(minutes) min left.")
    case .expired(let idle, _):
      String(localized: "Prompt cache likely expired (idle \(PromptCache.idle(idle))).")
    case .compacted: String(localized: "Prompt cache does not cover the compacted conversation.")
    }
  }

  /// What a session resumed cold says before its next message: that it will be paid for again.
  public var resumeNote: String? {
    switch self {
    case .unknown, .warm: nil
    case .compacted:
      String(localized: "The conversation was compacted, so your next message will re-cache it.")
    case .expired(let idle, let tokens):
      tokens.map {
        String(
          localized:
            "Idle \(PromptCache.idle(idle)). The prompt cache has likely expired, so your next message will re-cache about \(PromptCache.tokens($0)) tokens."
        )
      }
        ?? String(
          localized:
            "Idle \(PromptCache.idle(idle)). The prompt cache has likely expired, so your next message will re-cache the conversation."
        )
    }
  }
}
