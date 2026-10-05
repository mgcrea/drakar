import SwiftUI

/// The strip a divider is dragged by, wider than the line it straddles. The stack holding it
/// raises it (`zIndex`) over the pane drawn after it, which otherwise takes the clicks on its
/// half and leaves a few points to aim at.
struct ResizeHandle: View {
  /// `.horizontal` drags a column's width, `.vertical` a row's height.
  let axis: Axis
  /// The drag's travel along `axis` since it began, and nil once it ends.
  let onDrag: (CGFloat?) -> Void

  static let thickness: CGFloat = 12

  var body: some View {
    Color.clear
      .frame(
        width: axis == .horizontal ? Self.thickness : nil,
        height: axis == .vertical ? Self.thickness : nil
      )
      .contentShape(Rectangle())
      .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { onDrag(axis == .horizontal ? $0.translation.width : $0.translation.height) }
          .onEnded { _ in onDrag(nil) })
  }
}
