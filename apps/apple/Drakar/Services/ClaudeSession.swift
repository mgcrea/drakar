import DrakarKit
import Foundation
import Observation

/// One `claude` process working in one folder, and the transcript it has written.
///
/// Main-actor state over an `AgentProcess`: events are decoded off the main thread and
/// applied here in batches, which is all the view observes.
@Observable
final class ClaudeSession {
  enum Phase: Equatable {
    case idle
    case starting
    case ready
    case failed(String)
    case exited(status: Int32)
  }

  let folder: URL
  /// The account and session to resume, or nil for a new session under the shell's own
  /// configuration directory.
  let resuming: ResumeTarget?
  private(set) var transcript = Transcript()
  private(set) var phase: Phase = .idle
  /// The binary this session runs, for the footer and for bug reports.
  private(set) var executable: URL?
  /// The end of the CLI's stderr, shown when the process fails.
  private(set) var diagnostics = ""

  @ObservationIgnored private var process: AgentProcess?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var requestCount = 0

  init(folder: URL, resuming: ResumeTarget? = nil) {
    self.folder = folder
    self.resuming = resuming
  }

  /// The session's id once known: the resumed one at once, a new one or a fork's from
  /// `system/init`. A fork never answers with the original's id, which another process owns.
  var sessionID: String? {
    transcript.session?.sessionID ?? (resuming?.forks == true ? nil : resuming?.sessionID)
  }

  /// The title Claude Code gave the session, from its history.
  var title: String? { transcript.title }

  var canSend: Bool { phase == .ready && !transcript.isRunning }

  func start(command: ClaudeCommand = ClaudeCommand()) async {
    guard phase == .idle else { return }
    phase = .starting
    var command = command
    var environment = await Self.environment.value
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      phase = .failed(String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
      return
    }
    if let resuming {
      // `--resume` continues the session but does not replay it, so the past comes from
      // the transcript file, read off the main thread: they run to megabytes.
      let file = resuming.transcriptFile
      transcript =
        (try? await Task.detached { try Transcript.history(contentsOf: file) }.value)
        ?? Transcript()
      command.resumeSessionID = resuming.sessionID
      command.forksSession = resuming.forks == true
      environment = resuming.account.environment(environment)
    }
    guard let claude = ClaudeLocator.locate(path: environment["PATH"]) else {
      phase = .failed(
        String(localized: "Claude Code was not found. Install it, then open the folder again."))
      return
    }
    executable = claude
    let process = AgentProcess(
      .init(
        executable: claude, arguments: command.arguments, environment: environment,
        currentDirectory: folder))
    do {
      let stream = try process.start()
      self.process = process
      try process.send(.initialize(requestID: nextRequestID("init")))
      phase = .ready
      events = Task { [weak self] in
        for await event in stream { self?.handle(event) }
      }
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// `context` is the editor's open file or selection, sent ahead of the text as the
  /// extension's chat sends it.
  func send(_ prompt: String, context: EditorSelection? = nil) {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend, !text.isEmpty else { return }
    transcript.addPrompt(text, context: context?.label)
    write(.prompt(text, context: context.map { [$0.promptContext] } ?? []))
  }

  func answer(_ pending: Transcript.PendingPermission, _ decision: PermissionDecision) {
    write(.permission(requestID: pending.requestID, decision))
    transcript.resolvePermission(requestID: pending.requestID)
  }

  func interrupt() {
    guard transcript.isRunning else { return }
    write(.interrupt(requestID: nextRequestID("interrupt")))
  }

  /// Ends the process: input closed so it can finish cleanly, then terminated, because a
  /// window that closed mid-turn must not leave a `claude` working on nobody's behalf.
  func stop() {
    process?.closeInput()
    process?.terminate()
    events?.cancel()
  }

  private func handle(_ event: AgentProcess.Event) {
    switch event {
    case .messages(let messages):
      for message in messages { transcript.apply(message) }
    case .stderr(let text):
      diagnostics = String((diagnostics + text).suffix(4000))
    case .exited(let status, _):
      transcript.processExited()
      process = nil
      if case .failed = phase { return }
      phase = .exited(status: status)
    }
  }

  private func write(_ message: ClientMessage) {
    do {
      try process?.send(message)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func nextRequestID(_ prefix: String) -> String {
    requestCount += 1
    return "\(prefix)-\(requestCount)"
  }

  /// The login shell's environment, read once per launch and shared by every window: a
  /// terminal `claude` sees the user's PATH, and so must this one and the tools it runs.
  /// Without it, launchd's PATH plus the usual install directories.
  static let environment = Task<[String: String], Never> {
    if let environment = await ShellEnvironment.read() { return environment }
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    environment["PATH"] = [
      "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "",
    ].joined(separator: ":")
    return environment
  }
}
