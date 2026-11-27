import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Every account's plan usage")
struct AccountStoreTests {

  private let root: URL
  private let account: ClaudeAccount

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    let directory = root.appending(path: ".claude-work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    account = ClaudeAccount(directory: directory, isDefault: false)
  }

  private func writeConfig(percent: Int, fetchedAt: Int, modified: Date) throws {
    try Data(
      #"{"oauthAccount":{"organizationName":"Acme","organizationType":"claude_team"},"cachedUsageUtilization":{"fetchedAtMs":\#(fetchedAt),"utilization":{"five_hour":{"utilization":\#(percent),"resets_at":"2099-01-01T00:00:00+00:00"}}}}"#
        .utf8
    ).write(to: account.configFile)
    try FileManager.default.setAttributes(
      [.modificationDate: modified], ofItemAtPath: account.configFile.path(percentEncoded: false))
  }

  private func store(
    codexHome: URL? = nil, probeAgy: (() async -> AgyUsage?)? = nil
  ) async -> AccountStore {
    let account = self.account
    let home = codexHome ?? root.appending(path: ".codex", directoryHint: .isDirectory)
    let store = AccountStore(
      discover: { (accounts: [account], shell: account) },
      discoverCodexHome: { home },
      probeAgy: probeAgy ?? { nil })
    await store.start()
    store.stopPolling()
    return store
  }

  private let event =
    #"{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":4070908800}}}"#

  private func record(
    _ text: String, in store: AccountStore, for account: ClaudeAccount, at seconds: Double
  ) throws {
    store.record(
      try JSONValue.parse(Data(text.utf8)), for: account, at: Date(timeIntervalSince1970: seconds))
  }

  @Test func readsEachAccountAtStart() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 12, fetchedAt: 1000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    #expect(store.profile(for: account).name == "Acme")
    #expect(store.profile(for: account).plan == "Team")
    #expect(store.usage(for: account)?.fiveHour?.percent == 12)
  }

  @Test func rereadsAFileThatChanged() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 12, fetchedAt: 1000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    try writeConfig(percent: 40, fetchedAt: 2000, modified: Date(timeIntervalSince1970: 20))
    await store.reloadChanged()
    #expect(store.usage(for: account)?.fiveHour?.percent == 40)
  }

  @Test func aLiveReadingNewerThanTheCacheWins() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 12, fetchedAt: 1000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    try record(event, in: store, for: account, at: 5)
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
    #expect(store.usage(for: account)?.source == .live)
  }

  /// A cache written after the live reading (another process's turn) is the newer figure.
  @Test func aNewerCacheBeatsAnOlderLiveReading() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConfig(percent: 70, fetchedAt: 9_000_000, modified: Date(timeIntervalSince1970: 10))
    let store = await store()
    try record(event, in: store, for: account, at: 5)
    #expect(store.usage(for: account)?.fiveHour?.percent == 70)
  }

  @Test func anEventWithoutWindowsKeepsTheLastReading() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await store()
    try record(event, in: store, for: account, at: 5)
    try record(#"{"status":"allowed"}"#, in: store, for: account, at: 6)
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
  }

  /// A resumed session names its account without the trailing slash discovery gives it.
  @Test func liveReadingFindsTheAccountWhateverItsSpelling() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await store()
    let respelled = ClaudeAccount(
      directory: URL(filePath: String(account.directory.path(percentEncoded: false).dropLast())),
      isDefault: false)
    try record(event, in: store, for: respelled, at: 5)
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
  }

  /// What a running session streams reaches the store under the session's account.
  @Test func aSessionForwardsItsRateLimitEvents() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let fake = root.appending(path: "claude")
    try Data(
      "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"rate_limit_event\",\"rate_limit_info\":\(event)}'\ncat > /dev/null\n"
        .utf8
    ).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(
      account.directory.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = await store()
    let session = AgentSession(folder: root)
    session.executableOverride = fake
    session.accountStore = store
    await ClaudeChoice.$testSuite.withValue(suite) { await session.spawn() }
    defer { session.stop() }
    for _ in 0..<50 where store.usage(for: account) == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(store.usage(for: account)?.fiveHour?.percent == 50)
  }

  /// Clicking the account the window already uses changes nothing: a folder never picked
  /// keeps following Settings.
  @Test func pickingTheWindowsOwnAccountStoresNothing() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(
      account.directory.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    defer { defaults.removePersistentDomain(forName: suite) }
    let other = ClaudeAccount(
      directory: root.appending(path: ".claude-other", directoryHint: .isDirectory),
      isDefault: false)
    try FileManager.default.createDirectory(at: other.directory, withIntermediateDirectories: true)
    let folder = root.appending(path: "project", directoryHint: .isDirectory)

    let store = await store()
    ClaudeChoice.$testSuite.withValue(suite) {
      store.pick(account, for: folder)
      #expect(ClaudeChoice.pickedAccount(for: folder) == nil)
      store.pick(other, for: folder)
      #expect(ClaudeChoice.pickedAccount(for: folder)?.key == other.key)
    }
  }

  @Test func readsCodexRolloutAndMergesLiveReading() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: ".codex", directoryHint: .isDirectory)
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
    let dayDir = codexHome.appending(
      path: String(
        format: "sessions/%04d/%02d/%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1),
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    let rollout = dayDir.appending(path: "rollout-2026-11-27T10-00-00-abc.jsonl")
    let olderTimestamp = Date(timeIntervalSince1970: 1_795_000_000)
    try Data(
      #"{"timestamp":"2026-11-19T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":25.0,"window_minutes":300,"resets_at":4070908800},"secondary":{"used_percent":41.0,"window_minutes":10080,"resets_at":4070999999}}}}"#
        .utf8
    ).write(to: rollout)

    let store = await store(codexHome: codexHome)
    #expect(store.codexUsage?.plan == "Plus")
    #expect(store.codexUsage?.usage.fiveHour?.percent == 25)
    #expect(store.codexUsage?.usage.sevenDay?.percent == 41)
    #expect(store.codexUsage?.usage.source == .sessionLog)

    // A newer live reading from codex app-server beats the rollout.
    let live = CodexUsage(
      usage: AccountUsage(
        fiveHour: UsageWindow(percent: 62, resetsAt: nil),
        sevenDay: UsageWindow(percent: 45, resetsAt: nil),
        readAt: olderTimestamp.addingTimeInterval(3600 * 24 * 30), source: .live),
      plan: "Pro")
    store.recordCodex(live)
    #expect(store.codexUsage?.plan == "Pro")
    #expect(store.codexUsage?.usage.fiveHour?.percent == 62)
    #expect(store.codexUsage?.usage.source == .live)
  }

  @Test func probesAntigravityThrottlesAndKeepsLastOnFailure() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var probeCalls = 0
    var nextResult: AgyUsage? = AgyUsage(
      buckets: [
        AgyUsage.Bucket(id: "gemini-5h", window: UsageWindow(percent: 33, resetsAt: nil)),
        AgyUsage.Bucket(id: "3p-5h", window: UsageWindow(percent: 12, resetsAt: nil)),
      ],
      plan: "Google AI Pro",
      readAt: Date(timeIntervalSince1970: 1000))

    let store = AccountStore(
      discover: { (accounts: [self.account], shell: self.account) },
      discoverCodexHome: { self.root.appending(path: ".codex", directoryHint: .isDirectory) },
      probeAgy: {
        probeCalls += 1
        return nextResult
      })
    await store.start()
    // Wait for the initial start() probe task to settle before stopping polling.
    await store.probeAgyIfNeeded()?.value
    store.stopPolling()

    #expect(probeCalls == 1)
    #expect(store.agyUsage?.plan == "Google AI Pro")
    #expect(store.agyUsage?.peakWindow(.fiveHour)?.percent == 33)

    // Within the 20s throttle window, a second non-forced call does nothing.
    let throttled = store.probeAgyIfNeeded(now: Date.now)
    #expect(throttled == nil)
    #expect(probeCalls == 1)

    // Past the throttle window, a failing probe (nil) keeps the previous usage.
    nextResult = nil
    await store.probeAgyIfNeeded(now: Date.now.addingTimeInterval(30))?.value
    #expect(probeCalls == 2)
    #expect(store.agyUsage?.plan == "Google AI Pro")
    #expect(store.agyUsage?.peakWindow(.fiveHour)?.percent == 33)
  }

  @Test func probesGrokThrottlesAndKeepsLastOnFailure() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var probeCalls = 0
    var nextResult: GrokUsage? = GrokUsage(
      window: UsageWindow(percent: 18, resetsAt: nil),
      periodName: "weekly",
      plan: "X Premium",
      readAt: Date(timeIntervalSince1970: 1000))

    let store = AccountStore(
      discover: { (accounts: [self.account], shell: self.account) },
      discoverCodexHome: { self.root.appending(path: ".codex", directoryHint: .isDirectory) },
      discoverGrokHome: { self.root.appending(path: ".grok", directoryHint: .isDirectory) },
      probeGrok: {
        probeCalls += 1
        return nextResult
      })
    await store.start()
    await store.probeGrokIfNeeded()?.value
    store.stopPolling()

    #expect(probeCalls == 1)
    #expect(store.grokUsage?.plan == "X Premium")
    #expect(store.grokUsage?.window.percent == 18)

    // Within the 20s throttle window, a second non-forced call does nothing.
    let throttled = store.probeGrokIfNeeded(now: Date.now)
    #expect(throttled == nil)
    #expect(probeCalls == 1)

    // Past the throttle window, a failing probe (nil) keeps the previous usage.
    nextResult = nil
    await store.probeGrokIfNeeded(now: Date.now.addingTimeInterval(30))?.value
    #expect(probeCalls == 2)
    #expect(store.grokUsage?.plan == "X Premium")
    #expect(store.grokUsage?.window.percent == 18)
  }
}
