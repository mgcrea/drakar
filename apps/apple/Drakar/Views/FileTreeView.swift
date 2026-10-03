import AppKit
import DrakarKit
import SwiftUI

/// The window's folder in the sidebar: a click expands a folder or opens a file.
struct FileTreeView: View {
  let workspace: Workspace

  var body: some View {
    List {
      Section(workspace.folder.lastPathComponent) {
        ForEach(workspace.tree.rows) { row in
          FileRow(row: row, isOpen: row.node.path == workspace.active?.path) {
            workspace.toggle(row)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("files")
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
          .foregroundStyle(row.node.isDirectory ? Color.accentColor : .secondary)
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
