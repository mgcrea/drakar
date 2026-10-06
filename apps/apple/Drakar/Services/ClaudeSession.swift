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
  /// The account the session runs, or will resume, under; nil for a new session not yet
  /// started, which takes the window's.
  var effectiveAccount: ClaudeAccount? { account ?? resuming?.account }
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
  /// Its files are moving to another account (`SessionMoves`): nothing is sent and no
  /// process starts, since one would resume the session where it no longer is.
  var isMoving = false
  /// The mode the process last reported: `system/init`, a `status` line, a confirmed
  /// change. Nil without a process.
  private(set) var permissionMode: String?
  /// What this session's pills picked; nil follows the folder's pick. Frozen at each start.
  private(set) var modePick: PermissionMode?
  private(set) var modelPick: String?
  /// The running process started with `--allow-dangerously-skip-permissions`.
  private(set) var launchedWithBypass = false
  /// Why the last change was refused, until the next change.
  private(set) var pillNote: String?
  /// Where `initialize`'s model list goes; tests give their own.
  @ObservationIgnored var catalog: ModelCatalog = .shared
  /// Each switch sent and not yet answered, by request id: what its success keeps (the
  /// folder's pick) and what its refusal puts back.
  @ObservationIgnored private var pendingSwitches:
    [String: (confirm: () -> Void, revert: () -> Void)] = [:]
  /// The earlier question the person closed without answering, so it is not offered again.
  private(set) var dismissedQuestionID: String?
  /// Stands in for the located binary, in tests.
  @ObservationIgnored var executableOverride: URL?
  /// The accounts a new session's transcript is looked for in; the discovered ones, or a
  /// test's.
  @ObservationIgnored var accounts: () -> [ClaudeAccount] = { ClaudeAccount.discover() }
  /// Where the session's `rate_limit_event`s go; tests give it their own.
  @ObservationIgnored var accountStore: AccountStore = .shared

  /// For the window's attention: a turn ended, a permission request arrived, the process
  /// stopped on its own.
  @ObservationIgnored var onTurnEnded: (() -> Void)?
  @ObservationIgnored var onPermissionRequested: ((Transcript.PendingPermission) -> Void)?
  @ObservationIgnored var onStopped: (() -> Void)?
  /// The number of waiting permission requests changed: asked, answered, cancelled, or gone
  /// with the process.
  @ObservationIgnored var onPermissionsChanged: (() -> Void)?
  /// A prompt was sent: whatever the last turn asked is answered.
  @ObservationIgnored var onPromptSent: (() -> Void)?
  /// The process answered `initialize`: its reply, which lists the skills.
  @ObservationIgnored var onInitialized: ((JSONValue?) -> Void)?

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
    !isReadOnly && !isMoving && !historyFailed && !transcript.isRunning && phase != .starting
  }

  /// The mode the pill shows: the process's while it runs, else what the next start takes.
  var shownMode: String {
    if isProcessRunning, let permissionMode { return permissionMode }
    return (startingMode ?? .ask).rawValue
  }

  /// The mode the next start passes: this session's pick, else the folder's; Bypass only
  /// while Settings allows it.
  var startingMode: PermissionMode? {
    let mode =
      modePick
      ?? (isProcessRunning
        ? nil
        : ClaudeChoice.sessionPicks(for: folder).mode.flatMap(PermissionMode.init(rawValue:)))
    return mode == .bypass && !ClaudeChoice.allowsBypass ? nil : mode
  }

  /// The model picked for the session: its own, else (before a start) the folder's; nil for
  /// Claude Code's default.
  var pickedModel: String? {
    modelPick ?? (isProcessRunning ? nil : ClaudeChoice.sessionPicks(for: folder).model)
  }

  /// Bypass can be picked: Settings allows it, and a running process started able to.
  var offersBypass: Bool {
    ClaudeChoice.allowsBypass && (!isProcessRunning || launchedWithBypass)
  }

  /// At once on a running process, mid-turn included; else at the next start. The folder
  /// remembers it, Bypass aside, once the CLI took it.
  func setMode(_ mode: PermissionMode) {
    pillNote = nil
    let (previousPick, previousMode) = (modePick, permissionMode)
    modePick = mode
    guard let process else { return ClaudeChoice.pickMode(mode, for: folder) }
    permissionMode = mode.rawValue
    let id = nextRequestID("mode")
    pendingSwitches[id] = (
      confirm: { [folder] in ClaudeChoice.pickMode(mode, for: folder) },
      revert: { [weak self] in
        self?.modePick = previousPick
        self?.permissionMode = previousMode
      }
    )
    try? process.send(.setPermissionMode(requestID: id, mode: mode.rawValue))
  }

  /// `value` as `initialize`'s `models` give it; `default` is Claude Code's own.
  func setModel(_ value: String) {
    pillNote = nil
    let previous = modelPick
    modelPick = value
    guard let process else { return ClaudeChoice.pickModel(value, for: folder) }
    let id = nextRequestID("model")
    pendingSwitches[id] = (
      confirm: { [folder] in ClaudeChoice.pickModel(value, for: folder) },
      revert: { [weak self] in self?.modelPick = previous }
    )
    try? process.send(.setModel(requestID: id, model: value))
  }

  /// The CLI's word on its mode, whoever changed it: the pill shows it, and a restart
  /// carries on in it.
  private func adopt(mode: String) {
    permissionMode = mode
    if let known = PermissionMode(rawValue: mode) { modePick = known }
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
    onPromptSent?()
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
    guard stopCount == stops, process == nil, phase != .starting, !isMoving else { return }
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
    // The pills' picks, frozen for this process: the session's own, else the folder's.
    modelPick = pickedModel
    modePick = startingMode
    if let model = modelPick, model != "default" { command.model = model }
    if let mode = modePick, mode != .ask { command.permissionMode = mode.rawValue }
    command.allowsBypass = ClaudeChoice.allowsBypass
    var environment = await Self.environment.value
    guard stillWanted(since: stops) else { return }
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return fail(String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    if let resuming {
      command.resumeSessionID = resuming.sessionID
      command.forksSession = resuming.forks == true
    }
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: resuming, environment: environment,
      executableOverride: executableOverride)
    environment = launch.environment
    account = launch.account
    guard let claude = launch.executable else { return fail(ClaudeLaunch.notFound) }
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
      launchedWithBypass = command.allowsBypass
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

  /// The question the conversation ends on, which its process ended before it was answered
  /// (`Transcript.unansweredQuestion`): offered again in place of the composer, as the
  /// extension offers it, while nothing runs or waits and until it is dismissed.
  var earlierQuestion: Transcript.ToolCall? {
    guard canSend, transcript.pendingPermissions.isEmpty,
      let call = transcript.unansweredQuestion, call.id != dismissedQuestionID
    else { return nil }
    return call
  }

  /// Answers `earlierQuestion` with a prompt, the process that asked being gone: the
  /// resumed one reads it as the answer, and the transcript marks the question answered.
  func answerEarlierQuestion(_ answers: [String: String]) {
    guard let call = earlierQuestion else { return }
    let ordered = UserQuestion.list(call.input).compactMap { question in
      answers[question.question].map { (question: question.question, answer: $0) }
    }
    send(UserQuestion.earlierAnswerPrompt(ordered))
  }

  func dismissEarlierQuestion() {
    dismissedQuestionID = earlierQuestion?.id
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
    permissionMode = nil
    transcript.processExited()
    if case .failed = phase { return }
    if phase == .ready || phase == .starting { phase = .exited(status: 0) }
  }

  /// `stop()`, then the process's own exit, which can take a moment: a `claude` that is
  /// quitting may still write to the files a move is about to take. False when it is
  /// still running after `limit`.
  func stopAndWait(upTo limit: Duration = .seconds(5)) async -> Bool {
    let quitting = process
    stop()
    let deadline = ContinuousClock.now + limit
    while quitting?.isRunning == true {
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  /// The session's files moved to another account (`SessionMover`): its next start resumes
  /// `target` there, and the window's stored project names the new file. For a session
  /// with no process; `SessionMoves` stops an idle one first.
  func relocate(to target: ResumeTarget) {
    resuming = target
    savedTarget = target
    // The process that ran under the old account is gone; until the next one starts, the
    // session is on the account its files are under.
    account = nil
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
      permissionMode = nil
      if case .failed = phase { return }
      phase = .exited(status: status)
      onStopped?()
    }
  }

  private func apply(_ message: StreamMessage) {
    if case .rateLimit(let info) = message, let account {
      accountStore.record(info, for: account)
    }
    if case .controlResponse(let response) = message, response.requestID.hasPrefix("init-"),
      response.isSuccess
    {
      if let models = ModelOption.list(fromInitialize: response.response), let account {
        catalog.record(models, for: account)
      }
      if let mode = response.response?["current_permission_mode"]?.stringValue {
        adopt(mode: mode)
      }
      onInitialized?(response.response)
    }
    if case .controlResponse(let response) = message,
      response.requestID.hasPrefix("mode-") || response.requestID.hasPrefix("model-")
    {
      let pending = pendingSwitches.removeValue(forKey: response.requestID)
      if response.isSuccess {
        pending?.confirm()
        if let mode = response.response?["mode"]?.stringValue { adopt(mode: mode) }
      } else {
        pending?.revert()
        pillNote = response.error ?? String(localized: "Claude Code refused the change.")
      }
      return
    }
    if case .system(.initialized(let info)) = message, let mode = info.permissionMode {
      adopt(mode: mode)
    }
    if case .system(.status(_, let mode?)) = message { adopt(mode: mode) }
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
