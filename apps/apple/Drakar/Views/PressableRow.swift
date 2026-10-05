import SwiftUI

extension View {
  /// A row that acts on a click released over it, tinted while the mouse is down on it: the
  /// sidebar's session rows and the inspector's skills.
  func pressableRow(isSelected: Bool = false, action: @escaping () -> Void) -> some View {
    modifier(PressableRowChrome(isSelected: isSelected, action: action))
  }
}

/// The selected row's outline, in place of the list's filled highlight, and its trait; a
/// faint fill while the row is pressed, gone once the pointer leaves it as a button's is.
struct PressableRowChrome: ViewModifier {
  let isSelected: Bool
  let action: () -> Void
  @GestureState private var isPressed = false
  @State private var size = CGSize.zero

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating($isPressed) { value, pressed, _ in pressed = contains(value.location) }
          .onEnded { value in if contains(value.location) { action() } }
      )
      .listRowBackground(
        RoundedRectangle(cornerRadius: 5)
          .fill(isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
          .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
          .padding(.horizontal, 8)
      )
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func contains(_ point: CGPoint) -> Bool {
    CGRect(origin: .zero, size: size).contains(point)
  }
}
