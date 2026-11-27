import AppKit
import SwiftUI

struct GitPane: View {
  let workspace: Workspace
  @Binding var isCollapsed: Bool

  private struct RefreshID: Equatable {
    let folder: URL
    let isCollapsed: Bool
  }

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(
        title: String(localized: "Git"), caption: branch,
        systemImage: "arrow.triangle.branch",
        isCollapsed: $isCollapsed,
        help: isCollapsed ? String(localized: "Show Git") : String(localized: "Hide Git"),
        identifier: "git.header"
      ) {
        if isCollapsed, case .repository(let repository) = workspace.gitStatus,
          !repository.changes.isEmpty
        {
          let count = Set(repository.changes.map(\.path)).count
          Text(count, format: .number)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .background(Capsule().fill(.quaternary))
            .fixedSize()
            .help("Changed files")
            .accessibilityLabel("Changed files")
            .accessibilityValue(count.formatted())
            .accessibilityIdentifier("git.changedFiles")
        }
      }
      if !isCollapsed {
        contents
          .accessibilityIdentifier("git")
      }
    }
    .task(id: RefreshID(folder: workspace.folder, isCollapsed: isCollapsed)) {
      let interval: Duration = isCollapsed ? .seconds(10) : .seconds(3)
      while !Task.isCancelled {
        await workspace.refreshGitStatus()
        try? await Task.sleep(for: interval)
      }
    }
  }

  private var branch: String? {
    if case .repository(let repository) = workspace.gitStatus { repository.branch } else { nil }
  }

  @ViewBuilder private var contents: some View {
    switch workspace.gitStatus {
    case .none:
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    case .noRepository:
      message("No Git repository")
    case .unavailable:
      message("Git status unavailable")
    case .repository(let repository):
      if repository.changes.isEmpty {
        message("No changes")
      } else {
        List(repository.changes) { change in
          let fileURL = repository.root.appending(path: change.path)
          let isOpen = workspace.workspacePath(for: fileURL) == workspace.active?.path
          Button {
            workspace.open(fileURL)
          } label: {
            HStack {
              Text(change.path)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 4)
              Text(change.code.replacingOccurrences(of: ".", with: "–"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(!change.canOpen)
          .listRowBackground(
            isOpen
              ? RoundedRectangle(cornerRadius: 5).fill(.selection).padding(.horizontal, 8)
              : nil
          )
          .contextMenu {
            if change.existsOnDisk {
              Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
              }
            }
          }
          .help(helpText(for: change))
          .accessibilityLabel(change.path)
          .accessibilityValue(change.description)
        }
        .listStyle(.sidebar)
      }
    }
  }

  private func helpText(for change: GitStatus.Change) -> String {
    let title = change.originalPath.map { "\($0) → \(change.path)" } ?? change.path
    return change.description.isEmpty ? title : "\(title)\n\(change.description)"
  }

  private func message(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
