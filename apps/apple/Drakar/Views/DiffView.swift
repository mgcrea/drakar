import DrakarKit
import SwiftUI

/// A file change as the extension shows one: removed lines red, added lines green,
/// unchanged runs folded.
struct FileChangeView: View {
  let change: FileChange
  @Environment(\.sessionFolder) private var sessionFolder

  /// Inside the session's folder, the path from there; elsewhere, from home.
  private var displayedPath: String {
    if let folder = sessionFolder {
      let base = folder.path(percentEncoded: false)
      let prefix = base.hasSuffix("/") ? base : base + "/"
      if change.path.hasPrefix(prefix) { return String(change.path.dropFirst(prefix.count)) }
    }
    return ContentView.abbreviated(URL(filePath: change.path))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: change.isNewFile ? "doc.badge.plus" : "doc.text")
        Text(displayedPath)
          .font(.callout.monospaced())
          .lineLimit(1)
          .truncationMode(.head)
        Spacer()
        Text("+\(change.addedCount)").foregroundStyle(.green)
        Text("−\(change.removedCount)").foregroundStyle(.red)
      }
      .font(.callout)
      ForEach(Array(change.diffs.enumerated()), id: \.offset) { _, lines in
        DiffLinesView(lines: lines)
      }
    }
  }
}

struct DiffLinesView: View {
  let lines: [DiffLine]

  var body: some View {
    // Vertical only, with long lines wrapping: in a horizontal scroll view every row
    // shrinks to its text and the added and removed tints stop short of the edge.
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          row(line)
        }
      }
      .padding(.vertical, 4)
    }
    .frame(maxHeight: 320)
    .fixedSize(horizontal: false, vertical: true)
    .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
  }

  @ViewBuilder private func row(_ line: DiffLine) -> some View {
    switch line.kind {
    case .gap(let count):
      Text("⋯ \(count) unchanged lines")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    case .context, .added, .removed:
      HStack(spacing: 0) {
        Text(Self.marker(line.kind))
          .frame(width: 18)
          .foregroundStyle(.secondary)
        Text(line.text.isEmpty ? " " : line.text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.callout.monospaced())
      .padding(.trailing, 8)
      .background(Self.background(line.kind))
    }
  }

  private static func marker(_ kind: DiffLine.Kind) -> String {
    switch kind {
    case .added: "+"
    case .removed: "−"
    case .context, .gap: ""
    }
  }

  private static func background(_ kind: DiffLine.Kind) -> Color {
    switch kind {
    case .added: .green.opacity(0.15)
    case .removed: .red.opacity(0.15)
    case .context, .gap: .clear
    }
  }
}
