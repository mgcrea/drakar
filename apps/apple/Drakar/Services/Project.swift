import AppKit
import DrakarKit
import Foundation
import Observation

/// A skill put in the composer rather than sent: the text it put there, and what it takes.
struct SkillPrefill: Equatable {
  var text: String
  var hint: String
}

/// Where the inspector runs a skill.
enum SkillTarget {
  case newSession
  case current
}

/// A skill run in each of several folders: its sessions, and what is left to send them
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md).
@Observable
final class FanOutBatch: Identifiable {
  /// What its sessions' metas name it by, and what a stored window names it by.
  let id: UUID
  let skillName: String
  let prompt: String
  let agent: AgentKind
  let limit: Int?
  var queue: FanOut<UUID>
  /// What each of `queue.ids` was started with, in their order: what a window stored later
  /// rebuilds a session that never started from, and names one closed since by.
  let plan: [StoredFanOut.Entry]

  init(
    id: UUID = UUID(), skillName: String, prompt: String, agent: AgentKind = .claude,
    limit: Int?, plan: [StoredFanOut.Entry], queue: FanOut<UUID>
  ) {
    self.id = id
    self.skillName = skillName
    self.prompt = prompt
    self.agent = agent
    self.limit = limit
    self.plan = plan
    self.queue = queue
  }
}

/// A batch as a window stores it (spec §3 Fan-out batches): enough to carry on sending after
/// a relaunch, to the rows the session host still holds and to the sessions that never
/// started.
struct StoredFanOut: Codable, Equatable {
  struct Entry: Codable, Equatable {
    var folder: String
    var name: String
    var accountDirectory: String?
    var accountIsDefault: Bool?
    var mode: PermissionMode?
    var state: FanOut<UUID>.State
    /// The session host's id for its process, once the spawn was answered; the entry's mark
    /// in the process's meta finds it before.
    var hostID: String?
  }
  var batch: UUID
  var skillName: String
  var prompt: String
  var limit: Int?
  var entries: [Entry]
  /// Nil for Claude Code's, which older stored batches never named.
  var agent: AgentKind?
}

/// What one prompt to the marked sessions did: how many took it, and how many could not.
struct BroadcastResult: Equatable {
  var sent: Int
  var skipped: Int
}

/// What closing a tab would lose, the one case it asks about (session tabs spec, Closing).
enum CloseAsk: Equatable {
  /// Text or attachments in its composer, never sent.
  case unsentDraft
  /// A session at work, its turn running or waiting on the person, as the app's own child:
  /// there is no session host to hand it to.
  case stopsTurn
}

/// The Run in Each Subfolder sheet, on a skill, or with none yet to pick one.
struct FanOutRequest: Identifiable {
  let id = UUID()
  var skill: SkillEntry?
}

/// One session as a project window holds it: the session, and what the window keeps for it
/// while another is shown.
@Observable
final class ProjectSession: Identifiable {
  let id = UUID()
  let session: AgentSession
  /// The composer's text, kept across switches.
  var draft = ""
  /// The images and files going with the next prompt, kept as the draft is.
  var attachments: [Attachment] = []
  /// Why the last things offered were not all attached, until the next are.
  var attachmentNote: String?
  /// The skill the inspector put in the draft, while it waits for its arguments.
  var prefill: SkillPrefill?
  /// Bumped to ask the composer for the focus.
  var focusRequest = 0
  /// Bumped to ask the question card in the transcript for the focus.
  var questionFocusRequest = 0

  /// Reads `sources` into attachments, off the main thread, and says what could not be.
  func attach(_ sources: [AttachmentSource]) {
    guard !sources.isEmpty else { return }
    Task {
      var (attachments, notes) = await AttachmentIntake.load(sources)
      if !session.features.acceptsPDF {
        let refused = attachments.filter { $0.kind == .pdf }
        attachments.removeAll { $0.kind == .pdf }
        notes += refused.map {
          String(
            localized: "\(session.features.name) can't read PDFs here: \($0.preview.name ?? "PDF")")
        }
      }
      self.attachments += attachments
      attachmentNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
      focusRequest += 1
    }
  }

  /// What the prefilled skill takes, while the draft still starts with its name.
  var composerHint: String? {
    guard let prefill, draft.hasPrefix(prefill.text) else { return nil }
    return prefill.hint
  }
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

  init(session: AgentSession) {
    self.session = session
  }

  var sessionID: String? { session.sessionID }

  /// What stands for the history until it is read.
  private var unloadedPreview: SessionSummary? { session.hasLoadedHistory ? nil : preview }

  var displayTitle: String { knownTitle ?? String(localized: "New session") }

  /// The name, title or first prompt; nil before there is any, where the row says "New
  /// session".
  var knownTitle: String? {
    if let title = session.title { return title }
    if let prompt = session.status.firstPrompt { return prompt }
    if let preview = unloadedPreview, let title = preview.title ?? preview.lastPrompt {
      return String(title.prefix(80))
    }
    return nil
  }

  /// The first MCP server's question waiting on the person.
  var pendingElicitation: Transcript.PendingElicitation? {
    session.status.pendingElicitations.first
  }

  /// What the first waiting permission request wants, "Bash: make test", else what the
  /// first waiting question asks, "linear: Which team?".
  var waitingFor: String? {
    if let pending = session.status.pendingPermissions.first {
      let name = pending.request.displayName ?? pending.request.toolName
      let summary = pending.request.summary
      return summary.isEmpty ? name : "\(name): \(summary)"
    }
    guard let elicitation = pendingElicitation?.elicitation else { return nil }
    let server =
      elicitation.serverLabel.isEmpty
      ? String(localized: "An MCP server") : elicitation.serverLabel
    let message = elicitation.message
    return message.isEmpty ? server : "\(server): \(message)"
  }

  /// How much this session wants the person, from the most urgent thing it waits on. A
  /// question blocks its tool mid-turn as a permission does, so beside a plan or a choice it
  /// is the question's level that shows.
  var urgency: Urgency? {
    let permission = session.status.pendingPermissions.first.map { pending in
      pending.request.isChoice || pending.request.isPlan ? Urgency.choice : .permission
    }
    let question: Urgency? = pendingElicitation == nil ? nil : .permission
    if let waiting = [permission, question].compactMap(\.self).max() { return waiting }
    switch closingAsk?.kind {
    case .question: return .question
    case .offer: return .offer
    case nil: return nil
    }
  }

  /// What it wants, for the row's second line and the notification.
  var wants: String? {
    if let pending = session.status.pendingPermissions.first, pending.request.isChoice {
      return UserQuestion.list(pending.request.input).first?.question ?? waitingFor
    }
    if let pending = session.status.pendingPermissions.first, pending.request.isPlan {
      return String(localized: "Claude has finished a plan and is waiting for your review.")
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
    if !session.status.hasEntries, let preview {
      found = preview.closingMessageID.flatMap { id in preview.closingAsk.map { (id, $0) } }
    } else if let closing = session.status.closingText {
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
    let status = session.status
    if status.contextUsage == nil, let preview = unloadedPreview {
      return ContextGauge.make(
        usage: preview.context?.usage, reportedLimit: nil, initModelID: nil,
        attachmentModelID: preview.modelID, accountModelID: accountModel,
        messageModelID: preview.context?.modelID)
    }
    return ContextGauge.make(
      usage: status.contextUsage, reportedLimit: session.reportedContext?.maxTokens,
      initModelID: status.session?.model, attachmentModelID: nil,
      accountModelID: accountModel, messageModelID: status.contextModelID)
  }

  /// When a Codex session's rollout file was last written, as of the last read: a Codex
  /// row has no `preview`, which only Claude's transcripts give.
  var rolloutModified: Date?

  /// When the transcript was last written: the session's last activity, from the file.
  var lastActivity: Date? { preview?.modified ?? rolloutModified }

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

/// The pane of a project window the keys go to.
enum FocusedPane: String, Codable {
  case composer, editor, sessions
}

/// What a project window keeps between launches: the sessions it held and the one shown,
/// the editor's tabs and the active one, and the pane the keys were in.
struct StoredProject: Codable, Equatable {
  var sessions: [ResumeTarget] = []
  var selected: String?
  /// Per session id, the message id of the ask dismissed. Optional so that a window stored
  /// before the field existed still decodes.
  var dismissedQuestions: [String: String]?
  /// The open tabs' paths, in order. Optional for the same reason.
  var documents: [String]?
  var activeDocument: String?
  var focusedPane: FocusedPane?
  /// How the sidebar sorts; nil for `.opened`, and for a window stored before sorting.
  var sessionOrder: SessionOrder?
  /// Next After Replying; nil for off.
  var movesOnAfterReply: Bool?
  /// The batches still sending or running. Optional so that a window stored before they were
  /// kept still decodes.
  var fanOuts: [StoredFanOut]?
  /// Forks that ran no turn, so have no transcript of their own to resume. Optional so that a
  /// window stored before they were kept still decodes.
  var pendingForks: [StoredFork]?

  /// Nothing worth bringing back: no session, no tab, no batch, and no sort or switch chosen.
  var isEmpty: Bool {
    sessions.isEmpty && documents?.isEmpty != false && sessionOrder == nil
      && movesOnAfterReply == nil && fanOuts?.isEmpty != false
      && pendingForks?.isEmpty != false
  }
}

/// A fork not yet sent: what it forks and where, its name, and its composer's draft (a fork
/// from a prompt holds that prompt's text).
struct StoredFork: Codable, Equatable {
  var target: ResumeTarget
  var name: String?
  var draft: String
}

/// Each project's `StoredProject`, app-wide in `UserDefaults` by folder. A window's scene
/// storage comes back only when macOS restores windows at launch, which quitting closes by
/// default: without this, a window opened after a relaunch lost its sessions to Ended.
/// Removing a row from the window is what lets it go.
enum ProjectMemory {
  static let key = "drakar.projectSessions"

  /// `runner`: the runner the folder is on, nil for this Mac's.
  static func stored(
    for folder: URL, runner: String? = nil, in defaults: UserDefaults = .standard
  ) -> StoredProject? {
    all(in: defaults)[path(of: folder, runner: runner)]
  }

  static func remember(
    _ stored: StoredProject, for folder: URL, runner: String? = nil,
    in defaults: UserDefaults = .standard
  ) {
    var all = all(in: defaults)
    all[path(of: folder, runner: runner)] = stored.isEmpty ? nil : stored
    defaults.set(try? JSONEncoder().encode(all), forKey: key)
  }

  private static func all(in defaults: UserDefaults) -> [String: StoredProject] {
    defaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode([String: StoredProject].self, from: $0)
    } ?? [:]
  }

  /// A runner's folder under its runner's id, which no path of this Mac's starts with.
  private static func path(of folder: URL, runner: String?) -> String {
    let path = ProjectPath.normalize(folder)
    return runner.map { "\($0):\(path)" } ?? path
  }
}

/// A project window: a folder, its editor, and the sessions attached to it.
@Observable
final class Project {
  let folder: URL
  /// The runner the folder is on (`RunnerSettings.id`), nil for this Mac's. A runner's
  /// project is never the local one at the same path (remote sessions spec §4).
  let runner: String?
  let workspace: Workspace
  private(set) var sessions: [ProjectSession] = []
  var selectedID: ProjectSession.ID?
  /// How the sidebar lists Elsewhere. The tabs keep their own order, which only a drag changes.
  var sessionOrder: SessionOrder = .opened
  /// Next After Replying: a reply to the shown session shows the next one wanting the person.
  var movesOnAfterReply = false
  /// Per session live elsewhere, the message id of the ask dismissed, kept with the window's
  /// own in `StoredProject.dismissedQuestions`.
  private(set) var dismissedElsewhere: [String: String] = [:]
  /// Whether the shown session's composer takes the focus when it appears: not when the
  /// strip's or the sidebar's arrow keys chose it, so the keys stay where they are.
  @ObservationIgnored private(set) var focusesComposer = true
  /// While `broadcast` sends: a prompt to the marked rows doesn't move on.
  @ObservationIgnored private var isBroadcasting = false
  /// Stands in for the located binary in every session this window makes, in tests.
  @ObservationIgnored var executableOverride: URL?
  /// Where the sessions this window doesn't hold are listed from; tests give it their own.
  @ObservationIgnored var monitor = SessionMonitor.shared
  /// Where the window's sessions run and come back from: this Mac's host, or a runner
  /// project's runner's while it is the runner the project names, read each time rather
  /// than kept. None for a runner project whose runner is no longer the one set up: the
  /// window cannot reach it. Tests give their own.
  var sessionHost: SessionHost? {
    get {
      if let givenHost { return givenHost }
      guard let runner else { return .shared }
      return runnerHost().flatMap { $0.reaches(runner: runner) ? $0 : nil }
    }
    set { givenHost = newValue }
  }
  @ObservationIgnored private var givenHost: SessionHost?
  /// The runner set up now (`SessionHost.runner`); tests give their own.
  @ObservationIgnored var runnerHost: () -> SessionHost? = { SessionHost.runner }
  /// Says that a tab closed on a session taken over on its runner, and where; tests give
  /// their own.
  @ObservationIgnored var noticeTakenOver: (ProjectSession, String) -> Void = {
    Attention.shared.takenOver($0, on: $1)
  }
  /// The session host's processes being taken back, so that two calls take each once.
  @ObservationIgnored private var adopting: Set<String> = []
  /// The session host's ids for the processes another app holds that rows here showed
  /// read-only, which `released` or a new connection settles.
  @ObservationIgnored private var shownHeldElsewhere: Set<String> = []
  /// A runner's processes whose rows were closed here while this Mac still owned them and was
  /// reconnecting: such a one stays with its stale relay, and the host says `released` once
  /// that relay goes, as it does of a process brought back. Not taken then, for it was closed
  /// here; Home lists it, and opens it again (`reopen`).
  @ObservationIgnored private var closedHere: Set<String> = []
  /// The window's sessions whose tabs were closed at work, by session id, with the session
  /// host's id for each process (session tabs spec, After a tab at work is closed): listed
  /// under Elsewhere until the process ends, and opened from there by taking it back
  /// (`reopen`), never watched. Learnt when the tab closes, and from what a reopened window or
  /// a launch passes over (`adoptHeld`); dropped once the host lets the process go.
  private var closedAtWork: [String: String] = [:]
  /// A runner window's take-back found its runner out of reach (`takeBackHeld`): no listing
  /// came, which says nothing of what the runner holds for it. Taken back on the first new
  /// connection a listing comes on, as the take-back would have.
  @ObservationIgnored private var takeBackMissed = false
  /// The accounts a session rebuilt here, from a process the host holds, finds its picked
  /// account and its transcript in; tests give their own.
  @ObservationIgnored var accounts: () -> [ClaudeAccount] = { ClaudeAccount.discover() }
  /// The batches still sending or running, one banner each.
  private(set) var fanOuts: [FanOutBatch] = []
  /// The window closed or went home: nothing it takes back or restores starts after that.
  @ObservationIgnored private var isStopped = false
  /// The batches the window was stored with, until `takeBackHeld` has the rows they need.
  @ObservationIgnored private var storedFanOuts: [StoredFanOut] = []
  /// The Run in Each Subfolder sheet, while shown.
  var fanOutRequest: FanOutRequest?
  /// Rows marked with ⌘- or ⇧-click: the composer's prompt goes to each of them.
  private(set) var marked: Set<ProjectSession.ID> = []
  /// What the last prompt to the marked rows did, until the next click.
  private(set) var lastBroadcast: BroadcastResult?
  /// The last row clicked without ⇧: where a ⇧-click's range starts.
  @ObservationIgnored private var markAnchor: ProjectSession.ID?
  /// The lists the inspector shows: this folder's under the window's account.
  private(set) var capabilities: Capabilities
  /// What the lists brought since the inspector was last seen.
  private(set) var capabilityMarks = CapabilityMarks()
  /// How long file changes settle before the lists are read again; tests shorten it.
  @ObservationIgnored var capabilityDebounce: Duration = .seconds(2)
  @ObservationIgnored private var capabilityObserver: UUID?
  @ObservationIgnored private var capabilityRefresh: Task<Void, Never>?
  @ObservationIgnored private var codexSkillRefresh: Task<Void, Never>?
  /// Who hears the project's skill files change as it happens: the Skills window.
  @ObservationIgnored private var skillFileObservers: [UUID: () -> Void] = [:]
  /// The pane that had the keys at the last quit, until it takes them back.
  @ObservationIgnored private var restoredFocus: FocusedPane?

  init(folder: URL, runner: String? = nil, restoring stored: StoredProject? = nil) {
    self.folder = folder
    self.runner = runner
    // A runner's folder is none of this Mac's: no tree, watcher or editor read it here, and no
    // account of this Mac's lists it (remote sessions spec §4).
    workspace = Workspace(folder: folder, runner: runner)
    capabilities =
      runner == nil
      ? CapabilityStore.shared.capabilities(
        for: folder, account: AccountStore.shared.windowAccount(for: folder))
      : Capabilities.onRunner(folder: folder)
    for target in stored?.sessions ?? [] {
      guard !sessions.contains(where: { $0.sessionID == target.sessionID }) else { continue }
      let folder = URL(filePath: target.cwd, directoryHint: .isDirectory)
      let item = make(AgentSession(folder: folder, resuming: target))
      item.dismissedAsk = stored?.dismissedQuestions?[target.sessionID]
      sessions.append(item)
    }
    // Each its own row, though it shares its original's session id until its first turn.
    for fork in stored?.pendingForks ?? [] {
      let folder = URL(filePath: fork.target.cwd, directoryHint: .isDirectory)
      let session = AgentSession(folder: folder, resuming: fork.target)
      if let name = fork.name { session.rename(to: name) }
      let item = make(session)
      item.draft = fork.draft
      sessions.append(item)
    }
    // No fan-out runs on a runner's folder (remote sessions spec §4).
    storedFanOuts = runner == nil ? stored?.fanOuts ?? [] : []
    sessionOrder = stored?.sessionOrder ?? .opened
    movesOnAfterReply = stored?.movesOnAfterReply ?? false
    let own = Set(sessions.compactMap(\.sessionID))
    dismissedElsewhere = (stored?.dismissedQuestions ?? [:]).filter { !own.contains($0.key) }
    selectedID =
      sessions.first { $0.sessionID == stored?.selected }?.id ?? sessions.first?.id
    if let selected { load(selected) }
    for item in sessions { readPreview(item) }
    workspace.restore(
      stored?.documents ?? [], active: stored?.activeDocument, focus: stored?.focusedPane)
    // The editor's file may be gone since: the composer takes the keys rather than nobody.
    var focus = stored?.focusedPane ?? .composer
    if focus == .editor, workspace.documents.isEmpty { focus = .composer }
    focusesComposer = focus == .composer
    restoredFocus = focus
    observeCapabilities()
    workspace.onCapabilityFilesChanged = { [weak self] in self?.capabilityFilesChanged() }
    workspace.onCodexSkillFilesChanged = { [weak self] in self?.codexSkillFilesChanged() }
  }

  /// What to call a runner project's runner: its name as set up now, or that it is no longer
  /// set up. Nil for this Mac's.
  var runnerName: String? {
    runner.map { SessionHost.name(ofRunner: $0, on: runnerHost()) }
  }

  /// Whether `pane` is the one to take the keys back after a relaunch; true once.
  func claimsRestoredFocus(_ pane: FocusedPane) -> Bool {
    guard restoredFocus == pane else { return false }
    restoredFocus = nil
    return true
  }

  var selected: ProjectSession? { sessions.first { $0.id == selectedID } }

  func session(withID sessionID: String) -> ProjectSession? {
    sessions.first { $0.sessionID == sessionID }
  }

  /// The sessions below the window's own rows: live elsewhere, and ended. Kept until what
  /// it is made from changes: the sidebar, its badge, the menus and the window's storage
  /// each ask, and grouping looks at every session under the folder.
  var groups: ProjectGroups {
    let folder = ProjectPath.normalize(self.folder)
    let others = OpenSessions.shared.folders.filter { $0 != folder }
    let attached = Set(held.compactMap(\.sessionID))
    // A tab closed at work is elsewhere too, whether or not the registry was read since.
    let inOtherWindows = Set(
      OpenSessions.shared.projects.values.filter { $0 !== self }
        .flatMap { $0.held.compactMap(\.sessionID) }
    ).union(closedAtWork.keys)
    // Asked even when the groups are kept, so that a view reading them redraws on a change.
    // This Mac's transcripts are none of a runner's folder's.
    let summaries = runner == nil ? monitor.summaries(under: folder) : []
    let key = GroupsKey(
      generation: monitor.generation, others: others, attached: attached,
      inOtherWindows: inOtherWindows)
    if let keptGroups, keptGroups.key == key { return keptGroups.groups }
    let groups = ProjectSessions.group(
      summaries, folder: folder, otherFolders: others,
      attached: attached, inOtherWindows: inOtherWindows, checkout: monitor.checkout(of:))
    keptGroups = (key, groups)
    return groups
  }

  /// What `groups` is made from.
  private struct GroupsKey: Equatable {
    var generation: Int
    var others: [String]
    var attached: Set<String>
    var inOtherWindows: Set<String>
  }

  @ObservationIgnored private var keptGroups: (key: GroupsKey, groups: ProjectGroups)?

  /// `groups`, Elsewhere as the sidebar lists it.
  var listedGroups: ProjectGroups {
    var groups = groups
    groups.elsewhere = sessionOrder.sorted(groups.elsewhere) { summary in
      SessionOrder.Key(
        state: RowState(elsewhere: summary, urgency: urgency(of: summary)),
        activity: summary.live?.updatedAt ?? summary.modified, folder: summary.cwd ?? "")
    }
    return groups
  }

  /// How much a session listed elsewhere wants the person.
  func urgency(of summary: SessionSummary) -> Urgency? {
    Urgency.of(
      summary, recognisesAsks: AttentionChoice.recognisesAsks,
      dismissed: dismissedElsewhere[summary.sessionID])
  }

  /// Quiets the question or offer a session elsewhere ended on, until it asks another. On
  /// the session the window shows, from Session › Dismiss or the row's menu, it is a reply.
  func dismissAsk(_ summary: SessionSummary) {
    dismissedElsewhere[summary.sessionID] = summary.closingMessageID
    // A row watching it here asks again once that process exits, unless it knows too.
    let watching = session(withID: summary.sessionID)
    watching?.dismissedAsk = summary.closingMessageID
    Attention.shared.refresh()
    if let watching, watching.id == selectedID { replied(watching) }
  }

  /// A session listed elsewhere, shown: in the Drakar window that holds it, taken back as a
  /// live tab when its tab here was closed at work, or watched here.
  func openElsewhere(_ summary: SessionSummary, focusingComposer: Bool = true) {
    if let (owner, item) = OpenSessions.shared.locate(summary.sessionID) {
      owner.select(item)
      owner.workspace.window?.makeKeyAndOrderFront(nil)
    } else if let hostID = closedAtWork[summary.sessionID] {
      Task { await reopenClosed(hostID, summary, focusingComposer: focusingComposer) }
    } else if let target = ResumeTarget(summary) {
      attach(target, watching: true, readOnly: true, focusingComposer: focusingComposer)
    }
  }

  /// A tab closed at work opened again from Elsewhere: taken back while the host still holds
  /// its process; once that is gone, it is shown as any session elsewhere.
  private func reopenClosed(
    _ hostID: String, _ summary: SessionSummary, focusingComposer: Bool
  ) async {
    guard let held = await sessionHost?.listed(), !isStopped else { return }
    if held.contains(where: { $0.id == hostID }) {
      await reopen(hostID, among: held)
    } else {
      closedAtWork = closedAtWork.filter { $0.value != hostID }
      openElsewhere(summary, focusingComposer: focusingComposer)
    }
  }

  /// The session elsewhere the selected row watches, while it is listed there.
  private var watchedElsewhere: SessionSummary? {
    guard let selected, selected.isWatching, let id = selected.sessionID else { return nil }
    return groups.elsewhere.first { $0.sessionID == id }
  }

  /// Whether the shown session ended on a question or an offer Dismiss can quiet.
  var canDismissSelected: Bool {
    if selected?.closingAsk != nil { return true }
    guard let summary = watchedElsewhere else { return false }
    return [.question, .offer].contains(urgency(of: summary))
  }

  func dismissSelected() {
    if let selected, selected.closingAsk != nil {
      dismissAsk(selected)
    } else if let summary = watchedElsewhere {
      dismissAsk(summary)
    }
  }

  /// The question the shown session ended on, when a bare "Yes" answers it and its composer
  /// could send one: the toolbar's Yes and No, Session > Answer Yes and Answer No. Never for
  /// a session live elsewhere, which Drakar only watches.
  var yesOrNoSelected: ClosingAsk? {
    guard let selected, selected.session.canSend,
      !selected.session.status.isWaitingOnPerson,
      let ask = selected.closingAsk, ask.isYesOrNo
    else { return nil }
    return ask
  }

  /// Sends "Yes" to the shown session, as its composer would, leaving the draft as it is.
  func answerYesSelected() {
    guard yesOrNoSelected != nil, let selected else { return }
    takeOver(selected)
    selected.session.send("Yes")
  }

  /// Starts the shown session's reply with "No, " and focuses it, since a bare "No" mostly
  /// earns a "What would you like instead?"; `bare` sends just that. A draft already
  /// written is kept.
  func answerNoSelected(bare: Bool = false) {
    guard yesOrNoSelected != nil, let selected else { return }
    if bare {
      takeOver(selected)
      selected.session.send("No")
      return
    }
    if selected.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      selected.draft = "No, "
    }
    selected.focusRequest += 1
  }

  /// A new session in `folder` (the project's when nil), opened right of the shown tab or at
  /// `index` in the tabs, running `agent` (Settings' default when nil) under `account` (the
  /// folder's when nil), and shown unless `shows` is false. No process until it is prompted.
  @discardableResult func newSession(
    agent: AgentKind? = nil, folder: URL? = nil, account: ClaudeAccount? = nil,
    select shows: Bool = true, at index: Int? = nil
  ) -> ProjectSession {
    // A runner's sessions are Claude Code's (remote sessions spec, Goals), under the runner
    // shell's own account: none picked here reaches it (Ruling 11).
    let item = make(
      AgentSession(
        folder: folder ?? self.folder,
        agent: runner == nil ? agent ?? ClaudeChoice.defaultAgent : .claude,
        account: runner == nil ? account : nil))
    sessions.insert(item, at: index.map { min(max($0, 0), sessions.count) } ?? opensAt)
    if shows { select(item) }
    return item
  }

  /// New Session on Runner…: the window's blank row shown, or a new one made.
  func showNewSession() {
    if let blank = sessions.first(where: isBlank) { select(blank) } else { newSession() }
  }

  /// Whether a skill can go to `target`: a new session whenever work may be sent (the
  /// licence gate, checked here too so a refused prompt leaves no row made for nothing);
  /// the shown one only when it takes slash commands and could take a prompt now (not
  /// read-only, not mid-turn).
  func canRun(in target: SkillTarget) -> Bool {
    switch target {
    case .newSession: EntitlementMonitor.allowsWorkNow
    case .current:
      selected?.session.features.slashCommands == true && selected?.session.canSend == true
    }
  }

  /// The agent whose skills the inspector lists and a new session runs them in: the shown
  /// session's, Claude Code's when none is shown.
  var skillsAgent: AgentKind { selected?.session.agent ?? .claude }

  /// What Run Skill in Subfolders… offers: the inspector's list for `skillsAgent`, the CLI's
  /// own left out.
  var fanOutSkills: [SkillEntry] {
    let all: [SkillEntry] =
      switch skillsAgent {
      case .claude: capabilities.lists.skills ?? []
      case .codex: codexSkills(for: selected?.session).skills ?? []
      }
    return all.filter { !$0.isBuiltin }
  }

  /// Whether Run in Each Subfolder is offered: not on a runner's folder, whose subfolders
  /// this Mac cannot list (remote sessions spec §4).
  var offersFanOut: Bool { runner == nil }

  /// Reads the list `fanOutSkills` gives; none for a runner's folder, which no probe of this
  /// Mac's lists.
  func loadFanOutSkills() {
    guard offersFanOut else { return }
    switch skillsAgent {
    case .claude: capabilities.loadIfNeeded()
    case .codex: codexSkills(for: selected?.session).loadIfNeeded()
    }
  }

  /// Codex's skills for `session`'s folder, the project's own without a session: what its
  /// `/` menu lists and its prompts can name.
  func codexSkills(for session: AgentSession?) -> CodexSkills {
    CodexSkillStore.shared.skills(for: session?.folder ?? folder)
  }

  /// What `session`'s `/` menu offers: Codex's skills for a Codex session, Claude Code's
  /// commands and skills for the project otherwise.
  func slashCommands(for session: AgentSession) -> [SkillEntry] {
    guard session.features.slashCommands else { return [] }
    // A runner session's are what its own process listed: none before it has.
    if session.isOnRunner { return session.reportedCommands ?? [] }
    switch session.agent {
    case .claude: return capabilities.lists.commands ?? capabilities.lists.skills ?? []
    case .codex: return codexSkills(for: session).skills ?? []
    }
  }

  /// The first `/` typed in `session` reads its agent's list.
  func loadSlashCommands(for session: AgentSession) {
    // No probe of this Mac's `claude` lists a runner's folder.
    guard session.features.slashCommands, !session.isOnRunner else { return }
    switch session.agent {
    case .claude: capabilities.loadIfNeeded()
    case .codex: codexSkills(for: session).loadIfNeeded()
    }
  }

  /// A skill from the inspector: sent at once when it takes nothing, otherwise put at the
  /// start of the composer with what it takes shown, the focus there.
  func run(_ skill: SkillEntry, in target: SkillTarget) {
    guard canRun(in: target) else { return }
    let agent = skillsAgent
    // The dots are Claude Code's: a Codex skill of the same name leaves its dot.
    if agent == .claude { capabilityMarks.skills.remove(skill.name) }
    let item: ProjectSession
    switch target {
    case .newSession:
      // Codex's list is the shown session's folder's: the new session runs there, where its
      // prompt can name the skill.
      item = newSession(agent: agent, folder: agent == .codex ? selected?.session.folder : nil)
    case .current:
      guard let selected else { return }
      item = selected
    }
    if skill.takesArguments {
      let text = "/\(skill.name) "
      // The skill the inspector put there before, or this one already, gives way: what was
      // typed after it is kept, under the new name.
      var rest = Substring(item.draft)
      if let prefill = item.prefill, rest.hasPrefix(prefill.text) {
        rest = rest.dropFirst(prefill.text.count)
      } else if rest.hasPrefix(text) {
        rest = rest.dropFirst(text.count)
      }
      item.draft = text + rest
      item.prefill = SkillPrefill(text: text, hint: skill.argumentHint)
      item.focusRequest += 1
    } else {
      takeOver(item)
      item.session.send("/\(skill.name)")
    }
  }

  /// `skill` in a new session in each of `folders`, opened right of the shown tab in their
  /// order, the first shown: named after the skill and the folder, in `mode` and under
  /// `account` when given, and sent the skill all at once or `limit` at a time.
  func runInSubfolders(
    _ skill: SkillEntry, folders: [URL], arguments: String, mode: PermissionMode?, limit: Int?,
    account: ClaudeAccount? = nil
  ) {
    // Before any row is made: each `send` below would be refused anyway, and a batch whose
    // sessions never start would wait for ever.
    guard offersFanOut, !folders.isEmpty, EntitlementMonitor.allowsWorkNow else { return }
    let agent = skillsAgent
    if agent == .claude { capabilityMarks.skills.remove(skill.name) }
    let id = UUID()
    // Each right of the one before, where a new session would open.
    let start = opensAt
    let items = folders.enumerated().map { index, folder in
      let item = newSession(
        agent: agent, folder: folder, account: account, select: false, at: start + index)
      item.session.rename(to: "/\(skill.name) · \(folder.lastPathComponent)")
      if let mode { item.session.setMode(mode) }
      item.session.fanOut = FanOutMark(batch: id, index: index)
      return item
    }
    if let first = items.first { select(first) }
    let arguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    let batch = FanOutBatch(
      id: id, skillName: skill.name,
      prompt: arguments.isEmpty ? "/\(skill.name)" : "/\(skill.name) \(arguments)",
      agent: agent, limit: limit,
      plan: items.map { storedEntry(of: $0.session, state: .waiting) },
      queue: FanOut(ids: items.map(\.id), limit: limit))
    fanOuts.append(batch)
    send(batch.queue.start(), in: batch)
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// The waiting sessions of `batch` are not sent; those running go on.
  func cancelFanOut(_ batch: FanOutBatch) {
    _ = batch.queue.cancel()
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// How a row was clicked: plainly, with ⌘, or with ⇧.
  enum RowClick {
    case plain, toggle, extend
  }

  /// A click on a tab. Plain shows it and clears the marks; ⌘ marks or unmarks it (the shown
  /// tab is marked with the first); ⇧ marks the tabs from the last clicked to it, in the
  /// tabs' order, passing over the preview. Neither ⌘ nor ⇧ changes the tab shown, and on
  /// the preview, which is not the window's own to mark, neither does anything.
  func click(_ item: ProjectSession, _ kind: RowClick) {
    lastBroadcast = nil
    switch kind {
    case .plain:
      marked = []
      markAnchor = item.id
      select(item)
    case .toggle:
      // The preview is not one to mark, nor to start a range from.
      guard !item.isWatching else { return }
      // The shown row, if it is one of the window's own: a watched one can't be marked.
      if marked.isEmpty, let selected, !selected.isWatching, selected.id != item.id {
        marked = [selected.id]
      }
      if marked.remove(item.id) == nil { marked.insert(item.id) }
      markAnchor = item.id
    case .extend:
      // The window's own tabs: the preview is not one to mark.
      guard !item.isWatching else { return }
      let rows = held.map(\.id)
      guard let end = rows.firstIndex(of: item.id) else { return }
      // The last clicked row, else the one shown when that one was removed since.
      let start =
        markAnchor.flatMap { rows.firstIndex(of: $0) }
        ?? selectedID.flatMap { rows.firstIndex(of: $0) } ?? end
      marked.formUnion(rows[min(start, end)...max(start, end)])
    }
  }

  func markAll() {
    lastBroadcast = nil
    marked = Set(held.map(\.id))
  }

  func clearMarks() {
    lastBroadcast = nil
    marked = []
  }

  /// The marked rows still held, in the tabs' order.
  var markedSessions: [ProjectSession] { held.filter { marked.contains($0.id) } }

  /// How many marked rows are still held, counted without making the list.
  private var markedCount: Int { held.count { marked.contains($0.id) } }

  /// The composer sends to the marked rows rather than the shown one.
  var sendsToMarked: Bool { markedCount >= 2 }

  /// Whether a marked row could take the composer's prompt now, sent or queued.
  var canSendToMarked: Bool {
    held.contains { marked.contains($0.id) && ($0.session.canSend || $0.session.canQueue) }
  }

  /// The composer's chip: where the prompt goes, or what the last one there did.
  var broadcastLabel: String? {
    guard sendsToMarked else { return nil }
    guard let last = lastBroadcast else {
      return String(localized: "To \(markedCount) sessions")
    }
    let sent = String(localized: "Sent to \(last.sent)")
    return last.skipped == 0 ? sent : sent + " · " + String(localized: "\(last.skipped) skipped")
  }

  /// The prompt to each marked session: now where it could take one, queued in a turn that
  /// runs, skipped where it can't (open elsewhere, moving, starting, or a PDF its agent
  /// can't read). The marks stay.
  @discardableResult func broadcast(
    _ text: String, context: [EditorSelection], attachments: [Attachment]
  ) -> BroadcastResult {
    var result = BroadcastResult(sent: 0, skipped: 0)
    isBroadcasting = true
    defer { isBroadcasting = false }
    let hasPDF = attachments.contains { $0.kind == .pdf }
    for item in markedSessions {
      guard item.session.canSend || item.session.canQueue,
        !hasPDF || item.session.features.acceptsPDF
      else {
        result.skipped += 1
        continue
      }
      item.session.send(text, context: context, attachments: attachments)
      result.sent += 1
    }
    lastBroadcast = result
    return result
  }

  /// Ends each marked session's process; the rows stay.
  func stopMarked() {
    for item in markedSessions { end(item) }
  }

  /// Close N Tabs, on the marked tabs: each closes as `closeTab` closes it, at work handed
  /// to the session host, except those that would ask first (`closeAsk(for:)`), which stay
  /// open and marked, as Close Other Tabs leaves them. The shown one among those closing
  /// gives way to the nearest tab left standing, right of it first as a closed tab's
  /// neighbour is, else left, picked before any closes: a tab on its way out is never shown,
  /// and never reads its transcript.
  func closeMarked() {
    let closing = markedSessions.filter { closeAsk(for: $0) == nil }
    let gone = Set(closing.map(\.id))
    if let selectedID, gone.contains(selectedID),
      let index = sessions.firstIndex(where: { $0.id == selectedID })
    {
      let right = sessions[(index + 1)...].first { !gone.contains($0.id) }
      let left = sessions[..<index].last { !gone.contains($0.id) }
      self.selectedID = (right ?? left)?.id
    }
    for item in closing { closeTab(item) }
  }

  /// `item` ended a turn or stopped: its slot goes to the next waiting session.
  private func fanOutFinished(_ item: ProjectSession) {
    for batch in fanOuts { send(batch.queue.finished(item.id), in: batch) }
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// What `session` was started with, as a batch stores it.
  private func storedEntry(
    of session: AgentSession, state: FanOut<UUID>.State
  ) -> StoredFanOut.Entry {
    StoredFanOut.Entry(
      folder: session.folder.path(percentEncoded: false), name: session.name ?? "",
      accountDirectory: session.accountPick?.directory.path(percentEncoded: false),
      accountIsDefault: session.accountPick?.isDefault, mode: session.modePick, state: state,
      hostID: session.hostID)
  }

  private func storedFanOut(_ batch: FanOutBatch) -> StoredFanOut {
    let entries = zip(batch.queue.ids, batch.plan).map { id, planned in
      let state = batch.queue.state(of: id) ?? .finished
      // A row closed since keeps what it was started with.
      guard let session = sessions.first(where: { $0.id == id })?.session else {
        var entry = planned
        entry.state = state
        return entry
      }
      var entry = storedEntry(of: session, state: state)
      if entry.name.isEmpty { entry.name = planned.name }
      return entry
    }
    return StoredFanOut(
      batch: batch.id, skillName: batch.skillName, prompt: batch.prompt, limit: batch.limit,
      entries: entries, agent: batch.agent)
  }

  /// A session of `folder` that has been started before, which the window kept a row for.
  private func keptARow(in folder: String) -> Bool {
    sessions.contains {
      $0.session.resuming != nil && $0.session.folder.path(percentEncoded: false) == folder
    }
  }

  /// The batches stored with the window, carried on now that `adoptHeld` has brought back the
  /// rows the host held. An entry that was running takes its row, found by the host's id or
  /// else by the mark in the process's meta; when none came back its process is gone, so its
  /// slot goes to the next. A waiting entry becomes a new session in its folder, with its
  /// name, account and mode, sent when its turn comes. Entries done or cancelled only count.
  private func restoreFanOuts() {
    guard !isStopped else { return }
    let stored = storedFanOuts
    storedFanOuts = []
    for stored in stored {
      var ids: [UUID] = []
      var states: [UUID: FanOut<UUID>.State] = [:]
      var created: [(index: Int, entry: StoredFanOut.Entry)] = []
      for (index, entry) in stored.entries.enumerated() {
        var id = UUID()
        var state = entry.state
        var reused = false
        if state == .running {
          let mark = FanOutMark(batch: stored.batch, index: index)
          let row =
            sessions.first {
              $0.session.isHosted && entry.hostID != nil && $0.session.hostID == entry.hostID
            } ?? sessions.first { $0.session.isHosted && $0.session.fanOut == mark }
          if let row {
            id = row.id
            // A turn that ended while away is done; a pending permission is still its turn.
            // A row whose transcript holds no prompt never took the batch's: the quit came
            // while its spawn was unanswered, so the request was lost. It is sent again.
            if !row.session.isAtWork {
              let tookPrompt = row.session.status.firstPrompt != nil
              state = tookPrompt ? .finished : .waiting
              reused = state == .waiting
            }
          } else if entry.hostID == nil, !keptARow(in: entry.folder) {
            // Never reached a host and left no session behind: the prompt was lost with the
            // quit, and a new session in the folder takes it.
            state = .waiting
          } else {
            state = .finished
          }
        }
        ids.append(id)
        if state == .waiting && !reused {
          created.append((index, entry))
        } else {
          states[id] = state
        }
      }
      // Each right of the one before, where a new session would open.
      let start = opensAt
      for (offset, (index, entry)) in created.enumerated() {
        let account = entry.accountDirectory.map {
          ClaudeAccount(
            directory: URL(filePath: $0, directoryHint: .isDirectory),
            isDefault: entry.accountIsDefault ?? false)
        }
        let item = newSession(
          agent: stored.agent ?? .claude,
          folder: URL(filePath: entry.folder, directoryHint: .isDirectory),
          account: account, select: false, at: start + offset)
        item.session.rename(to: entry.name)
        if let mode = entry.mode { item.session.setMode(mode) }
        item.session.fanOut = FanOutMark(batch: stored.batch, index: index)
        ids[index] = item.id
        states[item.id] = .waiting
      }
      let batch = FanOutBatch(
        id: stored.batch, skillName: stored.skillName, prompt: stored.prompt,
        agent: stored.agent ?? .claude, limit: stored.limit, plan: stored.entries,
        queue: FanOut(ids: ids, limit: stored.limit, states: states))
      fanOuts.append(batch)
      // Slots the missing processes left go to the waiting ones.
      send(batch.queue.start(), in: batch)
    }
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// Sends `batch`'s prompt to `ids`; one closed meanwhile passes its slot on. One that
  /// cannot take it (the licence gate, after a trial ended) waits again rather than counting
  /// as running for a turn that never started: Cancel can clear it, and `resumeFanOuts`
  /// sends it once work may be sent.
  private func send(_ ids: [UUID], in batch: FanOutBatch) {
    for id in ids {
      guard let item = sessions.first(where: { $0.id == id }) else {
        send(batch.queue.finished(id), in: batch)
        continue
      }
      guard item.session.canSend || item.session.canQueue else {
        batch.queue.refused(id)
        continue
      }
      item.session.send(batch.prompt)
    }
  }

  /// The batches' waiting sessions, sent into the slots free now: what a refusal left
  /// waiting goes once a trial starts or a key is entered (`EntitlementMonitor.apply()`).
  func resumeFanOuts() {
    guard EntitlementMonitor.allowsWorkNow else { return }
    for batch in fanOuts { send(batch.queue.start(), in: batch) }
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// Hiding the inspector on its Skills & MCP tab: everything marked was seen.
  func clearCapabilityMarks() {
    capabilityMarks = CapabilityMarks()
  }

  /// A server row was opened.
  func unmarkServer(_ name: String) {
    capabilityMarks.servers.remove(name)
  }

  /// The window's account may be another now: the lists follow it. Not a runner's window,
  /// whose folder this Mac's accounts list nothing of and no probe of this Mac's reads.
  func accountMayHaveChanged() {
    guard runner == nil else { return }
    let entry = CapabilityStore.shared.capabilities(
      for: folder, account: AccountStore.shared.windowAccount(for: folder))
    guard entry !== capabilities else { return }
    if let capabilityObserver { capabilities.stopObserving(capabilityObserver) }
    // The old account's probe is nobody's now, unless another window shows its lists.
    cancelProbeUnlessShared(capabilities)
    capabilities = entry
    capabilityMarks = CapabilityMarks()
    observeCapabilities()
    entry.loadIfNeeded()
  }

  /// A session's `initialize` lists the project's skills only from the project's own
  /// folder, under the account the lists are for: a worktree is another checkout. The lists
  /// are Claude Code's: a Codex session never speaks for them. Nor does a runner's, whose
  /// folder and account are the runner's, whatever their paths.
  func speaksForProject(_ session: AgentSession) -> Bool {
    !session.isOnRunner
      && ProjectPath.normalize(session.folder) == ProjectPath.normalize(folder)
      && session.agent == .claude
      && capabilities.accountKey.map { session.account?.key == $0 } == true
  }

  /// `handler` hears each change to a file either agent reads the project's skills from, as
  /// it comes (the lists themselves are read again once changes settle).
  func observeSkillFiles(_ handler: @escaping () -> Void) -> UUID {
    let id = UUID()
    skillFileObservers[id] = handler
    return id
  }

  func stopObservingSkillFiles(_ id: UUID) {
    skillFileObservers[id] = nil
  }

  private func tellSkillFileObservers() {
    for handler in skillFileObservers.values { handler() }
  }

  private func observeCapabilities() {
    capabilityObserver = capabilities.observe { [weak self] changes in
      self?.capabilityMarks.add(changes)
    }
  }

  private func capabilityFilesChanged() {
    tellSkillFileObservers()
    capabilityRefresh = settled(replacing: capabilityRefresh) {
      $0.capabilities.refreshIfLoaded()
    }
  }

  private func codexSkillFilesChanged() {
    tellSkillFileObservers()
    codexSkillRefresh = settled(replacing: codexSkillRefresh) {
      CodexSkillStore.shared.skills(for: $0.folder).refreshIfLoaded()
    }
  }

  /// `refresh` once file changes have settled for `capabilityDebounce`, in place of `waiting`.
  private func settled(
    replacing waiting: Task<Void, Never>?, _ refresh: @escaping (Project) -> Void
  ) -> Task<Void, Never> {
    waiting?.cancel()
    let delay = capabilityDebounce
    return Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      refresh(self)
    }
  }

  /// The window is going: its probe too, unless another window shows the same lists.
  private func releaseCapabilities() {
    capabilityRefresh?.cancel()
    codexSkillRefresh?.cancel()
    if let capabilityObserver { capabilities.stopObserving(capabilityObserver) }
    capabilityObserver = nil
    cancelProbeUnlessShared(capabilities)
  }

  /// `entry`'s probe goes, unless another open window shows the same lists.
  private func cancelProbeUnlessShared(_ entry: Capabilities) {
    let shared = OpenSessions.shared.projects.values.contains {
      $0 !== self && $0.capabilities === entry
    }
    if !shared { entry.cancel() }
  }

  /// `target` opened right of the shown tab and shown, or the row already holding it, taken
  /// over unless `watching`. `readOnly` while another process has it open. Watched, it is the
  /// window's one preview tab: the preview it replaces goes as a removed row does, or stays
  /// as a tab of the window's own when something is typed or attached in it, which closing it
  /// would lose. The new preview takes the place of the one it replaces when that one was
  /// shown, so that going through the sidebar's rows leaves the tabs where they were.
  @discardableResult func attach(
    _ target: ResumeTarget, watching: Bool = false, readOnly: Bool = false,
    focusingComposer: Bool = true
  ) -> ProjectSession {
    if target.forks != true, let existing = session(withID: target.sessionID) {
      if !watching { takeOver(existing) }
      select(existing, focusingComposer: focusingComposer)
      return existing
    }
    let session = AgentSession(
      folder: URL(filePath: target.cwd, directoryHint: .isDirectory), resuming: target)
    session.isReadOnly = readOnly
    if target.forks == true, let name = forkName(for: target) { session.rename(to: name) }
    let item = make(session)
    item.isWatching = watching
    item.dismissedAsk = dismissedElsewhere[target.sessionID]
    let index = watching ? replacePreview() ?? opensAt : opensAt
    sessions.insert(item, at: index)
    select(item, focusingComposer: focusingComposer)
    return item
  }

  /// Where a session opens: right of the shown tab, else after the last.
  private var opensAt: Int {
    selectedID.flatMap { id in sessions.firstIndex { $0.id == id } }.map { $0 + 1 }
      ?? sessions.count
  }

  /// The preview tab out of the way of a new one: taken over when closing it would lose a
  /// draft or attachments, else removed. Where it was when it was the tab shown, for the new
  /// one to take its place, rather than its neighbour shown and loaded for nothing.
  private func replacePreview() -> Int? {
    guard let preview = sessions.first(where: \.isWatching) else { return nil }
    if hasUnsent(preview) {
      takeOver(preview)
      return nil
    }
    let place = preview.id == selectedID ? sessions.firstIndex { $0.id == preview.id } : nil
    if place != nil { selectedID = nil }
    drop(preview) { $0.stop() }
    return place
  }

  /// Something typed or attached in `item` and not sent.
  private func hasUnsent(_ item: ProjectSession) -> Bool {
    !item.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !item.attachments.isEmpty
  }

  /// "Pineapple (fork #2)" for a copy of `target`: its title, numbered after every fork of
  /// it the folder lists, in the window's rows and on disk. Nil when it has no title yet.
  private func forkName(for target: ResumeTarget) -> String? {
    let listed = monitor.summaries(
      under: ProjectPath.normalize(folder))
    let original =
      session(withID: target.sessionID)?.knownTitle
      ?? listed.first { $0.sessionID == target.sessionID }
      .flatMap { $0.title ?? $0.lastPrompt.map { String($0.prefix(80)) } }
    guard let original else { return nil }
    return SessionTitle.forkName(
      of: original, among: sessions.compactMap(\.knownTitle) + listed.compactMap(\.title))
  }

  /// A watched row, the preview tab, becomes one of the window's own where it is: it was
  /// prompted, or attached.
  func takeOver(_ item: ProjectSession) {
    guard item.isWatching else { return }
    item.isWatching = false
  }

  /// The preview tab, or its row in the sidebar, double-clicked: kept as one of the window's
  /// own tabs, as a prompt sent there keeps it.
  func promote(_ item: ProjectSession) {
    takeOver(item)
  }

  /// The window's tabs in order: its own rows and the preview. The strip lists these, and
  /// the window keeps its own rows in this order between launches.
  var tabs: [ProjectSession] { sessions }

  /// `id`'s tab dragged to `index` in the tabs, clamped to them. The tab shown stays shown.
  /// `index` is where the tab ends up, counted once it is out of its old place: moving the
  /// first of three tabs to the end is `2`, not `3`. A drop handler that is handed a
  /// destination counted before the removal, as SwiftUI's `onMove` is, takes one off it when
  /// the tab moves right.
  func moveTab(_ id: ProjectSession.ID, to index: Int) {
    guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
    let item = sessions.remove(at: from)
    sessions.insert(item, at: min(max(index, 0), sessions.count))
  }

  /// The tab shown once `item`'s closes: the one right of it, else the one left, else none.
  func neighbour(of item: ProjectSession) -> ProjectSession? {
    guard let index = sessions.firstIndex(where: { $0.id == item.id }) else { return nil }
    if index + 1 < sessions.count { return sessions[index + 1] }
    return index > 0 ? sessions[index - 1] : nil
  }

  /// A copy of a session open elsewhere, continued under a new id beside it. Its own
  /// transcript first: a fork still running its first process resumes its original.
  @discardableResult func fork(_ item: ProjectSession) -> ProjectSession {
    guard hasForkableTranscript(item),
      var target = item.session.savedTarget ?? item.session.resuming
    else { return item }
    target.forks = true
    return attach(target)
  }

  /// Whether `item` has a transcript to copy and no turn writing it: a fork taken mid-turn
  /// would copy a history that can end on a tool call with no result.
  func canFork(_ item: ProjectSession) -> Bool {
    hasForkableTranscript(item) && !item.session.status.isRunning
  }

  /// Never a runner session's: its transcript is on the runner, and nothing forks there in v1
  /// (remote sessions spec §4).
  private func hasForkableTranscript(_ item: ProjectSession) -> Bool {
    item.session.features.forks && !item.session.isOnRunner
      && (item.session.resuming ?? item.session.savedTarget) != nil
  }

  var canForkSelected: Bool { selected.map(canFork) ?? false }

  /// Forks `item` from the prompt `messageID`, cut just before it, with `text` in the new
  /// session's composer. The resume point is read from its transcript off the main actor:
  /// after the message before the prompt, a fork resumed there; before the first prompt,
  /// a plain new session in the same folder with the session's mode and model picks, there
  /// being nothing to keep. Claude Code sessions only. A fork not made (a prompt not in the
  /// file, a turn started, before or during the read) is said in `item`'s conversation,
  /// `afterRewind` in the note of the rewind that came first.
  @discardableResult func fork(
    _ item: ProjectSession, from messageID: String, text: String, afterRewind: Bool = false
  ) async -> ProjectSession? {
    guard let forked = await forkIfAble(item, from: messageID, text: text) else {
      item.session.noteNotForked(afterRewind: afterRewind)
      return nil
    }
    return forked
  }

  /// Where a fork from a prompt resumes, read from the transcript off the main actor.
  /// Settable so that a test can start a turn while it reads.
  @ObservationIgnored var readResumePoint: (URL, String) async -> ResumePoint? = {
    file, messageID in
    await Task.detached {
      (try? Transcript.lines(contentsOf: file)).flatMap {
        Transcript.resumePoint(before: messageID, in: $0)
      }
    }.value
  }

  private func forkIfAble(_ item: ProjectSession, from messageID: String, text: String) async
    -> ProjectSession?
  {
    guard canForkFrom(item), var target = item.session.savedTarget ?? item.session.resuming
    else { return nil }
    let point = await readResumePoint(target.transcriptFile, messageID)
    // A turn that started during the read writes the history the fork would copy.
    guard canForkFrom(item) else { return nil }
    let forked: ProjectSession
    switch point {
    case nil:
      return nil
    case .after(let message):
      target.forks = true
      target.resumeAt = message
      forked = attach(target)
    case .start:
      forked = newSession(agent: .claude, folder: item.session.folder, account: target.account)
      if let mode = item.session.modePick { forked.session.setMode(mode) }
      if let model = item.session.modelPick { forked.session.setModel(model) }
    }
    forked.draft = text
    return forked
  }

  /// Whether `item` can be forked from one of its prompts: as `canFork`, and only Claude
  /// Code's, whose prompts carry the CLI's message uuids (a Codex prompt's is Drakar's own).
  func canForkFrom(_ item: ProjectSession) -> Bool {
    offersForkFrom(item) && !item.session.status.isRunning
  }

  /// As `canForkFrom` but for the turn: a prompt's menu shows the fork through a turn,
  /// disabled, rather than taking it away.
  func offersForkFrom(_ item: ProjectSession) -> Bool {
    hasForkableTranscript(item) && item.session.agent == .claude
  }

  /// Whether `item` can take a name: not while another process has it, or its files move,
  /// nor on a runner with no process to ask (`AgentSession.canRename`).
  func canRename(_ item: ProjectSession) -> Bool { item.session.canRename }

  var canRenameSelected: Bool { selected.map(canRename) ?? false }

  func forkSelected() {
    if let selected, canFork(selected) { fork(selected) }
  }

  /// Whether Open Plan can ask the shown session for its plan: a Claude Code process Drakar
  /// drives, as its permission rules are read. Not a runner's, whose plan file is there and
  /// whose window has no editor.
  var canOpenPlanSelected: Bool {
    guard let session = selected?.session else { return false }
    return session.hasLiveRules && !session.isOnRunner
  }

  func openPlanSelected() async {
    if let selected { await openPlan(selected) }
  }

  /// `item`'s plan file in the side editor, asked of its process with `get_plan`. No plan
  /// yet, or no path to it, and no answer, are each said in its conversation; a file that
  /// will not read is the editor's problem, as for any file link.
  func openPlan(_ item: ProjectSession) async {
    let session = item.session
    guard session.hasLiveRules, !session.isOnRunner else { return }
    guard let reply = await session.readPlan() else {
      session.notePlanUnread()
      return
    }
    guard reply.exists, let path = reply.path else {
      session.noteNoPlan()
      return
    }
    workspace.open(URL(filePath: path))
  }

  /// Whether another app's process has `summary` open between turns, so that it can be
  /// ended for the session to move here. One in another Drakar window has no `live`.
  static func canMoveHere(_ summary: SessionSummary) -> Bool {
    guard let live = summary.live else { return false }
    return live.status != "busy"
  }

  /// Ends the process that has `summary` open and makes the session one of this window's
  /// rows, read-only until the registry says that process is gone (`liveChanged`). False
  /// when it was not ended: it started a turn, or is no longer the process listed.
  @discardableResult func moveHere(_ summary: SessionSummary) -> Bool {
    guard Self.canMoveHere(summary), let live = summary.live, let target = ResumeTarget(summary),
      LiveSession.end(live, account: summary.account)
    else { return false }
    attach(target, readOnly: true)
    return true
  }

  func select(_ item: ProjectSession, focusingComposer: Bool = true) {
    focusesComposer = focusingComposer
    selectedID = item.id
    item.isUnread = false
    load(item)
    Attention.shared.refresh()
  }

  /// Whether the sidebar's Ended group is expanded, and lists all its rows rather than the
  /// newest 20.
  var showsEnded = false
  var showsAllEnded = false

  /// Ended's rows as the sidebar lists them, expanded or not.
  func listedEnded(_ groups: ProjectGroups) -> [SessionSummary] {
    showsAllEnded ? groups.ended : Array(groups.ended.prefix(20))
  }

  /// Whether the selected row is watching `summary` here, so the list shows it selected.
  func isWatched(_ summary: SessionSummary) -> Bool {
    guard let item = session(withID: summary.sessionID), item.isWatching else { return false }
    return item.id == selectedID
  }

  /// An ended session, watched here.
  func openEnded(_ summary: SessionSummary, focusingComposer: Bool = true) {
    if let target = ResumeTarget(summary) {
      attach(target, watching: true, focusingComposer: focusingComposer)
    }
  }

  /// The sidebar's ↑ and ↓: the row `offset` rows from the one the preview tab shows (else
  /// the first row), in the sidebar's order, Elsewhere's as sorted then Ended's while it is
  /// expanded, opened as a click opens it. So it lands in the preview, which the next one
  /// replaces, and the keys stay in the list; a tab closed at work is taken back as a tab.
  /// Stops at the ends: false when there is no row to go to. The tabs are `step`'s.
  @discardableResult func stepSidebar(_ offset: Int) -> Bool {
    let groups = listedGroups
    let rows =
      groups.elsewhere.map { (summary: $0, ended: false) }
      + (showsEnded ? listedEnded(groups).map { (summary: $0, ended: true) } : [])
    guard !rows.isEmpty else { return false }
    let shown = tabs.first(where: \.isWatching)?.sessionID
    let index: Int
    if let current = rows.firstIndex(where: { $0.summary.sessionID == shown }) {
      index = current + offset
      guard rows.indices.contains(index) else { return false }
    } else {
      index = 0
    }
    let row = rows[index]
    if row.ended {
      openEnded(row.summary, focusingComposer: false)
    } else {
      openElsewhere(row.summary, focusingComposer: false)
    }
    return true
  }

  /// Shows the tab `offset` tabs from the selected one, in the tabs' order, as a click shows
  /// it. Only the tabs: the sessions listed elsewhere and Ended's are the sidebar's to open,
  /// and Next Session Needing You still reaches one elsewhere that wants the person.
  /// `wrapping` goes round the ends (Previous and Next Session), else stops at them (the
  /// arrow keys, which keep the keys). False when there is no tab.
  @discardableResult func step(
    _ offset: Int, wrapping: Bool, focusingComposer: Bool = true
  ) -> Bool {
    let tabs = tabs
    guard !tabs.isEmpty else { return false }
    let current = tabs.firstIndex { $0.id == selectedID }
    let index =
      switch (current, wrapping) {
      case (nil, _): offset < 0 && wrapping ? tabs.count - 1 : 0
      case (let current?, true): ((current + offset) % tabs.count + tabs.count) % tabs.count
      case (let current?, false): min(max(current + offset, 0), tabs.count - 1)
      }
    let item = tabs[index]
    select(item, focusingComposer: focusingComposer)
    // The tab shown already keeps its composer, which only focuses itself on appearing.
    if focusingComposer { item.focusRequest += 1 }
    return true
  }

  /// A row Next Session Needing You can go to: one of the window's own, or a session listed
  /// elsewhere.
  enum Stop {
    case row(ProjectSession)
    case elsewhere(SessionSummary)

    var item: ProjectSession? {
      if case .row(let item) = self { item } else { nil }
    }
  }

  /// The next tab after the selected one that wants the person, in the tabs' order, the
  /// preview among them, then those listed elsewhere as the sidebar sorts them unless
  /// `ownRowsOnly`: the most urgent level that counts first, then unread, wrapping. Never the
  /// selected tab. A preview watching a session elsewhere wants what that session does.
  func nextNeedingAttention(ownRowsOnly: Bool = false) -> Stop? {
    let elsewhere = ownRowsOnly ? [] : listedGroups.elsewhere.filter { $0.live != nil }
    let tabbed = Set(tabs.compactMap(\.sessionID))
    var rows: [(stop: Stop, level: Urgency?, isUnread: Bool, isSelected: Bool)] = tabs.map { item in
      let watched =
        item.isWatching ? elsewhere.first { $0.sessionID == item.sessionID } : nil
      let level = item.urgency ?? watched.flatMap { urgency(of: $0) }
      return (.row(item), level, item.isUnread, item.id == selectedID)
    }
    for summary in elsewhere where !tabbed.contains(summary.sessionID) {
      rows.append((.elsewhere(summary), urgency(of: summary), false, false))
    }
    let start = rows.firstIndex { $0.isSelected } ?? -1
    let ordered = rows[(start + 1)...] + rows[..<max(start, 0)]
    for level in Urgency.allCases.reversed() where AttentionChoice.isOn(level, .counts) {
      if let row = ordered.first(where: { $0.level == level }) { return row.stop }
    }
    return ordered.first { $0.isUnread }?.stop
  }

  /// The shown session was answered: with Next After Replying on, the next of the window's
  /// own rows that wants the person is shown, once what sent the reply has done (a composer
  /// still clears its draft). Not while the session still wants something, nor for a prompt
  /// sent to the marked rows, which the person is working through together; an answer or a
  /// Dismiss on the shown row moves on with rows marked too.
  private func replied(_ item: ProjectSession) {
    guard movesOnAfterReply, item.id == selectedID, !isBroadcasting else { return }
    Task { [weak self] in
      guard let self, self.selectedID == item.id, item.urgency == nil,
        let next = self.nextNeedingAttention(ownRowsOnly: true)?.item
      else { return }
      self.select(next)
      // The row shown already keeps its composer, which only focuses itself on appearing.
      next.focusRequest += 1
    }
  }

  func show(_ stop: Stop) {
    switch stop {
    case .row(let item): select(item)
    case .elsewhere(let summary): openElsewhere(summary)
    }
  }

  /// Quiets the row's question or offer until it asks another.
  func dismissAsk(_ item: ProjectSession) {
    item.dismissAsk()
    Attention.shared.refresh()
    replied(item)
  }

  /// Takes back what the session host holds for the window (`adoptHeld`), in the background.
  /// Meanwhile the rows the window kept for its sessions send nothing (`waitsForHost`), so that
  /// none starts its session's process again beside the one the host runs; what is typed in
  /// them stays in the composer, and goes with the row that takes their place.
  @discardableResult func takeBackHeld() -> Task<Void, Never> {
    let waiting = sessions.filter { $0.session.resuming != nil && !$0.session.isProcessRunning }
    for item in waiting { item.session.waitsForHost = true }
    let host = sessionHost
    return Task {
      // A runner's out of reach is no runner holding nothing: taken back once it is reached.
      let listed = host?.isRunner == true ? await host?.listed() : await host?.heldIfRunning()
      let held = listed ?? []
      // The window closed meanwhile: no row is made and nothing is sent, and the batches
      // stay as stored for the next launch.
      let olderHosts = await host?.heldByOlderHosts() ?? []
      guard !isStopped else { return }
      if host?.isRunner == true, listed == nil { takeBackMissed = true }
      await adoptHeld(held, olderHosts: olderHosts)
      restoreFanOuts()
      for item in waiting { item.session.waitsForHost = false }
    }
  }

  /// The processes the session host holds for this window (spec §3 Relaunch, §4): those no
  /// app has come back as rows, live; those another app holds, and all an older host holds
  /// (`olderHosts`), as read-only rows, until that app lets them go. The row the window kept
  /// for the same session gives way to one, as does the blank row a window opens with when
  /// it has nothing else. A window that closes meanwhile takes back nothing more, and leaves
  /// the rest to the next launch.
  ///
  /// Only what the window may take is taken (`SessionMeta.mayBeTaken`, remote sessions spec
  /// §5): on the runner's own Drakar, a process a Mac owns is shown read-only, free or not;
  /// a runner's window takes what this Mac owns, and shows nothing of the rest, which it has
  /// no transcript of (Home lists it). A runner's window hears every `released`, for a
  /// process brought back to this Mac is one it shows nothing of; not a new connection, for
  /// what it finds free then may be a row closed here, which only Home opens again, unless its
  /// take-back never reached the runner (`takeBackOnceReached`).
  ///
  /// A process whose tab was closed at work (`SessionMeta.closedAtWork`) is taken back by no
  /// window on its own, free or another app's; only `reopen(_:among:)` takes it
  /// (`includingClosed`).
  func adoptHeld(
    _ held: [HeldProcess], olderHosts: [HeldProcess] = [], includingClosed: Bool = false
  ) async {
    let own = ProjectPath.normalize(folder.path(percentEncoded: false))
    let ours = { (process: HeldProcess) -> Bool in
      guard !self.adopting.contains(process.id),
        self.sessionHost?.ended.contains(process.id) != true,
        !self.sessions.contains(where: { $0.session.hostID == process.id }),
        let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta),
        ProjectPath.normalize(meta.windowFolder) == own
      else { return false }
      guard includingClosed || meta.closedAtWork != true else {
        // Passed over, and listed under Elsewhere instead, while no app holds it.
        if process.attachedApp == nil, let id = meta.sessionID {
          self.closedAtWork[id] = process.id
        }
        return false
      }
      return true
    }
    // Another window of this app's is not another app.
    let isHeldHere = { (process: HeldProcess) in
      OpenSessions.shared.projects.values.contains { project in
        project.sessions.contains { $0.session.hostID == process.id }
      }
    }
    let onRunner = sessionHost?.isRunner == true
    let free = held.filter { $0.attachedApp == nil && ours($0) && mayTake($0) }
    // Another app's, or free but a Mac's.
    let notOurs = held.filter { process in
      process.attachedApp == nil ? !mayTake(process) : !isHeldHere(process)
    }
    let elsewhere =
      onRunner ? [] : (notOurs + olderHosts).filter { ours($0) && !isShownReadOnly($0.id) }
    let ids = (free + elsewhere).map(\.id)
    adopting.formUnion(ids)
    for process in free {
      await takeBack(process)
      adopting.remove(process.id)
      if isStopped { return }
    }
    for process in elsewhere {
      let session = await AgentSession(heldElsewhere: process, accounts: accounts)
      adopting.remove(process.id)
      guard let session else { continue }
      if isStopped { return session.stop() }
      adopt(session)
    }
    let watched = Set(held.map(\.id)).intersection(elsewhere.map(\.id))
    guard !watched.isEmpty || onRunner || !closedAtWork.isEmpty, !isStopped else { return }
    shownHeldElsewhere.formUnion(watched)
    watchReleases()
    // Let go of while its row was being made: no `released` says so again.
    if !watched.isEmpty { await settleShown() }
  }

  /// Hears what the host lets go of and each new connection, for as long as the window is.
  private func watchReleases() {
    sessionHost?.watchReleases(
      for: self, takes: { [weak self] id in self?.released(id) ?? false },
      connected: { [weak self] in
        Task {
          await self?.settleShown()
          await self?.takeBackOnceReached()
          await self?.settleClosed()
        }
      })
  }

  /// The tabs closed at work whose processes the host no longer holds, or has ended, leave
  /// Elsewhere: on a new connection, which no `released` sent while there was none reached.
  private func settleClosed() async {
    guard !closedAtWork.isEmpty, let held = await sessionHost?.listed() else { return }
    let running = Set(held.filter(\.running).map(\.id))
    closedAtWork = closedAtWork.filter { running.contains($0.value) }
  }

  /// Whether the window may attach to `process` on its own, at a launch or on `released`.
  private func mayTake(_ process: HeldProcess) -> Bool {
    guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta) else {
      return false
    }
    return meta.mayBeTaken(by: ThisMac.name, onRunner: sessionHost?.isRunner == true)
  }

  /// Another app let go of a process one of the window's rows shows read-only (`released`):
  /// the row takes it back, or the session if the process is gone. False when none shows
  /// it, or it is being taken back already, so that of the windows told, one attaches, once.
  private func released(_ id: String) -> Bool {
    // A tab closed at work whose process ended and was forgotten: no longer elsewhere.
    if closedAtWork.values.contains(id) { closedAtWork = closedAtWork.filter { $0.value != id } }
    // A runner's window shows no process it does not hold, so cannot tell at once whether
    // the one let go is its own, brought back to this Mac: it asks, and lets the other
    // windows ask too.
    if sessionHost?.isRunner == true {
      guard !closedHere.contains(id) else { return false }
      Task {
        guard !isStopped, let held = await sessionHost?.listed() else { return }
        await adoptHeld(held.filter { $0.id == id })
      }
      return false
    }
    guard isShownReadOnly(id), !adopting.contains(id) else { return false }
    Task {
      guard let held = await sessionHost?.listed() else { return }
      await settle(id, among: held)
    }
    return true
  }

  /// The take-back a runner window missed (`takeBackMissed`), once a listing comes: what this
  /// Mac owns there and no app holds becomes the window's rows, as at a launch, but for the
  /// rows closed here meanwhile, which only Home opens again. Once.
  private func takeBackOnceReached() async {
    guard takeBackMissed, !isStopped, let held = await sessionHost?.listed() else { return }
    // Another connection's got there first.
    guard takeBackMissed, !isStopped else { return }
    takeBackMissed = false
    await adoptHeld(held.filter { !closedHere.contains($0.id) })
  }

  /// What the host holds now, for each row showing one of its processes read-only: on a new
  /// connection, which no `released` sent while there was none reached.
  private func settleShown() async {
    shownHeldElsewhere = shownHeldElsewhere.filter(isShownReadOnly)
    guard !shownHeldElsewhere.isEmpty, let held = await sessionHost?.listed() else { return }
    for id in shownHeldElsewhere { await settle(id, among: held) }
  }

  /// The row showing `id` read-only takes its process back once no app holds it, or becomes
  /// the session to resume here once the host no longer has it, as a session whose process
  /// elsewhere went away does; unless the row is being taken back already.
  private func settle(_ id: String, among held: [HeldProcess]) async {
    guard !isStopped, isShownReadOnly(id), !adopting.contains(id) else { return }
    if let process = held.first(where: { $0.id == id }) {
      // Held by another app still, or free but a Mac's: left to it, and shown on.
      guard process.attachedApp == nil, mayTake(process) else { return }
      adopting.insert(id)
      defer { adopting.remove(id) }
      await takeBack(process)
    } else if let shown = sessions.first(where: { $0.session.heldElsewhere == id })?.session {
      let session = AgentSession(
        folder: shown.folder, resuming: shown.resuming, agent: shown.agent,
        account: shown.accountPick)
      adopt(session, replacing: id)
      await session.loadHistory()
    }
  }

  /// A process of the window's that Home opened again: taken back if the window may take it,
  /// though its row was closed here, and shown. One whose tab was closed at work loses the
  /// mark, and its end with its turn, once taken back.
  func reopen(_ hostID: String, among held: [HeldProcess]) async {
    closedHere.remove(hostID)
    closedAtWork = closedAtWork.filter { $0.value != hostID }
    let process = held.filter { $0.id == hostID }
    let closed = process.contains {
      (try? JSONDecoder().decode(SessionMeta.self, from: $0.meta))?.closedAtWork == true
    }
    await adoptHeld(process, includingClosed: true)
    guard let item = sessions.first(where: { $0.session.hostID == hostID }) else { return }
    if closed { item.session.reopenedAfterClose() }
    select(item)
  }

  private func isShownReadOnly(_ hostID: String) -> Bool {
    sessions.contains { $0.session.heldElsewhere == hostID }
  }

  /// `process` attached and replayed, live, in place of its row. A row showing it read-only
  /// stays as it was should the host refuse: another app took it first. A window that closed
  /// during the replay stops it as it stopped its rows: no process stays attached to this app
  /// with no row to show it. The session, once it has a row.
  ///
  /// On a runner, the runner's own Drakar may take the process over between the listing and
  /// the attach: the host refuses it then, and the row would stay out of reach of a session
  /// no longer this Mac's. Listed again, one this Mac no longer owns closes its tab with the
  /// notice a reconnect gives (`takenOver`).
  @discardableResult private func takeBack(_ process: HeldProcess) async -> AgentSession? {
    guard let session = await reattached(process) else { return nil }
    if session.isOutOfReach, isShownReadOnly(process.id) { return nil }
    var takenOver = false
    if session.isOutOfReach, session.refusedAsHeldElsewhere, let host = sessionHost,
      host.isRunner, case .notOwned = await host.ownership(of: process.id)
    {
      takenOver = true
    }
    guard !isStopped else {
      session.stop()
      return nil
    }
    adopt(session, replacing: process.id)
    if takenOver, let item = sessions.first(where: { $0.session === session }) {
      self.takenOver(item)
      return nil
    }
    return session
  }

  /// `process` attached and replayed, out of reach if the host refused it, and no row's yet.
  /// Nil with no host, a meta this app cannot read, or a window closed meanwhile, which
  /// stops it.
  private func reattached(_ process: HeldProcess) async -> AgentSession? {
    // Asked each time: a replay before this one may have cost the connection.
    guard let host = sessionHost, let client = await host.client(), !isStopped,
      let session = await AgentSession(
        reattaching: process, client: client, throughRunner: host.isRunner, accounts: accounts)
    else { return nil }
    if isStopped {
      session.stop()
      return nil
    }
    return session
  }

  // MARK: - The handoff (remote sessions spec §5)

  /// Open on the Runner, for a runner's session this Mac holds: it is the runner's own
  /// Drakar's from now on, which attaches on `released` if it shows it, or at its next
  /// launch. Its row closes here, and the window with its last row.
  func openOnRunner(_ item: ProjectSession) {
    guard canOpenOnRunner(item) else { return }
    item.session.handOver(to: nil)
    remove(item)
    if sessions.isEmpty { workspace.window?.close() }
  }

  func canOpenOnRunner(_ item: ProjectSession) -> Bool {
    runner != nil && item.session.isOnRunner && item.session.canHandOver
  }

  /// Bring Back, on the runner's own Drakar: the session goes back to the Mac that started
  /// it, whose Drakar attaches on `released`. Shown read-only here from then on, as every
  /// session a Mac owns is.
  func bringBack(_ item: ProjectSession) {
    guard let origin = bringBackDestination(item), let id = item.session.hostID else { return }
    item.session.handOver(to: origin)
    remove(item)
    Task {
      guard let held = await sessionHost?.listed() else { return }
      await adoptHeld(held.filter { $0.id == id })
    }
  }

  /// The Mac Bring Back sends `item` to: the one that started it on this runner. Nil when it
  /// was started here, or this window reaches its host as a runner.
  func bringBackDestination(_ item: ProjectSession) -> String? {
    guard runner == nil, sessionHost?.isRunner == false, item.session.canHandOver else {
      return nil
    }
    return item.session.origin
  }

  /// Take Over Here, on the runner's own Drakar, for a row showing read-only a session a Mac
  /// owns: taken while that Mac does not hold it, and this Mac's from then on, so that Mac
  /// leaves it alone when it comes back. Nil once taken, or the process gone (the row
  /// settles as for any `released`); else why not: the Mac holds it now, or the host could
  /// not give it.
  func takeOver(_ item: ProjectSession) async -> String? {
    guard canTakeOver(item), let id = item.session.heldElsewhere,
      let owner = item.session.belongsTo, !adopting.contains(id)
    else { return nil }
    let inUse = String(localized: "In use on \(owner)")
    let unreachable = String(localized: "Drakar can't reach the session host.")
    guard let held = await sessionHost?.listed() else { return unreachable }
    guard let process = held.first(where: { $0.id == id }) else { return nil }
    guard process.attachedApp == nil else { return inUse }
    adopting.insert(id)
    defer { adopting.remove(id) }
    guard let session = await reattached(process) else {
      return isStopped ? nil : unreachable
    }
    // The row stays as it was.
    guard !session.isOutOfReach else {
      // That Mac attached meanwhile.
      if session.refusedAsHeldElsewhere { return inUse }
      return String(
        localized:
          "Drakar could not take this session over: the session host would not give its process back. It runs on there, still \(owner)'s."
      )
    }
    adopt(session, replacing: id)
    session.claim()
    return nil
  }

  /// A runner's session taken over on the runner while this Mac was away (spec §5): its tab
  /// closes, the window with its last, and a notice says where it went.
  private func takenOver(_ item: ProjectSession) {
    remove(item)
    if sessions.isEmpty { workspace.window?.close() }
    noticeTakenOver(item, sessionHost?.runnerName ?? String(localized: "the runner"))
  }

  func canTakeOver(_ item: ProjectSession) -> Bool {
    runner == nil && item.session.heldElsewhere != nil && item.session.belongsTo != nil
  }

  /// `replacing`: the host's id for the process a read-only row shows, which the session
  /// takes the place of.
  private func adopt(_ session: AgentSession, replacing hostID: String? = nil) {
    let item = make(session)
    let replaced = sessions.firstIndex { row in
      if let hostID, row.session.heldElsewhere == hostID { return true }
      guard !row.session.isProcessRunning else { return false }
      if let id = session.sessionID, row.sessionID == id { return true }
      return sessions.count == 1 && isBlank(row)
    }
    if let replaced {
      let row = sessions[replaced]
      item.draft = row.draft
      item.attachments = row.attachments
      item.dismissedAsk = row.dismissedAsk
      item.preview = row.preview
      sessions[replaced] = item
      marked.remove(row.id)
      if selectedID == row.id { selectedID = item.id }
    } else {
      // Where a new session opens: a tab taken back or opened again lands by the one shown.
      sessions.insert(item, at: opensAt)
    }
    if selectedID == nil { selectedID = item.id }
    session.reportReplayedCommands()
    // Its process, under the host, is this app's own now, not another app's live session.
    if session.isHosted { SessionMonitor.shared.hostedChanged() }
    Attention.shared.refresh()
  }

  /// A new session never started, nothing typed in it.
  private func isBlank(_ item: ProjectSession) -> Bool {
    item.session.phase == .idle && item.session.resuming == nil
      && !item.session.status.hasEntries && item.draft.isEmpty
      && item.attachments.isEmpty
  }

  /// End Session: stops the process; the row stays, and its next prompt resumes it, or starts
  /// anew on a runner. A stop asked for reports no exit, so its slot in a batch is freed here.
  /// The one way a runner's session ends; every other stop lets it go (spec §4).
  func end(_ item: ProjectSession) {
    item.session.stop(ending: true)
    fanOutFinished(item)
  }

  /// Another process took `item` up: its process here stops.
  func gaveWay(_ item: ProjectSession) {
    item.session.stop()
    fanOutFinished(item)
    Attention.shared.continuedElsewhere(item, in: self)
  }

  func remove(_ item: ProjectSession) {
    drop(item) { $0.stop() }
  }

  /// Closing a tab (session tabs spec, Closing): its session at work goes on in the session
  /// host, marked closed, and ends with its turn (`AgentSession.closeTab()`); an idle one
  /// stops as a removed row's does. The row goes either way. What closing would lose is
  /// `closeAsk(for:)`'s, asked before.
  func closeTab(_ item: ProjectSession) {
    let sessionID = item.session.sessionID
    let hostID = item.session.hostID
    var marked = false
    drop(item) { marked = $0.closeTab() }
    guard marked, let sessionID, let hostID else { return }
    closedAtWork[sessionID] = hostID
    watchReleases()
    // Under the host and no longer this app's row: the registry lists it as elsewhere now.
    SessionMonitor.shared.hostedChanged()
  }

  /// What closing `item`'s tab would lose, for the window to ask about first; nil when
  /// nothing. The draft is said first: the turn is lost only with no host to hand it to.
  /// `draftConfirmed` once the person agreed to lose the draft, for what else to ask.
  func closeAsk(for item: ProjectSession, draftConfirmed: Bool = false) -> CloseAsk? {
    if !draftConfirmed, hasUnsent(item) { return .unsentDraft }
    if item.session.isAtWork, !item.session.isHosted { return .stopsTurn }
    return nil
  }

  /// Close Other Tabs: every tab but `item` closes as `closeTab` closes it, except those that
  /// would ask first (`closeAsk(for:)`), which stay open: one menu item is no place for a
  /// dialog per tab, and nothing is lost unasked.
  func closeOthers(than item: ProjectSession) {
    closeQuietly(sessions.filter { $0.id != item.id }, keeping: item)
  }

  /// Close Tabs to the Right: the tabs right of `item`, as `closeOthers(than:)` closes them.
  func closeToTheRight(of item: ProjectSession) {
    guard let index = sessions.firstIndex(where: { $0.id == item.id }) else { return }
    closeQuietly(Array(sessions[(index + 1)...]), keeping: item)
  }

  /// `items` closed but for those that would ask. The shown tab among them gives way to
  /// `item` first, so that no tab on its way out is shown and read in between.
  private func closeQuietly(_ items: [ProjectSession], keeping item: ProjectSession) {
    let closing = items.filter { closeAsk(for: $0) == nil }
    if closing.contains(where: { $0.id == selectedID }) { select(item) }
    for other in closing { closeTab(other) }
  }

  /// `item`'s row out of the window once `stop` has let its session go. Shown, its
  /// `neighbour` is shown in its place.
  private func drop(_ item: ProjectSession, stopping stop: (AgentSession) -> Void) {
    // Only while waiting out its own stale relay: a `detach` sent on a live connection is never
    // answered `released` to this app, and a Bring Back after it is for this window to take.
    // Handed over, its owner is gone, and a Bring Back of it is this window's too.
    if item.session.isOnRunner, item.session.owner != nil, item.session.isReconnecting,
      let id = item.session.hostID
    {
      closedHere.insert(id)
    }
    stop(item.session)
    if selectedID == item.id { selectedID = neighbour(of: item)?.id }
    sessions.removeAll { $0.id == item.id }
    marked.remove(item.id)
    fanOutFinished(item)
    if let selected { load(selected) }
    Attention.shared.refresh()
  }

  /// `handingOver` when the window goes: the sessions at work carry on in the session host.
  /// A runner's carry on there whatever the stop, at work or idle.
  func stopAll(handingOver: Bool = false) {
    isStopped = true
    for item in sessions { item.session.stop(handingOver: handingOver) }
    releaseCapabilities()
  }

  /// Rows that want the person at a level that counts: the group's header.
  var waitingCount: Int {
    let counts = { AttentionChoice.isOn($0, .counts) }
    return sessions.count { $0.urgency.map(counts) ?? false }
      + groups.elsewhere.count { urgency(of: $0).map(counts) ?? false }
  }

  /// Sessions mid-turn.
  var runningCount: Int { sessions.count { $0.session.status.isRunning } }

  /// Sessions mid-turn that closing the window would interrupt: the session host keeps the
  /// others working.
  var stoppedByClosing: Int { RunningSessions.stoppedByLeaving(sessions.map(\.session)) }

  /// The window's own rows; a watched one is not kept.
  var held: [ProjectSession] { sessions.filter { !$0.isWatching } }

  var stored: StoredProject {
    // A session elsewhere that ended will not ask again from that message.
    let ended = Set(groups.ended.map(\.sessionID))
    let dismissed =
      held.compactMap { item -> (String, String)? in
        guard let id = item.sessionID, let message = item.dismissedAsk else { return nil }
        return (id, message)
      } + dismissedElsewhere.filter { !ended.contains($0.key) }.map { ($0.key, $0.value) }
    // Batches not yet restored are kept as they were stored.
    let batches = fanOuts.map(storedFanOut) + storedFanOuts
    // Only an unsent fork's draft is read, so only typing there writes the window again.
    let forks = held.compactMap { item -> StoredFork? in
      let session = item.session
      guard session.savedTarget == nil, session.status.session == nil,
        let target = session.resuming, target.forks == true
      else { return nil }
      return StoredFork(target: target, name: session.name, draft: item.draft)
    }
    return StoredProject(
      sessions: held.compactMap(\.session.savedTarget),
      selected: selected.flatMap { $0.isWatching ? nil : $0.session.savedTarget?.sessionID },
      dismissedQuestions: dismissed.isEmpty
        ? nil : Dictionary(dismissed, uniquingKeysWith: { first, _ in first }),
      documents: workspace.documents.isEmpty ? nil : workspace.documents.map(\.path),
      activeDocument: workspace.active?.path,
      focusedPane: workspace.focusedPane,
      sessionOrder: sessionOrder == .opened ? nil : sessionOrder,
      movesOnAfterReply: movesOnAfterReply ? true : nil,
      fanOuts: batches.isEmpty ? nil : batches,
      pendingForks: forks.isEmpty ? nil : forks)
  }

  private func make(_ session: AgentSession) -> ProjectSession {
    if let executableOverride { session.executableOverride = executableOverride }
    session.windowFolder = folder
    session.runner = runner
    if let sessionHost { session.sessionHost = sessionHost }
    // Asked again at each spawn: the runner may be reached by then, though it was not now.
    if runner != nil { session.currentHost = { [weak self] in self?.sessionHost } }
    let item = ProjectSession(session: session)
    session.onTurnEnded = { [weak self, weak item] in
      guard let self, let item else { return }
      self.fanOutFinished(item)
      if item.id != self.selectedID { item.isUnread = true }
      self.readRolloutDate(item)
      Attention.shared.turnEnded(item, in: self)
    }
    // A start that failed reports no stop: its slot in a batch is freed all the same.
    session.onFailed = { [weak self, weak item] in
      guard let self, let item else { return }
      self.fanOutFinished(item)
    }
    session.onPermissionRequested = { [weak self, weak item] in
      guard let self, let item else { return }
      Attention.shared.permissionRequested(item, in: self)
    }
    session.onPermissionsChanged = { Attention.shared.refresh() }
    session.onTakenOver = { [weak self, weak item] in
      guard let self, let item else { return }
      self.takenOver(item)
    }
    session.onPromptSent = { Attention.shared.refresh() }
    session.onReplied = { [weak self, weak item] in
      guard let self, let item else { return }
      self.replied(item)
    }
    session.onStopped = { [weak self, weak item] in
      Attention.shared.refresh()
      guard let self, let item else { return }
      self.fanOutFinished(item)
      guard item.id != self.selectedID, item.hasStopped else { return }
      item.isUnread = true
    }
    session.onInitialized = { [weak self, weak session] reply in
      guard let self, let session, self.speaksForProject(session),
        let skills = ProjectCapabilities.skills(fromInitialize: reply)
      else { return }
      self.capabilities.sessionReported(
        skills: skills, commands: ProjectCapabilities.commands(fromInitialize: reply))
    }
    session.onCommandsChanged = { [weak self, weak session] commands in
      guard let self, let session, self.speaksForProject(session),
        let skills = ProjectCapabilities.skills(fromInitialize: .object(["commands": commands]))
      else { return }
      self.capabilities.sessionReported(
        skills: skills, commands: ProjectCapabilities.commands(fromInitialize: commands))
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
    guard target.agentKind == .claude else { return readRolloutDate(item) }
    let (file, account) = (target.transcriptFile, target.account)
    Task { [weak item] in
      let summary = await Task.detached { SessionIndex.summary(of: file, account: account) }.value
      item?.preview = summary
      Attention.shared.refresh()
    }
  }

  /// A Codex row's last activity, off the main thread: its rollout file's date, as a Claude
  /// row's comes with its transcript's summary. Nothing watches Codex's files, so it is read
  /// again when a turn ends, by which point Codex has written the turn.
  private func readRolloutDate(_ item: ProjectSession) {
    guard let target = item.session.savedTarget ?? item.session.resuming,
      target.agentKind == .codex, !target.file.isEmpty
    else { return }
    let file = target.transcriptFile
    Task { [weak item] in
      let date = await Task.detached {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      }.value
      item?.rolloutModified = date
    }
  }
}
