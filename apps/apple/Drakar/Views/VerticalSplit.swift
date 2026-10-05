import SwiftUI

/// Two panes stacked with a divider to drag between them: the sidebar's sessions over its
/// files. `SplitPanes` turned on its side, for the same reason it is not `HSplitView`.
struct VerticalSplit<Top: View, Bottom: View>: View {
  /// The top pane's share of the height.
  @Binding var fraction: Double
  var minimum: CGFloat = 90
  /// A pane folded to its own height (its header), as a collapsed section does in VS Code.
  /// Each folds toward its own edge: a folded top pane lets the bottom move up, a folded
  /// bottom one sinks to the foot and gives the top the height. Both folded leave the
  /// space between them empty. The fraction is kept for when they unfold.
  var collapsesTop = false
  var collapsesBottom = false
  @ViewBuilder let top: Top
  @ViewBuilder let bottom: Bottom

  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { geometry in
      let total = max(geometry.size.height - 1, 1)
      VStack(spacing: 0) {
        if collapsesTop {
          top.fixedSize(horizontal: false, vertical: true)
          Divider()
          if collapsesBottom {
            Spacer(minLength: 0)
            Divider()
          }
        } else if collapsesBottom {
          top.frame(maxHeight: .infinity)
          Divider()
        } else {
          top.frame(height: height(total))
          Divider().overlay { handle(total) }.zIndex(1)
        }
        if collapsesBottom {
          bottom.fixedSize(horizontal: false, vertical: true)
        } else {
          bottom.frame(maxHeight: .infinity)
        }
      }
    }
  }

  private func handle(_ total: CGFloat) -> some View {
    ResizeHandle(axis: .vertical) { travel in
      guard let travel else {
        dragStart = nil
        return
      }
      let start = dragStart ?? Double(height(total) / total)
      dragStart = start
      fraction = Double(clamp(CGFloat(start) * total + travel, total) / total)
    }
  }

  private func height(_ total: CGFloat) -> CGFloat { clamp(total * CGFloat(fraction), total) }

  private func clamp(_ height: CGFloat, _ total: CGFloat) -> CGFloat {
    max(min(height, total - minimum), min(minimum, total / 2))
  }
}
