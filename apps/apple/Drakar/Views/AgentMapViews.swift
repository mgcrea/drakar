import DrakarKit
import SwiftUI

/// A call the agent map asked the transcript to scroll to and open.
struct RevealRequest: Equatable {
  let callID: String
  let serial: Int
  let at: Date
}

/// What the transcript hands its cards when a reveal arrives: the call and the calls whose
/// cards hold it, all to open, and when, so a card the lazy stack makes a moment later still
/// opens and one made long after does not.
struct TranscriptReveal: Equatable {
  var callIDs: Set<String>
  var at: Date

  /// Asked for just now: a card made while the scroll lands still answers.
  var isFresh: Bool { at.timeIntervalSinceNow > -2 }
}

extension EnvironmentValues {
  @Entry var transcriptReveal: TranscriptReveal? = nil
}

extension AgentMap.State {
  /// The sidebar's colours: green at work, blue waiting on the person, red for a failure.
  var tint: Color {
    switch self {
    case .waiting: .blue
    case .running: .green
    case .failed: .red
    case .idle: .secondary
    }
  }

  /// The extension's words.
  var help: String {
    switch self {
    case .waiting:
      String(localized: "An agent is waiting for your permission · Click to open the agent map")
    case .running: String(localized: "Agents are working · Click to open the agent map")
    case .failed: String(localized: "An agent failed · Click to open the agent map")
    case .idle: String(localized: "Click to open the agent map")
    }
  }
}

/// The extension's agents pill, left of the model: once the session started a subagent, how
/// many are working, with a dot for the most urgent of them, and the agent map on a click.
/// It stays at "0 agents" once they are done, as the extension's does.
struct AgentsPill: View {
  let session: AgentSession
  /// Scrolls the transcript to a call and opens its card.
  var reveal: ((String) -> Void)?
  @State private var isShown = false

  static func label(_ working: Int) -> String {
    working == 1 ? String(localized: "1 agent") : String(localized: "\(working) agents")
  }

  var body: some View {
    let map = session.status.agents
    Button {
      isShown.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "person.2")
        Circle().fill(map.state.tint).frame(width: 6, height: 6)
        Text(Self.label(map.working)).monospacedDigit()
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .buttonStyle(PillButtonStyle())
    .fixedSize()
    .help(map.state.help)
    .accessibilityLabel("\(Self.label(map.working)) · \(map.state.help)")
    .accessibilityIdentifier("composer.agents")
    .popover(isPresented: $isShown, arrowEdge: .top) {
      AgentMapPanel(
        session: session,
        reveal: reveal.map { reveal in
          { call in
            isShown = false
            reveal(call)
          }
        })
    }
  }
}

/// The agent map: the session, the agents under the call that started each, and the other
/// tasks in the background. A row opens its card in the transcript, where its transcript,
/// output and Stop already are; a working one can be stopped from here too.
struct AgentMapPanel: View {
  let session: AgentSession
  var reveal: ((String) -> Void)?

  var body: some View {
    // The transcript, not `status`: only while the panel is up, at the transcript view's pace.
    let map = session.displayedTranscript.agentMap
    VStack(alignment: .leading, spacing: 0) {
      Text("Agent map").font(.headline)
        .padding(.horizontal, 14).padding(.top, 12)
      Text(subtitle(map))
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.bottom, 8)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          sessionRow
          ForEach(rows(map.agents, depth: 1), id: \.agent.id) { row in
            AgentRow(
              agent: row.agent, depth: row.depth, controls: session.tasks,
              open: reveal.map { reveal in { reveal(row.agent.callID) } })
          }
          if !map.tasks.isEmpty {
            Text(
              map.tasks.count == 1
                ? String(localized: "1 background task")
                : String(localized: "\(map.tasks.count) background tasks")
            )
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
            ForEach(map.tasks) { task in
              BackgroundTaskRow(
                task: task, controls: session.tasks,
                open: task.callID.flatMap { call in reveal.map { reveal in { reveal(call) } } })
            }
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 420)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 380)
    .accessibilityIdentifier("agentMap")
  }

  private func subtitle(_ map: AgentMap) -> String {
    let count = map.allAgents.count
    let agents = count == 1 ? String(localized: "1 agent") : String(localized: "\(count) agents")
    return reveal == nil ? agents : String(localized: "\(agents) · click one to open its card")
  }

  private var sessionRow: some View {
    let status = session.status
    let title = status.title ?? status.firstPrompt ?? String(localized: "This session")
    return HStack(spacing: 8) {
      Circle().fill(status.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
      Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 8)
      Text(status.isRunning ? String(localized: "Working") : String(localized: "Idle"))
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
  }

  private struct Row {
    let agent: AgentMap.Agent
    let depth: Int
  }

  private func rows(_ agents: [AgentMap.Agent], depth: Int) -> [Row] {
    agents.flatMap { [Row(agent: $0, depth: depth)] + rows($0.children, depth: depth + 1) }
  }
}

/// How long a task has run, or ran: ticking each second while it works.
private struct ElapsedText: View {
  let startedAt: Date?
  let endedAt: Date?
  let durationMS: Int?
  let isRunning: Bool

  var body: some View {
    if isRunning, let startedAt {
      TimelineView(.periodic(from: startedAt, by: 1)) { context in
        Text(Self.format(context.date.timeIntervalSince(startedAt)))
      }
    } else if let seconds {
      Text(Self.format(seconds))
    }
  }

  private var seconds: TimeInterval? {
    if let durationMS, durationMS > 0 { return Double(durationMS) / 1000 }
    if let startedAt, let endedAt, endedAt > startedAt {
      return endedAt.timeIntervalSince(startedAt)
    }
    return nil
  }

  static func format(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(0, seconds.rounded()))
      .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
  }
}

private struct AgentRow: View {
  let agent: AgentMap.Agent
  let depth: Int
  let controls: TaskControls?
  let open: (() -> Void)?

  private var state: (tint: Color, label: String) {
    if agent.isWorking && agent.isWaiting {
      return (.blue, String(localized: "Waiting for your permission"))
    }
    switch agent.task.status {
    case .running: return (.green, String(localized: "Working"))
    case .completed: return (.secondary, String(localized: "Finished"))
    case .failed: return (.red, String(localized: "Failed"))
    case .stopped, .ended: return (.secondary, String(localized: "Stopped"))
    }
  }

  var body: some View {
    let task = agent.task
    HStack(spacing: 8) {
      Circle().fill(state.tint).frame(width: 7, height: 7).help(state.label)
      Text(task.description ?? String(localized: "Agent"))
        .lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 8)
      HStack(spacing: 4) {
        ElapsedText(
          startedAt: task.startedAt, endedAt: task.endedAt, durationMS: task.durationMS,
          isRunning: agent.isWorking)
        if let tokens = task.totalTokens, tokens > 0 {
          Text("· \(tokens.formatted(.number.notation(.compactName))) tokens")
        }
      }
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      if agent.isWorking, let taskID = task.taskID, let controls, controls.isAvailable {
        StopButton(taskID: taskID, controls: controls)
      }
    }
    .padding(.leading, 8 + CGFloat(depth - 1) * 14).padding(.trailing, 8).padding(.vertical, 5)
    .modifier(RowAction(open: open, help: task.description))
    .accessibilityIdentifier("agentMap.agent.\(agent.callID)")
  }
}

private struct BackgroundTaskRow: View {
  let task: AgentMap.Task
  let controls: TaskControls?
  let open: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(Color.green).frame(width: 7, height: 7)
      Text(task.description ?? task.taskType ?? String(localized: "Task"))
        .lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 8)
      ElapsedText(startedAt: task.startedAt, endedAt: nil, durationMS: nil, isRunning: true)
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      if let controls, controls.isAvailable {
        StopButton(taskID: task.taskID, controls: controls)
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .modifier(RowAction(open: open, help: task.description))
    .accessibilityIdentifier("agentMap.task.\(task.taskID)")
  }
}

private struct StopButton: View {
  let taskID: String
  let controls: TaskControls

  var body: some View {
    let isStopping = controls.stopping.contains(taskID)
    Button(isStopping ? String(localized: "Stopping…") : String(localized: "Stop")) {
      controls.stop(taskID: taskID)
    }
    .controlSize(.small)
    .disabled(isStopping)
  }
}

/// A row that opens its card on a click, highlighted under the pointer.
private struct RowAction: ViewModifier {
  let open: (() -> Void)?
  let help: String?
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .background(
        isHovered && open != nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .onTapGesture { open?() }
      .help(help ?? "")
  }
}
