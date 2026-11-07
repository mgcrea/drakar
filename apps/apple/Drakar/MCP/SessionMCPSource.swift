import DrakarKit
import DrakarMCP
import Foundation

/// The MCP tools' `SessionSource`, answered from what the app already holds: its windows'
/// sessions (`OpenSessions`), the processes its session hosts keep with no window (this Mac's
/// and the runner's), and the sessions the monitor follows in other processes and on disk.
///
/// Called from the listener's connections, off the main actor: every read hops to it, where
/// the model lives, and hands back plain values. A session is listed once, by the agent's own
/// id, in the first place it is found: a window, then a host, then the monitor (spec §2).
/// One with no id yet is listed nowhere.
nonisolated final class SessionMCPSource: SessionSource, @unchecked Sendable {
  let defaults: UserDefaults
  let openSessions: OpenSessions
  let monitor: SessionMonitor
  /// What the session hosts list now, nil for a listing that never came; tests give their
  /// own.
  @MainActor var listHosts: () async -> HostListings = { await HostListings.now() }
  /// Each host's last listing that came, by `HostListings.Key`: a listing that never came
  /// (a host slower than its limit) says nothing of what it holds, so the last one stands
  /// rather than every background row dropping out for that call.
  @MainActor private var lastHeld: [HostListings.Key: [HeldProcess]] = [:]

  /// Tests give a scratch `defaults`, their own windows and a monitor of their own.
  @MainActor
  init(
    defaults: UserDefaults = .standard, openSessions: OpenSessions = .shared,
    monitor: SessionMonitor = .shared
  ) {
    self.defaults = defaults
    self.openSessions = openSessions
    self.monitor = monitor
  }

  // MARK: - Reads

  func sessions(includeEnded: Bool, endedLimit: Int) async -> [SessionRow] {
    await rows(includeEnded: includeEnded, endedLimit: endedLimit)
  }

  func detail(of id: String) async -> SessionDetail? {
    await detailOnMain(of: id)
  }

  func attention() async -> [AttentionItem] {
    await attentionOnMain()
  }

  func transcript(of id: String) async throws -> Transcript {
    switch await transcriptSource(of: id) {
    case .live(let transcript): return transcript
    case .file(let file): return try await Self.history(of: file)
    case .refused(let message): throw SessionError(message)
    }
  }

  func projects() async -> [DrakarMCP.ProjectRow] {
    await MainActor.run { projectRows() }
  }

  func runner() async -> RunnerStatus? {
    await MainActor.run { runnerStatus() }
  }

  func workRefusal() async -> String? {
    await MainActor.run { EntitlementMonitor.allowsWorkNow ? nil : LockedComposerCard.refusal }
  }

  func permissionsAllowed() async -> Bool {
    await MainActor.run { defaults.bool(forKey: MCPSettingsKey.allowsPermissions) }
  }

  // MARK: - Writes (Task 8)

  func start(_ request: StartRequest) async throws -> String { throw Self.notReady }
  func send(to id: String, text: String) async throws -> SendOutcome { throw Self.notReady }
  func interrupt(_ id: String) async throws { throw Self.notReady }
  func end(_ id: String) async throws { throw Self.notReady }
  func answer(_ id: String, requestID: String, with decision: PermissionDecision) async throws {
    throw Self.notReady
  }
  func answer(_ id: String, requestID: String, with answer: ElicitationAnswer) async throws {
    throw Self.notReady
  }

  private static let notReady = SessionError("Not ready")
}

// MARK: - Finding sessions

extension SessionMCPSource {
  /// A session listed, with what its row was made from, for the reads that need more of it.
  @MainActor enum Found {
    case window(Project, ProjectSession, SessionRow)
    case background(Background)
    /// Live elsewhere, or ended: what the monitor read of its transcript.
    case monitored(SessionSummary, SessionRow)

    var row: SessionRow {
      switch self {
      case .window(_, _, let row), .monitored(_, let row): row
      case .background(let background): background.row
      }
    }
  }

  @MainActor private func rows(includeEnded: Bool, endedLimit: Int) async -> [SessionRow] {
    await found(includeEnded: includeEnded, endedLimit: endedLimit).map(\.row)
  }

  /// Every session listed, windows first, then the hosts' background processes, then those
  /// live in another process; with `includeEnded`, the newest `endedLimit` ended ones last.
  /// The hosts are asked first, so the windows are read after the wait, as they stand.
  @MainActor func found(includeEnded: Bool, endedLimit: Int) async -> [Found] {
    let held = await heldProcesses()
    let summaries = summariesByID()
    let windows = windowEntries(summaries: summaries)
    var listed = Set(windows.map(\.row.id))
    var background: [Background] = []
    let hosts: [(processes: [HeldProcess], runner: String?)] = [
      (held.local, nil), (held.runner, held.runnerName),
    ]
    for (processes, runner) in hosts {
      let rows = Self.backgroundRows(
        processes, runner: runner, live: monitor.liveSessions, excluding: listed,
        summary: { summaries[$0] }, accountModel: { [monitor] in monitor.accountModel(for: $0) })
      listed.formUnion(rows.map(\.row.id))
      background += rows
    }
    var found = windows.map { Found.window($0.project, $0.item, $0.row) }
    found += background.map(Found.background)
    let unlisted = monitor.all.filter { summary in
      listed.insert(summary.sessionID).inserted
    }
    let dismissed = dismissedElsewhere()
    found += unlisted.filter { $0.live != nil }.map {
      .monitored($0, elsewhereRow($0, dismissed: dismissed[$0.sessionID]))
    }
    if includeEnded {
      found += unlisted.filter { $0.live == nil }.prefix(max(endedLimit, 0))
        .map { .monitored($0, endedRow($0)) }
    }
    return found
  }

  /// The one session `id` names, live, else ended however long ago.
  /// A window's row is found without asking a host, which a window takes precedence over.
  @MainActor private func find(_ id: String) async -> Found? {
    if let window = windowEntries(summaries: summariesByID()).first(where: { $0.row.id == id }) {
      return .window(window.project, window.item, window.row)
    }
    if let found = await found(includeEnded: false, endedLimit: 0).first(where: {
      $0.row.id == id
    }) {
      return found
    }
    return summariesByID()[id].map { .monitored($0, endedRow($0)) }
  }

  /// Each open window's rows that have an id, once each: a row the window holds before one it
  /// only watches. Windows by folder, then their tabs in order, so the list reads the same
  /// from one call to the next.
  @MainActor private func windowEntries(
    summaries: [String: SessionSummary]
  ) -> [(project: Project, item: ProjectSession, row: SessionRow)] {
    let projects = openSessions.projects.values.sorted {
      ($0.runner ?? "", ProjectPath.normalize($0.folder))
        < ($1.runner ?? "", ProjectPath.normalize($1.folder))
    }
    let entries = projects.flatMap { project in
      project.sessions.map { (project: project, item: $0) }
    }
    var chosen: [String: ObjectIdentifier] = [:]
    for entry in entries.filter({ !$0.item.isWatching }) + entries.filter(\.item.isWatching) {
      guard let id = entry.item.sessionID, chosen[id] == nil else { continue }
      chosen[id] = ObjectIdentifier(entry.item)
    }
    return entries.compactMap { entry in
      guard let id = entry.item.sessionID, chosen[id] == ObjectIdentifier(entry.item) else {
        return nil
      }
      let row = windowRow(entry.item, in: entry.project, summary: summaries[id])
      return (entry.project, entry.item, row)
    }
  }

  /// What this Mac's host and the runner's hold. Neither is started by a read: this Mac's is
  /// asked only when it runs, the runner's only while connected.
  @MainActor private func heldProcesses() async -> (
    local: [HeldProcess], runner: [HeldProcess], runnerName: String?
  ) {
    let listings = await listHosts()
    let local = held(listings.local, by: .thisMac)
    guard let runner = listings.runner else { return (local, [], nil) }
    return (local, held(runner.held, by: .runner(runner.id)), runner.name)
  }

  /// `listed` when it came, kept for the next call; else the last that came, nothing for a
  /// host that has never answered.
  @MainActor private func held(_ listed: [HeldProcess]?, by key: HostListings.Key)
    -> [HeldProcess]
  {
    guard let listed else { return lastHeld[key] ?? [] }
    lastHeld[key] = listed
    return listed
  }

  /// The monitor's summaries by session id, the newest of an id's transcripts.
  @MainActor func summariesByID() -> [String: SessionSummary] {
    Dictionary(monitor.all.map { ($0.sessionID, $0) }, uniquingKeysWith: { newest, _ in newest })
  }

  // MARK: - Detail and attention

  @MainActor private func detailOnMain(of id: String) async -> SessionDetail? {
    switch await find(id) {
    case .window(let project, let item, let row):
      let session = item.session
      return SessionDetail(
        row: row, pending: Self.pending(of: item),
        queued: session.transcript.queuedPrompts.map(\.text),
        permissionMode: session.shownMode,
        accountFolder: project.runner == nil
          ? session.effectiveAccount?.directory.path(percentEncoded: false) : nil)
    case .background(let background):
      return SessionDetail(row: background.row, accountFolder: background.accountFolder)
    case .monitored(let summary, let row):
      return SessionDetail(
        row: row, accountFolder: summary.account.directory.path(percentEncoded: false))
    case nil:
      return nil
    }
  }

  /// Every session Drakar's `Urgency` gives a level, most urgent first: a window's pending
  /// requests, one item each, and its turn's closing ask; a session elsewhere at the level
  /// its registry and transcript give it. A host's background processes have no window to
  /// ask in, and are not counted, as Home and the Dock do not count them.
  @MainActor private func attentionOnMain() async -> [AttentionItem] {
    let all = await found(includeEnded: false, endedLimit: 0)
    let summaries = summariesByID()
    let dismissed = dismissedElsewhere()
    var items: [AttentionItem] = []
    for found in all {
      switch found {
      case .window(let project, let item, let row):
        if let summary = Self.followed(item, summary: summaries[row.id]) {
          let dismissed = item.dismissedAsk ?? project.dismissedElsewhere[row.id]
          let level = level(of: summary, dismissed: dismissed)
          items += Self.elsewhereItem(summary, level: level, row: row).map { [$0] } ?? []
        } else {
          items += Self.attentionItems(of: item, row: row)
        }
      case .monitored(let summary, let row):
        let level = level(of: summary, dismissed: dismissed[row.id])
        items += Self.elsewhereItem(summary, level: level, row: row).map { [$0] } ?? []
      case .background:
        break
      }
    }
    return Self.mostUrgentFirst(items)
  }

  // MARK: - Transcripts

  enum TranscriptSource: Sendable {
    case live(Transcript)
    case file(URL)
    case refused(String)
  }

  /// Where `id`'s transcript is read: its window's own, live; else its file, as Home's
  /// preview reads one. A runner's session with no window has no file here, and a Codex
  /// session's history is read only by a window.
  @MainActor private func transcriptSource(of id: String) async -> TranscriptSource {
    switch await find(id) {
    case .window(_, let item, _):
      // A row not shown yet has not read its history: read as its tab would, once.
      if !item.session.hasLoadedHistory { await item.session.loadHistory() }
      return .live(item.session.displayedTranscript)
    case .background(let background):
      let title = background.row.title ?? id
      if let runner = background.row.runner {
        return .refused("Open \(title) in Drakar first: its transcript is on \(runner).")
      }
      if background.row.agent == .codex {
        return .refused(
          "Open \(title) in Drakar first: a Codex session's history is read in its window.")
      }
      if let file = summariesByID()[id]?.file ?? background.transcriptFile { return .file(file) }
      return .refused("Open \(title) in Drakar first: its transcript was not found on this Mac.")
    case .monitored(let summary, _):
      return .file(summary.file)
    case nil:
      return .refused("No session \(id). drakar_list_sessions lists them.")
    }
  }

  /// A transcript file, read off the main actor: one runs to megabytes.
  @concurrent private static func history(of file: URL) async throws -> Transcript {
    do {
      return try Transcript.history(contentsOf: file)
    } catch {
      throw SessionError("Its transcript could not be read: \(error.localizedDescription)")
    }
  }

  // MARK: - Projects and runner

  /// The tracked projects, this Mac's, each open or not; then the runner's folders open in a
  /// window, the only ones of the runner's this Mac knows as projects.
  @MainActor private func projectRows() -> [DrakarMCP.ProjectRow] {
    let open = openSessions.projects.values
    let openHere = Set(open.filter { $0.runner == nil }.map { ProjectPath.normalize($0.folder) })
    var rows = ProjectList.shared.tracked.paths.map { path in
      DrakarMCP.ProjectRow(
        folder: path, isOpen: openHere.contains(ProjectPath.normalize(path)))
    }
    var seen: Set<String> = []
    for project in open.sorted(by: { $0.folder.path < $1.folder.path }) where project.runner != nil
    {
      let folder = ProjectPath.normalize(project.folder)
      let runner = project.runnerName
      guard seen.insert("\(runner ?? ""):\(folder)").inserted else { continue }
      rows.append(DrakarMCP.ProjectRow(folder: folder, runner: runner, isOpen: true))
    }
    return rows
  }

  /// The runner as Settings › Runner shows it, nil with none set up.
  @MainActor private func runnerStatus() -> RunnerStatus? {
    guard let settings = RunnerSettings.read(from: defaults) else { return nil }
    let host = SessionHost.runner
    return RunnerStatus(
      name: host?.runnerName ?? settings.displayName, isConnected: host?.isAvailable ?? false,
      drakarVersion: host?.facts?.drakar,
      claudeVersion: host?.facts?.claude.first?.version,
      lastError: host?.failure?.message)
  }
}

/// What the session hosts list, as one read of them: nil for a listing that never came, which
/// says nothing of what a host holds.
@MainActor struct HostListings {
  /// The host a listing is kept for: this Mac's, or the runner by its id, so a listing of one
  /// runner never stands for another set up since.
  enum Key: Hashable {
    case thisMac
    case runner(String)
  }

  struct Runner {
    var id: String
    var name: String?
    var held: [HeldProcess]?
  }

  /// This Mac's host; empty when it is not up, which a read never starts.
  var local: [HeldProcess]?
  /// The runner set up, if any. Asked only while connected, so a read never waits on ssh: not
  /// connected is a listing that did not come.
  var runner: Runner?

  static func now() async -> HostListings {
    let local = await SessionHost.shared.listedIfRunning()
    guard let host = SessionHost.runner, let id = host.runnerID else {
      return HostListings(local: local)
    }
    let held = host.isAvailable ? await host.listed() : nil
    return HostListings(local: local, runner: Runner(id: id, name: host.runnerName, held: held))
  }
}
