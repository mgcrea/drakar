import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What the pills offer and say")
struct SessionPillsTests {

  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "drakar-pill-\(UUID().uuidString)", directoryHint: .isDirectory)
  private let models = [
    ModelOption(
      value: "default", resolvedModel: "claude-opus-5-5", displayName: "Default (recommended)",
      supportsAutoMode: true),
    ModelOption(
      value: "haiku", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5"),
  ]

  private func scoped(allowsBypass: Bool = true, _ body: () throws -> Void) rethrows {
    let suite = "drakar-pill-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(allowsBypass, forKey: PreferenceKey.allowsBypass)
    try ClaudeChoice.$testSuite.withValue(suite, operation: body)
  }

  @Test func autoOnlyForAModelThatTakesIt() {
    scoped {
      let session = ClaudeSession(folder: folder)
      #expect(SessionPills.offeredModes(session, models: models) == PermissionMode.allCases)
      session.setModel("haiku")
      #expect(!SessionPills.offeredModes(session, models: models).contains(.auto))
      // No list yet: Auto waits for one.
      #expect(!SessionPills.offeredModes(session, models: nil).contains(.auto))
    }
  }

  @Test func bypassOnlyWhenAllowed() {
    scoped(allowsBypass: false) {
      let session = ClaudeSession(folder: folder)
      #expect(!SessionPills.offeredModes(session, models: models).contains(.bypass))
    }
  }

  /// The model's own name, not the menu's "Default (recommended)".
  @Test func labelsTheModel() {
    scoped {
      let session = ClaudeSession(folder: folder)
      #expect(SessionPills.modelLabel(for: session, in: models) == "Opus 5.5")
      #expect(SessionPills.modelLabel(for: session, in: nil) == "Default")
      session.setModel("haiku")
      #expect(SessionPills.modelLabel(for: session, in: models) == "Haiku 4.5")
      session.setModel("claude-opus-4-8")
      #expect(SessionPills.modelLabel(for: session, in: models) == "Opus 4.8")
    }
  }
}
