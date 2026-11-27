import DrakarKit
import Foundation
import Observation

/// Every account's name, plan and plan usage, for the toolbar's account item. One for the
/// app, since every window reads the same accounts.
///
/// - **Claude Code**: `.claude.json` cache (polled every 5s) + live `rate_limit_event` from
///   Drakar's own sessions; newer reading wins.
/// - **Codex**: newest rollout log under `$CODEX_HOME/sessions/` (polled every 5s when the
///   newest file changes) + live `account/rateLimits/updated` from Drakar's own sessions;
///   newer reading wins.
/// - **Antigravity**: live `statusLine` probe via `agy --settings` in an isolated temp
///   directory (`AgyLimitsProbe`), run at launch, every 3 minutes, and (throttled to 20s)
///   when opening the account popover or finishing an Antigravity turn.
/// - **Grok Build**: live `_x.ai/billing` probe via `grok agent stdio` (`GrokLimitsProbe`),
///   run on the same cadence as Antigravity (launch, every 3 minutes, popover open, or
///   finishing a Grok turn).
@Observable
final class AccountStore {
  static let shared = AccountStore()

  static let probeInterval: TimeInterval = 3 * 60
  static let probeThrottle: TimeInterval = 20

  private(set) var accounts: [ClaudeAccount] = []
  /// The account a `claude` runs under when Drakar names none: the shell's
  /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
  private(set) var shellAccount: ClaudeAccount
  /// Where Codex keeps its sessions (`$CODEX_HOME`, else `~/.codex`).
  private(set) var codexHome: URL
  /// Where Grok Build keeps its sessions (`$GROK_HOME`, else `~/.grok`).
  private(set) var grokHome: URL
  /// By `ClaudeAccount.key`.
  private var profiles: [String: AccountProfile] = [:]
  private var live: [String: AccountUsage] = [:]
  private var codexRollout: CodexUsage?
  private var codexLive: CodexUsage?
  private(set) var agyUsage: AgyUsage?
  private(set) var grokUsage: GrokUsage?

  @ObservationIgnored private var modified: [String: Date] = [:]
  @ObservationIgnored private var codexRolloutStamp: CodexRolloutLimits.Stamp?
  @ObservationIgnored private var codexHasRead = false
  @ObservationIgnored private var poll: Timer?
  @ObservationIgnored private var probeTimer: Timer?
  @ObservationIgnored private var agyProbeTask: Task<Void, Never>?
  @ObservationIgnored private var lastAgyProbe: Date?
  @ObservationIgnored private var grokProbeTask: Task<Void, Never>?
  @ObservationIgnored private var lastGrokProbe: Date?
  @ObservationIgnored private var started: Task<Void, Never>?
  @ObservationIgnored private let discover:
    () async -> (accounts: [ClaudeAccount], shell: ClaudeAccount)
  @ObservationIgnored private let discoverCodexHome: () async -> URL
  @ObservationIgnored private let discoverGrokHome: () async -> URL
  @ObservationIgnored private let probeAgy: () async -> AgyUsage?
  @ObservationIgnored private let probeGrok: () async -> GrokUsage?

  /// `discover`, `discoverCodexHome`, `discoverGrokHome`, `probeAgy`, and `probeGrok` replace
  /// login-shell discovery and live CLI probing, for tests.
  init(
    discover: (() async -> (accounts: [ClaudeAccount], shell: ClaudeAccount))? = nil,
    discoverCodexHome: (() async -> URL)? = nil,
    discoverGrokHome: (() async -> URL)? = nil,
    probeAgy: (() async -> AgyUsage?)? = nil,
    probeGrok: (() async -> GrokUsage?)? = nil
  ) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let standard = home.appending(path: ".claude").path(percentEncoded: false)
    shellAccount = ClaudeChoice.account(at: standard)
    codexHome = CodexRolloutLimits.resolveHome(environment: [:], home: home)
    grokHome = GrokLimitsProbe.resolveHome(environment: [:], home: home)
    self.discover =
      discover ?? {
        let shellDirectory = (await AgentSession.environment.value)["CLAUDE_CONFIG_DIR"]
        let extra = shellDirectory.map { [URL(filePath: $0, directoryHint: .isDirectory)] } ?? []
        return (
          ClaudeAccount.discover(extra: extra), ClaudeChoice.account(at: shellDirectory ?? standard)
        )
      }
    self.discoverCodexHome =
      discoverCodexHome ?? {
        guard discover == nil else {
          return CodexRolloutLimits.resolveHome(environment: [:], home: home)
        }
        let environment = await AgentSession.environment.value
        return CodexRolloutLimits.resolveHome(environment: environment, home: home)
      }
    self.discoverGrokHome =
      discoverGrokHome ?? {
        guard discover == nil else {
          return GrokLimitsProbe.resolveHome(environment: [:], home: home)
        }
        let environment = await AgentSession.environment.value
        return GrokLimitsProbe.resolveHome(environment: environment, home: home)
      }
    self.probeAgy =
      probeAgy ?? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
          AgyLimitsProbe.isHomePresent()
        else { return nil }
        let environment = await AgentSession.environment.value
        guard let executable = AgyLaunch.locate(path: environment["PATH"]) else { return nil }
        return await AgyLimitsProbe.limits(executable: executable, environment: environment)
      }
    self.probeGrok =
      probeGrok ?? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
          return nil
        }
        let environment = await AgentSession.environment.value
        let grokHome = GrokLimitsProbe.resolveHome(environment: environment, home: home)
        guard GrokLimitsProbe.isHomePresent(at: grokHome),
          let executable = AgyLaunch.locate(path: environment["PATH"], binary: "grok")
        else { return nil }
        return await GrokLimitsProbe.limits(executable: executable, environment: environment)
      }
  }

  /// Finds the accounts once, reads them, then rereads any whose file changed every 5 s, and
  /// schedules periodic Antigravity and Grok Build quota probes every 3 minutes. Polled, not
  /// watched: an FSEvents stream is recursive, and `~/.claude.json` sits in the home folder.
  func start() async {
    if let started { return await started.value }
    let task = Task<Void, Never> {
      let found = await discover()
      accounts = found.accounts
      shellAccount = found.shell
      codexHome = await discoverCodexHome()
      grokHome = await discoverGrokHome()
      await reloadChanged()
      poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        // Discarded and typed: Swift 6.3 (CI's Xcode 26.6) cannot tell what this closure
        // returns, nor the Task's Failure, nor then the enclosing Task's.
        MainActor.assumeIsolated { _ = Task<Void, Never> { await self?.reloadChanged() } }
      }
      _ = probeAgyIfNeeded()
      _ = probeGrokIfNeeded()
      probeTimer = Timer.scheduledTimer(
        withTimeInterval: Self.probeInterval, repeats: true
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          _ = self?.probeAgyIfNeeded()
          _ = self?.probeGrokIfNeeded()
        }
      }
    }
    started = task
    await task.value
  }

  /// For tests: no timer or probe task outliving the test.
  func stopPolling() {
    poll?.invalidate()
    poll = nil
    probeTimer?.invalidate()
    probeTimer = nil
    agyProbeTask?.cancel()
    agyProbeTask = nil
    grokProbeTask?.cancel()
    grokProbeTask = nil
  }

  /// Rereads each Claude account whose `.claude.json` changed and Codex's newest rollout when
  /// it changed. Files are parsed off the main actor, and unchanged values are not reassigned.
  func reloadChanged() async {
    var changed: [ClaudeAccount] = []
    for account in Set(accounts + [shellAccount]) {
      let path = account.configFile.path(percentEncoded: false)
      let date =
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
      guard profiles[account.key] == nil || modified[account.key] != date else { continue }
      modified[account.key] = date
      changed.append(account)
    }

    let codexHome = self.codexHome
    let previousStamp = codexRolloutStamp
    let hasReadCodex = codexHasRead

    async let claudeRead: [AccountProfile] =
      changed.isEmpty
      ? []
      : await Task.detached { changed.map { AccountProfile(reading: $0) } }.value

    async let codexRead: (stamp: CodexRolloutLimits.Stamp?, usage: CodexUsage?)? =
      await Task.detached {
        let stamp = CodexRolloutLimits.newestRollout(in: codexHome)
        guard !hasReadCodex || stamp != previousStamp else { return nil }
        return (stamp, CodexRolloutLimits.read(in: codexHome))
      }.value

    let read = await claudeRead
    for (account, profile) in zip(changed, read) where profiles[account.key] != profile {
      profiles[account.key] = profile
    }

    if let codex = await codexRead {
      codexRolloutStamp = codex.stamp
      codexHasRead = true
      if let reading = codex.usage {
        let merged = reading.merged(codexRollout)
        if codexRollout != merged { codexRollout = merged }
      }
    }
  }

  func profile(for account: ClaudeAccount) -> AccountProfile {
    profiles[account.key] ?? AccountProfile(json: nil, fallbackName: account.name)
  }

  /// The newer of the live reading and the cache.
  func usage(for account: ClaudeAccount) -> AccountUsage? {
    let cached = profiles[account.key]?.cachedUsage
    guard let live = live[account.key] else { return cached }
    return live.merged(cached)
  }

  /// A Claude session's `rate_limit_info`. One that names no window keeps the last reading.
  func record(_ info: JSONValue, for account: ClaudeAccount, at now: Date = .now) {
    guard let usage = AccountUsage(live: info, at: now) else { return }
    live[account.key] = usage.merged(live[account.key])
  }

  /// The newer of Codex's live `app-server` reading and its newest rollout log.
  var codexUsage: CodexUsage? {
    guard let codexLive else { return codexRollout }
    return codexLive.merged(codexRollout)
  }

  /// A Codex session's `account/rateLimits/updated`.
  func recordCodex(_ reading: CodexUsage) {
    let merged = reading.merged(codexLive)
    if codexLive != merged { codexLive = merged }
  }

  /// Probes Antigravity's live quotas unless throttled or a probe is already running. A failed
  /// probe keeps the last reading.
  @discardableResult
  func probeAgyIfNeeded(force: Bool = false, now: Date = .now) -> Task<Void, Never>? {
    if let existing = agyProbeTask { return existing }
    if !force, let last = lastAgyProbe, now.timeIntervalSince(last) < Self.probeThrottle {
      return nil
    }
    lastAgyProbe = now
    let probe = self.probeAgy
    let task = Task<Void, Never> { [weak self] in
      let reading = await probe()
      guard let self else { return }
      self.agyProbeTask = nil
      guard let reading, !Task.isCancelled else { return }
      let merged = reading.merged(self.agyUsage)
      if self.agyUsage != merged { self.agyUsage = merged }
    }
    agyProbeTask = task
    return task
  }

  /// Probes Grok Build's live allowance unless throttled or a probe is already running. A failed
  /// probe keeps the last reading.
  @discardableResult
  func probeGrokIfNeeded(force: Bool = false, now: Date = .now) -> Task<Void, Never>? {
    if let existing = grokProbeTask { return existing }
    if !force, let last = lastGrokProbe, now.timeIntervalSince(last) < Self.probeThrottle {
      return nil
    }
    lastGrokProbe = now
    let probe = self.probeGrok
    let task = Task<Void, Never> { [weak self] in
      let reading = await probe()
      guard let self else { return }
      self.grokProbeTask = nil
      guard let reading, !Task.isCancelled else { return }
      let merged = reading.merged(self.grokUsage)
      if self.grokUsage != merged { self.grokUsage = merged }
    }
    grokProbeTask = task
    return task
  }
}
