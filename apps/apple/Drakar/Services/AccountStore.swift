import DrakarKit
import Foundation
import Observation

/// Every account's name, plan and plan usage, for the toolbar's account item. One for the
/// app, since every window reads the same accounts.
///
/// Usage comes from two places and the newer reading wins: the `.claude.json` cache any
/// `claude` of the account rewrites (polled, see `start()`), and the `rate_limit_event` each
/// of Drakar's own sessions streams (`record`). Nothing here starts a process or calls the
/// network.
@Observable
final class AccountStore {
  static let shared = AccountStore()

  private(set) var accounts: [ClaudeAccount] = []
  /// The account a `claude` runs under when Drakar names none: the shell's
  /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
  private(set) var shellAccount: ClaudeAccount
  /// By `ClaudeAccount.key`.
  private var profiles: [String: AccountProfile] = [:]
  private var live: [String: AccountUsage] = [:]

  @ObservationIgnored private var modified: [String: Date] = [:]
  @ObservationIgnored private var poll: Timer?
  @ObservationIgnored private var started: Task<Void, Never>?
  @ObservationIgnored private let discover:
    () async -> (accounts: [ClaudeAccount], shell: ClaudeAccount)

  /// `discover` replaces the login-shell discovery, for tests.
  init(discover: (() async -> (accounts: [ClaudeAccount], shell: ClaudeAccount))? = nil) {
    let standard = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
      .path(percentEncoded: false)
    shellAccount = ClaudeChoice.account(at: standard)
    self.discover =
      discover ?? {
        let shellDirectory = (await AgentSession.environment.value)["CLAUDE_CONFIG_DIR"]
        let extra = shellDirectory.map { [URL(filePath: $0, directoryHint: .isDirectory)] } ?? []
        return (
          ClaudeAccount.discover(extra: extra), ClaudeChoice.account(at: shellDirectory ?? standard)
        )
      }
  }

  /// Finds the accounts once, reads them, then rereads any whose file changed every 5 s.
  /// Polled, not watched: an FSEvents stream is recursive, and `~/.claude.json` sits in the
  /// home folder.
  func start() async {
    if let started { return await started.value }
    let task = Task {
      let found = await discover()
      accounts = found.accounts
      shellAccount = found.shell
      reloadChanged()
      poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.reloadChanged() }
      }
    }
    started = task
    await task.value
  }

  /// For tests: no timer outliving the test.
  func stopPolling() {
    poll?.invalidate()
    poll = nil
  }

  /// Rereads each account whose `.claude.json` changed since it was last read.
  func reloadChanged() {
    for account in Set(accounts + [shellAccount]) {
      let path = account.configFile.path(percentEncoded: false)
      let date =
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
      guard profiles[account.key] == nil || modified[account.key] != date else { continue }
      modified[account.key] = date
      profiles[account.key] = AccountProfile(reading: account)
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

  /// A session's `rate_limit_info`. One that names no window keeps the last reading.
  func record(_ info: JSONValue, for account: ClaudeAccount, at now: Date = .now) {
    guard let usage = AccountUsage(live: info, at: now) else { return }
    live[account.key] = usage.merged(live[account.key])
  }
}
