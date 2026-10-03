import SupportKitUI
import SwiftUI

@main
struct AmiralApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .commands {
      SupportCommands(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
    }

    // A real Settings scene: Amiral is a windowed app with a Dock icon and menus, unlike
    // the fleet's three other Developer ID apps, which are LSUIElement agents and have to
    // open their settings through HostedWindow instead.
    Settings {
      SettingsView()
    }
  }
}
