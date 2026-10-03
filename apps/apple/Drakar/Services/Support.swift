import Foundation
import SupportKit
import SupportKitSettings

/// Drakar's identity for the shared support package.
///
/// One constant; the feedback URL, the support page, the prefilled issue and the
/// mail draft are all derived from it. Nothing here opens a connection — the
/// package builds URLs and hands them to `openURL`.
///
/// Note: `siteURL` and `trackerURL` follow the fleet's canonical shape but neither
/// resolves yet — `apps/website` and the `mgcrea/support/drakar` folder both
/// arrive with the site. Until they do, the Help menu and the About pane's support
/// rows lead nowhere. They are wired ahead of the site deliberately, as calque's
/// and maquette's were: the app gets its settings window, its version on screen
/// and its Help menu from the first commit, and nothing here needs to change when
/// the site lands. `survey.sh drakar --net` is how to see that it has; re-check
/// before the first release, and say so in PLAN.md's open questions until then.
enum Support {
  static let app = SupportApp(
    slug: "drakar",
    displayName: "Drakar",
    siteURL: URL(string: "https://drakar.mgcrea.io")!,
    trackerURL: URL(string: "https://github.com/mgcrea/support/tree/main/drakar")!,
    // nil for good: Drakar is distributed directly (Developer ID) and never has a
    // store id. An empty string would build a rating URL that 404s.
    appStoreID: nil
  )

  /// Whether the Help menu lists the public tracker above the feedback form.
  ///
  /// False suits an app sold to people who are not developers: a public issue is a
  /// wall to someone who would otherwise have written a sentence. Make it true for
  /// a developer tool, where the tracker is where its users already are — Drakar is one.
  static let preferIssueTracker = true

  /// Which Settings pane is showing.
  ///
  /// No `legacyKeys`: Drakar has never shipped a settings window, so there is no
  /// stored pane anywhere to migrate.
  static let settings = SettingsSelection<SettingsPane>(app: app)
}
