/// What `result.total_cost_usd` is to the person: Claude Code reports it at API list prices
/// whatever the login, and only an API key turns it into a bill.
public enum Billing: Sendable, Equatable {
  case subscription
  case apiKey

  /// Unknown counts as a subscription: an estimate shown as a bill is the worse mistake.
  public init(apiKeySource: String?) {
    self = apiKeySource == nil || apiKeySource == "none" ? .subscription : .apiKey
  }
}
