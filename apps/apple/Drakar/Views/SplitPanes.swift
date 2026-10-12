import SwiftUI

/// Two panes side by side with a divider to drag between them: the main one, and one beside
/// it on either edge that can be hidden.
///
/// Not `HSplitView`: it kept its panes' widths as they were, so a narrower window pushed
/// the sidebar off its leading edge instead of narrowing them (seen at 900 points wide).
struct SplitPanes<Side: View, Main: View>: View {
  /// The side pane's share of the width.
  @Binding var fraction: Double
  /// False hides the side pane and the divider, leaving the main pane the same view, so its
  /// state (the transcript's scroll position) survives the editor appearing.
  var showsSide = true
  /// The edge the side pane is on.
  var edge: HorizontalEdge = .leading
  var sideMinimum: CGFloat = 260
  var mainMinimum: CGFloat = 320
  @ViewBuilder let side: Side
  @ViewBuilder let main: Main

  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { geometry in
      let total = max(geometry.size.width - 1, 1)
      HStack(spacing: 0) {
        if showsSide, edge == .leading {
          side.frame(width: sideWidth(total))
          divider(total).zIndex(1)
        }
        main.frame(maxWidth: .infinity)
        if showsSide, edge == .trailing {
          divider(total).zIndex(1)
          side.frame(width: sideWidth(total))
        }
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
          let start = dragStart ?? Double(sideWidth(total) / total)
          dragStart = start
          // A drag to the right widens a leading pane and narrows a trailing one.
          let width = CGFloat(start) * total + (edge == .leading ? travel : -travel)
          fraction = Double(clamp(width, total) / total)
        }
      }
  }

  private func sideWidth(_ total: CGFloat) -> CGFloat {
    clamp(total * CGFloat(fraction), total)
  }

  /// Within both minimums, the main pane's winning when the window is too narrow for both:
  /// the session is what the window is for.
  private func clamp(_ width: CGFloat, _ total: CGFloat) -> CGFloat {
    max(min(width, total - mainMinimum), min(sideMinimum, total / 3))
  }
}
