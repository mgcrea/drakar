import DrakarKit
import SwiftUI

/// What a conversation has cost, as Claude Code prices it: marked ≈ when it is only an
/// estimate, under a subscription, and as a bill when an API key pays it.
struct CostText: View {
  let cost: Double
  let billing: Billing
  var fractionDigits = 2

  init(_ cost: Double, apiKeySource: String?, fractionDigits: Int = 2) {
    self.cost = cost
    self.billing = Billing(apiKeySource: apiKeySource)
    self.fractionDigits = fractionDigits
  }

  var body: some View {
    Text(label)
      .monospacedDigit()
      .help(
        billing == .subscription
          ? "API-equivalent estimate of this conversation from token counts. Your subscription is not billed per token."
          : "This conversation, billed to your API key")
  }

  private var label: String {
    let amount = cost.formatted(.currency(code: "USD").precision(.fractionLength(fractionDigits)))
    return billing == .subscription ? "≈ \(amount)" : amount
  }
}
