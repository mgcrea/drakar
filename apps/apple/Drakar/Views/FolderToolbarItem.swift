import AppKit
import DrakarKit
import SwiftUI

/// The folder the shown session runs in, beside the account, when it is not the window's:
/// a skill run in each subfolder, a worktree, a session from elsewhere.
struct FolderToolbarItem: View {
  let folder: URL
  let label: String
  /// The runner the folder is on, by name; nil for this Mac's. A runner's folder is shown as
  /// text: this Mac's Finder has none of it.
  var runner: String? = nil

  /// The label for `session` in a window on `project`; nil when it runs in the project's
  /// own folder.
  static func label(for session: AgentSession, in project: URL) -> String? {
    ProjectPath.label(
      of: session.folder.path(percentEncoded: false), in: project.path(percentEncoded: false))
  }

  var body: some View {
    if let runner {
      HStack(spacing: 6) {
        Image(systemName: "folder")
        Text(label)
      }
      .help(String(localized: "Runs in \(folder.path(percentEncoded: false)) on \(runner)"))
      .accessibilityIdentifier("window.folder")
    } else {
      menu
    }
  }

  private var menu: some View {
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
