import AppKit
import DrakarKit
import SwiftUI

/// The project's sessions over its files, the split and which panes are folded away kept
/// per window.
struct ProjectSidebar: View {
  let project: Project
  @SceneStorage("drakar.sessionsFraction") private var fraction = 0.38
  @SceneStorage("drakar.sessionsCollapsed") private var sessionsCollapsed = false
  @SceneStorage("drakar.filesCollapsed") private var filesCollapsed = false

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

/// The sessions this window holds. Rows keep their order whatever their state does, so a
/// row never moves under the pointer.
struct SessionListView: View {
  let project: Project
  @Binding var isCollapsed: Bool
  @State private var showsEnded = false
  @State private var showsAllEnded = false
  /// Read only to redraw the account badges when a pick or the Settings default changes.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""
  /// The list takes the arrow keys once one of the window's rows is clicked, as the native
  /// selection did.
  @FocusState private var isFocused: Bool
  private var monitor: SessionMonitor { .shared }

  private var groups: ProjectGroups {
    let folder = ProjectPath.normalize(project.folder.path(percentEncoded: false))
    let others = OpenSessions.shared.folders.filter { $0 != folder }
    let attached = Set(project.held.compactMap(\.sessionID))
    let inOtherWindows = Set(
      OpenSessions.shared.projects.values.filter { $0 !== project }
        .flatMap { $0.held.compactMap(\.sessionID) })
    return ProjectSessions.group(
      monitor.summaries(under: folder), folder: folder, otherFolders: others,
      attached: attached, inOtherWindows: inOtherWindows, checkout: monitor.checkout(of:))
  }

  var body: some View {
    let _ = (picks, settingsAccount)
    VStack(spacing: 0) {
      header
      if !isCollapsed { list }
    }
    .task { await monitor.include(folder: project.folder.path(percentEncoded: false)) }
  }

  private var header: some View {
    PaneHeader(
      title: String(localized: "Sessions"), systemImage: "bubble.left.and.bubble.right",
      isCollapsed: $isCollapsed,
      help: isCollapsed ? String(localized: "Show sessions") : String(localized: "Hide sessions"),
      identifier: "sessions.header", isFirst: true
    ) {
      if project.waitingCount > 0 {
        Text(project.waitingCount, format: .number)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .background(.blue, in: Capsule())
          .help("Wants you: \(project.waitingCount)")
          .accessibilityLabel("\(project.waitingCount) waiting for you")
          .accessibilityIdentifier("sessions.waiting")
      }
      Button("New Session", systemImage: "plus") { project.newSession() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("New session (⌘N)")
        .accessibilityIdentifier("sessions.new")
    }
  }

  private var list: some View {
    List {
      Section("This Window") {
        ForEach(project.held) { item in
          SessionRow(
            item: item, isSelected: item.id == project.selectedID,
            windowAccount: AccountStore.shared.windowAccount(for: project.folder)
          )
          .contentShape(Rectangle())
          .onTapGesture {
            project.select(item, focusingComposer: false)
            isFocused = true
          }
          .selectionBorder(item.id == project.selectedID)
          .contextMenu { menu(for: item) }
          .accessibilityIdentifier("sessions.attached.\(item.sessionID ?? item.id.uuidString)")
        }
      }
      let groups = groups
      if !groups.elsewhere.isEmpty {
        Section("Elsewhere") {
          ForEach(groups.elsewhere) { summary in
            SummaryRow(summary: summary, host: monitor.host(of: summary), monitor: monitor)
              .contentShape(Rectangle())
              .onTapGesture { openElsewhere(summary) }
              .selectionBorder(isWatched(summary))
              .accessibilityAddTraits(.isButton)
              .accessibilityIdentifier("sessions.elsewhere.\(summary.sessionID)")
          }
        }
      }
      if !groups.ended.isEmpty {
        Section(isExpanded: $showsEnded) {
          ForEach(showsAllEnded ? groups.ended : Array(groups.ended.prefix(20))) { summary in
            SummaryRow(summary: summary, host: nil, monitor: monitor)
              .contentShape(Rectangle())
              .selectionBorder(isWatched(summary))
              .onTapGesture { openEnded(summary) }
              .accessibilityAddTraits(.isButton)
              .accessibilityIdentifier("sessions.ended.\(summary.sessionID)")
          }
          if groups.ended.count > 20, !showsAllEnded {
            Button("Show All \(groups.ended.count)") { showsAllEnded = true }
              .buttonStyle(.link)
          }
        } header: {
          Text("Ended (\(groups.ended.count))")
        }
      }
    }
    .listStyle(.sidebar)
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    // The list had the keys at the last quit: it takes them back.
    .onAppear { if project.claimsRestoredFocus(.sessions) { isFocused = true } }
    .onChange(of: isFocused) { _, focused in
      if focused { project.workspace.focusedPane = .sessions }
    }
    .onKeyPress(.downArrow) { move(1) }
    .onKeyPress(.upArrow) { move(-1) }
    .accessibilityIdentifier("sessions")
  }

  /// The row above or below the selected one, in the list's order, shown as a click shows
  /// it. A session open in another Drakar window is passed over: showing it would leave
  /// this one.
  private func move(_ step: Int) -> KeyPress.Result {
    let groups = groups
    var rows: [(isSelected: Bool, show: () -> Void)] = project.held.map { item in
      (item.id == project.selectedID, { project.select(item, focusingComposer: false) })
    }
    for summary in groups.elsewhere where OpenSessions.shared.locate(summary.sessionID) == nil {
      rows.append((isWatched(summary), { openElsewhere(summary) }))
    }
    if showsEnded {
      for summary in showsAllEnded ? groups.ended : Array(groups.ended.prefix(20)) {
        rows.append((isWatched(summary), { openEnded(summary) }))
      }
    }
    guard !rows.isEmpty else { return .ignored }
    let index = rows.firstIndex(where: \.isSelected).map { $0 + step } ?? 0
    rows[min(max(index, 0), rows.count - 1)].show()
    return .handled
  }

  private func openEnded(_ summary: SessionSummary) {
    if let target = ResumeTarget(summary) { project.attach(target, watching: true) }
  }

  private func openElsewhere(_ summary: SessionSummary) {
    if let (owner, item) = OpenSessions.shared.locate(summary.sessionID) {
      owner.select(item)
      owner.workspace.window?.makeKeyAndOrderFront(nil)
    } else if let target = ResumeTarget(summary) {
      project.attach(target, watching: true, readOnly: true)
    }
  }

  /// Whether the selected row is watching `summary` here, so the list shows it selected.
  private func isWatched(_ summary: SessionSummary) -> Bool {
    guard let item = project.session(withID: summary.sessionID), item.isWatching else {
      return false
    }
    return item.id == project.selectedID
  }

  @ViewBuilder private func menu(for item: ProjectSession) -> some View {
    if item.closingAsk != nil {
      Button("Dismiss") { project.dismissAsk(item) }
      Divider()
    }
    if item.session.isProcessRunning {
      Button("End Session") { confirmIfRunning(item) { project.end(item) } }
    }
    Button("Remove from Window") { confirmIfRunning(item) { project.remove(item) } }
    if let file = item.session.savedTarget?.transcriptFile {
      Divider()
      Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
  }

  /// Mid-turn, stopping loses the turn: ask first.
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

extension View {
  /// The selected row's outline, in place of the list's filled highlight, and its trait.
  fileprivate func selectionBorder(_ isSelected: Bool) -> some View {
    listRowBackground(
      isSelected
        ? RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5)
          .padding(.horizontal, 8) : nil
    )
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// One attached session: what it is doing, and its title.
struct SessionRow: View {
  let item: ProjectSession
  let isSelected: Bool
  /// The account new sessions in this window start under.
  let windowAccount: ClaudeAccount

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
    guard let account = item.session.effectiveAccount, account.key != windowAccount.key
    else { return nil }
    return account
  }

  private var detail: String? {
    var parts: [String] = []
    if let lead = item.wants ?? item.stopReason { parts.append(lead) }
    if let when = item.lastActivity {
      parts.append(when.formatted(.relative(presentation: .named)))
    }
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

/// A session this window does not hold: live elsewhere, or ended.
struct SummaryRow: View {
  let summary: SessionSummary
  /// Where it is live, or nil for an ended one.
  let host: String?
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
    // Another window's own child has no registry entry: its row knows.
    if let (_, item) = OpenSessions.shared.locate(summary.sessionID) {
      let state = RowState(item)
      return state == .elsewhere ? .idle : state
    }
    return switch summary.live?.status {
    case "busy": summary.awaitsToolResult ? .runningTool : .working
    case "waiting": .waiting
    default: .idle
    }
  }

  private var detail: String {
    let when = (summary.live?.updatedAt ?? summary.modified)
      .formatted(.relative(presentation: .named))
    var parts = [when]
    let waiting =
      OpenSessions.shared.locate(summary.sessionID)?.1.waitingFor ?? summary.live?.waitingFor
    if let waiting { parts.insert(waiting, at: 0) }
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

  /// What an attached session is doing.
  init(_ item: ProjectSession) {
    let session = item.session
    if let urgency = item.urgency {
      self =
        switch urgency {
        case .permission: .waiting
        case .choice: .choosing
        case .question: .asked
        case .offer: .offered
        }
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
