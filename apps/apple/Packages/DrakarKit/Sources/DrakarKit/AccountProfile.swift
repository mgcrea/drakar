import Foundation

/// Who an account is, in the words its `.claude.json` gives: the organization and the plan,
/// with the plan usage Claude Code last cached there.
public struct AccountProfile: Sendable, Equatable {
  public var name: String
  public var plan: String?
  public var cachedUsage: AccountUsage?

  public init(name: String, plan: String?, cachedUsage: AccountUsage?) {
    self.name = name
    self.plan = plan
    self.cachedUsage = cachedUsage
  }

  /// `account.configFile`, or the directory's name alone when it cannot be read.
  public init(reading account: ClaudeAccount) {
    let json = (try? Data(contentsOf: account.configFile)).flatMap { try? JSONValue.parse($0) }
    self.init(json: json, fallbackName: account.name)
  }

  public init(json: JSONValue?, fallbackName: String) {
    let oauth = json?["oauthAccount"]
    name =
      Self.name(
        organization: oauth?["organizationName"]?.stringValue,
        email: oauth?["emailAddress"]?.stringValue) ?? fallbackName
    plan = Self.plan(
      tiers: [
        oauth?["userRateLimitTier"]?.stringValue, oauth?["organizationRateLimitTier"]?.stringValue,
      ],
      type: oauth?["organizationType"]?.stringValue)
    cachedUsage = json?["cachedUsageUtilization"].flatMap { AccountUsage(cache: $0) }
  }

  /// The organization, except the one Claude generates for a personal login,
  /// `"<email>'s Organization"`. Never the email: one person can hold two organizations.
  static func name(organization: String?, email: String?) -> String? {
    guard let organization, !organization.isEmpty else { return nil }
    let generated =
      email.map { organization == "\($0)'s Organization" }
      ?? organization.hasSuffix("'s Organization")
    return generated ? String(localized: "Personal") : organization
  }

  /// The tier says which Max; the organization type covers the rest.
  static func plan(tiers: [String?], type: String?) -> String? {
    for tier in tiers.compactMap({ $0 }) {
      if tier.hasSuffix("max_20x") { return "Max 20x" }
      if tier.hasSuffix("max_5x") { return "Max 5x" }
      if tier == "pro" || tier.hasSuffix("_pro") { return "Pro" }
    }
    return switch type {
    case "claude_max": "Max"
    case "claude_team": "Team"
    case "claude_pro": "Pro"
    case "claude_enterprise": "Enterprise"
    default: nil
    }
  }
}
