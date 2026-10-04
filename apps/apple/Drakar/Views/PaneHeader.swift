import SwiftUI

/// A sidebar pane's title, as in VS Code: a click on the chevron, icon or name folds the
/// pane to this header, and the pane's own controls sit at the end, outside that button.
/// Both panes use it, so their icons line up. Open, it draws a line under itself to keep its
/// chevron apart from the rows' own; folded, the split's divider does that.
struct PaneHeader<Trailing: View>: View {
  let title: String
  /// Quieter text after the title: the path of the folder the Files pane shows.
  var caption: String? = nil
  let systemImage: String
  @Binding var isCollapsed: Bool
  let help: String
  /// The fold button's accessibility identifier.
  let identifier: String
  /// The sidebar's top pane: the title bar above already gives it room.
  var isFirst = false
  @ViewBuilder var trailing: Trailing

  var body: some View {
    VStack(spacing: 0) {
      row
      if !isCollapsed { Divider() }
    }
  }

  private var row: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Button {
        withAnimation(.snappy(duration: 0.2)) { isCollapsed.toggle() }
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            .frame(width: 10)
          Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 18)
          Text(title)
            .lineLimit(1)
            .layoutPriority(1)
          if let caption {
            Text(caption)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(help)
      .accessibilityLabel(caption.map { "\(title), \($0)" } ?? title)
      .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier(identifier)
      trailing
    }
    .font(.headline)
    .padding(.horizontal, 12)
    .padding(.top, isFirst ? 8 : 11)
    .padding(.bottom, 11)
  }
}
