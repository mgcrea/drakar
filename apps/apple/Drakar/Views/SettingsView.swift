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
  case about

  var title: LocalizedStringKey {
    switch self {
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .about: "info.circle"
    }
  }

  static var defaultPane: SettingsPane { .about }
}

// MARK: - Preferences

/// The defaults keys, named the way every other key in the fleet is: the slug, then
/// the setting (`drakar.showsGrid`). Empty until the first preference.
enum PreferenceKey {}

// MARK: - The window

/// The sidebar, the persisted pane, the `settings.pane.*` identifiers and the
/// heading all come from the shared scaffold; what stays here are the pane bodies.
struct SettingsView: View {
  var body: some View {
    SettingsScaffold(selection: Support.settings) { pane in
      switch pane {
      case .about:
        AboutSettingsPane(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      }
    }
    // A floor, not a fixed size, and sized for the sidebar: it spends up to 240pt
    // before a pane sees any width at all.
    .settingsWindowSize(minWidth: 660, idealWidth: 700, minHeight: 400, idealHeight: 460)
  }
}

#Preview {
  SettingsView()
}
