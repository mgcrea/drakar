import Foundation

/// An Antigravity (`agy`) account's plan quotas and tier, decoded from `agy`'s documented
/// `statusLine` JSON payload.
///
/// Measured on `agy` 1.5.18 (2026-11-27): four keys under `quota` — `gemini-5h`,
/// `gemini-weekly`, `3p-5h`, `3p-weekly` — each carrying `remaining_fraction` (`0…1`),
/// `reset_time` (ISO-8601 UTC) and `reset_in_seconds`. Untouched pools report
/// `remaining_fraction: 1`, `reset_time: "1970-01-01T00:00:00Z"` and `reset_in_seconds: 0`,
/// which means the window has not started ticking yet (`resetsAt == nil`), never that it
/// rolled over in 1970.
public struct AgyUsage: Sendable, Equatable {
  public enum WindowLength: Sendable, Equatable {
    case fiveHour
    case sevenDay

    public var shortLabel: String {
      switch self {
      case .fiveHour: "5h"
      case .sevenDay: "7d"
      }
    }
  }

  /// One quota bucket from `agy`'s `statusLine` payload.
  public struct Bucket: Sendable, Equatable, Identifiable {
    /// Raw bucket key as `agy` names it: `"gemini-5h"`, `"gemini-weekly"`, `"3p-5h"`,
    /// `"3p-weekly"`.
    public var id: String
    /// Percentage spent (`0…100`), converted from `remaining_fraction` to match Claude Code
    /// and Codex.
    public var window: UsageWindow

    public init(id: String, window: UsageWindow) {
      self.id = id
      self.window = window
    }

    public var length: WindowLength? {
      if id == "5h" || id.hasSuffix("-5h") { return .fiveHour }
      if id == "weekly" || id.hasSuffix("-weekly") || id.hasSuffix("-7d") { return .sevenDay }
      return nil
    }

    /// The model pool this bucket governs: `"Gemini"` or `"Partner models"` for the measured
    /// prefixes, or the capitalized prefix for anything `agy` adds later.
    public var groupName: String {
      if id.hasPrefix("gemini-") { return String(localized: "Gemini") }
      if id.hasPrefix("3p-") { return String(localized: "Partner models") }
      for suffix in ["-5h", "-weekly", "-7d"] where id.hasSuffix(suffix) {
        let prefix = String(id.dropLast(suffix.count))
        if !prefix.isEmpty { return prefix.capitalized }
      }
      return id
    }

    /// Gemini first (5h, then 7d), then partner models (5h, then 7d), then anything new by id.
    var sortRank: (Int, String) {
      let rank =
        switch id {
        case "gemini-5h": 0
        case "gemini-weekly": 1
        case "3p-5h": 2
        case "3p-weekly": 3
        default: 4
        }
      return (rank, id)
    }
  }

  /// One model pool's pair of windows, in bucket display order, for the account picker popover.
  public struct Group: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?

    public init(name: String, fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
      self.name = name
      self.fiveHour = fiveHour
      self.sevenDay = sevenDay
    }
  }

  public var buckets: [Bucket]
  /// `"Google AI Pro"`, `"Google AI Ultra"`: `plan_tier` when reported.
  public var plan: String?
  public var readAt: Date

  public init(buckets: [Bucket], plan: String?, readAt: Date) {
    self.buckets = buckets
    self.plan = plan
    self.readAt = readAt
  }

  /// Narrowly decodes `agy`'s `statusLine` JSON bytes (`quota` and `plan_tier` only;
  /// `email`, `context_window`, `workspace`, and `cost` are ignored).
  public init?(statusLineData data: Data, at now: Date = .now) {
    guard let json = try? JSONValue.parse(data) else { return nil }
    self.init(statusLine: json, at: now)
  }

  public init?(statusLine json: JSONValue, at now: Date = .now) {
    guard case .object(let quota) = json["quota"], !quota.isEmpty else { return nil }
    var buckets: [Bucket] = []
    for (id, entry) in quota {
      if entry["disabled"]?.boolValue == true { continue }
      guard let remaining = entry["remaining_fraction"]?.numberValue else { continue }
      let clamped = min(max(remaining, 0), 1)
      let percent = Int(((1.0 - clamped) * 100.0).rounded())
      let resetInSeconds = entry["reset_in_seconds"]?.numberValue
      let parsedReset = entry["reset_time"]?.stringValue.flatMap(AccountUsage.parseISO8601)
      let resetsAt: Date? =
        if let seconds = resetInSeconds, seconds <= 0 {
          nil
        } else if let parsedReset, parsedReset.timeIntervalSince1970 <= 1 {
          nil
        } else {
          parsedReset
        }
      buckets.append(Bucket(id: id, window: UsageWindow(percent: percent, resetsAt: resetsAt)))
    }
    guard !buckets.isEmpty else { return nil }
    buckets.sort { $0.sortRank < $1.sortRank }
    let plan = json["plan_tier"]?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    self.init(buckets: buckets, plan: plan, readAt: now)
  }

  /// The highest-utilization bucket for a window length (Gemini first on ties), for compact
  /// glance surfaces like the toolbar button where only two bars fit. When `now` is given,
  /// rolled-over buckets are zeroed first so an expired pool never shadows an active one.
  public func peakWindow(_ length: WindowLength, at now: Date? = nil) -> UsageWindow? {
    let matching = buckets.filter { $0.length == length }.map { bucket in
      now.map { bucket.window.current(at: $0) } ?? bucket.window
    }
    guard var best = matching.first else { return nil }
    for candidate in matching.dropFirst() where candidate.percent > best.percent {
      best = candidate
    }
    return best
  }

  /// Peak 5h and 7d windows in `AccountUsage` shape for compact toolbar rendering.
  public func summary(at now: Date) -> AccountUsage {
    AccountUsage(
      fiveHour: peakWindow(.fiveHour, at: now),
      sevenDay: peakWindow(.sevenDay, at: now),
      readAt: readAt,
      source: .probe)
  }

  /// Buckets grouped by model pool (`Gemini`, `Partner models`, …), preserving sort order.
  public var groups: [Group] {
    var order: [String] = []
    var byName: [String: Group] = [:]
    for bucket in buckets {
      let name = bucket.groupName
      if byName[name] == nil {
        order.append(name)
        byName[name] = Group(name: name, fiveHour: nil, sevenDay: nil)
      }
      switch bucket.length {
      case .fiveHour: if byName[name]?.fiveHour == nil { byName[name]?.fiveHour = bucket.window }
      case .sevenDay: if byName[name]?.sevenDay == nil { byName[name]?.sevenDay = bucket.window }
      case nil: break
      }
    }
    return order.compactMap { byName[$0] }
  }

  /// Read more than ten minutes before `now`.
  public func isStale(at now: Date) -> Bool {
    now.timeIntervalSince(readAt) > 600
  }

  /// The newer reading wins; if the winner lacks `plan`, the older one's is kept.
  public func merged(_ other: AgyUsage?) -> AgyUsage {
    guard let other else { return self }
    if other.readAt > readAt {
      return AgyUsage(buckets: other.buckets, plan: other.plan ?? plan, readAt: other.readAt)
    }
    return AgyUsage(buckets: buckets, plan: plan ?? other.plan, readAt: readAt)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
