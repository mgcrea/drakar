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
      .accessibilityIdentifier("tool.\(id)")
  }
}

/// A subagent: what it was asked and how far it has got while it works, its tool calls inside
/// the card rather than among the session's, and its report once it ends. One sent to the
/// background reads so until the notification that it ended, which may come a turn later.
struct AgentCallView: View {
  let call: Transcript.ToolCall
  let task: AgentTask?
  let children: [Transcript.Entry]
  @State private var isExpanded = false

  private var report: AgentReport? { call.result?.agentReport }
  private var isBackground: Bool { report?.isBackgrounded == true || task?.isBackgrounded == true }

  private enum State { case running, done, failed }

  private var state: State {
    if let task, isBackground || call.result == nil {
      switch task.status {
      case .running: return .running
      case .completed: return .done
      case .failed, .ended: return .failed
      }
    }
    guard let result = call.result else { return .running }
    return result.isError ? .failed : .done
  }

  /// Under the description: its progress while it runs, else what it used.
  private var detail: String? {
    if state == .running, isBackground, task?.progressLine == nil {
      return String(localized: "Running in the background")
    }
    if let line = task?.progressLine { return line }
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
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        if let prompt = task?.prompt ?? call.input["prompt"]?.stringValue {
          Text(prompt)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(8)
        }
        ForEach(children) { child in
          EntryView(entry: child).equatable()
        }
        if let reportText {
          Divider()
          MarkdownView(text: reportText)
            .copyOnHover(reportText)
        }
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        statusIcon
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
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
    }
    .modifier(CardFrame(id: call.id))
  }

  @ViewBuilder private var statusIcon: some View {
    switch state {
    case .running: ProgressView().controlSize(.mini)
    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
            .foregroundStyle(todo.status == .inProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
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
      Text("Waiting for you").font(.callout).foregroundStyle(.secondary)
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
