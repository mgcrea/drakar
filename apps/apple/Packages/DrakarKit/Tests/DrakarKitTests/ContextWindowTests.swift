import DrakarKit
import Foundation
import Testing

@Suite("Context window")
struct ContextWindowTests {

  @Test func prefersTheSessionsOwnModel() {
    let window = ContextWindow.resolve(
      sessionModelID: "claude-opus-5[1m]", accountModelID: "sonnet",
      messageModelID: "claude-opus-5", observedTotal: 10)
    #expect(window == ContextWindow(limit: 1_000_000, source: .sessionModel("claude-opus-5[1m]")))
  }

  @Test func fallsBackToTheAccountThenTheMessage() {
    #expect(
      ContextWindow.resolve(
        sessionModelID: nil, accountModelID: "opus[1m]", messageModelID: "claude-opus-5",
        observedTotal: 0
      ).source == .accountDefault("opus[1m]"))
    #expect(
      ContextWindow.resolve(
        sessionModelID: nil, accountModelID: nil, messageModelID: "claude-opus-5",
        observedTotal: 0) == ContextWindow(limit: 200_000, source: .assumed("claude-opus-5")))
    #expect(
      ContextWindow.resolve(
        sessionModelID: nil, accountModelID: nil, messageModelID: nil, observedTotal: 0)
        == ContextWindow(limit: 200_000, source: .unknown))
  }

  /// A 1M session with no attachment reads 389k against an assumed 200k: the measurement
  /// wins, so the gauge never passes full.
  @Test func usageAboveTheWindowMeansAWiderWindow() {
    let window = ContextWindow.resolve(
      sessionModelID: nil, accountModelID: nil, messageModelID: "claude-opus-5",
      observedTotal: 389_013)
    #expect(window == ContextWindow(limit: 1_000_000, source: .observed))
  }

  @Test func aReportedLimitIsTakenAsItIs() throws {
    let gauge = try #require(
      ContextGauge.make(
        usage: TokenUsage(input: 1, cacheCreation: 0, cacheRead: 149_999, output: 0),
        reportedLimit: 200_000, initModelID: "claude-opus-5[1m]", attachmentModelID: nil,
        accountModelID: nil, messageModelID: nil))
    #expect(gauge.window == ContextWindow(limit: 200_000, source: .reported))
    #expect(gauge.fraction == 0.75)
    #expect(gauge.level == .high)
  }

  @Test func theInitModelStandsForTheSession() throws {
    let gauge = try #require(
      ContextGauge.make(
        usage: TokenUsage(input: 0, cacheCreation: 0, cacheRead: 950_000, output: 0),
        reportedLimit: nil, initModelID: "claude-opus-5[1m]", attachmentModelID: nil,
        accountModelID: nil, messageModelID: "claude-opus-5"))
    #expect(gauge.window.limit == 1_000_000)
    #expect(gauge.level == .critical)
  }

  @Test func noUsageIsNoGauge() {
    #expect(
      ContextGauge.make(
        usage: nil, reportedLimit: 200_000, initModelID: nil, attachmentModelID: nil,
        accountModelID: nil, messageModelID: nil) == nil)
  }

  @Test func readsTheAccountsConfiguredModel() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "account-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(#"{"model":"opus[1m]","theme":"dark"}"#.utf8)
      .write(to: folder.appending(path: "settings.json"))
    #expect(
      ContextWindow.accountModelID(ClaudeAccount(directory: folder, isDefault: false)) == "opus[1m]"
    )
    #expect(
      ContextWindow.accountModelID(
        ClaudeAccount(directory: folder.appending(path: "none"), isDefault: false)) == nil)
  }
}
