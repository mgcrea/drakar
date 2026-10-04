import Foundation

/// How much of one plan window (5 hours, 7 days) an account has used.
public struct UsageWindow: Sendable, Equatable {
  /// 0–100.
  public var percent: Int
  public var resetsAt: Date?
  /// The CLI refused a request against this window: the limit is reached, whatever the
  /// percentage says.
  public var isRejected: Bool

  public enum Level: Sendable, Equatable {
    /// Below 70 %.
    case normal
    /// From 70 %.
    case high
    /// From 90 %, or rejected.
    case critical
  }

  public init(percent: Int, resetsAt: Date?, isRejected: Bool = false) {
    self.percent = min(max(percent, 0), 100)
    self.resetsAt = resetsAt
    self.isRejected = isRejected
  }

  public var level: Level {
    if isRejected || percent >= 90 { return .critical }
    return percent >= 70 ? .high : .normal
  }

  /// As it stands at `now`: a window past its reset has been emptied, whatever was read
  /// before.
  public func current(at now: Date) -> UsageWindow {
    guard let resetsAt, resetsAt <= now else { return self }
    return UsageWindow(percent: 0, resetsAt: nil)
  }
}

/// An account's plan windows, from whichever source read them last.
public struct AccountUsage: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    /// A `rate_limit_event` from a running session.
    case live
    /// `cachedUsageUtilization` in the account's `.claude.json`.
    case cache
  }

  public var fiveHour: UsageWindow?
  public var sevenDay: UsageWindow?
  public var readAt: Date
  public var source: Source

  public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, readAt: Date, source: Source) {
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
    self.readAt = readAt
    self.source = source
  }

  /// `cachedUsageUtilization`: `fetchedAtMs`, and `utilization.five_hour` / `seven_day` with a
  /// whole `utilization` and an ISO-8601 `resets_at`.
  public init?(cache json: JSONValue) {
    guard let milliseconds = json["fetchedAtMs"]?.numberValue, let windows = json["utilization"]
    else { return nil }
    let fiveHour = Self.cacheWindow(windows["five_hour"])
    let sevenDay = Self.cacheWindow(windows["seven_day"])
    guard fiveHour != nil || sevenDay != nil else { return nil }
    self.init(
      fiveHour: fiveHour, sevenDay: sevenDay,
      readAt: Date(timeIntervalSince1970: milliseconds / 1000), source: .cache)
  }

  /// `rate_limit_info`: `unifiedWindows.five_hour` / `seven_day` with a fractional
  /// `utilization` and `resetsAt` in epoch seconds. `status: rejected` names the refused
  /// window in `rateLimitType`.
  public init?(live info: JSONValue, at now: Date = .now) {
    guard let windows = info["unifiedWindows"] else { return nil }
    let rejected =
      info["status"]?.stringValue == "rejected" ? info["rateLimitType"]?.stringValue : nil
    let fiveHour = Self.liveWindow(windows["five_hour"], rejected: rejected == "five_hour")
    let sevenDay = Self.liveWindow(windows["seven_day"], rejected: rejected == "seven_day")
    guard fiveHour != nil || sevenDay != nil else { return nil }
    self.init(fiveHour: fiveHour, sevenDay: sevenDay, readAt: now, source: .live)
  }

  /// The newer of the two: a stale cache never replaces a fresher live reading.
  public func merged(_ other: AccountUsage?) -> AccountUsage {
    guard let other, other.readAt > readAt else { return self }
    return other
  }

  /// Read more than ten minutes before `now`.
  public func isStale(at now: Date) -> Bool {
    now.timeIntervalSince(readAt) > 600
  }

  private static func cacheWindow(_ json: JSONValue?) -> UsageWindow? {
    guard let value = json?["utilization"]?.numberValue else { return nil }
    let resets = json?["resets_at"]?.stringValue.flatMap(date(iso:))
    return UsageWindow(percent: Int(value.rounded()), resetsAt: resets)
  }

  private static func liveWindow(_ json: JSONValue?, rejected: Bool) -> UsageWindow? {
    guard let value = json?["utilization"]?.numberValue else { return nil }
    let resets = json?["resetsAt"]?.numberValue.map { Date(timeIntervalSince1970: $0) }
    return UsageWindow(
      percent: Int((value * 100).rounded()), resetsAt: resets, isRejected: rejected)
  }

  /// The CLI writes six fractional digits, which `ISO8601DateFormatter` refuses: the
  /// fraction is dropped, a reset time needs no better than the second.
  private static func date(iso text: String) -> Date? {
    let trimmed = text.replacingOccurrences(
      of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
  }
}
