import SwiftUI

/// The strip a divider is dragged by, wider than the line it straddles, lit as VS Code's sash
/// is: an accent line once the pointer has rested on it a moment, and for as long as a drag
/// lasts. The stack holding it raises it (`zIndex`) over the pane drawn after it, which
/// otherwise takes the clicks on its half and leaves a few points to aim at.
struct ResizeHandle: View {
  /// `.horizontal` drags a column's width, `.vertical` a row's height.
  let axis: Axis
  /// The drag's travel along `axis` since it began, and nil once it ends.
  let onDrag: (CGFloat?) -> Void

  static let thickness: CGFloat = 12
  static let lineWidth: CGFloat = 4
  /// How long the pointer rests before the line shows, so passing over it draws nothing.
  static let hoverDelay: Duration = .milliseconds(300)

  @State private var isHovered = false
  @State private var isLit = false
  @State private var isDragging = false

  var body: some View {
    Color.clear
      .frame(
        width: axis == .horizontal ? Self.thickness : nil,
        height: axis == .vertical ? Self.thickness : nil
      )
      .overlay {
        if isLit || isDragging {
          Rectangle()
            .fill(Color.accentColor)
            .frame(
              width: axis == .horizontal ? Self.lineWidth : nil,
              height: axis == .vertical ? Self.lineWidth : nil)
        }
      }
      .contentShape(Rectangle())
      .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
      .onHover { isHovered = $0 }
      .task(id: isHovered) {
        guard isHovered else {
          isLit = false
          return
        }
        guard (try? await Task.sleep(for: Self.hoverDelay)) != nil else { return }
        isLit = true
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged {
            isDragging = true
            onDrag(axis == .horizontal ? $0.translation.width : $0.translation.height)
          }
          .onEnded { _ in
            isDragging = false
            onDrag(nil)
          })
  }
}
