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
  let id = UUID()
  let skillName: String
  let prompt: String
  var queue: FanOut<UUID>

  init(skillName: String, prompt: String, queue: FanOut<UUID>) {
    self.skillName = skillName
    self.prompt = prompt
    self.queue = queue
  }
}

/// What one prompt to the marked sessions did: how many took it, and how many could not.
struct BroadcastResult: Equatable {
  var sent: Int
  var skipped: Int
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
    for entry in session.transcript.entries {
      if case .prompt(let text) = entry.kind { return String(text.prefix(80)) }
    }
    if let preview = unloadedPreview, let title = preview.title ?? preview.lastPrompt {
      return String(title.prefix(80))
    }
    return nil
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
      return pending.request.isChoice || pending.request.isPlan ? .choice : .permission
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
    if let pending = session.transcript.pendingPermissions.first, pending.request.isPlan {
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

  /// Nothing worth bringing back: no session, no tab, and no sort or switch chosen.
  var isEmpty: Bool {
    sessions.isEmpty && documents?.isEmpty != false && sessionOrder == nil
      && movesOnAfterReply == nil
  }
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
    all[path(of: folder)] = stored.isEmpty ? nil : stored
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
  /// How the sidebar lists the window's own rows and Elsewhere's.
  var sessionOrder: SessionOrder = .opened
  /// Next After Replying: a reply to the shown session shows the next one wanting the person.
  var movesOnAfterReply = false
  /// Per session live elsewhere, the message id of the ask dismissed, kept with the window's
  /// own in `StoredProject.dismissedQuestions`.
  private(set) var dismissedElsewhere: [String: String] = [:]
  /// Whether the shown session's composer takes the focus when it appears: not when the
  /// sidebar's arrow keys chose it, so the keys keep moving in the list.
  @ObservationIgnored private(set) var focusesComposer = true
  /// While `broadcast` sends: a prompt to the marked rows doesn't move on.
  @ObservationIgnored private var isBroadcasting = false
  /// Stands in for the located binary in every session this window makes, in tests.
  @ObservationIgnored var executableOverride: URL?
  /// Where the sessions this window doesn't hold are listed from; tests give it their own.
  @ObservationIgnored var monitor = SessionMonitor.shared
  /// Where the window's sessions run and come back from; tests give their own.
  @ObservationIgnored var sessionHost = SessionHost.shared
  /// The session host's processes being taken back, so that two calls take each once.
  @ObservationIgnored private var adopting: Set<String> = []
  /// The batches still sending or running, one banner each; not saved with the window.
  private(set) var fanOuts: [FanOutBatch] = []
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

  init(folder: URL, restoring stored: StoredProject? = nil) {
    self.folder = folder
    workspace = Workspace(folder: folder)
    capabilities = CapabilityStore.shared.capabilities(
      for: folder, account: AccountStore.shared.windowAccount(for: folder))
    for target in stored?.sessions ?? [] {
      guard !sessions.contains(where: { $0.sessionID == target.sessionID }) else { continue }
      let folder = URL(filePath: target.cwd, directoryHint: .isDirectory)
      let item = make(AgentSession(folder: folder, resuming: target))
      item.dismissedAsk = stored?.dismissedQuestions?[target.sessionID]
      sessions.append(item)
    }
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
    let folder = ProjectPath.normalize(self.folder.path(percentEncoded: false))
    let others = OpenSessions.shared.folders.filter { $0 != folder }
    let attached = Set(held.compactMap(\.sessionID))
    let inOtherWindows = Set(
      OpenSessions.shared.projects.values.filter { $0 !== self }
        .flatMap { $0.held.compactMap(\.sessionID) })
    // Asked even when the groups are kept, so that a view reading them redraws on a change.
    let summaries = monitor.summaries(under: folder)
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

  /// The window's own rows as the sidebar lists them.
  var listedHeld: [ProjectSession] {
    sessionOrder.sorted(held) { item in
      SessionOrder.Key(
        state: RowState(item), activity: item.lastActivity,
        folder: item.session.folder.path(percentEncoded: false))
    }
  }

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

  /// A session listed elsewhere, shown: in the Drakar window that holds it, or watched here.
  func openElsewhere(_ summary: SessionSummary, focusingComposer: Bool = true) {
    if let (owner, item) = OpenSessions.shared.locate(summary.sessionID) {
      owner.select(item)
      owner.workspace.window?.makeKeyAndOrderFront(nil)
    } else if let target = ResumeTarget(summary) {
      attach(target, watching: true, readOnly: true, focusingComposer: focusingComposer)
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
      selected.session.transcript.pendingPermissions.isEmpty,
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

  /// A new session in `folder` (the project's when nil), on top, running `agent` (Settings'
  /// default when nil) under `account` (the folder's when nil), and shown unless `shows` is
  /// false. No process until it is prompted.
  @discardableResult func newSession(
    agent: AgentKind? = nil, folder: URL? = nil, account: ClaudeAccount? = nil,
    select shows: Bool = true
  ) -> ProjectSession {
    let item = make(
      AgentSession(
        folder: folder ?? self.folder, agent: agent ?? ClaudeChoice.defaultAgent,
        account: account))
    sessions.insert(item, at: 0)
    if shows { select(item) }
    return item
  }

  /// Whether a skill can go to `target`: a new session always can; the shown one only when
  /// it takes slash commands and could take a prompt now (not read-only, not mid-turn).
  func canRun(in target: SkillTarget) -> Bool {
    switch target {
    case .newSession: true
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

  /// Reads the list `fanOutSkills` gives.
  func loadFanOutSkills() {
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
    switch session.agent {
    case .claude: return capabilities.lists.commands ?? capabilities.lists.skills ?? []
    case .codex: return codexSkills(for: session).skills ?? []
    }
  }

  /// The first `/` typed in `session` reads its agent's list.
  func loadSlashCommands(for session: AgentSession) {
    guard session.features.slashCommands else { return }
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

  /// `skill` in a new session in each of `folders`, on top in their order, the first shown:
  /// named after the skill and the folder, in `mode` and under `account` when given, and
  /// sent the skill all at once or `limit` at a time.
  func runInSubfolders(
    _ skill: SkillEntry, folders: [URL], arguments: String, mode: PermissionMode?, limit: Int?,
    account: ClaudeAccount? = nil
  ) {
    guard !folders.isEmpty else { return }
    let agent = skillsAgent
    if agent == .claude { capabilityMarks.skills.remove(skill.name) }
    // Each goes on top, so the last folder first leaves them in order.
    let items = Array(
      folders.reversed().map { folder in
        let item = newSession(agent: agent, folder: folder, account: account, select: false)
        item.session.rename(to: "/\(skill.name) · \(folder.lastPathComponent)")
        if let mode { item.session.setMode(mode) }
        return item
      }.reversed())
    if let first = items.first { select(first) }
    let arguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    let batch = FanOutBatch(
      skillName: skill.name,
      prompt: arguments.isEmpty ? "/\(skill.name)" : "/\(skill.name) \(arguments)",
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

  /// A click on a held row. Plain shows it and clears the marks; ⌘ marks or unmarks it
  /// (the shown row is marked with the first); ⇧ marks the rows from the last clicked to it,
  /// in the list's order. Neither ⌘ nor ⇧ changes the row shown.
  func click(_ item: ProjectSession, _ kind: RowClick) {
    lastBroadcast = nil
    switch kind {
    case .plain:
      marked = []
      markAnchor = item.id
      select(item)
    case .toggle:
      if marked.isEmpty, let selectedID, selectedID != item.id { marked = [selectedID] }
      if marked.remove(item.id) == nil { marked.insert(item.id) }
      markAnchor = item.id
    case .extend:
      let rows = listedHeld.map(\.id)
      guard let end = rows.firstIndex(of: item.id) else { return }
      let start = (markAnchor ?? selectedID).flatMap { rows.firstIndex(of: $0) } ?? end
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

  /// The marked rows still held, in the list's order.
  var markedSessions: [ProjectSession] { listedHeld.filter { marked.contains($0.id) } }

  /// How many marked rows are still held. Counted without `markedSessions`, whose sort
  /// reads every row's state and so redraws the composer on any row's delta.
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

  /// Takes every marked session out of the window.
  func removeMarked() {
    for item in markedSessions { remove(item) }
    marked = []
  }

  /// `item` ended a turn or stopped: its slot goes to the next waiting session.
  private func fanOutFinished(_ item: ProjectSession) {
    for batch in fanOuts { send(batch.queue.finished(item.id), in: batch) }
    fanOuts.removeAll { $0.queue.isDone }
  }

  /// Sends `batch`'s prompt to `ids`; one closed meanwhile passes its slot on.
  private func send(_ ids: [UUID], in batch: FanOutBatch) {
    for id in ids {
      guard let item = sessions.first(where: { $0.id == id }) else {
        send(batch.queue.finished(id), in: batch)
        continue
      }
      item.session.send(batch.prompt)
    }
  }

  /// Hiding the inspector after it was on screen: everything was seen.
  func clearCapabilityMarks() {
    capabilityMarks = CapabilityMarks()
  }

  /// A server row was opened.
  func unmarkServer(_ name: String) {
    capabilityMarks.servers.remove(name)
  }

  /// The window's account may be another now: the lists follow it.
  func accountMayHaveChanged() {
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
  /// are Claude Code's: a Codex session never speaks for them.
  func speaksForProject(_ session: AgentSession) -> Bool {
    ProjectPath.normalize(session.folder.path(percentEncoded: false))
      == ProjectPath.normalize(folder.path(percentEncoded: false))
      && session.agent == .claude && session.account?.key == capabilities.accountKey
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

  /// `target` on top and shown, or the row already holding it, taken over unless
  /// `watching`. `readOnly` while another process has it open.
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
    sessions.insert(item, at: 0)
    select(item, focusingComposer: focusingComposer)
    return item
  }

  /// "Pineapple (fork #2)" for a copy of `target`: its title, numbered after every fork of
  /// it the folder lists, in the window's rows and on disk. Nil when it has no title yet.
  private func forkName(for target: ResumeTarget) -> String? {
    let listed = monitor.summaries(
      under: ProjectPath.normalize(folder.path(percentEncoded: false)))
    let original =
      session(withID: target.sessionID)?.knownTitle
      ?? listed.first { $0.sessionID == target.sessionID }
      .flatMap { $0.title ?? $0.lastPrompt.map { String($0.prefix(80)) } }
    guard let original else { return nil }
    return SessionTitle.forkName(
      of: original, among: sessions.compactMap(\.knownTitle) + listed.compactMap(\.title))
  }

  /// A watched row becomes one of the window's own, on top: it was prompted, or attached.
  func takeOver(_ item: ProjectSession) {
    guard item.isWatching else { return }
    item.isWatching = false
    sessions.removeAll { $0.id == item.id }
    sessions.insert(item, at: 0)
  }

  /// A copy of a session open elsewhere, continued under a new id beside it. Its own
  /// transcript first: a fork still running its first process resumes its original.
  @discardableResult func fork(_ item: ProjectSession) -> ProjectSession {
    guard var target = item.session.savedTarget ?? item.session.resuming else { return item }
    target.forks = true
    return attach(target)
  }

  /// Whether `item` has a transcript to copy and no turn writing it: a fork taken mid-turn
  /// would copy a history that can end on a tool call with no result.
  func canFork(_ item: ProjectSession) -> Bool {
    item.session.features.forks
      && (item.session.resuming ?? item.session.savedTarget) != nil
      && !item.session.transcript.isRunning
  }

  var canForkSelected: Bool { selected.map(canFork) ?? false }

  /// Whether `item` can take a name: not while another process has it, or its files move.
  func canRename(_ item: ProjectSession) -> Bool {
    !item.session.isReadOnly && !item.session.isMoving
  }

  var canRenameSelected: Bool { selected.map(canRename) ?? false }

  func forkSelected() {
    if let selected, canFork(selected) { fork(selected) }
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
  /// newest 20: what the arrow keys and Previous and Next Session pass through.
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

  /// Shows the row `offset` rows from the selected one, in the sidebar's order, as a click
  /// shows it: the window's own rows, those elsewhere, then Ended's while it is expanded. A
  /// session open in another Drakar window is passed over: showing it would leave this one.
  /// `wrapping` goes round the ends (Previous and Next Session), else stops at them (the
  /// list's arrow keys, which keep the keys). False when there is no row.
  @discardableResult func step(
    _ offset: Int, wrapping: Bool, focusingComposer: Bool = true
  ) -> Bool {
    let groups = listedGroups
    var rows: [(isSelected: Bool, show: () -> Void)] = listedHeld.map { item in
      (
        item.id == selectedID,
        { [unowned self] in
          select(item, focusingComposer: focusingComposer)
          // The row shown already keeps its composer, which only focuses itself on appearing.
          if focusingComposer { item.focusRequest += 1 }
        }
      )
    }
    for summary in groups.elsewhere where OpenSessions.shared.locate(summary.sessionID) == nil {
      rows.append(
        (
          isWatched(summary),
          { [unowned self] in openElsewhere(summary, focusingComposer: focusingComposer) }
        ))
    }
    if showsEnded {
      for summary in listedEnded(groups) {
        rows.append(
          (
            isWatched(summary),
            { [unowned self] in openEnded(summary, focusingComposer: focusingComposer) }
          ))
      }
    }
    guard !rows.isEmpty else { return false }
    let current = rows.firstIndex(where: \.isSelected)
    let index =
      switch (current, wrapping) {
      case (nil, _): offset < 0 && wrapping ? rows.count - 1 : 0
      case (let current?, true): ((current + offset) % rows.count + rows.count) % rows.count
      case (let current?, false): min(max(current + offset, 0), rows.count - 1)
      }
    rows[index].show()
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

  /// The next row after the selected one that wants the person, in the list's order as
  /// sorted (the window's own, then those elsewhere unless `ownRowsOnly`): the most urgent
  /// level that counts first, then unread, wrapping. Never the selected row.
  func nextNeedingAttention(ownRowsOnly: Bool = false) -> Stop? {
    let watched = selected.flatMap { $0.isWatching ? $0.sessionID : nil }
    var rows: [(stop: Stop, level: Urgency?, isUnread: Bool, isSelected: Bool)] = listedHeld.map {
      (.row($0), $0.urgency, $0.isUnread, $0.id == selectedID)
    }
    let elsewhere = ownRowsOnly ? [] : listedGroups.elsewhere
    for summary in elsewhere where summary.live != nil {
      rows.append(
        (.elsewhere(summary), urgency(of: summary), false, summary.sessionID == watched))
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

  /// The processes the session host holds for this window and no app has (spec §3
  /// Relaunch), back as rows, live. The row the window kept for the same session gives way
  /// to one, as does the blank row a window opens with when it has nothing else.
  func adoptHeld(_ held: [HeldProcess]) async {
    let own = ProjectPath.normalize(folder.path(percentEncoded: false))
    let ids = held.compactMap { process -> String? in
      guard process.attachedApp == nil, !adopting.contains(process.id),
        !sessions.contains(where: { $0.session.hostID == process.id }),
        let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta),
        ProjectPath.normalize(meta.windowFolder) == own
      else { return nil }
      return process.id
    }
    adopting.formUnion(ids)
    defer { adopting.subtract(ids) }
    for process in held where ids.contains(process.id) {
      // Asked each time: a replay before this one may have cost the connection.
      guard let client = await sessionHost.client(),
        let session = await AgentSession(reattaching: process, client: client)
      else { continue }
      adopt(session)
    }
  }

  private func adopt(_ session: AgentSession) {
    let item = make(session)
    let replaced = sessions.firstIndex { row in
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
      sessions.insert(item, at: 0)
    }
    if selectedID == nil { selectedID = item.id }
    session.reportReplayedCommands()
    Attention.shared.refresh()
  }

  /// A new session never started, nothing typed in it.
  private func isBlank(_ item: ProjectSession) -> Bool {
    item.session.phase == .idle && item.session.resuming == nil
      && item.session.transcript.entries.isEmpty && item.draft.isEmpty
      && item.attachments.isEmpty
  }

  /// Stops the process; the row stays, and its next prompt resumes it. A stop asked for
  /// reports no exit, so its slot in a batch is freed here.
  func end(_ item: ProjectSession) {
    item.session.stop()
    fanOutFinished(item)
  }

  /// Another process took `item` up: its process here stops.
  func gaveWay(_ item: ProjectSession) {
    item.session.stop()
    fanOutFinished(item)
    Attention.shared.continuedElsewhere(item, in: self)
  }

  func remove(_ item: ProjectSession) {
    item.session.stop()
    sessions.removeAll { $0.id == item.id }
    marked.remove(item.id)
    fanOutFinished(item)
    if selectedID == item.id { selectedID = sessions.first?.id }
    if let selected { load(selected) }
    Attention.shared.refresh()
  }

  func stopAll() {
    for item in sessions { item.session.stop() }
    releaseCapabilities()
  }

  /// Rows that want the person at a level that counts: the group's header.
  var waitingCount: Int {
    let counts = { AttentionChoice.isOn($0, .counts) }
    return sessions.count { $0.urgency.map(counts) ?? false }
      + groups.elsewhere.count { urgency(of: $0).map(counts) ?? false }
  }

  /// Sessions mid-turn: what closing the window would interrupt.
  var runningCount: Int { sessions.count { $0.session.transcript.isRunning } }

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
    return StoredProject(
      sessions: held.compactMap(\.session.savedTarget),
      selected: selected.flatMap { $0.isWatching ? nil : $0.session.savedTarget?.sessionID },
      dismissedQuestions: dismissed.isEmpty
        ? nil : Dictionary(dismissed, uniquingKeysWith: { first, _ in first }),
      documents: workspace.documents.isEmpty ? nil : workspace.documents.map(\.path),
      activeDocument: workspace.active?.path,
      focusedPane: workspace.focusedPane,
      sessionOrder: sessionOrder == .opened ? nil : sessionOrder,
      movesOnAfterReply: movesOnAfterReply ? true : nil)
  }

  private func make(_ session: AgentSession) -> ProjectSession {
    if let executableOverride { session.executableOverride = executableOverride }
    session.windowFolder = folder
    session.sessionHost = sessionHost
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
    session.onPermissionRequested = { [weak self, weak item] _ in
      guard let self, let item else { return }
      Attention.shared.permissionRequested(item, in: self)
    }
    session.onPermissionsChanged = { Attention.shared.refresh() }
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
