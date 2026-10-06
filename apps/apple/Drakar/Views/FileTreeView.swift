import AppKit
import DrakarKit
import SwiftUI

/// The window's folder in the sidebar: a click expands a folder or opens a file. Its header
/// folds the whole tree away to the sidebar's foot (⇧⌘E), leaving the sessions above it the
/// height.
struct FileTreeView: View {
  let workspace: Workspace
  @Binding var isCollapsed: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
      if !isCollapsed {
        List {
          ForEach(workspace.tree.rows) { row in
            FileRow(row: row, isOpen: row.node.path == workspace.active?.path) {
              workspace.toggle(row)
            }
          }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("files")
      }
    }
  }

  private var header: some View {
    PaneHeader(
      title: String(localized: "Files"), caption: ContentView.abbreviated(workspace.folder),
      systemImage: "folder",
      isCollapsed: $isCollapsed,
      help: isCollapsed
        ? String(localized: "Show files (⇧⌘E)") : String(localized: "Hide files (⇧⌘E)"),
      identifier: "files.header"
    ) {}
  }
}

private struct FileRow: View {
  let row: FileTree.Row
  let isOpen: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
          .opacity(row.node.isDirectory ? 1 : 0)
          .frame(width: 10)
        Image(systemName: row.node.isDirectory ? "folder" : "doc.text")
          .foregroundStyle(row.node.isDirectory ? Theme.accent : .secondary)
          .frame(width: 16)
        Text(row.node.name)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(row.depth) * 14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(
      isOpen ? RoundedRectangle(cornerRadius: 5).fill(.selection).padding(.horizontal, 8) : nil
    )
    .contextMenu {
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: row.node.path)])
      }
    }
    .accessibilityIdentifier("file.\(row.node.name)")
  }
}
