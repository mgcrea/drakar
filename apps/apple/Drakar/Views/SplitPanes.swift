import SwiftUI

/// Two panes side by side with a divider to drag between them.
///
/// Not `HSplitView`: it kept its panes' widths as they were, so a narrower window pushed
/// the sidebar off its leading edge instead of narrowing them (seen at 900 points wide).
struct SplitPanes<Leading: View, Trailing: View>: View {
  /// The leading pane's share of the width.
  @Binding var fraction: Double
  /// False hides the leading pane and the divider, leaving the trailing pane the same view,
  /// so its state (the transcript's scroll position) survives the editor appearing.
  var showsLeading = true
  var leadingMinimum: CGFloat = 260
  var trailingMinimum: CGFloat = 320
  @ViewBuilder let leading: Leading
  @ViewBuilder let trailing: Trailing

  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { geometry in
      let total = max(geometry.size.width - 1, 1)
      HStack(spacing: 0) {
        if showsLeading {
          leading.frame(width: leadingWidth(total))
          divider(total).zIndex(1)
        }
        trailing.frame(maxWidth: .infinity)
      }
    }
  }

  private func divider(_ total: CGFloat) -> some View {
    Divider()
      .overlay {
        ResizeHandle(axis: .horizontal) { travel in
          guard let travel else {
            dragStart = nil
            return
          }
          let start = dragStart ?? Double(leadingWidth(total) / total)
          dragStart = start
          fraction = Double(clamp(CGFloat(start) * total + travel, total) / total)
        }
      }
  }

  private func leadingWidth(_ total: CGFloat) -> CGFloat {
    clamp(total * CGFloat(fraction), total)
  }

  /// Within both minimums, the trailing pane's winning when the window is too narrow for
  /// both: the session is what the window is for.
  private func clamp(_ width: CGFloat, _ total: CGFloat) -> CGFloat {
    max(min(width, total - trailingMinimum), min(leadingMinimum, total / 3))
  }
}
