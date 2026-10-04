import DrakarKit
import SwiftUI

/// How full a session's context is: a percentage over a thin bar, amber from 75 % and red
/// from 90 %, with the figures and the window's source in the tooltip.
struct ContextGaugeView: View {
  let gauge: ContextGauge

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(gauge.fraction, format: .percent.precision(.fractionLength(0)))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(gauge.level == .normal ? .secondary : tint)
      Capsule()
        .fill(.quaternary)
        .frame(width: 34, height: 3)
        .overlay(alignment: .leading) {
          Capsule().fill(tint).frame(width: 34 * gauge.fraction, height: 3)
        }
    }
    .help(help)
    .accessibilityElement()
    .accessibilityLabel("Context")
    .accessibilityValue(help)
  }

  private var tint: Color {
    switch gauge.level {
    case .normal: .secondary
    case .high: .orange
    case .critical: .red
    }
  }

  private var help: String {
    let used = gauge.used.formatted(.number.notation(.compactName))
    let limit = gauge.window.limit.formatted(.number.notation(.compactName))
    return String(localized: "\(used) of \(limit). \(gauge.window.source.explanation)")
  }
}
