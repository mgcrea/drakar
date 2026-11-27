import Foundation

/// A Grok Build account's plan allowance and tier, decoded from `grok agent stdio`'s
/// `_x.ai/billing` extension response.
///
/// Measured on `grok` 1.0.34 (2026-09-17):
/// `{"config":{"creditUsagePercent":13.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
/// "start":"…","end":"…"},"billingPeriodEnd":"…"},"subscription_tier":"X Premium"}`.
/// Monetary fields (`onDemandCap`, `onDemandUsed`, `prepaidBalance`) are ignored.
public struct GrokUsage: Sendable, Equatable {
  public enum Period: String, Sendable, Equatable {
    case weekly
    case monthly

    public var shortLabel: String {
      switch self {
      case .weekly: "7d"
      case .monthly: "mo"
      }
    }
  }

  public var window: UsageWindow
  /// `"weekly"`, `"monthly"`, or another raw lowercase suffix if xAI adds a new period type.
  public var periodName: String?
  /// `"X Premium"`, `"SuperGrok"`, … from `subscription_tier` when non-empty.
  public var plan: String?
  public var readAt: Date

  public init(window: UsageWindow, periodName: String?, plan: String?, readAt: Date) {
    self.window = window
    self.periodName = periodName
    self.plan = plan
    self.readAt = readAt
  }

  public var period: Period? {
    periodName.flatMap(Period.init(rawValue:))
  }

  public var shortLabel: String? {
    period?.shortLabel
  }

  public init?(billingData data: Data, at now: Date = .now) {
    guard let json = try? JSONValue.parse(data) else { return nil }
    self.init(billingResult: json, at: now)
  }

  public init?(billingResult json: JSONValue, at now: Date = .now) {
    guard let config = json["config"],
      let percent = config["creditUsagePercent"]?.numberValue
    else { return nil }
    let clamped = min(max(percent, 0), 100)
    let current = config["currentPeriod"]
    let periodName = current?["type"]?.stringValue?
      .replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .nilIfEmpty
    let end = current?["end"]?.stringValue ?? config["billingPeriodEnd"]?.stringValue
    let resetsAt = end.flatMap(AccountUsage.parseISO8601)
    let plan = json["subscription_tier"]?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    self.init(
      window: UsageWindow(percent: Int(clamped.rounded()), resetsAt: resetsAt),
      periodName: periodName,
      plan: plan,
      readAt: now)
  }

  /// Read more than ten minutes before `now`.
  public func isStale(at now: Date) -> Bool {
    now.timeIntervalSince(readAt) > 600
  }

  /// The newer reading wins; if the winner lacks `plan` or `periodName`, the older one's is
  /// kept.
  public func merged(_ other: GrokUsage?) -> GrokUsage {
    guard let other else { return self }
    if other.readAt > readAt {
      return GrokUsage(
        window: other.window, periodName: other.periodName ?? periodName,
        plan: other.plan ?? plan, readAt: other.readAt)
    }
    return GrokUsage(
      window: window, periodName: periodName ?? other.periodName, plan: plan ?? other.plan,
      readAt: readAt)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
