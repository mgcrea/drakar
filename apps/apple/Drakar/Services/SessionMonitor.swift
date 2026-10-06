import DrakarKit
import Foundation
import Observation

/// Every session on disk, kept current from FSEvents: what a project window lists as
/// elsewhere and ended, and what the picker lists. One for the app, since every window
/// reads the same folders. Armada's `SessionWatcher`, narrowed to what Drakar shows.
@Observable
final class SessionMonitor {
  static let shared = SessionMonitor()

  /// By transcript path, its folder resolved (`key(_:)`): one id can have a transcript per
  /// account.
  private(set) var byFile: [String: SessionSummary] = [:]
  private(set) var isLoaded = false
  /// Every transcript folder, for home's counts: every session on disk, not only the newest
  /// listed in `byFile`.
  private(set) var folders: [TranscriptFolder] = []
  /// The sessions a `claude` process has open now, outside Drakar.
  private(set) var liveSessions: [LiveSession] = []

  @ObservationIgnored private var accounts: [ClaudeAccount]
  @ObservationIgnored private var accountModels: [URL: String] = [:]
  @ObservationIgnored private var live: [URL: [String: LiveSession]] = [:]
  @ObservationIgnored private var watchers: [FolderWatcher] = []
  @ObservationIgnored private var sweep: Timer?
  @ObservationIgnored private var included: Set<String> = []
  @ObservationIgnored private var discovery: Task<Void, Never>?
  @ObservationIgnored private let discover: (() async -> [ClaudeAccount])?
  @ObservationIgnored private var generations: [String: Int] = [:]
  /// `realpath` of each transcript folder seen, so a key costs one lookup.
  @ObservationIgnored private var resolvedFolders: [String: String] = [:]
  /// A linked worktree's `cwd` → the same folder in its main checkout, from `folders`.
  @ObservationIgnored private var checkouts: [String: String] = [:]
  @ObservationIgnored private var folderScan: Task<Void, Never>?
  /// Whether the registries were read once: before that, no id is known to be live.
  @ObservationIgnored private(set) var hasReadRegistries = false

  /// `accounts` for tests; the app discovers them, its shell's `CLAUDE_CONFIG_DIR` included.
  /// `discover` replaces the login-shell discovery, for tests.
  init(accounts: [ClaudeAccount] = [], discover: (() async -> [ClaudeAccount])? = nil) {
    self.accounts = accounts
    self.discover = discover
  }

  /// The ids a `claude` process has open now.
  var liveIDs: Set<String> { Set(live.values.flatMap(\.keys)) }

  var all: [SessionSummary] { byFile.values.sorted { $0.modified > $1.modified } }

  func summaries(under folder: String) -> [SessionSummary] {
    let owners = ProjectPath.Owners([folder])
    return byFile.values.filter { summary in
      summary.cwd.map { owners.owner(of: checkout(of: $0)) != nil } ?? false
    }
  }

  /// `cwd` as it sits in its main checkout: a linked worktree's sessions belong to their
  /// repository. Known once the folders are scanned; until then, `cwd` itself.
  func checkout(of cwd: String) -> String {
    checkouts[ProjectPath.normalize(cwd)] ?? cwd
  }

  /// The summary of `file`, when it is among those read.
  func summary(forFile file: URL) -> SessionSummary? { byFile[key(file)] }

  /// Reads `file`'s summary when the newest 500 did not include it: a project row's gauge
  /// is its newest session's, however old.
  func load(_ file: URL, account: ClaudeAccount) async {
    guard summary(forFile: file) == nil else { return }
    let summary = await Task.detached { SessionIndex.summary(of: file, account: account) }.value
    if let summary, self.summary(forFile: file) == nil { merge([summary]) }
  }

  /// The one terminal session of `folder` connected to the bridge, when there is exactly one.
  func connectedSession(under folder: String) -> SessionSummary? {
    let connected = summaries(under: folder).filter { summary in
      summary.live.map { IDEBridge.shared.connectedPIDs.contains($0.pid) } ?? false
    }
    return connected.count == 1 ? connected.first : nil
  }

  func accountModel(for account: ClaudeAccount) -> String? { accountModels[account.directory] }

  /// Where a live session runs, in words.
  /// `project` is the asking window: the session being in it does not make it "another
  /// window".
  func host(of summary: SessionSummary, excluding project: Project? = nil) -> String {
    if let (owner, _) = OpenSessions.shared.locate(summary.sessionID), owner !== project {
      return String(localized: "another Drakar window")
    }
    return switch summary.live?.entrypoint {
    case "claude-vscode": String(localized: "VS Code")
    case "cli": String(localized: "a terminal")
    case "claude-desktop": String(localized: "the Claude app")
    default: String(localized: "another app")
    }
  }

  /// Finds the accounts once, whoever asks first; later callers wait for the same answer.
  private func ensureAccounts() async {
    if let discovery { return await discovery.value }
    guard accounts.isEmpty else { return }
    let task = Task {
      if let discover = self.discover {
        self.accounts = await discover()
      } else {
        let extra =
          (await AgentSession.environment.value)["CLAUDE_CONFIG_DIR"].map {
            [URL(filePath: $0, directoryHint: .isDirectory)]
          } ?? []
        self.accounts = ClaudeAccount.discover(extra: extra)
      }
      for account in self.accounts {
        self.accountModels[account.directory] = ContextWindow.accountModelID(account)
      }
    }
    discovery = task
    await task.value
  }

  func start() async {
    guard watchers.isEmpty else { return }
    await ensureAccounts()
    guard watchers.isEmpty else { return }
    let accounts = self.accounts
    for account in accounts where accountModels[account.directory] == nil {
      accountModels[account.directory] = ContextWindow.accountModelID(account)
    }
    // Before the long listing: a restored row live in a terminal locks at once.
    readRegistries()
    let listed = await Task.detached { SessionIndex.list(accounts: accounts, limit: 500) }.value
    merge(listed)
    readRegistries()
    isLoaded = true
    scanFolders(after: .zero)
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
    await ensureAccounts()
    let accounts = self.accounts
    let listed = await Task.detached {
      SessionIndex.list(accounts: accounts, limit: 200, under: folder)
    }.value
    merge(listed)
    // A linked worktree's transcripts are named after its own path, not the folder's.
    let owners = ProjectPath.Owners([folder])
    let worktrees = folders.filter { entry in
      guard let checkout = entry.checkout, let cwd = entry.cwd else { return false }
      return checkout != ProjectPath.normalize(cwd) && owners.owner(of: checkout) != nil
    }
    guard !worktrees.isEmpty else { return }
    let read = await Task.detached {
      worktrees.flatMap { entry in
        entry.sessionIDs.compactMap { id in
          SessionIndex.summary(
            of: entry.folder.appending(path: "\(id).jsonl"), account: entry.account)
        }
      }
    }.value
    merge(read)
  }

  /// Rescans the transcript folders, `delay` after the last change asked: a streaming
  /// session writes many times a second, and the counts need none of those in between.
  private func scanFolders(after delay: Duration) {
    folderScan?.cancel()
    let (accounts, previous) = (self.accounts, folders)
    folderScan = Task {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      let scanned = await Task.detached {
        SessionIndex.folders(accounts: accounts, previous: previous)
      }.value
      guard !Task.isCancelled else { return }
      for entry in scanned {
        if let cwd = entry.cwd, let checkout = entry.checkout {
          checkouts[ProjectPath.normalize(cwd)] = checkout
        }
      }
      if scanned != folders { folders = scanned }
    }
  }

  private func merge(_ summaries: [SessionSummary]) {
    for var summary in summaries {
      summary.live = live[summary.account.directory]?[summary.sessionID]
      byFile[key(summary.file)] = summary
    }
  }

  /// The transcript's path with its folder's links resolved: FSEvents reports resolved
  /// paths, the listing the spelling it was given (`~/.claude` may be a link, the temporary
  /// folder is `/var` → `/private/var`), and a deleted file cannot be resolved itself.
  private func key(_ file: URL) -> String {
    let folder = file.deletingLastPathComponent().path(percentEncoded: false)
    let resolved =
      resolvedFolders[folder]
      ?? {
        let resolved = ProjectPath.resolved(folder)
        resolvedFolders[folder] = resolved
        return resolved
      }()
    return resolved + "/" + file.lastPathComponent
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
    if !files.isEmpty { scanFolders(after: .seconds(2)) }
    for path in files {
      let file = URL(filePath: path)
      let generation = generations[path, default: 0] + 1
      generations[path] = generation
      Task {
        let read = Task.detached { SessionIndex.summary(of: file, account: account) }
        let summary = await read.value
        // A newer read of this file started meanwhile: its answer wins.
        guard generations[path] == generation else { return }
        guard let summary else { return forget(path) }
        merge([summary])
        OpenSessions.shared.transcriptWritten(summary)
      }
    }
  }

  /// A transcript that was deleted leaves the lists.
  private func forget(_ path: String) {
    byFile[key(URL(filePath: path))] = nil
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
    let sessions = live.values.flatMap(\.values).sorted { $0.pid < $1.pid }
    if sessions != liveSessions { liveSessions = sessions }
    hasReadRegistries = true
    OpenSessions.shared.liveChanged(liveIDs)
  }

  private func sweepDead() {
    let dead = live.values.contains { sessions in
      sessions.values.contains { !LiveSession.isAlive($0.pid) }
    }
    if dead { readRegistries() }
  }
}
