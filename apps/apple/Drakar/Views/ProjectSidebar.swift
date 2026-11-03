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
    if project.runner != nil {
      // A runner's folder has no files here (remote sessions spec §4): its sessions alone.
      SessionListView(project: project, isCollapsed: $sessionsCollapsed)
    } else {
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
}

/// The project's sessions this window does not hold as tabs: those live elsewhere, and those
/// ended. A row opens in the window's preview tab. Elsewhere keeps the order its summaries
/// come in unless the window sorts it (`SessionOrder`), when a row moves as soon as its state
/// does: what wants the person rises. A skill running in each subfolder shows its progress
/// on top.
struct SessionListView: View {
  let project: Project
  @Binding var isCollapsed: Bool
  /// The default agent, observed so the New Session button's labels follow Settings.
  @AppStorage(PreferenceKey.defaultAgent) private var defaultAgentRaw = AgentKind.claude.rawValue
  private var defaultAgent: AgentKind { AgentKind(rawValue: defaultAgentRaw) ?? .claude }
  /// The list keeps ↑ and ↓ while they move through its rows, each opened in the preview
  /// tab; a click hands the keys to the composer.
  @FocusState private var isFocused: Bool
  private var monitor: SessionMonitor { .shared }

  private var groups: ProjectGroups { project.listedGroups }

  var body: some View {
    VStack(spacing: 0) {
      header
      if !isCollapsed { list }
    }
    // This Mac's transcripts under the path are none of a runner's folder's.
    .task {
      if project.runner == nil {
        await monitor.include(folder: project.folder.path(percentEncoded: false))
      }
    }
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
    let groups = groups
    return List {
      if !project.fanOuts.isEmpty {
        Section {
          ForEach(project.fanOuts) { batch in
            FanOutBanner(batch: batch) { project.cancelFanOut(batch) }
          }
        }
      }
      if !groups.elsewhere.isEmpty {
        Section("Elsewhere") {
          ForEach(groups.elsewhere) { summary in
            SummaryRow(
              summary: summary, host: monitor.host(of: summary),
              urgency: project.urgency(of: summary), monitor: monitor
            )
            .pressableRow(isSelected: project.isWatched(summary)) {
              open(summary) { project.openElsewhere(summary) }
            }
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
              .pressableRow(isSelected: project.isWatched(summary)) {
                open(summary) { project.openEnded(summary) }
              }
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
    .animation(.snappy, value: groups.elsewhere.map(\.sessionID))
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    // The list had the keys at the last quit: it takes them back.
    .onAppear { if project.claimsRestoredFocus(.sidebar) { isFocused = true } }
    .onChange(of: isFocused) { _, focused in
      if focused { project.workspace.focusedPane = .sidebar }
    }
    .onKeyPress(.downArrow) { project.stepSidebar(1) ? .handled : .ignored }
    .onKeyPress(.upArrow) { project.stepSidebar(-1) ? .handled : .ignored }
    .accessibilityIdentifier("sessions")
  }

  /// A row opened in the window's preview tab; the second click of a double click keeps it
  /// there as a tab of the window's own, as a double click on the preview tab does.
  private func open(_ summary: SessionSummary, with action: () -> Void) {
    action()
    guard (NSApp.currentEvent?.clickCount ?? 1) >= 2,
      let item = project.session(withID: summary.sessionID), item.isWatching
    else { return }
    project.promote(item)
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
    } else if session.status.isRunning {
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
