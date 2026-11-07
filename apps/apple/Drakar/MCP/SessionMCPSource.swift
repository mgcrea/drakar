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
  /// The runner set up now; tests give their own.
  @MainActor var runnerHost: () -> SessionHost? = { SessionHost.runner }
  /// How a project's window is opened when none is (`MCPWindows`), nil before any window has
  /// handed the scene's action over; tests give their own.
  @MainActor var openWindow: () -> ((WindowRoute) -> Void)? = { MCPWindows.openWindow }

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

  // MARK: - Writes

  func start(_ request: StartRequest) async throws -> String {
    try await startOnMain(request)
  }

  func send(to id: String, text: String) async throws -> SendOutcome {
    try await sendOnMain(to: id, text: text)
  }

  func interrupt(_ id: String) async throws {
    try await interruptOnMain(id)
  }

  func end(_ id: String) async throws {
    try await endOnMain(id)
  }

  func answer(_ id: String, requestID: String, with decision: PermissionDecision) async throws {
    try await answerOnMain(id, requestID: requestID, with: decision)
  }

  func answer(_ id: String, requestID: String, with answer: ElicitationAnswer) async throws {
    try await answerOnMain(id, requestID: requestID, with: answer)
  }
}

// MARK: - Writes

// Each write is the call the window's own control makes (spec Anti-goals), on the main actor
// as the window makes it, and none takes the keyboard: no tab is selected for it, and a window
// it needs is found or opened through `MCPWindows`.
extension SessionMCPSource {
  /// How long a session started has to report its id.
  static let sessionIDLimit = Duration.seconds(30)

  /// A new session in the folder's project window, sent its first prompt: the window's own
  /// blank row when the window was opened for it, else a new tab it does not switch to.
  @MainActor private func startOnMain(_ request: StartRequest) async throws -> String {
    if !EntitlementMonitor.allowsWorkNow { throw SessionError(LockedComposerCard.refusal) }
    let route =
      try request.runner.map { try runnerRoute(request.folder, runner: $0) }
      ?? localRoute(request.folder)
    let wasOpen = openSessions.project(for: route) != nil
    let project = try await windowed(route)
    let agent: AgentKind? = request.agent.map { $0 == .codex ? .codex : .claude }
    let blank = wasOpen ? nil : project.blankRow()
    let item =
      blank.flatMap { agent == nil || $0.session.agent == agent ? $0 : nil }
      ?? project.newSession(agent: agent, select: false)
    guard item.session.canSend else { throw SessionError(sendRefusal(item, in: project)) }
    if let model = request.model { item.session.setModel(model) }
    project.forAgent { item.session.send(request.prompt) }
    return try await sessionID(
      of: item, startedIn: route.folder?.path(percentEncoded: false) ?? request.folder)
  }

  /// This Mac's folder, `~` being this Mac's home; refused when it is not a folder here.
  @MainActor private func localRoute(_ folder: String) throws -> WindowRoute {
    let path = NSString(string: folder).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw SessionError("There is no folder at \(folder) on this Mac.")
    }
    return .project(URL(filePath: path, directoryHint: .isDirectory))
  }

  /// The runner's folder, `~` being the runner's home as New Session on Runner takes it;
  /// refused unless the runner named is the one set up, and connected.
  @MainActor private func runnerRoute(_ folder: String, runner name: String) throws
    -> WindowRoute
  {
    guard let settings = RunnerSettings.read(from: defaults),
      settings.displayName.caseInsensitiveCompare(name) == .orderedSame
    else {
      throw SessionError("No runner named \(name) is set up.")
    }
    let id = settings.id.uuidString
    let host = runnerHost()
    guard let host, host.reaches(runner: id), host.isAvailable else {
      throw SessionError("\(settings.displayName) can't be reached: \(Self.reason(host)).")
    }
    guard let path = NewRunnerSession.path(from: folder, home: host.facts?.home) else {
      throw SessionError("\(folder) names no folder on \(settings.displayName).")
    }
    return .project(URL(filePath: path, directoryHint: .isDirectory), runner: id)
  }

  /// Why a runner is out of reach, as its last failure says, without a closing period.
  @MainActor private static func reason(_ host: SessionHost?) -> String {
    let message = host?.failure?.message.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return message.flatMap { $0.isEmpty ? nil : $0 } ?? "it isn't connected"
  }

  /// The project `route` names, its window opened behind the others when none is.
  @MainActor private func windowed(_ route: WindowRoute) async throws -> Project {
    try await MCPWindows.project(for: route, in: openSessions, opening: openWindow()).get()
  }

  /// `item`'s session id once it has one; refused when its start failed, or once
  /// `sessionIDLimit` has gone by.
  @MainActor private func sessionID(of item: ProjectSession, startedIn folder: String)
    async throws -> String
  {
    let deadline = ContinuousClock.now + Self.sessionIDLimit
    while true {
      if let id = item.sessionID { return id }
      switch item.session.phase {
      case .failed(let reason):
        throw SessionError("The session in \(folder) could not start: \(reason)")
      case .exited:
        throw SessionError("The session in \(folder) ended before it had a session id.")
      case .idle, .starting, .ready: break
      }
      guard ContinuousClock.now < deadline else { break }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        break
      }
    }
    throw SessionError(
      "Started in \(folder), but it has no session id yet. drakar_list_sessions will show it "
        + "once it does.")
  }

  /// Sent as the composer sends: now when the session can take a prompt, queued behind a
  /// running turn. A session in the background is taken back into its window first, and an
  /// ended one resumed there.
  @MainActor private func sendOnMain(to id: String, text: String) async throws -> SendOutcome {
    let (project, item) = try await target(of: id, resumingEnded: true)
    let session = item.session
    // As showing its tab reads it, before the composer could send.
    if !session.hasLoadedHistory { await session.loadHistory() }
    let outcome: SendOutcome
    if session.canSend {
      outcome = .sent
    } else if session.canQueue {
      outcome = .queued
    } else {
      throw SessionError(sendRefusal(item, in: project))
    }
    Self.send(text, to: item, in: project)
    return outcome
  }

  /// As the composer sends: a watched row becomes one of the window's own first. Not async,
  /// so that it is the window's `takeOver`, not the handoff's of the same name.
  @MainActor private static func send(_ text: String, to item: ProjectSession, in project: Project)
  {
    project.takeOver(item)
    project.forAgent { item.session.send(text) }
  }

  /// Escape: the running turn ends, and what was queued behind it runs next.
  @MainActor private func interruptOnMain(_ id: String) async throws {
    // A background process this Mac's registry says is idle is not taken back for nothing.
    let (project, item) = try await target(of: id, resumingEnded: false) { row in
      if row.runner == nil, row.state == .idle {
        throw SessionError("\(row.title ?? row.id) has no turn running.")
      }
    }
    if let refusal = heldRefusal(item, in: project) { throw SessionError(refusal) }
    let session = item.session
    let title = Self.shownTitle(of: item)
    // Nothing would reach the process until the connection is back.
    if session.isReconnecting { throw Self.reconnecting(title) }
    guard session.status.isRunning, session.isProcessRunning else {
      throw SessionError("\(title) has no turn running.")
    }
    session.interrupt(keepingQueued: true)
  }

  /// End Session: the process stops, the row stays.
  @MainActor private func endOnMain(_ id: String) async throws {
    let (project, item) = try await target(of: id, resumingEnded: false)
    if let refusal = heldRefusal(item, in: project) { throw SessionError(refusal) }
    project.end(item)
  }

  @MainActor private func answerOnMain(
    _ id: String, requestID: String, with decision: PermissionDecision
  ) async throws {
    let (project, session) = try await answering(id, requestID: requestID)
    // Read again now: the person may have answered it since it was listed.
    guard
      let pending = session.status.pendingPermissions.first(where: {
        $0.requestID == requestID
      })
    else { throw SessionError.noLongerWaiting(requestID) }
    project.forAgent { session.answer(pending, decision) }
  }

  @MainActor private func answerOnMain(
    _ id: String, requestID: String, with answer: ElicitationAnswer
  ) async throws {
    let (project, session) = try await answering(id, requestID: requestID)
    guard
      let pending = session.status.pendingElicitations.first(where: {
        $0.requestID == requestID
      })
    else { throw SessionError.noLongerWaiting(requestID) }
    project.forAgent { session.answer(pending, answer) }
  }

  /// The window's session a request is answered in. Only a window's session has requests to
  /// answer; one reconnecting keeps them waiting, as its panel does.
  @MainActor private func answering(_ id: String, requestID: String) async throws
    -> (Project, AgentSession)
  {
    guard case .window(let project, let item, _) = await find(id) else {
      throw SessionError.noLongerWaiting(requestID)
    }
    if item.session.isReconnecting { throw Self.reconnecting(Self.shownTitle(of: item)) }
    // With no process, an answer would reach nobody.
    guard item.session.isProcessRunning else { throw SessionError.noLongerWaiting(requestID) }
    return (project, item.session)
  }

  /// The window row a write acts on: a window's as it is; one in the background taken back
  /// into its project's window first, as Home's rows take one back; with `resumingEnded`, an
  /// ended one opened in its project's window to be resumed, as Home's "open" does. One live
  /// in another process is refused, as is one ended for anything but a message. `vetting`
  /// may refuse a background row before it is taken back.
  @MainActor private func target(
    of id: String, resumingEnded: Bool, vetting: (SessionRow) throws -> Void = { _ in }
  ) async throws -> (Project, ProjectSession) {
    switch await find(id) {
    case .window(let project, let item, _):
      return (project, item)
    case .background(let background):
      try vetting(background.row)
      return try await takeBack(background)
    case .monitored(let summary, let row):
      let title = row.title ?? id
      // An ended session is listed elsewhere too: ended is read first.
      guard row.state == .ended else {
        throw SessionError(
          "\(title) runs in \(row.heldBy ?? "another app"); Drakar only follows it.")
      }
      guard resumingEnded else {
        throw SessionError("\(title) has ended. drakar_send_message resumes it.")
      }
      return try await resume(summary, row: row)
    case nil:
      throw SessionError("No session \(id). drakar_list_sessions lists them.")
    }
  }

  /// An ended session opened in its project's window as one of its tabs, not shown.
  @MainActor private func resume(_ summary: SessionSummary, row: SessionRow) async throws
    -> (Project, ProjectSession)
  {
    let refusal = SessionError(
      "\(row.title ?? row.id) can't be resumed: its transcript names no folder.")
    guard !row.folder.isEmpty else { throw refusal }
    let project = try await windowed(
      .project(URL(filePath: row.folder, directoryHint: .isDirectory)))
    guard let item = project.openEnded(summary, focusingComposer: false, showing: false) else {
      throw refusal
    }
    return (project, item)
  }

  /// A process the session host holds with no window, taken back into its project's window
  /// as Home's runner rows take one back (`RunnerSection.open`), the tab shown staying.
  @MainActor private func takeBack(_ background: Background) async throws
    -> (Project, ProjectSession)
  {
    let row = background.row
    let title = row.title ?? row.id
    if row.state == .unreachable {
      throw SessionError(
        "\(title) is on \(row.runner ?? "the runner"), which can't be reached: "
          + "\(Self.reason(runnerHost())).")
    }
    let project = try await windowed(
      .project(
        URL(filePath: background.meta.windowFolder, directoryHint: .isDirectory),
        runner: background.runnerID))
    let listings = await listHosts()
    let held =
      background.runnerID == nil
      ? listings.local
      : listings.runner.flatMap { $0.id == background.runnerID ? $0.held : nil }
    guard let held else {
      throw SessionError("\(title)'s session host did not answer. Try again in a moment.")
    }
    await project.reopen(background.hostID, among: held, showing: false)
    // A window just opened takes back what it may by itself (`takeBackHeld`), and `reopen`
    // leaves the process to it: the row comes once that is done.
    let deadline = ContinuousClock.now + MCPWindows.registrationLimit
    while true {
      if let item = project.sessions.first(where: {
        $0.session.hostID == background.hostID || (!$0.isWatching && $0.sessionID == row.id)
      }) {
        return (project, item)
      }
      guard ContinuousClock.now < deadline else { break }
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        break
      }
    }
    throw SessionError("\(title) could not be taken back from the background. Try again.")
  }

  /// Why `item` takes no message now, in the order the composer's place says it.
  @MainActor private func sendRefusal(_ item: ProjectSession, in project: Project) -> String {
    if let held = heldRefusal(item, in: project) { return held }
    let session = item.session
    let title = Self.shownTitle(of: item)
    if session.isReconnecting { return Self.reconnecting(title).message }
    if let gone = session.goneOnRunnerText { return gone }
    if session.isOutOfReach {
      return "\(title) can't be reached: its process runs on where this Mac can't send to it."
    }
    if !EntitlementMonitor.allowsWorkNow { return LockedComposerCard.refusal }
    if session.isMoving { return "\(title) is moving to another account. Try again once it has." }
    if session.waitsForHost || session.phase == .starting {
      return "\(title) is starting. Try again in a moment."
    }
    return "\(title) can't take a message now."
  }

  /// Why nothing is sent to `item` from here: another Drakar holds its process, or another
  /// app runs it and this window only follows it. Nil for a row of the window's own.
  @MainActor private func heldRefusal(_ item: ProjectSession, in project: Project) -> String? {
    let row = windowRow(item, in: project, summary: item.sessionID.flatMap { summariesByID()[$0] })
    guard row.readOnly else { return nil }
    let title = Self.shownTitle(of: item)
    let holder = row.heldBy ?? "another app"
    if item.session.heldElsewhere != nil {
      return "\(title) is held by \(holder); send it from there."
    }
    return "\(title) runs in \(holder); Drakar only follows it."
  }

  @MainActor private static func reconnecting(_ title: String) -> SessionError {
    SessionError("\(title) is reconnecting to its session host. Try again in a moment.")
  }

  @MainActor private static func shownTitle(of item: ProjectSession) -> String {
    item.knownTitle ?? item.sessionID ?? "This session"
  }
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
    let hosts: [(processes: [HeldProcess], runner: String?, runnerID: String?, unreachable: Bool)] =
      [
        (held.local, nil, nil, false),
        (held.runner, held.runnerName, held.runnerID, held.runnerUnreachable),
      ]
    for (processes, runner, runnerID, unreachable) in hosts {
      var rows = Self.backgroundRows(
        processes, runner: runner, live: monitor.liveSessions, excluding: listed,
        summary: { summaries[$0] }, accountModel: { [monitor] in monitor.accountModel(for: $0) })
      for index in rows.indices {
        rows[index].runnerID = runnerID
        // Kept from before the connection dropped: nothing can be sent to them until it is
        // back.
        if unreachable { rows[index].row.state = .unreachable }
      }
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
  /// asked only when it runs, the runner's only while connected. `runnerUnreachable`: the
  /// runner is not connected, and what it holds is as last listed.
  @MainActor private func heldProcesses() async -> (
    local: [HeldProcess], runner: [HeldProcess], runnerName: String?, runnerID: String?,
    runnerUnreachable: Bool
  ) {
    let listings = await listHosts()
    let local = held(listings.local, by: .thisMac)
    guard let runner = listings.runner else { return (local, [], nil, nil, false) }
    return (
      local, held(runner.held, by: .runner(runner.id)), runner.name, runner.id,
      !runner.isConnected
    )
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
    /// Nil for a listing that did not come, as while not connected.
    var held: [HeldProcess]?
    var isConnected = true
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
    return HostListings(
      local: local,
      runner: Runner(id: id, name: host.runnerName, held: held, isConnected: host.isAvailable))
  }
}
