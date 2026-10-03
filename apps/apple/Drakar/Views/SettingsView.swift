import SupportKitSettings
import SwiftUI

// MARK: - Settings

/// The panes, and the order they sit in.
///
/// About only, for now. A General pane joins with the app's first real preference
/// and goes first, with `defaultPane` moved to it; an empty pane shipped to fill
/// the sidebar is a pane somebody opens once. An entitlement pane joins only when
/// something is actually sold: before a StoreKit product is registered it would
/// be a button that fails.
///
/// About stays last, because it answers a question you only ask with a bug report
/// open.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case about

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .about: "info.circle"
    }
  }

  static var defaultPane: SettingsPane { .general }
}

// MARK: - Preferences

/// The defaults keys, named the way every other key in the fleet is: the slug, then
/// the setting.
enum PreferenceKey {
  /// Which folders Drakar offers itself as the editor for, to `claude` run in a terminal.
  static let editorScope = "drakar.editorScope"
}

/// Where a terminal `claude` finds Drakar as its editor (`docs/claude-ide-bridge.md`).
enum EditorScope: String, CaseIterable {
  /// The folders of Drakar's open session windows: the default, because a second editor
  /// matching the same folder as VS Code stops `claude --ide` connecting to either.
  case openFolders
  /// Every folder in the home folder.
  case home
  /// Never: no lock file is written.
  case off

  static var current: EditorScope {
    UserDefaults.standard.string(forKey: PreferenceKey.editorScope).flatMap(EditorScope.init)
      ?? .openFolders
  }
}

// MARK: - The window

/// The sidebar, the persisted pane, the `settings.pane.*` identifiers and the
/// heading all come from the shared scaffold; what stays here are the pane bodies.
struct SettingsView: View {
  var body: some View {
    SettingsScaffold(selection: Support.settings) { pane in
      switch pane {
      case .general: GeneralPane()
      case .about:
        AboutSettingsPane(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      }
    }
    // A floor, not a fixed size, and sized for the sidebar: it spends up to 240pt
    // before a pane sees any width at all.
    .settingsWindowSize(minWidth: 660, idealWidth: 700, minHeight: 400, idealHeight: 460)
  }
}

struct GeneralPane: View {
  @AppStorage(PreferenceKey.editorScope) private var editorScope = EditorScope.openFolders

  var body: some View {
    Form {
      Section {
        Picker("Be the editor for Claude Code in a terminal", selection: $editorScope) {
          Text("In folders open in Drakar").tag(EditorScope.openFolders)
          Text("In any folder in my home folder").tag(EditorScope.home)
          Text("Never").tag(EditorScope.off)
        }
        .accessibilityIdentifier("settings.editorScope")
      } footer: {
        Text(
          "Run `claude --ide` in one of these folders, or type /ide in a running session, and its edits open here for you to accept or reject. If VS Code has the same folder open, pick the editor with /ide."
        )
      }
    }
    .formStyle(.grouped)
    .onChange(of: editorScope) { IDEBridge.shared.refreshFolders() }
  }
}

#Preview {
  SettingsView()
}
