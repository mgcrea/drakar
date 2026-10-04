import DrakarKit
import Foundation
import Observation

/// Every session on disk, kept current from FSEvents: what a project window lists as
/// elsewhere and ended, and what the picker lists. One for the app, since every window
/// reads the same folders. Armada's `SessionWatcher`, narrowed to what Drakar shows.
@Observable
final class SessionMonitor {
  static let shared = SessionMonitor()

  /// By transcript path (`SessionSummary.id`): one id can have a transcript per account.
  private(set) var byFile: [String: SessionSummary] = [:]
  private(set) var isLoaded = false

  @ObservationIgnored private var accounts: [ClaudeAccount]
  @ObservationIgnored private var accountModels: [URL: String] = [:]
  @ObservationIgnored private var live: [URL: [String: LiveSession]] = [:]
  @ObservationIgnored private var watchers: [FolderWatcher] = []
  @ObservationIgnored private var sweep: Timer?
  @ObservationIgnored private var included: Set<String> = []

  /// `accounts` for tests; the app discovers them, its shell's `CLAUDE_CONFIG_DIR` included.
  init(accounts: [ClaudeAccount] = []) {
    self.accounts = accounts
  }

  var all: [SessionSummary] { byFile.values.sorted { $0.modified > $1.modified } }

  func summaries(under folder: String) -> [SessionSummary] {
    byFile.values.filter { summary in
      summary.cwd.map { ProjectPath.owner(of: $0, among: [folder]) != nil } ?? false
    }
  }

  func accountModel(for account: ClaudeAccount) -> String? { accountModels[account.directory] }

  /// Where a live session runs, in words.
  func host(of summary: SessionSummary) -> String {
    if OpenSessions.shared.locate(summary.sessionID) != nil {
      return String(localized: "another Drakar window")
    }
    return switch summary.live?.entrypoint {
    case "claude-vscode": String(localized: "VS Code")
    case "cli": String(localized: "a terminal")
    case "claude-desktop": String(localized: "the Claude app")
    default: String(localized: "another app")
    }
  }

  func start() async {
    guard watchers.isEmpty else { return }
    if accounts.isEmpty {
      let extra =
        (await ClaudeSession.environment.value)["CLAUDE_CONFIG_DIR"].map {
          [URL(filePath: $0, directoryHint: .isDirectory)]
        } ?? []
      accounts = ClaudeAccount.discover(extra: extra)
    }
    let accounts = self.accounts
    for account in accounts {
      accountModels[account.directory] = ContextWindow.accountModelID(account)
    }
    let listed = await Task.detached { SessionIndex.list(accounts: accounts, limit: 500) }.value
    merge(listed)
    readRegistries()
    isLoaded = true
    for account in accounts {
      for name in ["sessions", "projects"] {
        let folder = account.directory.appending(path: name, directoryHint: .isDirectory)
        if let watcher = FolderWatcher(
          folder: folder,
          onChange: { [weak self] paths in
            self?.changed(paths, in: account)
          })
        {
          watchers.append(watcher)
        }
      }
    }
    // A crashed session leaves its registry file behind: its pid is checked every second.
    sweep = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sweepDead() }
    }
  }

  func stop() {
    for watcher in watchers { watcher.stop() }
    watchers = []
    sweep?.invalidate()
    sweep = nil
  }

  /// A project window's own sessions, past the 500 newest the app reads at launch.
  func include(folder: String) async {
    guard included.insert(folder).inserted else { return }
    let accounts = self.accounts
    let listed = await Task.detached {
      SessionIndex.list(accounts: accounts, limit: 200, under: folder)
    }.value
    merge(listed)
  }

  private func merge(_ summaries: [SessionSummary]) {
    for var summary in summaries {
      summary.live = live[summary.account.directory]?[summary.sessionID]
      byFile[summary.id] = summary
    }
  }

  private func changed(_ paths: [String], in account: ClaudeAccount) {
    var registry = false
    var files: Set<String> = []
    for path in paths {
      let url = URL(filePath: path)
      if url.pathExtension == "json",
        url.deletingLastPathComponent().lastPathComponent == "sessions"
      {
        registry = true
      } else if url.pathExtension == "jsonl",
        // `<project>/<id>.jsonl` only: a subagent writes under `<project>/<id>/…`.
        url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "projects"
      {
        files.insert(path)
      }
    }
    if registry { readRegistries() }
    for path in files {
      let file = URL(filePath: path)
      Task {
        let read = Task.detached { SessionIndex.summary(of: file, account: account) }
        guard let summary = await read.value else { return }
        merge([summary])
        OpenSessions.shared.transcriptWritten(summary.sessionID)
      }
    }
  }

  private func readRegistries() {
    for account in accounts {
      live[account.directory] = Dictionary(
        LiveSession.read(account: account).map { ($0.sessionID, $0) },
        uniquingKeysWith: { first, _ in first })
    }
    for (key, summary) in byFile {
      let current = live[summary.account.directory]?[summary.sessionID]
      if summary.live != current { byFile[key]?.live = current }
    }
    OpenSessions.shared.liveChanged(Set(live.values.flatMap(\.keys)))
  }

  private func sweepDead() {
    let dead = live.values.contains { sessions in
      sessions.values.contains { !LiveSession.isAlive($0.pid) }
    }
    if dead { readRegistries() }
  }
}
