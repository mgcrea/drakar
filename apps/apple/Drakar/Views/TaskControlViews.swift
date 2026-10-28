import AppKit
import Combine
import DrakarKit
import SwiftUI

extension EnvironmentValues {
  /// The shown session's Stop, Run in background and task output; nil outside a session.
  @Entry var taskControls: TaskControls? = nil
}

/// What a card offers for its task, decided from the call, the task and the controls. Only
/// a task the CLI reported starting (it has an ID) is offered anything.
struct TaskOffer: Equatable {
  var stop: Bool
  var runInBackground: Bool
  var output: Bool

  /// The tools the extension offers to move to the background.
  private static let movable: Set<String> = ["Bash", "PowerShell", "Agent", "Task"]

  static func of(call: Transcript.ToolCall, task: AgentTask?, controls: TaskControls?)
    -> TaskOffer
  {
    var offer = TaskOffer(stop: false, runInBackground: false, output: false)
    guard let controls, let task, let taskID = task.taskID else { return offer }
    let isRunning = task.status == .running
    // `get_task_output` answers only for shell and Monitor tasks; an agent has none. Its last
    // tail stays readable once the session stops driving it.
    offer.output =
      task.taskType == "local_bash" && task.isBackgrounded
      && (controls.isAvailable || controls.outputs[taskID] != nil)
    guard controls.isAvailable else { return offer }
    offer.stop = isRunning
    // Hidden for the session once it said moves are off, except on the card that asked,
    // which says so.
    offer.runInBackground =
      isRunning && !task.isBackgrounded && call.result == nil
      && Self.movable.contains(call.name)
      && (!controls.backgroundDisabled || controls.backgroundOutcomes[call.id] != nil)
    return offer
  }
}

/// How a card with a task reads. A stopped task, or one in the background, reads as its task
/// says, whatever its call's result: a stopped foreground call's result is the interrupt's
/// error, a background one's the note that it went there.
enum TaskCardState: Equatable {
  case running, done, failed, stopped

  static func of(result: Transcript.ToolResult?, task: AgentTask?, isBackground: Bool)
    -> TaskCardState
  {
    if let task, task.status == .stopped || isBackground || result == nil {
      switch task.status {
      case .running: return .running
      case .completed: return .done
      case .stopped: return .stopped
      case .failed, .ended: return .failed
      }
    }
    guard let result else { return .running }
    return result.isError ? .failed : .done
  }
}

struct TaskStatusIcon: View {
  let state: TaskCardState

  var body: some View {
    switch state {
    case .running: ProgressView().controlSize(.mini)
    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
    }
  }
}

/// At the trailing end of a card's header while its task runs.
struct StopTaskButton: View {
  let taskID: String
  @Environment(\.taskControls) private var controls

  var body: some View {
    let isStopping = controls?.stopping.contains(taskID) == true
    Button(isStopping ? String(localized: "Stopping…") : String(localized: "Stop")) {
      controls?.stop(taskID: taskID)
    }
    .controlSize(.small)
    .disabled(isStopping)
    .accessibilityIdentifier("task.stop.\(taskID)")
  }
}

/// Under a card's header: the last stop the CLI refused, in the extension's words, its own
/// error in the tooltip. Shown whether or not the task still runs, so the click said something.
struct StopFailureNote: View {
  let taskID: String
  @Environment(\.taskControls) private var controls

  var body: some View {
    if let error = controls?.stopFailures[taskID] {
      Label(TaskControl.stopFailure, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(error)
        .accessibilityIdentifier("task.stop.\(taskID).failure")
    }
  }
}

/// Under a card's header while its call runs in the foreground: the button, then what the
/// CLI answered. Only a failure offers the button again.
struct RunInBackgroundLine: View {
  let toolUseID: String
  @Environment(\.taskControls) private var controls

  var body: some View {
    let outcome = controls?.backgroundOutcomes[toolUseID]
    VStack(alignment: .leading, spacing: 4) {
      if outcome == nil || outcome == .failed {
        Button(String(localized: "Run in background")) {
          controls?.runInBackground(toolUseID: toolUseID)
        }
        .controlSize(.small)
        .disabled(controls?.moving.contains(toolUseID) == true)
        .accessibilityIdentifier("task.background.\(toolUseID)")
      }
      if let message = outcome?.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("task.background.\(toolUseID).message")
      }
    }
  }
}

/// A background shell task's output, closed until opened. Open, it is read every second
/// while the task runs and its window is visible, and once when the task ended. Read from the
/// task's output file when it is known, else asked of the process.
struct TaskOutputSection: View {
  let taskID: String
  let isRunning: Bool
  /// From the call's result, or the notification that the task ended.
  let outputFile: URL?
  @Environment(\.taskControls) private var controls
  @State private var isExpanded = false
  /// The window the section is in, by identity, and whether any of it is on screen.
  @State private var window: ObjectIdentifier?
  @State private var isWindowVisible = false

  /// What the reading depends on: a change to any stops it and starts it again.
  private struct Reading: Equatable {
    var isExpanded: Bool
    var isRunning: Bool
    var isWindowVisible: Bool
    var isAvailable: Bool
    var outputFile: URL?
  }

  var body: some View {
    let output = controls?.outputs[taskID]
    let text = output?.displayText ?? ""
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 4) {
        if text.isEmpty {
          Text(TaskControl.noOutput)
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          CodeBlock(text: text)
        }
        if let note = output?.note {
          Text(note)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 4)
    } label: {
      Text(String(localized: "Output"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
    }
    .accessibilityIdentifier("task.output.\(taskID)")
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
      id: Reading(
        isExpanded: isExpanded, isRunning: isRunning, isWindowVisible: isWindowVisible,
        isAvailable: controls?.isAvailable == true, outputFile: outputFile)
    ) {
      await read()
    }
  }

  private func read() async {
    guard isExpanded, let controls else { return }
    // Ended: its last output, once for the task, whatever changes after.
    guard isRunning else {
      return controls.readEndedOutput(taskID: taskID, file: outputFile)
    }
    guard isWindowVisible, outputFile != nil || controls.isAvailable else { return }
    while !Task.isCancelled {
      controls.readOutput(taskID: taskID, file: outputFile)
      try? await Task.sleep(for: .seconds(1))
    }
  }
}
