import DrakarKit
import Foundation
import Observation

/// One session as a project window holds it: the session, and what the window keeps for it
/// while another is shown.
@Observable
final class ProjectSession: Identifiable {
  let id = UUID()
  let session: ClaudeSession
  /// The composer's text, kept across switches.
  var draft = ""
  /// A turn ended, or the process stopped, while another session was shown.
  var isUnread = false
  /// The entry at the top of the transcript when it was last shown; nil while it followed
  /// the bottom.
  var scrollAnchor: String?
  /// The transcript's summary, read at restore and kept current as the file changes: a row
  /// not shown yet has its title and gauge without its whole history being read, and every
  /// row its last activity.
  var preview: SessionSummary?
  /// Opened from Elsewhere or Ended to look at: listed there, not with the window's own rows,
  /// and not kept between launches, until it is taken over.
  var isWatching = false
  /// The message id of the ask the person dismissed: that one stays quiet, the next one
  /// does not.
  var dismissedAsk: String?
  /// `ClosingAsk.detect` of the newest closing text, kept until the text changes: a row
  /// asks on every draw, and a reply can be long.
  @ObservationIgnored private var detected: (key: String, ask: ClosingAsk?)?

  init(session: ClaudeSession) {
    self.session = session
  }

  var sessionID: String? { session.sessionID }

  /// What stands for the history until it is read.
  private var unloadedPreview: SessionSummary? { session.hasLoadedHistory ? nil : preview }

  var displayTitle: String {
    if let title = session.title { return title }
    for entry in session.transcript.entries {
      if case .prompt(let text) = entry.kind { return String(text.prefix(80)) }
    }
    if let preview = unloadedPreview, let title = preview.title ?? preview.lastPrompt {
      return String(title.prefix(80))
    }
    return String(localized: "New session")
  }

  /// What the first waiting permission request wants: "Bash: make test".
  var waitingFor: String? {
    guard let pending = session.transcript.pendingPermissions.first else { return nil }
    let name = pending.request.displayName ?? pending.request.toolName
    let summary = pending.request.summary
    return summary.isEmpty ? name : "\(name): \(summary)"
  }

  /// How much this session wants the person, from the most urgent thing it waits on.
  var urgency: Urgency? {
    if let pending = session.transcript.pendingPermissions.first {
      return pending.request.isChoice ? .choice : .permission
    }
    switch closingAsk?.kind {
    case .question: return .question
    case .offer: return .offer
    case nil: return nil
    }
  }

  /// What it wants, for the row's second line and the notification.
  var wants: String? {
    if let pending = session.transcript.pendingPermissions.first, pending.request.isChoice {
      return UserQuestion.list(pending.request.input).first?.question ?? waitingFor
    }
    return waitingFor ?? closingAsk?.text
  }

  /// The question or offer the newest turn ended on, while it waits: nil once a prompt
  /// went, after Dismiss, once the process ended, and for a row held read-only.
  var closingAsk: ClosingAsk? { asked?.ask }

  /// Quiets `closingAsk` until a newer one.
  func dismissAsk() {
    dismissedAsk = asked?.messageID
  }

  private var asked: (messageID: String, ask: ClosingAsk)? {
    guard AttentionChoice.recognisesAsks, !session.isReadOnly else { return nil }
    switch session.phase {
    case .exited, .failed: return nil
    case .idle, .starting, .ready: break
    }
    let found: (messageID: String, ask: ClosingAsk)?
    // The file's summary stands in only while nothing is in memory: a session started here
    // has no history to read, and the summary of its file lags the live turn.
    if session.transcript.entries.isEmpty, let preview {
      found = preview.closingMessageID.flatMap { id in preview.closingAsk.map { (id, $0) } }
    } else if let closing = session.transcript.closingText {
      found = detect(closing).map { (closing.messageID, $0) }
    } else {
      found = nil
    }
    guard let found, found.messageID != dismissedAsk else { return nil }
    return found
  }

  private func detect(_ closing: ClosingText) -> ClosingAsk? {
    let key = "\(closing.messageID)#\(closing.text.utf8.count)"
    if let detected, detected.key == key { return detected.ask }
    let ask = ClosingAsk.detect(closing.text)
    detected = (key, ask)
    return ask
  }

  /// The gauge from what this session knows: its process's report, its own model, the
  /// account's, the newest message's.
  func gauge(accountModel: String?) -> ContextGauge? {
    let transcript = session.transcript
    if transcript.contextUsage == nil, let preview = unloadedPreview {
      return ContextGauge.make(
        usage: preview.context?.usage, reportedLimit: nil, initModelID: nil,
        attachmentModelID: preview.modelID, accountModelID: accountModel,
        messageModelID: preview.context?.modelID)
    }
    return ContextGauge.make(
      usage: transcript.contextUsage, reportedLimit: session.reportedContext?.maxTokens,
      initModelID: transcript.session?.model, attachmentModelID: nil,
      accountModelID: accountModel, messageModelID: transcript.contextModelID)
  }

  /// When the transcript was last written: the session's last activity, from the file.
  var lastActivity: Date? { preview?.modified }

  /// Why the row stopped, for its second line: the failure, or "Stopped, exit 1".
  var stopReason: String? {
    switch session.phase {
    case .failed(let reason): reason
    case .exited(let status) where status != 0: String(localized: "Stopped, exit \(status)")
    case .idle, .starting, .ready, .exited: nil
    }
  }

  var hasStopped: Bool {
    switch session.phase {
    case .failed: true
    case .exited(let status): status != 0
    case .idle, .starting, .ready: false
    }
  }
}

/// What a project window keeps between launches: the sessions it held, and the one shown.
struct StoredProject: Codable, Equatable {
  var sessions: [ResumeTarget] = []
  var selected: String?
  /// Per session id, the message id of the ask dismissed. Optional so that a window stored
  /// before the field existed still decodes.
  var dismissedQuestions: [String: String]?
}

/// Each project's `StoredProject`, app-wide in `UserDefaults` by folder. A window's scene
/// storage comes back only when macOS restores windows at launch, which quitting closes by
/// default: without this, a window opened after a relaunch lost its sessions to Ended.
/// Removing a row from the window is what lets it go.
enum ProjectMemory {
  static let key = "drakar.projectSessions"

  static func stored(for folder: URL, in defaults: UserDefaults = .standard) -> StoredProject? {
    all(in: defaults)[path(of: folder)]
  }

  static func remember(
    _ stored: StoredProject, for folder: URL, in defaults: UserDefaults = .standard
  ) {
    var all = all(in: defaults)
    all[path(of: folder)] = stored.sessions.isEmpty ? nil : stored
    defaults.set(try? JSONEncoder().encode(all), forKey: key)
  }

  private static func all(in defaults: UserDefaults) -> [String: StoredProject] {
    defaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode([String: StoredProject].self, from: $0)
    } ?? [:]
  }

  private static func path(of folder: URL) -> String {
    ProjectPath.normalize(folder.path(percentEncoded: false))
  }
}

/// A project window: a folder, its editor, and the sessions attached to it.
@Observable
final class Project {
  let folder: URL
  let workspace: Workspace
  private(set) var sessions: [ProjectSession] = []
  var selectedID: ProjectSession.ID?
  /// Whether the shown session's composer takes the focus when it appears: not when the
  /// sidebar's arrow keys or a click there chose it, so the keys keep moving in the list.
  @ObservationIgnored private(set) var focusesComposer = true

  init(folder: URL, restoring stored: StoredProject? = nil) {
    self.folder = folder
    workspace = Workspace(folder: folder)
    for target in stored?.sessions ?? [] {
      guard !sessions.contains(where: { $0.sessionID == target.sessionID }) else { continue }
      let folder = URL(filePath: target.cwd, directoryHint: .isDirectory)
      let item = make(ClaudeSession(folder: folder, resuming: target))
      item.dismissedAsk = stored?.dismissedQuestions?[target.sessionID]
      sessions.append(item)
    }
    selectedID =
      sessions.first { $0.sessionID == stored?.selected }?.id ?? sessions.first?.id
    if let selected { load(selected) }
    for item in sessions { readPreview(item) }
  }

  var selected: ProjectSession? { sessions.first { $0.id == selectedID } }

  func session(withID sessionID: String) -> ProjectSession? {
    sessions.first { $0.sessionID == sessionID }
  }

  /// A new session in the project's folder, on top and shown. No process until it is
  /// prompted.
  @discardableResult func newSession() -> ProjectSession {
    let item = make(ClaudeSession(folder: folder))
    sessions.insert(item, at: 0)
    select(item)
    return item
  }

  /// `target` on top and shown, or the row already holding it, taken over unless
  /// `watching`. `readOnly` while another process has it open.
  @discardableResult func attach(
    _ target: ResumeTarget, watching: Bool = false, readOnly: Bool = false
  ) -> ProjectSession {
    if target.forks != true, let existing = session(withID: target.sessionID) {
      if !watching { takeOver(existing) }
      select(existing)
      return existing
    }
    let session = ClaudeSession(
      folder: URL(filePath: target.cwd, directoryHint: .isDirectory), resuming: target)
    session.isReadOnly = readOnly
    let item = make(session)
    item.isWatching = watching
    sessions.insert(item, at: 0)
    select(item)
    return item
  }

  /// A watched row becomes one of the window's own, on top: it was prompted, or attached.
  func takeOver(_ item: ProjectSession) {
    guard item.isWatching else { return }
    item.isWatching = false
    sessions.removeAll { $0.id == item.id }
    sessions.insert(item, at: 0)
  }

  /// A copy of a session open elsewhere, continued under a new id beside it.
  @discardableResult func fork(_ item: ProjectSession) -> ProjectSession {
    guard var target = item.session.resuming ?? item.session.savedTarget else { return item }
    target.forks = true
    return attach(target)
  }

  func select(_ item: ProjectSession, focusingComposer: Bool = true) {
    focusesComposer = focusingComposer
    selectedID = item.id
    item.isUnread = false
    load(item)
    Attention.shared.refresh()
  }

  /// The next row after the selected one that wants the person: the most urgent level that
  /// counts first, then unread, wrapping. Never the selected row.
  func nextNeedingAttention() -> ProjectSession? {
    let start = sessions.firstIndex { $0.id == selectedID } ?? -1
    let ordered = sessions[(start + 1)...] + sessions[..<max(start, 0)]
    for level in Urgency.allCases.reversed() where AttentionChoice.isOn(level, .counts) {
      if let item = ordered.first(where: { $0.urgency == level }) { return item }
    }
    return ordered.first { $0.isUnread }
  }

  /// Quiets the row's question or offer until it asks another.
  func dismissAsk(_ item: ProjectSession) {
    item.dismissAsk()
    Attention.shared.refresh()
  }

  /// Stops the process; the row stays, and its next prompt resumes it.
  func end(_ item: ProjectSession) {
    item.session.stop()
  }

  func remove(_ item: ProjectSession) {
    item.session.stop()
    sessions.removeAll { $0.id == item.id }
    if selectedID == item.id { selectedID = sessions.first?.id }
    if let selected { load(selected) }
    Attention.shared.refresh()
  }

  func stopAll() {
    for item in sessions { item.session.stop() }
  }

  /// Rows that want the person at a level that counts: the group's header.
  var waitingCount: Int {
    sessions.count { item in item.urgency.map { AttentionChoice.isOn($0, .counts) } ?? false }
  }

  /// Sessions mid-turn: what closing the window would interrupt.
  var runningCount: Int { sessions.count { $0.session.transcript.isRunning } }

  /// The window's own rows; a watched one is not kept.
  var held: [ProjectSession] { sessions.filter { !$0.isWatching } }

  var stored: StoredProject {
    let dismissed = held.compactMap { item -> (String, String)? in
      guard let id = item.sessionID, let message = item.dismissedAsk else { return nil }
      return (id, message)
    }
    return StoredProject(
      sessions: held.compactMap(\.session.savedTarget),
      selected: selected.flatMap { $0.isWatching ? nil : $0.session.savedTarget?.sessionID },
      dismissedQuestions: dismissed.isEmpty
        ? nil : Dictionary(dismissed, uniquingKeysWith: { first, _ in first }))
  }

  private func make(_ session: ClaudeSession) -> ProjectSession {
    let item = ProjectSession(session: session)
    session.onTurnEnded = { [weak self, weak item] in
      guard let self, let item else { return }
      if item.id != self.selectedID { item.isUnread = true }
      Attention.shared.turnEnded(item, in: self)
    }
    session.onPermissionRequested = { [weak self, weak item] _ in
      guard let self, let item else { return }
      Attention.shared.permissionRequested(item, in: self)
    }
    session.onPermissionsChanged = { [weak item] in Attention.shared.permissionsChanged(item) }
    session.onPromptSent = { Attention.shared.refresh() }
    session.onStopped = { [weak self, weak item] in
      Attention.shared.refresh()
      guard let self, let item, item.id != self.selectedID, item.hasStopped else { return }
      item.isUnread = true
    }
    return item
  }

  private func load(_ item: ProjectSession) {
    Task { await item.session.loadHistory() }
  }

  /// The title and context from the transcript's end, off the main thread: every restored
  /// row shows them, while only the selected one reads its history.
  private func readPreview(_ item: ProjectSession) {
    guard let target = item.session.resuming else { return }
    let (file, account) = (target.transcriptFile, target.account)
    Task { [weak item] in
      let summary = await Task.detached { SessionIndex.summary(of: file, account: account) }.value
      item?.preview = summary
      Attention.shared.refresh()
    }
  }
}
