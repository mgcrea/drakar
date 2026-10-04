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
}

/// A project window: a folder, its editor, and the sessions attached to it.
@Observable
final class Project {
  let folder: URL
  let workspace: Workspace
  private(set) var sessions: [ProjectSession] = []
  var selectedID: ProjectSession.ID?

  init(folder: URL, restoring stored: StoredProject? = nil) {
    self.folder = folder
    workspace = Workspace(folder: folder)
    for target in stored?.sessions ?? [] {
      guard !sessions.contains(where: { $0.sessionID == target.sessionID }) else { continue }
      let folder = URL(filePath: target.cwd, directoryHint: .isDirectory)
      sessions.append(make(ClaudeSession(folder: folder, resuming: target)))
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

  /// `target` on top and shown, or the row already holding it. `readOnly` while another
  /// process has it open.
  @discardableResult func attach(_ target: ResumeTarget, readOnly: Bool = false) -> ProjectSession {
    if target.forks != true, let existing = session(withID: target.sessionID) {
      select(existing)
      return existing
    }
    let session = ClaudeSession(
      folder: URL(filePath: target.cwd, directoryHint: .isDirectory), resuming: target)
    session.isReadOnly = readOnly
    let item = make(session)
    sessions.insert(item, at: 0)
    select(item)
    return item
  }

  /// A copy of a session open elsewhere, continued under a new id beside it.
  @discardableResult func fork(_ item: ProjectSession) -> ProjectSession {
    guard var target = item.session.resuming ?? item.session.savedTarget else { return item }
    target.forks = true
    return attach(target)
  }

  func select(_ item: ProjectSession) {
    selectedID = item.id
    item.isUnread = false
    load(item)
    Attention.shared.refresh()
  }

  /// The next row after the selected one that wants the person: waiting on a permission
  /// first, then unread, wrapping. Never the selected row.
  func nextNeedingAttention() -> ProjectSession? {
    let start = sessions.firstIndex { $0.id == selectedID } ?? -1
    let ordered = sessions[(start + 1)...] + sessions[..<max(start, 0)]
    return ordered.first { $0.waitingFor != nil } ?? ordered.first { $0.isUnread }
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

  /// Rows waiting on a permission request, for the group's header.
  var waitingCount: Int { sessions.count { $0.waitingFor != nil } }

  /// Sessions mid-turn: what closing the window would interrupt.
  var runningCount: Int { sessions.count { $0.session.transcript.isRunning } }

  var stored: StoredProject {
    StoredProject(
      sessions: sessions.compactMap(\.session.savedTarget),
      selected: selected?.session.savedTarget?.sessionID)
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
    session.onStopped = { [weak self, weak item] in
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
    }
  }
}
