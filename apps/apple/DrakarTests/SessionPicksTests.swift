import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What a folder's next session starts with")
struct SessionPicksTests {

  private let folder = URL(filePath: "/tmp/drakar-picks-\(UUID().uuidString)/")

  private func scoped(_ body: () throws -> Void) rethrows {
    let suite = "drakar-picks-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    try ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  @Test func remembersTheLastPicks() {
    scoped {
      #expect(ClaudeChoice.sessionPicks(for: folder) == .init())
      ClaudeChoice.pickModel("sonnet", for: folder)
      ClaudeChoice.pickMode(.plan, for: folder)
      #expect(ClaudeChoice.sessionPicks(for: folder) == .init(model: "sonnet", mode: "plan"))
      // Normalised like the account picks: a trailing slash is the same folder.
      let bare = URL(filePath: String(folder.path(percentEncoded: false).dropLast()))
      #expect(ClaudeChoice.sessionPicks(for: bare).model == "sonnet")
    }
  }

  /// No session starts in Bypass: picking it leaves the folder's mode as it was.
  @Test func neverRemembersBypass() {
    scoped {
      ClaudeChoice.pickMode(.acceptEdits, for: folder)
      ClaudeChoice.pickMode(.bypass, for: folder)
      #expect(ClaudeChoice.sessionPicks(for: folder).mode == "acceptEdits")
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

  /// Another window's pick, or the Settings switch, redraws the pills that read them.
  @Test func aPickElsewhereRedrawsWhatReadsIt() {
    scoped {
      let redrawn = PickFlag()
      withObservationTracking {
        _ = ClaudeChoice.sessionPicks(for: folder)
        _ = ClaudeChoice.allowsBypass
      } onChange: {
        redrawn.value = true
      }
      ClaudeChoice.pickModel("haiku", for: folder)
      #expect(redrawn.value)
    }
  }
}

/// Set from an observation callback, which may not capture a variable.
private final class PickFlag: @unchecked Sendable {
  var value = false
}
