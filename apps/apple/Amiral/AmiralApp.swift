import SupportKitUI
import SwiftUI

@main
struct AmiralApp: App {
  var body: some Scene {
    // One window per session, keyed by its route: a window opened without one shows the
    // session list, and SwiftUI reopens each session's window at the next launch.
    WindowGroup(for: SessionRoute.self) { $route in
      ContentView(route: $route)
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
