import AppKit
import DrakarKit
import SwiftUI

/// The project's sessions over its files, the split and which panes are folded away kept
/// per window. A new window starts with the files folded to the foot: sessions are what it
/// is for.
struct ProjectSidebar: View {
  let project: Project
  @SceneStorage("drakar.sessionsFraction") private var fraction = 0.38
  @SceneStorage("drakar.sessionsCollapsed") private var sessionsCollapsed = false
  @SceneStorage("drakar.filesCollapsed") private var filesCollapsed = true

  var body: some View {
    VerticalSplit(
      fraction: $fraction, collapsesTop: sessionsCollapsed, collapsesBottom: filesCollapsed
    ) {
      SessionListView(project: project, isCollapsed: $sessionsCollapsed)
    } bottom: {
      FileTreeView(workspace: project.workspace, isCollapsed: $filesCollapsed)
    }
    .focusedSceneValue(\.filesCollapsed, $filesCollapsed)
  }
}

/// The sessions this window holds. Rows keep the order they came in unless the window sorts
/// them (`SessionOrder`), when a row moves as soon as its state does: what wants the person
/// rises.
struct SessionListView: View {
  let project: Project
  @Binding var isCollapsed: Bool
  /// Read only to redraw the account badges when a pick or the Settings default changes.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""
  /// The default agent, observed so the New Session button's labels follow Settings.
  @AppStorage(PreferenceKey.defaultAgent) private var defaultAgentRaw = AgentKind.claude.rawValue
  private var defaultAgent: AgentKind { AgentKind(rawValue: defaultAgentRaw) ?? .claude }
  /// The list keeps the arrow keys while they move through it; a click hands them to the
  /// composer.
  @FocusState private var isFocused: Bool
  private var monitor: SessionMonitor { .shared }

  private var groups: ProjectGroups { project.listedGroups }

  var body: some View {
    let _ = (picks, settingsAccount)
    VStack(spacing: 0) {
      header
      if !isCollapsed { list }
    }
    .task { await monitor.include(folder: project.folder.path(percentEncoded: false)) }
  }

  private var header: some View {
    let waiting = project.waitingCount
    return PaneHeader(
      title: String(localized: "Sessions"), systemImage: "bubble.left.and.bubble.right",
      isCollapsed: $isCollapsed,
      help: isCollapsed ? String(localized: "Show sessions") : String(localized: "Hide sessions"),
      identifier: "sessions.header", isFirst: true
    ) {
      if waiting > 0 {
        Text(waiting, format: .number)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .background(.blue, in: Capsule())
          .help("Wants you: \(waiting)")
          .accessibilityLabel("\(waiting) waiting for you")
          .accessibilityIdentifier("sessions.waiting")
      }
      Menu {
        Picker("Sort Sessions", selection: Bindable(project).sessionOrder) {
          ForEach(SessionOrder.allCases) { order in
            Text(order.label).tag(order)
          }
        }
        .pickerStyle(.inline)
        Divider()
        Toggle("Next After Replying", isOn: Bindable(project).movesOnAfterReply)
      } label: {
        Image(systemName: "arrow.up.arrow.down")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Sort sessions: \(project.sessionOrder.label)")
      .accessibilityLabel("Sort Sessions")
      .accessibilityIdentifier("sessions.order")
      Button("New Session", systemImage: "plus") {
        // ⌥-click starts the agent that is not the default.
        let other = NSEvent.modifierFlags.contains(.option)
        project.newSession(agent: other ? defaultAgent.other : nil)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help(
        "New \(defaultAgent.name) session (⌘N); ⌥-click for \(defaultAgent.other.name) (⌃⌘N)"
      )
      .contextMenu {
        ForEach(AgentKind.allCases, id: \.self) { agent in
          Button("New \(agent.name) Session") { project.newSession(agent: agent) }
        }
      }
      .accessibilityIdentifier("sessions.new")
    }
  }

  private var list: some View {
    let held = project.listedHeld
    let groups = groups
    return List {
      Section("This Window") {
        ForEach(project.fanOuts) { batch in
          FanOutBanner(batch: batch) { project.cancelFanOut(batch) }
        }
        ForEach(held) { item in
          SessionRow(
            item: item, isSelected: item.id == project.selectedID,
            windowAccount: AccountStore.shared.windowAccount(for: project.folder),
            subfolder: ProjectPath.child(
              of: item.session.folder.path(percentEncoded: false),
              below: project.folder.path(percentEncoded: false))
          )
          .pressableRow(
            isSelected: item.id == project.selectedID, isMarked: project.marked.contains(item.id)
          ) {
            let click = Self.rowClick(NSEvent.modifierFlags)
            project.click(item, click)
            // The row shown already keeps its composer, which only focuses itself on appearing.
            if click == .plain { item.focusRequest += 1 }
          }
          .contextMenu {
            if project.sendsToMarked, project.marked.contains(item.id) {
              markedMenu
            } else {
              menu(for: item)
            }
          }
          .accessibilityIdentifier("sessions.attached.\(item.sessionID ?? item.id.uuidString)")
        }
      }
      if !groups.elsewhere.isEmpty {
        Section("Elsewhere") {
          ForEach(groups.elsewhere) { summary in
            SummaryRow(
              summary: summary, host: monitor.host(of: summary),
              urgency: project.urgency(of: summary), monitor: monitor
            )
            .pressableRow(isSelected: project.isWatched(summary)) { project.openElsewhere(summary) }
            .contextMenu { menu(for: summary, ended: false) }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sessions.elsewhere.\(summary.sessionID)")
          }
        }
      }
      if !groups.ended.isEmpty {
        Section(isExpanded: Bindable(project).showsEnded) {
          ForEach(project.listedEnded(groups)) { summary in
            SummaryRow(summary: summary, host: nil, urgency: nil, monitor: monitor)
              .pressableRow(isSelected: project.isWatched(summary)) { project.openEnded(summary) }
              .contextMenu { menu(for: summary, ended: true) }
              .accessibilityAddTraits(.isButton)
              .accessibilityIdentifier("sessions.ended.\(summary.sessionID)")
          }
          if groups.ended.count > 20, !project.showsAllEnded {
            Button("Show All \(groups.ended.count)") { project.showsAllEnded = true }
              .buttonStyle(.link)
          }
        } header: {
          Text("Ended (\(groups.ended.count))")
        }
      }
    }
    .listStyle(.sidebar)
    // A row that moves slides to its place, where the eye can follow it.
    .animation(.snappy, value: held.map(\.id))
    .animation(.snappy, value: groups.elsewhere.map(\.sessionID))
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    // The list had the keys at the last quit: it takes them back.
    .onAppear { if project.claimsRestoredFocus(.sessions) { isFocused = true } }
    .onChange(of: isFocused) { _, focused in
      if focused { project.workspace.focusedPane = .sessions }
    }
    .onKeyPress(.escape) {
      guard !project.marked.isEmpty else { return .ignored }
      project.clearMarks()
      return .handled
    }
    .onKeyPress(characters: ["a"]) { press in
      guard press.modifiers == .command else { return .ignored }
      project.markAll()
      return .handled
    }
    .onKeyPress(.downArrow) { move(1) }
    .onKeyPress(.upArrow) { move(-1) }
    .accessibilityIdentifier("sessions")
  }

  private func move(_ offset: Int) -> KeyPress.Result {
    project.step(offset, wrapping: false, focusingComposer: false) ? .handled : .ignored
  }

  @ViewBuilder private func menu(for item: ProjectSession) -> some View {
    if item.closingAsk != nil {
      Button("Dismiss") { project.dismissAsk(item) }
      Divider()
    }
    Button("Rename…") { RenameSessionPrompt.run(for: item) }
      .disabled(!project.canRename(item))
    // Hidden for an agent that cannot fork (Codex), disabled while a turn runs.
    if item.session.features.forks, (item.session.resuming ?? item.session.savedTarget) != nil {
      Button("Fork a Copy") { project.fork(item) }
        .disabled(!project.canFork(item))
    }
    Divider()
    if item.session.isProcessRunning {
      Button("End Session") { confirmIfRunning(item) { project.end(item) } }
    }
    Button("Remove from Window") { confirmIfRunning(item) { project.remove(item) } }
    if let candidate = SessionMoves.candidate(for: item) {
      let others = SessionMoves.destinations(from: candidate.account)
      if !others.isEmpty {
        Divider()
        Menu("Move to") {
          ForEach(others, id: \.key) { account in
            Button(AccountStore.shared.profile(for: account).name) {
              SessionMoves.moveOne(candidate, to: account)
            }
          }
        }
      }
    }
    if item.sessionID != nil || item.session.savedTarget != nil { Divider() }
    if let id = item.sessionID { copyIDButton(id) }
    if let file = item.session.savedTarget?.transcriptFile {
      Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
  }

  /// An elsewhere row running in another process cannot move; the menu says where it runs.
  @ViewBuilder private func moveMenu(for summary: SessionSummary, host: String?) -> some View {
    let others = SessionMoves.destinations(from: summary.account)
    if !others.isEmpty {
      Menu("Move to") {
        ForEach(others, id: \.key) { account in
          Button(AccountStore.shared.profile(for: account).name) {
            SessionMoves.moveOne(SessionMoves.candidate(for: summary), to: account)
          }
          .disabled(host != nil)
        }
        if let host {
          Text("Running in \(host)")
        }
      }
    }
  }

  /// A row of Elsewhere or Ended. Resuming one live elsewhere would interleave two writers:
  /// it forks, or moves here once the app running it has been told to let it go.
  @ViewBuilder private func menu(for summary: SessionSummary, ended: Bool) -> some View {
    let showable = !ended && ShowInVSCode.canShow(summary)
    let dismissable = !ended && [.question, .offer].contains(project.urgency(of: summary))
    if showable {
      Button("Show in VS Code") { ShowInVSCode.show(summary) }
    }
    if dismissable {
      Button("Dismiss") { project.dismissAsk(summary) }
    }
    if showable || dismissable {
      Divider()
    }
    if ended, let target = ResumeTarget(summary) {
      Button("Resume in This Window") { project.attach(target) }
    }
    if !ended, summary.live != nil {
      Button("Move to This Window…") { MoveHere.confirm(summary, into: project) }
        .disabled(!Project.canMoveHere(summary))
    }
    if let target = ResumeTarget(summary, forking: true) {
      Button("Fork a Copy") { project.attach(target) }
    }
    if let watched = project.session(withID: summary.sessionID), watched.isWatching {
      Button("Close") { project.remove(watched) }
    }
    moveMenu(for: summary, host: ended ? nil : monitor.host(of: summary))
    Divider()
    copyIDButton(summary.sessionID)
    Button("Show Transcript in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([summary.file])
    }
  }

  private func copyIDButton(_ sessionID: String) -> some View {
    Button("Copy Session ID") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(sessionID, forType: .string)
    }
  }

  /// Mid-turn, stopping loses the turn: ask first.
  /// ⌘ marks one row more or less, ⇧ a range; a plain click shows the row.
  static func rowClick(_ flags: NSEvent.ModifierFlags) -> Project.RowClick {
    if flags.contains(.command) { return .toggle }
    if flags.contains(.shift) { return .extend }
    return .plain
  }

  /// What a right-click on one of several marked rows does to them all.
  @ViewBuilder private var markedMenu: some View {
    let marked = project.markedSessions
    if marked.contains(where: \.session.isProcessRunning) {
      Button("End \(marked.count) Sessions") { confirmIfRunning(marked) { project.stopMarked() } }
    }
    Button("Remove \(marked.count) Sessions from Window") {
      confirmIfRunning(marked) { project.removeMarked() }
    }
    Divider()
    Button("Unmark All") { project.clearMarks() }
  }

  /// As for one row, once for the marked rows still working.
  private func confirmIfRunning(_ items: [ProjectSession], then action: @escaping () -> Void) {
    let working = items.filter(\.session.transcript.isRunning).count
    guard working > 0 else { return action() }
    let alert = NSAlert()
    alert.messageText =
      working == 1
      ? String(localized: "1 session is still working.")
      : String(localized: "\(working) sessions are still working.")
    alert.informativeText = String(localized: "Stopping them now ends their turns part-way.")
    alert.addButton(withTitle: String(localized: "Stop"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    if alert.runModal() == .alertFirstButtonReturn { action() }
  }

  private func confirmIfRunning(_ item: ProjectSession, then action: @escaping () -> Void) {
    guard item.session.transcript.isRunning else { return action() }
    let alert = NSAlert()
    alert.messageText = String(localized: "“\(item.displayTitle)” is still working.")
    alert.informativeText = String(localized: "Stopping it now ends the turn part-way.")
    alert.addButton(withTitle: String(localized: "Stop"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    if alert.runModal() == .alertFirstButtonReturn { action() }
  }
}

/// One attached session: what it is doing, and its title.
struct SessionRow: View {
  let item: ProjectSession
  let isSelected: Bool
  /// The account new sessions in this window start under.
  let windowAccount: ClaudeAccount
  /// The project's subfolder it runs in, when not the project's own.
  var subfolder: String? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      StateDot(state: state)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(item.displayTitle)
            .lineLimit(1)
            .fontWeight(item.isUnread ? .semibold : .regular)
          if item.isUnread {
            Circle().fill(.blue).frame(width: 5, height: 5).accessibilityLabel("Unread")
          }
          if item.session.agent == .codex {
            Text("Codex")
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().fill(.quaternary))
              .accessibilityIdentifier("sessions.agent.codex")
          }
          if let other = otherAccount {
            Text(AccountStore.shared.profile(for: other).name)
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().fill(.quaternary))
              .help("Runs under the account in \(ContentView.abbreviated(other.directory))")
          }
        }
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if let gauge = item.gauge(
        accountModel: item.session.resuming.flatMap {
          SessionMonitor.shared.accountModel(for: $0.account)
        })
      {
        ContextGaugeView(gauge: gauge)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var state: RowState { RowState(item) }

  /// The session's account when it is not the window's.
  private var otherAccount: ClaudeAccount? {
    guard item.session.features.showsAccount,
      let account = item.session.effectiveAccount, account.key != windowAccount.key
    else { return nil }
    return account
  }

  private var detail: String? {
    var parts: [String] = []
    if let lead = item.wants ?? item.stopReason { parts.append(lead) }
    if let when = item.lastActivity {
      parts.append(when.formatted(.relative(presentation: .named)))
    }
    if let subfolder { parts.append(subfolder) }
    if let worktreeName { parts.append(worktreeName) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The worktree's folder name, for a session running below the project root.
  private var worktreeName: String? {
    let path = item.session.folder.path(percentEncoded: false)
    guard let range = path.range(of: "/.claude/worktrees/") else { return nil }
    return String(path[range.upperBound...].prefix { $0 != "/" })
  }
}

/// A skill running in each subfolder: how far it has got, and Cancel for those still waiting.
private struct FanOutBanner: View {
  let batch: FanOutBatch
  let cancel: () -> Void

  var body: some View {
    HStack {
      Text("/\(batch.skillName) · \(batch.queue.summary)")
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer()
      if batch.queue.count(.waiting) > 0 {
        Button("Cancel", action: cancel).buttonStyle(.link).font(.caption)
      }
    }
    .accessibilityIdentifier("sessions.fanout.\(batch.skillName)")
  }
}

/// A session this window does not hold: live elsewhere, or ended.
struct SummaryRow: View {
  let summary: SessionSummary
  /// Where it is live, or nil for an ended one.
  let host: String?
  /// How much it wants the person, from outside Drakar; nil for an ended one.
  let urgency: Urgency?
  let monitor: SessionMonitor

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      if host != nil {
        StateDot(state: state)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(summary.displayTitle).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if let gauge {
        ContextGaugeView(gauge: gauge)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var state: RowState {
    guard host != nil else { return .idle }
    return RowState(elsewhere: summary, urgency: urgency)
  }

  private var detail: String {
    let when = (summary.live?.updatedAt ?? summary.modified)
      .formatted(.relative(presentation: .named))
    var parts = [when]
    let wants =
      OpenSessions.shared.locate(summary.sessionID)?.1.wants
      ?? urgency?.wants(of: summary) ?? summary.live?.waitingFor
    if let wants { parts.insert(wants, at: 0) }
    if let host { parts.append(host) }
    if summary.live.map({ IDEBridge.shared.connectedPIDs.contains($0.pid) }) == true {
      parts.append(String(localized: "connected"))
    }
    return parts.joined(separator: " · ")
  }

  private var gauge: ContextGauge? {
    ContextGauge.make(
      usage: summary.context?.usage, reportedLimit: nil, initModelID: nil,
      attachmentModelID: summary.modelID,
      accountModelID: monitor.accountModel(for: summary.account),
      messageModelID: summary.context?.modelID)
  }
}

/// A row's state, in Claude Code's words and Armada's colours.
enum RowState {
  case working, runningTool, waiting, choosing, asked, offered, idle, notStarted, stopped, ended,
    elsewhere

  /// What a session that wants the person shows.
  init(_ urgency: Urgency) {
    self =
      switch urgency {
      case .permission: .waiting
      case .choice: .choosing
      case .question: .asked
      case .offer: .offered
      }
  }

  /// What an attached session is doing.
  init(_ item: ProjectSession) {
    let session = item.session
    if let urgency = item.urgency {
      self.init(urgency)
    } else if session.transcript.isRunning {
      self = .working
    } else if item.hasStopped {
      self = .stopped
    } else if session.isReadOnly {
      self = .elsewhere
    } else if session.isProcessRunning {
      self = .idle
    } else if case .exited = session.phase {
      self = .ended
    } else {
      self = .notStarted
    }
  }

  /// What a session live elsewhere is doing, `urgency` being how much it wants the person.
  init(elsewhere summary: SessionSummary, urgency: Urgency?) {
    // Another window's own child has no registry entry: its row knows.
    if let (_, item) = OpenSessions.shared.locate(summary.sessionID) {
      let state = RowState(item)
      self = state == .elsewhere ? .idle : state
    } else if let urgency {
      self.init(urgency)
    } else {
      self =
        switch summary.live?.status {
        case "busy": summary.awaitsToolResult ? .runningTool : .working
        case "waiting": .waiting
        default: .idle
        }
    }
  }

  /// How much a row in this state needs the person, most first: Needs Me First's levels.
  var need: Int {
    switch self {
    case .waiting: 0
    case .choosing: 1
    case .asked: 2
    case .offered: 3
    case .idle: 4
    case .stopped: 5
    case .working, .runningTool: 6
    case .notStarted, .ended, .elsewhere: 7
    }
  }

  var label: String {
    switch self {
    case .working: String(localized: "Working")
    case .runningTool: String(localized: "Probably running a tool")
    case .waiting: String(localized: "Waiting for you")
    case .choosing: String(localized: "Asks you to choose")
    case .asked: String(localized: "Asked you")
    case .offered: String(localized: "Offered")
    case .idle: String(localized: "Idle")
    case .notStarted: String(localized: "Not started")
    case .stopped: String(localized: "Stopped")
    case .ended: String(localized: "Stopped")
    case .elsewhere: String(localized: "Open elsewhere")
    }
  }

  var tint: Color {
    switch self {
    case .working: .green
    case .runningTool: .orange
    case .waiting, .choosing, .asked: .blue
    case .stopped: .red
    case .offered, .idle, .notStarted, .ended, .elsewhere: .secondary
    }
  }
}

/// A row's state as a dot: filled, or a ring for what a finished turn asked, so that a
/// blocked tool and a question read apart at a glance. Same size either way.
struct StateDot: View {
  let state: RowState

  var body: some View {
    Group {
      if state == .asked || state == .offered {
        Circle().strokeBorder(state.tint, lineWidth: 1.5)
      } else {
        Circle().fill(state.tint)
      }
    }
    .frame(width: 7, height: 7)
    .help(state.label)
  }
}
