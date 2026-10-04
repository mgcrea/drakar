import SwiftUI

/// Two panes stacked with a divider to drag between them: the sidebar's sessions over its
/// files. `SplitPanes` turned on its side, for the same reason it is not `HSplitView`.
struct VerticalSplit<Top: View, Bottom: View>: View {
  /// The top pane's share of the height.
  @Binding var fraction: Double
  var minimum: CGFloat = 90
  @ViewBuilder let top: Top
  @ViewBuilder let bottom: Bottom

  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { geometry in
      let total = max(geometry.size.height - 1, 1)
      VStack(spacing: 0) {
        top.frame(height: height(total))
        Divider()
          .overlay {
            Color.clear
              .frame(height: 9)
              .contentShape(Rectangle())
              .pointerStyle(.rowResize)
              .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                  .onChanged { drag in
                    let start = dragStart ?? Double(height(total) / total)
                    dragStart = start
                    fraction = Double(
                      clamp(CGFloat(start) * total + drag.translation.height, total) / total)
                  }
                  .onEnded { _ in dragStart = nil })
          }
        bottom.frame(maxHeight: .infinity)
      }
    }
  }

  private func height(_ total: CGFloat) -> CGFloat { clamp(total * CGFloat(fraction), total) }

  private func clamp(_ height: CGFloat, _ total: CGFloat) -> CGFloat {
    max(min(height, total - minimum), min(minimum, total / 2))
  }
}
