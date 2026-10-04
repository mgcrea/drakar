import DrakarKit
import Foundation
import Observation

/// One session in a project window: its history from disk, and a `claude` process from its
/// first prompt on.
///
/// Main-actor state over an `AgentProcess`: events are decoded off the main thread and
/// applied here in batches, which is all the view observes.
@Observable
final class ClaudeSession {
  enum Phase: Equatable {
    /// No process: never started, or a history shown until the first prompt.
    case idle
    case starting
    case ready
    case failed(String)
    case exited(status: Int32)
  }

  let folder: URL
  /// What this session continues; nil for a new one. Becomes the session's own target
  /// once it has one, so that a prompt after the process ended resumes it.
  private(set) var resuming: ResumeTarget?
  private(set) var transcript = Transcript()
  private(set) var phase: Phase = .idle
  /// The binary this session runs, for the footer and for bug reports.
  private(set) var executable: URL?
  /// The account it runs under, picked or the shell's; nil until it starts.
  private(set) var account: ClaudeAccount?
  /// The end of the CLI's stderr, shown when the process fails.
  private(set) var diagnostics = ""
  /// The process's answer to `get_context_usage` after its last turn: the exact window.
  private(set) var reportedContext: ContextUsageReply?
  /// What reopening the window resumes: known from the start for a resumed session, and
  /// from its first finished turn for a new one or a fork, once its transcript exists.
  private(set) var savedTarget: ResumeTarget?
  /// The transcript's history was read into `transcript`.
  private(set) var hasLoadedHistory = false
  /// The arguments the next spawn runs with (a model for a debug launch).
  var command = ClaudeCommand()
  /// Open in another process: the transcript follows its file and nothing is sent.
  var isReadOnly = false
  /// Stands in for the located binary, in tests.
  @ObservationIgnored var executableOverride: URL?
  /// The accounts a new session's transcript is looked for in; the discovered ones, or a
  /// test's.
  @ObservationIgnored var accounts: () -> [ClaudeAccount] = { ClaudeAccount.discover() }

  /// For the window's attention: a turn ended, a permission request arrived, the process
  /// stopped on its own.
  @ObservationIgnored var onTurnEnded: (() -> Void)?
  @ObservationIgnored var onPermissionRequested: ((Transcript.PendingPermission) -> Void)?
  @ObservationIgnored var onStopped: (() -> Void)?
  /// The number of waiting permission requests changed: asked, answered, cancelled, or gone
  /// with the process.
  @ObservationIgnored var onPermissionsChanged: (() -> Void)?

  @ObservationIgnored private var process: AgentProcess?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var requestCount = 0
  @ObservationIgnored private var historyLoad: Task<Void, Never>?
  /// True from the start for a session with a transcript, until its history is read.
  @ObservationIgnored private var isLoadingHistory = false
  @ObservationIgnored private var promptsDuringLoad: [(String, String?)] = []
  /// The history could not be read: the reason stays in `phase` and nothing is sent.
  @ObservationIgnored private var historyFailed = false
  @ObservationIgnored private var follower: TranscriptFollower?
  /// A prompt sent before the process existed, written right after `initialize`.
  @ObservationIgnored private var pendingPrompt: ClientMessage?
  /// Bumped by every `stop()`: a spawn that started before one must not start a process
  /// after it, for a window that closed or a row that was removed meanwhile.
  @ObservationIgnored private var stopCount = 0

  init(folder: URL, resuming: ResumeTarget? = nil) {
    self.folder = folder
    self.resuming = resuming
    savedTarget = resuming?.forks == true ? nil : resuming
    isLoadingHistory = resuming != nil
  }

  /// The session's id once known: the resumed one at once, a new one or a fork's from
  /// `system/init`. A fork never answers with the original's id, which another process owns.
  var sessionID: String? {
    transcript.session?.sessionID ?? (resuming?.forks == true ? nil : resuming?.sessionID)
  }

  /// The title Claude Code gave the session, from its history.
  var title: String? { transcript.title }

  var isProcessRunning: Bool { process != nil }

  var canSend: Bool {
    !isReadOnly && !historyFailed && !transcript.isRunning && phase != .starting
  }

  /// The history from the transcript file, once: `--resume` continues a session but does
  /// not replay it, and transcripts run to megabytes, so it is read off the main thread.
  /// Every caller waits for the same load.
  func loadHistory() async {
    if historyLoad == nil {
      historyLoad = Task { await self.readHistory() }
    }
    await historyLoad?.value
  }

  private func readHistory() async {
    guard let file = resuming?.transcriptFile else {
      isLoadingHistory = false
      return
    }
    let loaded = await Task.detached { () -> (Transcript, TranscriptFollower)? in
      var follower = TranscriptFollower(file: file)
      var transcript = Transcript()
      guard (try? follower.catchUp(&transcript)) != nil else { return nil }
      return (transcript, follower)
    }.value
    isLoadingHistory = false
    guard let (transcript, follower) = loaded else {
      historyFailed = true
      phase = .failed(
        String(
          localized:
            "The transcript of this session is missing. It may have been deleted, or its account removed."
        ))
      return
    }
    self.transcript = transcript
    self.follower = follower
    hasLoadedHistory = true
    // Prompts typed while the history was being read go after it.
    for (text, context) in promptsDuringLoad { self.transcript.addPrompt(text, context: context) }
    promptsDuringLoad = []
  }

  /// What another process appended, for a read-only session.
  func catchUp() {
    guard isReadOnly, var follower else { return }
    try? follower.catchUp(&transcript)
    self.follower = follower
  }

  /// `context` is the editor's open file or selections, sent ahead of the text as the
  /// extension's chat sends it. Starts the process when there is none.
  func send(_ prompt: String, context: [EditorSelection] = []) {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend, !text.isEmpty else { return }
    let label = context.isEmpty ? nil : context.map(\.label).joined(separator: ", ")
    transcript.addPrompt(text, context: label)
    if isLoadingHistory { promptsDuringLoad.append((text, label)) }
    let message = ClientMessage.prompt(text, context: context.map(\.promptContext))
    if process == nil {
      pendingPrompt = message
      // Counted now, not when the task runs: a `stop()` before then cancels it too.
      let stops = stopCount
      Task { await spawn(unlessStoppedSince: stops) }
    } else {
      write(message)
    }
  }

  /// Starts `claude`, resuming this session if it has a transcript.
  func spawn() async {
    await spawn(unlessStoppedSince: stopCount)
  }

  /// Every await is a point where the window may have closed (`stop()`) or another process
  /// may have opened the session (`isReadOnly`): after each, either ends the spawn.
  private func spawn(unlessStoppedSince stops: Int) async {
    guard stopCount == stops, process == nil, phase != .starting else { return }
    if resuming?.forks == true || resuming == nil {
      // A first turn that never finished (End Session, a crash) left no saved target, but
      // the transcript exists from `system/init` on: look for it.
      if savedTarget == nil, transcript.session?.sessionID != nil { savedTarget = findTarget() }
      // A session whose process ended goes on under its own id, never as a fork again.
      if let saved = savedTarget { resuming = saved }
    }
    phase = .starting
    await loadHistory()
    guard stillWanted(since: stops) else { return }
    if historyFailed { return fail(nil) }
    var command = command
    var environment = await Self.environment.value
    guard stillWanted(since: stops) else { return }
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return fail(String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    if let resuming {
      command.resumeSessionID = resuming.sessionID
      command.forksSession = resuming.forks == true
    }
    // A resume under the account that wrote it; a new session under its folder's pick, else
    // the one in Settings, else left to the shell.
    let chosen = resuming?.account ?? ClaudeChoice.account(forNewSessionIn: folder)
    if let chosen { environment = chosen.environment(environment) }
    account =
      chosen
      ?? ClaudeChoice.account(
        at: environment["CLAUDE_CONFIG_DIR"]
          ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
          .path(percentEncoded: false))
    guard
      let claude = executableOverride
        ?? ClaudeLocator.locate(preferred: ClaudeChoice.executable, path: environment["PATH"])
    else {
      return fail(
        String(localized: "Claude Code was not found. Install it, then open the folder again."))
    }
    executable = claude
    // The last word before the process starts, with no await after it: a session live in
    // another process now is followed, not written to. The monitor may not have read the
    // registries yet at launch, so the account's own registry is read here too.
    if let resuming, resuming.forks != true, isLiveElsewhere(resuming) {
      isReadOnly = true
      _ = stillWanted(since: stops)
      return
    }
    let process = AgentProcess(
      .init(
        executable: claude, arguments: command.arguments, environment: environment,
        currentDirectory: folder))
    do {
      let stream = try process.start()
      self.process = process
      try process.send(.initialize(requestID: nextRequestID("init")))
      if let pendingPrompt {
        try process.send(pendingPrompt)
        self.pendingPrompt = nil
      }
      phase = .ready
      events = Task { [weak self] in
        for await event in stream { self?.handle(event) }
      }
    } catch {
      fail(error.localizedDescription)
    }
  }

  /// False when a `stop()` came since `stops` (which already settled the phase), or when
  /// the session became read-only, which leaves it as it was before the prompt.
  private func stillWanted(since stops: Int) -> Bool {
    guard stopCount == stops else { return false }
    guard isReadOnly else { return true }
    phase = .idle
    pendingPrompt = nil
    notingPermissions { transcript.processExited() }
    return false
  }

  private func isLiveElsewhere(_ target: ResumeTarget) -> Bool {
    let monitor = SessionMonitor.shared
    if monitor.hasReadRegistries, monitor.liveIDs.contains(target.sessionID) { return true }
    return LiveSession.read(account: target.account).contains { $0.sessionID == target.sessionID }
  }

  func answer(_ pending: Transcript.PendingPermission, _ decision: PermissionDecision) {
    write(.permission(requestID: pending.requestID, decision))
    notingPermissions { transcript.resolvePermission(requestID: pending.requestID) }
  }

  func interrupt() {
    guard transcript.isRunning else { return }
    write(.interrupt(requestID: nextRequestID("interrupt")))
  }

  /// Ends the process: input closed so it can finish cleanly, then terminated, because a
  /// window that closed mid-turn must not leave a `claude` working on nobody's behalf.
  func stop() {
    let waiting = transcript.pendingPermissions.count
    defer { permissionsMayHaveChanged(from: waiting) }
    stopCount += 1
    pendingPrompt = nil
    process?.closeInput()
    process?.terminate()
    events?.cancel()
    // The cancelled event task will not report the exit, so it is recorded here.
    process = nil
    transcript.processExited()
    if case .failed = phase { return }
    if phase == .ready || phase == .starting { phase = .exited(status: 0) }
  }

  /// `message` nil keeps the reason already in `phase`.
  private func fail(_ message: String?) {
    if let message { phase = .failed(message) }
    pendingPrompt = nil
    notingPermissions { transcript.processExited() }
  }

  private func notingPermissions(_ change: () -> Void) {
    let waiting = transcript.pendingPermissions.count
    change()
    permissionsMayHaveChanged(from: waiting)
  }

  private func permissionsMayHaveChanged(from waiting: Int) {
    if transcript.pendingPermissions.count != waiting { onPermissionsChanged?() }
  }

  private func handle(_ event: AgentProcess.Event) {
    switch event {
    case .messages(let messages):
      for message in messages { apply(message) }
    case .stderr(let text):
      diagnostics = String((diagnostics + text).suffix(4000))
    case .exited(let status, _):
      notingPermissions { transcript.processExited() }
      process = nil
      if case .failed = phase { return }
      phase = .exited(status: status)
      onStopped?()
    }
  }

  private func apply(_ message: StreamMessage) {
    if case .controlResponse(let response) = message, response.requestID.hasPrefix("context-") {
      if response.isSuccess, let reply = ContextUsageReply(response.response) {
        reportedContext = reply
      }
      return
    }
    let waiting = transcript.pendingPermissions.count
    transcript.apply(message)
    if transcript.pendingPermissions.count > waiting,
      let pending = transcript.pendingPermissions.last
    {
      onPermissionRequested?(pending)
    }
    permissionsMayHaveChanged(from: waiting)
    if case .result = message {
      if savedTarget == nil { savedTarget = findTarget() }
      // Not `write`: a failed context request must not mark the session failed.
      try? process?.send(.contextUsage(requestID: nextRequestID("context")))
      onTurnEnded?()
    }
  }

  /// The transcript lands under whichever account the shell selected; look for it in each.
  /// It exists from the first prompt on, which is when `system/init` gave the id.
  private func findTarget() -> ResumeTarget? {
    guard let id = sessionID else { return nil }
    for account in accounts() {
      let projects = account.directory.appending(path: "projects")
      let folders =
        (try? FileManager.default.contentsOfDirectory(atPath: projects.path(percentEncoded: false)))
        ?? []
      for name in folders {
        let file = projects.appending(path: "\(name)/\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
          continue
        }
        return ResumeTarget(
          sessionID: id, cwd: transcript.session?.cwd ?? folder.path(percentEncoded: false),
          file: file.path(percentEncoded: false),
          accountDirectory: account.directory.path(percentEncoded: false),
          accountIsDefault: account.isDefault)
      }
    }
    return nil
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
