import DrakarKit
import Foundation
import SupportKit
import SupportKitSettings
import Testing

@testable import Drakar

/// A protocol cannot require an enum case, so the fleet convention — every app
/// ships an About pane, and the identifiers behind it never move — is pinned here
/// instead. The raw values are load-bearing: they are the stored pane, the
/// `settings.pane.*` accessibility identifiers and what a screenshot stage names.
@Suite("Settings panes")
struct SettingsPaneTests {

  @Test func shipsAnAboutPane() {
    #expect(SettingsPane.allCases.contains { $0.rawValue == "about" })
  }

  /// Add a pane here when it is added to the enum; never rename one that has shipped.
  @Test func keepsPaneIdentifiersStable() {
    #expect(
      SettingsPane.allCases.map(\.rawValue) == ["general", "transcript", "attention", "about"])
  }

  /// Nothing is sold yet, so every pane sits in the one ungrouped configuration
  /// list. This fails the day a Pro pane lands without a group, which is the point.
  @Test func drawsOneUngroupedList() {
    #expect(SettingsPane.allCases.allSatisfy { $0.group == .configuration })
  }

  /// The slug is the prefix of every defaults key and the tail of every support URL,
  /// so it is not free to drift from the repo's name. `@MainActor` because `Support`
  /// takes the app target's default isolation; without it this does not compile.
  @Test @MainActor func theSupportIdentityIsThisApps() {
    #expect(Support.app.slug == "drakar")
    #expect(Support.app.siteURL.host() == "drakar.mgcrea.io")
  }

  /// The default account is run with `CLAUDE_CONFIG_DIR` unset, because the CLI keys its
  /// keychain item by the variable: picking `~/.claude` must not name it.
  @Test @MainActor func picksTheDefaultAccountByLeavingTheVariableUnset() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let standard = ClaudeChoice.account(at: home + ".claude")
    #expect(standard.isDefault)
    #expect(ClaudeChoice.account(at: home + ".claude/").isDefault)
    #expect(standard.environment(["CLAUDE_CONFIG_DIR": "/elsewhere"])["CLAUDE_CONFIG_DIR"] == nil)

    let other = ClaudeChoice.account(at: home + ".claude-work")
    #expect(!other.isDefault)
    #expect(other.name == "work")
    #expect(other.environment([:])["CLAUDE_CONFIG_DIR"] == home + ".claude-work")
  }
}
