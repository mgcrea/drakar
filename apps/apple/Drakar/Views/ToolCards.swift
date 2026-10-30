import AppKit
import Combine
import DrakarKit
import SwiftUI

/// The cards of the tools the extension draws its own way: a subagent, a todo list, a plan.
/// Each keeps `ToolCallView`'s frame so the transcript reads as one list.
private struct CardFrame: ViewModifier {
  let id: String

  func body(content: Content) -> some View {
    content
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
      // A container, so the controls inside keep their own identifiers.
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("tool.\(id)")
  }
}

/// A subagent: what it was asked and how far it has got while it works, its tool calls inside
/// the card rather than among the session's, and its report once it ends. One sent to the
/// background reads so until the notification that it ended, which may come a turn later.
///
/// Open, the card reads the subagent's own file when there is one, which holds its whole
/// conversation (text and thinking a foreground subagent never streams, and all of it after a
/// reload), in place of the lines streamed under its call.
struct AgentCallView: View {
  let call: Transcript.ToolCall
  let task: AgentTask?
  let children: [Transcript.Entry]
  /// What the CLI reported of the tasks its calls run as (a long Bash of its own), by call.
  var childTasks: [String: AgentTask] = [:]
  @State private var isExpanded = false
  /// Made when the card is first opened, never for one kept closed.
  @State private var feed: SubagentFeed?
  /// The window the card is in, by identity, and whether any of it is on screen.
  @State private var window: ObjectIdentifier?
  @State private var isWindowVisible = false
  @Environment(\.taskControls) private var controls

  /// What the file is named by: the task's id while it is reported, its report's after a
  /// reload. Neither, while it runs in a session read from its file: the feed finds it by the
  /// call's id.
  private var agentID: String? { task?.taskID ?? report?.agentID }

  private var report: AgentReport? { call.result?.agentReport }

  private var isBackground: Bool { report?.isBackgrounded == true || task?.isBackgrounded == true }

  private var state: TaskCardState {
    TaskCardState.of(result: call.result, task: task, isBackground: isBackground)
  }

  /// Under the description: its progress while it runs, else what it used.
  private var detail: String? {
    if state == .stopped { return String(localized: "Stopped") }
    if state == .running, isBackground, task?.progressLine == nil {
      return String(localized: "Running in the background")
    }
    if let line = task?.progressLine {
      // Its progress says more than the note, but not that it went to the background.
      if state == .running, isBackground { return String(localized: "In the background · \(line)") }
      return line
    }
    guard let report else { return nil }
    var finished = AgentTask()
    finished.toolUses = report.toolUses
    finished.totalTokens = report.totalTokens
    finished.durationMS = report.durationMS
    return finished.progressLine
  }

  /// The report itself, without the frame the model reads around it.
  private var reportText: String? {
    if let text = report?.text, !(report?.isBackgrounded ?? false) { return text }
    if let summary = task?.summary { return summary }
    guard let result = call.result, report == nil else { return nil }
    return result.content.isEmpty ? nil : result.content
  }

  var body: some View {
    let offer = TaskOffer.of(call: call, task: task, controls: controls)
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        // Not the file's, which it opens with: that one is not drawn among its entries.
        if let prompt = task?.prompt ?? call.input["prompt"]?.stringValue {
          Text(prompt)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(8)
        }
        if let own = feed?.transcript, let drawn = feed?.drawn {
          ForEach(drawn.top) { entry in
            EntryView(
              entry: entry, children: drawn.children[entry.id] ?? [],
              task: own.agentTasks[entry.id] ?? childTasks[entry.id]
            )
            .equatable()
          }
        } else {
          ForEach(children) { child in
            EntryView(entry: child, task: childTasks[child.id]).equatable()
          }
        }
        if let reportText {
          Divider()
          MarkdownView(text: reportText)
            .copyOnHover(reportText)
        }
      }
      .padding(.top, 6)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          TaskStatusIcon(state: state)
          Text(call.name).fontWeight(.semibold)
          VStack(alignment: .leading, spacing: 1) {
            Text(call.summary)
              .lineLimit(1)
              .truncationMode(.tail)
            if let detail {
              Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          if offer.stop, let taskID = task?.taskID {
            Spacer(minLength: 8)
            StopTaskButton(taskID: taskID)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
        if offer.runInBackground { RunInBackgroundLine(toolUseID: call.id) }
        if let taskID = task?.taskID { StopFailureNote(taskID: taskID) }
      }
    }
    .modifier(CardFrame(id: call.id))
    .background(
      WindowReader { found in
        // Not during the update that put the view in its window.
        Task { @MainActor in
          window = ObjectIdentifier(found)
          isWindowVisible = found.occlusionState.contains(.visible)
        }
      }
    )
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
    ) { notification in
      guard let changed = notification.object as? NSWindow, ObjectIdentifier(changed) == window
      else { return }
      isWindowVisible = changed.occlusionState.contains(.visible)
    }
    .task(
      id: FeedTrigger(
        isOpen: isExpanded, agentID: agentID, transcriptFile: controls?.transcriptFile,
        isRunning: state == .running, isWindowVisible: isWindowVisible)
    ) {
      await follow()
    }
  }

  /// What starts, restarts or stops following the file: a card closed, a task that ended,
  /// or its window hidden cancels the loop, and the run that replaces it reads once more.
  private struct FeedTrigger: Equatable {
    let isOpen: Bool
    let agentID: String?
    let transcriptFile: URL?
    let isRunning: Bool
    let isWindowVisible: Bool
  }

  /// Reads the file once, then every second while the task runs and its window is visible.
  /// A new session's first turn saved no transcript yet: it is looked for until found.
  private func follow() async {
    guard isExpanded else { return }
    guard let transcriptFile = controls?.resolvedTranscriptFile() else {
      self.feed = nil
      guard state == .running, isWindowVisible else { return }
      // Found, it changes the trigger, and the run that replaces this one reads it.
      while !Task.isCancelled, controls?.resolvedTranscriptFile() == nil {
        try? await Task.sleep(for: .seconds(1))
      }
      return
    }
    let feed: SubagentFeed
    if let current = self.feed, current.transcriptFile == transcriptFile,
      agentID == nil || current.agentID == agentID
    {
      feed = current
    } else {
      feed = SubagentFeed(agentID: agentID, toolUseID: call.id, transcriptFile: transcriptFile)
      self.feed = feed
    }
    await feed.refresh()
    guard state == .running, isWindowVisible else { return }
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      await feed.refresh()
    }
  }
}

/// A `TodoWrite`: its list, open, as the extension shows it.
struct TodoCallView: View {
  let call: Transcript.ToolCall

  var body: some View {
    let todos = TodoList.todos(call.input)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "checklist").foregroundStyle(.secondary)
        Text("Todos").fontWeight(.semibold)
        Text("\(TodoList.progress(todos)) done")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      TodoRows(todos: todos)
    }
    .modifier(CardFrame(id: call.id))
  }
}

struct TodoRows: View {
  let todos: [Todo]

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: Self.symbol(todo.status))
            .foregroundStyle(
              todo.status == .inProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          Text(todo.status == .inProgress ? todo.activeForm ?? todo.content : todo.content)
            .strikethrough(todo.status == .completed)
            .foregroundStyle(todo.status == .completed ? .secondary : .primary)
            .fontWeight(todo.status == .inProgress ? .medium : .regular)
        }
        .font(.callout)
      }
    }
  }

  static func symbol(_ status: Todo.Status) -> String {
    switch status {
    case .pending: "circle"
    case .inProgress: "circle.lefthalf.filled"
    case .completed: "checkmark.circle"
    }
  }
}

/// An `ExitPlanMode`: the plan by its title, what became of it, and the plan itself inside.
struct PlanCallView: View {
  let call: Transcript.ToolCall
  /// Its panel is up; otherwise a plan without a result was never answered, its process gone.
  let isAsked: Bool
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        if let plan = PlanApproval.plan(call.input) {
          MarkdownView(text: plan).copyOnHover(plan)
        }
        if case .keptPlanning(let feedback?) = call.planOutcome {
          Label(feedback, systemImage: "arrowshape.turn.up.left")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "list.bullet.clipboard").foregroundStyle(.secondary)
        Text("Plan").fontWeight(.semibold)
        Text(call.summary).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 8)
        outcome
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
    }
    .modifier(CardFrame(id: call.id))
  }

  @ViewBuilder private var outcome: some View {
    switch call.planOutcome {
    case .approved?:
      Label("Approved", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.callout)
    case .keptPlanning?:
      Label("Kept planning", systemImage: "arrow.uturn.backward.circle")
        .foregroundStyle(.secondary)
        .font(.callout)
    case .waiting?, nil:
      Text(isAsked ? "Waiting for you" : "No answer").font(.callout).foregroundStyle(.secondary)
    }
  }
}

/// Above the composer while a turn runs: the newest list's current item and how far along
/// it is, opening to the whole list, as the extension pins its todos.
struct TodoStrip: View {
  let todos: [Todo]
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.snappy) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "circle.lefthalf.filled").foregroundStyle(.tint)
          Text(current).lineLimit(1).truncationMode(.tail)
          Text(TodoList.progress(todos))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
          Spacer(minLength: 4)
          Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isExpanded { TodoRows(todos: todos) }
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .accessibilityIdentifier("todos.strip")
  }

  private var current: String {
    guard let todo = TodoList.current(todos) else { return String(localized: "Todos") }
    return todo.activeForm ?? todo.content
  }
}
