import DrakarKit
import SwiftUI

/// At the end of the transcript, where the working indicator stands during a turn: the tasks
/// the session left running in the background once its turn ended, each with how long it has
/// run. The session carries on by itself when one ends, so this says what it waits on. A
/// click on a task shows its card, which holds its output.
struct BackgroundTasksIndicator: View {
  let tasks: [AgentMap.Task]
  /// Shows the card of the call that started a task.
  let reveal: (String) -> Void
  @Environment(\.agentName) private var agentName
  @Environment(\.taskControls) private var controls

  /// Past these, the rest are counted.
  static let shownLimit = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(tasks.prefix(Self.shownLimit)) { task in
        row(task)
      }
      if tasks.count > Self.shownLimit {
        Text("+\(tasks.count - Self.shownLimit) more")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 22)
      }
      Text(
        tasks.count == 1
          ? String(localized: "\(agentName) carries on when it finishes.")
          : String(localized: "\(agentName) carries on as each finishes.")
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
      .padding(.leading, 22)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("transcript.backgroundWork")
  }

  private func row(_ task: AgentMap.Task) -> some View {
    HStack(spacing: 8) {
      Button {
        if let callID = task.callID { reveal(callID) }
      } label: {
        HStack(spacing: 8) {
          ProgressView().controlSize(.mini).frame(width: 14)
          Text(Self.title(of: task))
            .lineLimit(1)
            .truncationMode(.middle)
          if let startedAt = task.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text(Self.elapsed(from: startedAt, to: context.date))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(String(localized: "Show its card"))
      if controls?.isAvailable == true {
        StopTaskButton(taskID: task.taskID)
      }
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      String(localized: "Running in the background: \(Self.title(of: task))"))
  }

  static func title(of task: AgentMap.Task) -> String {
    if let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines),
      !description.isEmpty
    {
      return description
    }
    return task.taskType == "local_agent"
      ? String(localized: "A subagent") : String(localized: "A background task")
  }

  /// "0:42", "12:05", "1:03:20".
  static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }
}
