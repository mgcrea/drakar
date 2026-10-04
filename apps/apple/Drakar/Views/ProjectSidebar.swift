import AppKit
import DrakarKit
import SwiftUI

/// The project's sessions over its files, the split kept per window.
struct ProjectSidebar: View {
  let project: Project
  @SceneStorage("drakar.sessionsFraction") private var fraction = 0.38

  var body: some View {
    VerticalSplit(fraction: $fraction) {
      SessionListView(project: project)
    } bottom: {
      FileTreeView(workspace: project.workspace)
    }
  }
}

/// The sessions this window holds. Rows keep their order whatever their state does, so a
/// row never moves under the pointer.
struct SessionListView: View {
  let project: Project
  @State private var showsEnded = false
  @State private var showsAllEnded = false
  private var monitor: SessionMonitor { .shared }

  private var groups: ProjectGroups {
    let folder = ProjectPath.normalize(project.folder.path(percentEncoded: false))
    let others = OpenSessions.shared.folders.filter { $0 != folder }
    let attached = Set(project.sessions.compactMap(\.sessionID))
    let inOtherWindows = Set(
      OpenSessions.shared.projects.values.filter { $0 !== project }
        .flatMap { $0.sessions.compactMap(\.sessionID) })
    return ProjectSessions.group(
      monitor.summaries(under: folder), folder: folder, otherFolders: others,
      attached: attached, inOtherWindows: inOtherWindows)
  }

  var body: some View {
    List(selection: selection) {
      Section {
        ForEach(project.sessions) { item in
          SessionRow(item: item, isSelected: item.id == project.selectedID)
            .tag(item.id)
            .contextMenu { menu(for: item) }
            .accessibilityIdentifier("sessions.attached.\(item.sessionID ?? item.id.uuidString)")
        }
      } header: {
        HStack {
          Text("This Window")
          Spacer()
          Button("New Session", systemImage: "plus") { project.newSession() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("New session (⌘N)")
            .accessibilityIdentifier("sessions.new")
        }
      }
      let groups = groups
      if !groups.elsewhere.isEmpty {
        Section("Elsewhere") {
          ForEach(groups.elsewhere) { summary in
            SummaryRow(summary: summary, host: monitor.host(of: summary), monitor: monitor)
              .contentShape(Rectangle())
              .onTapGesture { openElsewhere(summary) }
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
              .onTapGesture { if let target = ResumeTarget(summary) { project.attach(target) } }
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
    .accessibilityIdentifier("sessions")
    .task { await monitor.include(folder: project.folder.path(percentEncoded: false)) }
  }

  private func openElsewhere(_ summary: SessionSummary) {
    if let (owner, item) = OpenSessions.shared.locate(summary.sessionID) {
      owner.select(item)
      owner.workspace.window?.makeKeyAndOrderFront(nil)
    } else if let target = ResumeTarget(summary) {
      project.attach(target, readOnly: true)
    }
  }

  private var selection: Binding<ProjectSession.ID?> {
    Binding(
      get: { project.selectedID },
      set: { id in
        if let item = project.sessions.first(where: { $0.id == id }) { project.select(item) }
      })
  }

  @ViewBuilder private func menu(for item: ProjectSession) -> some View {
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

/// One attached session: what it is doing, and its title.
struct SessionRow: View {
  let item: ProjectSession
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Circle()
        .fill(state.tint)
        .frame(width: 7, height: 7)
        .help(state.label)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(item.displayTitle)
            .lineLimit(1)
            .fontWeight(item.isUnread ? .semibold : .regular)
          if item.isUnread {
            Circle().fill(.blue).frame(width: 5, height: 5).accessibilityLabel("Unread")
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

  private var state: RowState {
    let session = item.session
    if item.waitingFor != nil { return .waiting }
    if session.transcript.isRunning { return .working }
    if item.hasStopped { return .stopped }
    if session.isReadOnly { return .elsewhere }
    if session.isProcessRunning { return .idle }
    if case .exited = session.phase { return .ended }
    return .notStarted
  }

  private var detail: String? {
    if let waiting = item.waitingFor { return waiting }
    if case .failed(let reason) = item.session.phase { return reason }
    return worktreeName
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
      Circle().fill(state.tint).frame(width: 7, height: 7).help(state.label)
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
    return switch summary.live?.status {
    case "busy":
      TranscriptTail.read(summary.file)?.isAwaitingToolResult == true ? .runningTool : .working
    case "waiting": .waiting
    default: .idle
    }
  }

  private var detail: String {
    let when = (summary.live?.updatedAt ?? summary.modified)
      .formatted(.relative(presentation: .named))
    var parts = [when]
    if let waiting = summary.live?.waitingFor { parts.insert(waiting, at: 0) }
    if let host { parts.append(host) }
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
  case working, runningTool, waiting, idle, notStarted, stopped, ended, elsewhere

  var label: String {
    switch self {
    case .working: String(localized: "Working")
    case .runningTool: String(localized: "Probably running a tool")
    case .waiting: String(localized: "Waiting for you")
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
    case .waiting: .blue
    case .stopped: .red
    case .idle, .notStarted, .ended, .elsewhere: .secondary
    }
  }
}
