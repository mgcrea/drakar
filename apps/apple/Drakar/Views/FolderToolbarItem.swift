import AppKit
import DrakarKit
import SwiftUI

/// The folder the shown session runs in, beside the account, when it is not the window's:
/// a skill run in each subfolder, a worktree, a session from elsewhere.
struct FolderToolbarItem: View {
  let folder: URL
  let label: String

  /// The label for `session` in a window on `project`; nil when it runs in the project's
  /// own folder.
  static func label(for session: AgentSession, in project: URL) -> String? {
    ProjectPath.label(
      of: session.folder.path(percentEncoded: false), in: project.path(percentEncoded: false))
  }

  var body: some View {
    Menu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
      Button("Open as Project") { WindowTabs.open(.project(folder), asTab: false) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "folder")
        Text(label)
      }
    }
    .menuIndicator(.hidden)
    .help(String(localized: "Runs in \(ContentView.abbreviated(folder))"))
    .accessibilityIdentifier("window.folder")
  }
}
