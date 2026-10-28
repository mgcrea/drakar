import DrakarKit
import Foundation
import Observation

/// A session's Stop, Run in background and task output: what was asked of the agent, what
/// it answered, and what still waits on an answer. The cards read it; the session sends
/// what it asks (never noted, so a replay never sends one again) and hands it the replies.
///
/// A stop that took is not shown from here: Claude Code answers success even for a task
/// that had ended, and the task's own lines say it stopped (`AgentTask.Status.stopped`).
@Observable
final class TaskControls {
  /// The session is driven and its agent controls tasks. Read through `availability`, so a
  /// view reading it observes the session's own properties.
  var isAvailable: Bool { availability() }
  /// The session's transcript, for subagent files; set for every Claude Code session, driven
  /// or not, once it has one.
  var transcriptFile: URL?
  /// Task ids a stop was sent for, until it is answered, the process ends or `timeout`.
  private(set) var stopping: Set<String> = []
  /// Task id to the CLI's error, for the last stop it refused.
  private(set) var stopFailures: [String: String] = [:]
  /// Tool use ids a move to the background was sent for, until answered or `timeout`.
  private(set) var moving: Set<String> = []
  private(set) var backgroundOutcomes: [String: BackgroundOutcome] = [:]
  /// The session runs with background tasks turned off: no move is offered again.
  private(set) var backgroundDisabled = false
  /// Task id to its last output read.
  private(set) var outputs: [String: TaskOutput] = [:]
  /// Ended tasks whose last output was read: never read again.
  @ObservationIgnored private var endedReads: Set<String> = []

  /// Settable so that a session can hand closures over itself once it exists.
  @ObservationIgnored var availability: () -> Bool
  @ObservationIgnored var send: (AgentCommand) -> Void
  /// The transcript of a session that knows its id but saved no target yet (a new one in
  /// its first turn), looked for without saving anything.
  @ObservationIgnored var locateTranscript: () -> URL? = { nil }
  @ObservationIgnored private let timeout: Duration
  /// Bumped by each request for an id: a timeout clears a wait only if no later request
  /// for that id started one of its own.
  @ObservationIgnored private var attempts: [String: Int] = [:]

  init(
    timeout: Duration = .seconds(10), availability: @escaping () -> Bool = { false },
    send: @escaping (AgentCommand) -> Void = { _ in }
  ) {
    self.timeout = timeout
    self.availability = availability
    self.send = send
  }

  /// Nothing goes while a stop for the task waits.
  func stop(taskID: String) {
    guard isAvailable, !stopping.contains(taskID) else { return }
    stopping.insert(taskID)
    stopFailures[taskID] = nil
    send(.stopTask(taskID: taskID))
    expire("stop-\(taskID)") { $0.stopping.remove(taskID) }
  }

  /// Nothing goes while a move for the call waits, nor once the session said moves are off.
  func runInBackground(toolUseID: String) {
    guard isAvailable, !backgroundDisabled, !moving.contains(toolUseID) else { return }
    moving.insert(toolUseID)
    backgroundOutcomes[toolUseID] = nil
    send(.backgroundCall(toolUseID: toolUseID))
    expire("background-\(toolUseID)") { $0.moving.remove(toolUseID) }
  }

  /// `transcriptFile`, else the one `locateTranscript` finds, kept once found.
  func resolvedTranscriptFile() -> URL? {
    if let transcriptFile { return transcriptFile }
    guard let located = locateTranscript() else { return nil }
    transcriptFile = located
    return located
  }

  /// Paced by whoever asks: each call sends one request.
  func fetchOutput(taskID: String) {
    guard isAvailable else { return }
    send(.taskOutput(taskID: taskID))
  }

  /// The task's output now: the tail of its output file when it is known, which reaches
  /// neither the process nor the session host's log, read anywhere; else asked of the
  /// process (`fetchOutput`). A file that cannot be read leaves the last tail shown.
  func readOutput(taskID: String, file: URL?) {
    guard let file else { return fetchOutput(taskID: taskID) }
    if let output = TaskOutput(tailOf: file) { outputs[taskID] = output }
  }

  /// An ended task's last output, read the first time it is asked for and never after.
  func readEndedOutput(taskID: String, file: URL?) {
    guard endedReads.insert(taskID).inserted else { return }
    readOutput(taskID: taskID, file: file)
  }

  /// A reply the session received; every other signal is ignored. One that comes after
  /// its timeout still says what happened.
  func answered(_ signal: SessionSignal) {
    switch signal {
    case .taskStopAnswered(let taskID, let error):
      stopping.remove(taskID)
      stopFailures[taskID] = error
    case .backgroundAnswered(let toolUseID, let outcome):
      moving.remove(toolUseID)
      backgroundOutcomes[toolUseID] = outcome
      if outcome == .disabled { backgroundDisabled = true }
    case .taskOutputAnswered(let taskID, let output):
      // A reply without output leaves the last one shown.
      if let output { outputs[taskID] = output }
    default:
      break
    }
  }

  /// The process went: nothing it was asked will be answered.
  func processEnded() {
    stopping.removeAll()
    moving.removeAll()
  }

  /// Runs `clear` after `timeout`, unless another request for `key` came meanwhile.
  private func expire(_ key: String, clear: @escaping (TaskControls) -> Void) {
    let attempt = (attempts[key] ?? 0) + 1
    attempts[key] = attempt
    Task { [weak self, timeout] in
      try? await Task.sleep(for: timeout)
      guard let self, self.attempts[key] == attempt else { return }
      clear(self)
    }
  }
}
