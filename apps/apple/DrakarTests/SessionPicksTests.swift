import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What new sessions start with")
struct SessionPicksTests {

  private let folder = URL(filePath: "/tmp/drakar-picks-\(UUID().uuidString)/")

  private func scoped(_ body: () throws -> Void) rethrows {
    let suite = "drakar-picks-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    try ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  @Test func readsTheDefaultsForNewSessions() {
    scoped {
      #expect(ClaudeChoice.defaultModel == nil)
      #expect(ClaudeChoice.defaultMode == nil)
      ClaudeChoice.defaults.set("sonnet", forKey: PreferenceKey.defaultModel)
      ClaudeChoice.defaults.set("plan", forKey: PreferenceKey.defaultMode)
      #expect(ClaudeChoice.defaultModel == "sonnet")
      #expect(ClaudeChoice.defaultMode == .plan)
      // "Claude Code's default" is stored empty.
      ClaudeChoice.defaults.set("", forKey: PreferenceKey.defaultModel)
      #expect(ClaudeChoice.defaultModel == nil)
    }
  }

  /// A Bypass default stands only while Settings allows Bypass.
  @Test func defaultsToBypassOnlyWhileAllowed() {
    scoped {
      ClaudeChoice.defaults.set("bypassPermissions", forKey: PreferenceKey.defaultMode)
      #expect(ClaudeChoice.defaultMode == .bypass)
      ClaudeChoice.defaults.set(false, forKey: PreferenceKey.allowsBypass)
      #expect(ClaudeChoice.defaultMode == nil)
    }
  }

  @Test func allowsBypassUntilTurnedOff() {
    scoped {
      #expect(ClaudeChoice.allowsBypass)
      ClaudeChoice.defaults.set(false, forKey: PreferenceKey.allowsBypass)
      #expect(!ClaudeChoice.allowsBypass)
    }
  }

  @Test func theProbeFillsTheCatalog() async throws {
    let catalog = ModelCatalog()
    let account = ClaudeAccount(directory: URL(filePath: "/tmp/.claude-a"), isDefault: false)
    let entry = Capabilities(folder: folder, account: account)
    entry.catalog = catalog
    entry.probe = { _, _ in
      ProbeOutcome(
        capabilities: ProjectCapabilities(
          skills: [], models: [ModelOption(value: "haiku", displayName: "Haiku 4.5")]))
    }
    #expect(catalog.models(for: account) == nil)
    entry.refresh()
    for _ in 0..<100 where entry.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    #expect(catalog.models(for: account)?.map(\.value) == ["haiku"])
  }

  /// A default changed in Settings redraws the pills that read it.
  @Test func aChangeInSettingsRedrawsWhatReadsIt() {
    scoped {
      let redrawn = PickFlag()
      withObservationTracking {
        _ = ClaudeChoice.defaultModel
        _ = ClaudeChoice.defaultMode
      } onChange: {
        redrawn.value = true
      }
      ClaudeChoice.defaults.set("haiku", forKey: PreferenceKey.defaultModel)
      #expect(redrawn.value)
    }
  }

  @Test func readsTheDefaultEffort() {
    scoped {
      #expect(ClaudeChoice.defaultEffort == nil)
      ClaudeChoice.defaults.set("max", forKey: PreferenceKey.defaultEffort)
      #expect(ClaudeChoice.defaultEffort == "max")
      ClaudeChoice.defaults.set("", forKey: PreferenceKey.defaultEffort)
      #expect(ClaudeChoice.defaultEffort == nil)
    }
  }
}

/// Set from an observation callback, which may not capture a variable.
private final class PickFlag: @unchecked Sendable {
  var value = false
}
