import DrakarKit
import Foundation
import Observation

/// One session in a project window: its history from disk, and its agent's process from its
/// first prompt on.
///
/// Main-actor state over an `AgentProcess` and an `AgentBackend`: lines are parsed off the
/// main thread, interpreted by the backend, and applied here, which is all the view observes.
@Observable
final class AgentSession {
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
  /// Claude Code's only: a Codex target's account fields are placeholders.
  var effectiveAccount: ClaudeAccount? {
    features.showsAccount ? account ?? resuming?.account : nil
  }
  /// The end of the CLI's stderr, shown when the process fails.
  private(set) var diagnostics = ""
  /// The process's answer to `get_context_usage` after its last turn: the exact window.
  private(set) var reportedContext: ContextUsageReply?
  /// What reopening the window resumes: known from the start for a resumed session, and
  /// from its first finished turn for a new one or a fork, once its transcript exists.
  private(set) var savedTarget: ResumeTarget?
  /// The transcript's history was read into `transcript`.
  private(set) var hasLoadedHistory = false
  /// The agent's wire format: how it starts, what its lines mean, how a command is written.
  @ObservationIgnored let backend: AgentBackend
  /// Open in another process: the transcript follows its file and nothing is sent.
  var isReadOnly = false
  /// Its files are moving to another account (`SessionMoves`): nothing is sent and no
  /// process starts, since one would resume the session where it no longer is.
  var isMoving = false
  /// The mode the process last reported: `system/init`, a `status` line, a confirmed
  /// change. Nil without a process.
  private(set) var permissionMode: String?
  /// What this session's pills picked; nil follows Settings. Frozen at each start.
  private(set) var modePick: PermissionMode?
  private(set) var modelPick: String?
  /// The effort this session's pill picked; nil leaves Claude Code's. Lasts across starts.
  private(set) var effortPick: String?
  /// The effort the process says it applies (`get_settings`): `settings.json`'s, else the
  /// model's own. Nil without a process, or for a model without effort.
  private(set) var appliedEffort: String?
  /// The model the process says it runs (`get_settings`' `applied.model`), after its start
  /// and after each switch; nil without a process.
  private(set) var appliedModel: String?
  /// The running process started with `--allow-dangerously-skip-permissions`.
  private(set) var launchedWithBypass = false
  /// Why the last change was refused, or that it takes from the next turn, until the next
  /// change.
  private(set) var pillNote: String?
  /// What `pillNote` says of a pick made mid-turn that takes from the next one.
  static let fromNextTurn = String(localized: "From the next turn")
  /// The note is a refusal, shown in red; the next-turn note is only information.
  var pillNoteIsRefusal: Bool { pillNote != nil && pillNote != Self.fromNextTurn }
  /// Where `initialize`'s model list goes; tests give their own.
  @ObservationIgnored var catalog: ModelCatalog = .shared
  /// Switches the CLI has not answered, oldest first: which pill, and what puts it back if
  /// refused.
  @ObservationIgnored private var unansweredChanges: [UnansweredChange] = []
  /// The name given here, by a rename or to a fork: shown at once, ahead of the history's.
  private(set) var name: String?
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
  /// A start that failed before any process ran (folder gone, no CLI): no stop is reported.
  @ObservationIgnored var onFailed: (() -> Void)?
  /// The number of waiting permission requests changed: asked, answered, cancelled, or gone
  /// with the process.
  @ObservationIgnored var onPermissionsChanged: (() -> Void)?
  /// A prompt was sent: whatever the last turn asked is answered.
  @ObservationIgnored var onPromptSent: (() -> Void)?
  /// The person answered what the session waited on: a permission request, or the turn
  /// that ended with a prompt. Not a session's first prompt, nor one queued mid-turn.
  @ObservationIgnored var onReplied: (() -> Void)?
  /// The process answered `initialize`: its reply, which lists the skills.
  @ObservationIgnored var onInitialized: ((JSONValue?) -> Void)?
  /// The commands and skills changed mid-session: the new list, as `initialize` lists them.
  @ObservationIgnored var onCommandsChanged: ((JSONValue) -> Void)?
  /// A turn ended with prompts queued, and nobody was told yet: the next lifecycle line says
  /// whether one starts a turn or the queue empties without one.
  @ObservationIgnored private var turnEndDeferred = false

  @ObservationIgnored private var process: AgentProcess?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var historyLoad: Task<Void, Never>?
  /// True from the start for a session with a transcript, until its history is read.
  @ObservationIgnored private var isLoadingHistory = false
  @ObservationIgnored private var promptsDuringLoad:
    [(text: String, context: String?, attachments: [AttachmentPreview])] = []
  /// The history could not be read: the reason stays in `phase` and nothing is sent.
  @ObservationIgnored private var historyFailed = false
  @ObservationIgnored private var follower: TranscriptFollower?
  /// A prompt sent before the process existed, written right after `initialize`.
  @ObservationIgnored private var pendingPrompt: AgentCommand?
  /// A name the CLI has not recorded yet: passed with `--name` to the next start, or sent
  /// once a running process has said which session it is.
  @ObservationIgnored private var unsentName: String?
  /// Bumped by every `stop()`: a spawn that started before one must not start a process
  /// after it, for a window that closed or a row that was removed meanwhile.
  @ObservationIgnored private var stopCount = 0

  /// `agent` nil takes the target's, else Claude Code. `backend` stands in for tests.
  init(
    folder: URL, resuming: ResumeTarget? = nil, agent: AgentKind? = nil,
    backend: AgentBackend? = nil
  ) {
    self.folder = folder
    self.resuming = resuming
    self.backend = backend ?? (agent ?? resuming?.agentKind ?? .claude).makeBackend()
    savedTarget = resuming?.forks == true ? nil : resuming
    isLoadingHistory = resuming != nil
  }

  /// What its sessions can do beyond a conversation, which the views ask.
  var features: AgentFeatures { backend.features }
  var agent: AgentKind { features.agent }

  /// The session's id once known: the resumed one at once, a new one or a fork's from
  /// `system/init`. A fork never answers with the original's id, which another process owns.
  var sessionID: String? {
    transcript.session?.sessionID ?? (resuming?.forks == true ? nil : resuming?.sessionID)
  }

  /// The session's name, or the title Claude Code gave it, from its history.
  var title: String? { name ?? transcript.title }

  var isProcessRunning: Bool { process != nil }

  var canSend: Bool {
    !isReadOnly && !isMoving && !historyFailed && !transcript.isRunning && phase != .starting
  }

  /// A prompt typed while a turn runs goes now, and waits in the CLI until it can be taken:
  /// at the next tool boundary, or once the turn ends.
  var canQueue: Bool {
    !isReadOnly && !isMoving && !historyFailed && transcript.isRunning && process != nil
  }

  /// The mode the pill shows: the process's while it runs, else what the next start takes.
  var shownMode: String {
    if isProcessRunning, let permissionMode { return permissionMode }
    return (startingMode ?? .ask).rawValue
  }

  /// The mode the next start passes: this session's pick, else Settings' default for its
  /// agent; Bypass only while Settings allows it.
  var startingMode: PermissionMode? {
    let fallback = agent == .codex ? ClaudeChoice.codexDefaultMode : ClaudeChoice.defaultMode
    let mode = modePick ?? (isProcessRunning ? nil : fallback)
    return mode == .bypass && !ClaudeChoice.allowsBypass ? nil : mode
  }

  /// The model picked for the session: its own, else (before a start) Settings' default;
  /// nil for Claude Code's.
  var pickedModel: String? {
    modelPick
      ?? (isProcessRunning || !features.usesSettingsDefaults ? nil : ClaudeChoice.defaultModel)
  }

  /// The effort the pill shows: the session's pick, else what the process applies, else
  /// (before a start) Settings' default.
  var shownEffort: String? {
    effortPick ?? appliedEffort
      ?? (isProcessRunning || !features.usesSettingsDefaults ? nil : ClaudeChoice.defaultEffort)
  }

  /// The model running now, as the process says it after a switch, with the `[1m]` its
  /// start reported when it is the same model; else its start's.
  var runningModel: String? {
    let started = transcript.session?.model
    guard let appliedModel else { return started }
    if let started, started.replacingOccurrences(of: "[1m]", with: "") == appliedModel {
      return started
    }
    return appliedModel
  }

  /// Bypass can be picked: Settings allows it, and a running process started able to.
  var offersBypass: Bool {
    ClaudeChoice.allowsBypass && (!isProcessRunning || launchedWithBypass)
  }

  /// At once on a running process, mid-turn included; else at the next start. The
  /// session's alone: Settings keeps its default.
  func setMode(_ mode: PermissionMode) {
    pillNote = nil
    let (previousPick, previousMode) = (modePick, permissionMode)
    modePick = mode
    // Codex's running turn keeps its policy, but what Bypass lets through is accepted at
    // once (`CodexPolicy.letsThrough`): it already holds.
    if !features.picksApplyAtOnce, transcript.isRunning, mode != .bypass {
      pillNote = Self.fromNextTurn
    }
    guard let process else { return }
    permissionMode = mode.rawValue
    guard let id = try? backend.send(.setMode(mode.rawValue), to: process) else { return }
    unansweredChanges.append(
      .init(id: id, pill: .mode) { [weak self] in
        self?.modePick = previousPick
        self?.permissionMode = previousMode
      })
  }

  /// `value` as `initialize`'s `models` give it; `default` is Claude Code's own.
  func setModel(_ value: String) {
    pillNote = nil
    let previous = modelPick
    modelPick = value
    if !features.picksApplyAtOnce, transcript.isRunning {
      pillNote = Self.fromNextTurn
    }
    guard let process else { return }
    guard let id = try? backend.send(.setModel(value), to: process) else { return }
    unansweredChanges.append(
      .init(id: id, pill: .model) { [weak self] in self?.modelPick = previous })
  }

  /// `level` as the model's `effortLevels` give it. At once on a running process, as a flag
  /// setting that never reaches `settings.json`; else at the next start.
  func setEffort(_ level: String) {
    pillNote = nil
    let previous = effortPick
    effortPick = level
    if !features.picksApplyAtOnce, transcript.isRunning {
      pillNote = Self.fromNextTurn
    }
    guard let process else { return }
    guard let id = try? backend.send(.setEffort(level), to: process) else { return }
    unansweredChanges.append(
      .init(id: id, pill: .effort) { [weak self] in self?.effortPick = previous })
  }

  /// A refusal puts back its own pick only. A later switch of the same pill still in
  /// flight shows over it, and takes over what to put back should it be refused too.
  private func changeAnswered(_ id: String, refusal: String?) {
    guard let index = unansweredChanges.firstIndex(where: { $0.id == id }) else {
      if let refusal { pillNote = refusal }
      return
    }
    let change = unansweredChanges.remove(at: index)
    guard let refusal else { return }
    if let later = unansweredChanges[index...].firstIndex(where: { $0.pill == change.pill }) {
      unansweredChanges[later].revert = change.revert
    } else {
      change.revert()
    }
    pillNote = refusal
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
    if let resuming, resuming.agentKind == .codex { return await readCodexHistory(resuming) }
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
    // Said where the next message would be sent from: a session another process runs sends
    // nothing from here.
    if !isReadOnly, features.showsPromptCache { self.transcript.noteColdCache() }
    // Prompts typed while the history was being read go after it.
    for prompt in promptsDuringLoad {
      self.transcript.addPrompt(
        prompt.text, context: prompt.context, attachments: prompt.attachments)
    }
    promptsDuringLoad = []
  }

  /// A Codex session's history, from a short-lived `codex app-server`. Unreadable, the session
  /// opens empty with a note and still resumes its thread on the next prompt.
  private func readCodexHistory(_ target: ResumeTarget) async {
    let environment = await Self.environment.value
    var loaded: [AgentEvent] = []
    var problem: String?
    if let executable = executableOverride ?? CodexLaunch.locate(path: environment["PATH"]) {
      do {
        loaded = try await CodexHistory.events(
          threadID: target.sessionID,
          configuration: CodexLaunch.configuration(
            executable: executable, environment: environment, folder: folder))
      } catch {
        problem = error.localizedDescription
      }
    } else {
      problem = CodexLaunch.notFound
    }
    isLoadingHistory = false
    var transcript = Transcript()
    for event in loaded { transcript.apply(event) }
    if let problem {
      transcript.apply(
        .note(
          .init(
            text: String(localized: "Codex's history of this session could not be read: \(problem)")
          )))
    }
    self.transcript = transcript
    hasLoadedHistory = true
    for prompt in promptsDuringLoad {
      self.transcript.addPrompt(
        prompt.text, context: prompt.context, attachments: prompt.attachments)
    }
    promptsDuringLoad = []
  }

  /// What another process appended, for a read-only session.
  func catchUp() {
    guard isReadOnly, var follower else { return }
    try? follower.catchUp(&transcript)
    self.follower = follower
  }

  /// `context` is the editor's open file or selections, sent ahead of the text as the
  /// extension's chat sends it, and `attachments` after it. Starts the process when there is
  /// none. A prompt of attachments alone needs no text.
  func send(
    _ prompt: String, context: [EditorSelection] = [], attachments: [Attachment] = []
  ) {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend || canQueue, !text.isEmpty || !attachments.isEmpty else { return }
    let label = context.isEmpty ? nil : context.map(\.label).joined(separator: ", ")
    let previews = attachments.map(\.preview)
    // Named, so that the CLI's lifecycle lines say when it is taken, and it can be cancelled.
    let uuid = UUID().uuidString.lowercased()
    let command = AgentCommand.prompt(
      text: text, context: context, uuid: uuid, attachments: attachments)
    if canQueue {
      transcript.queue(
        QueuedPrompt(uuid: uuid, text: text, context: label, attachments: previews))
      onPromptSent?()
      write(command)
      return
    }
    let answersTurn = !transcript.entries.isEmpty
    transcript.addPrompt(text, context: label, attachments: previews)
    onPromptSent?()
    if answersTurn { onReplied?() }
    if isLoadingHistory { promptsDuringLoad.append((text, label, previews)) }
    if process == nil {
      pendingPrompt = command
      // Counted now, not when the task runs: a `stop()` before then cancels it too.
      let stops = stopCount
      Task { await spawn(unlessStoppedSince: stops) }
    } else {
      write(command)
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
      if savedTarget == nil, transcript.session?.sessionID != nil { savedTarget = locateTarget() }
      // A session whose process ended goes on under its own id, never as a fork again.
      if let saved = savedTarget { resuming = saved }
    }
    phase = .starting
    await loadHistory()
    guard stillWanted(since: stops) else { return }
    if historyFailed { return fail(nil) }
    // The pills' picks, frozen for this process: the session's own, else Settings'.
    modelPick = pickedModel
    modePick = startingMode
    let effort = effortPick ?? (features.usesSettingsDefaults ? ClaudeChoice.defaultEffort : nil)
    let allowsBypass = ClaudeChoice.allowsBypass
    let environment = await Self.environment.value
    guard stillWanted(since: stops) else { return }
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return fail(String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    let start = AgentStart(
      folder: folder, resuming: resuming, environment: environment,
      executableOverride: executableOverride, model: modelPick, mode: modePick, effort: effort,
      allowsBypass: allowsBypass, name: unsentName)
    let launch = backend.launch(start)
    account = launch.account
    guard let configuration = launch.configuration else { return fail(backend.notFoundMessage) }
    executable = launch.executable
    // The last word before the process starts, with no await after it: a session live in
    // another process now is followed, not written to. The monitor may not have read the
    // registries yet at launch, so the account's own registry is read here too.
    if let resuming, resuming.forks != true, isLiveElsewhere(resuming) {
      isReadOnly = true
      _ = stillWanted(since: stops)
      return
    }
    let process = AgentProcess(configuration)
    do {
      let stream = try process.start()
      self.process = process
      // A switch the previous process never answered never will be.
      unansweredChanges.removeAll()
      launchedWithBypass = start.allowsBypass
      unsentName = nil
      try backend.started(process, then: pendingPrompt)
      pendingPrompt = nil
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
    guard target.agentKind == .claude else { return false }
    let monitor = SessionMonitor.shared
    if monitor.hasReadRegistries, monitor.liveIDs.contains(target.sessionID) { return true }
    return LiveSession.read(account: target.account).contains { $0.sessionID == target.sessionID }
  }

  /// Runs the plan: with edits accepted, in auto mode when `autoMode`, the mode switched
  /// first as the extension switches it; or each edit approved, which leaves plan mode for
  /// the default one.
  func approvePlan(_ pending: Transcript.PendingPermission, editsManually: Bool, autoMode: Bool) {
    if !editsManually { setMode(autoMode ? .auto : .acceptEdits) }
    answer(pending, PlanApproval.approve(pending.request.input, editsManually: editsManually))
  }

  func answer(_ pending: Transcript.PendingPermission, _ decision: PermissionDecision) {
    write(.answer(requestID: pending.requestID, decision: decision))
    notingPermissions { transcript.resolvePermission(requestID: pending.requestID) }
    onReplied?()
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

  /// Names the session as `/rename` does. A running process records it; a session with a
  /// transcript and no process gets it written there; one with neither takes it when it
  /// starts. False when it cannot be named: read-only, moving, or its file not writable.
  @discardableResult func rename(to newName: String) -> Bool {
    guard let title = SessionTitle.clean(newName), !isReadOnly, !isMoving else { return false }
    if process != nil {
      unsentName = title
      sendUnsentName()
    } else if agent == .claude, let target = ownTarget() {
      // Written behind no process's back: one opened elsewhere since would keep its own name.
      guard !isLiveElsewhere(target),
        (try? SessionTitle.write(
          title, sessionID: target.sessionID, transcript: target.transcriptFile)) != nil
      else { return false }
    } else {
      unsentName = title
    }
    name = title
    return true
  }

  /// The transcript this session writes to, once it has one: never a fork's original.
  private func ownTarget() -> ResumeTarget? {
    if let savedTarget { return savedTarget }
    if let resuming, resuming.forks != true { return resuming }
    if transcript.session?.sessionID != nil { savedTarget = locateTarget() }
    return savedTarget
  }

  /// The running process is told the name once it has said which session it is.
  private func sendUnsentName() {
    guard let title = unsentName, let process, let id = sessionID else { return }
    unsentName = nil
    // Not `write`: a name that did not take must not mark the session failed.
    _ = try? backend.send(.rename(title: title, sessionID: id), to: process)
  }

  /// Stops the turn, and drops what was queued behind it: stop means stop. Esc keeps the
  /// queue, as the extension's does: what was queued runs next.
  func interrupt(keepingQueued: Bool = false) {
    guard transcript.isRunning else { return }
    write(.interrupt(cancelQueued: !keepingQueued))
  }

  /// Takes back a prompt sent while a turn ran, unless the CLI took it already; it leaves
  /// the queue on the CLI's `cancelled`.
  func cancelQueued(_ prompt: QueuedPrompt) {
    if let process { _ = try? backend.send(.cancelQueued(uuid: prompt.uuid), to: process) }
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
    appliedEffort = nil
    appliedModel = nil
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
    onFailed?()
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
    case .lines(let lines):
      for line in lines { receive(line) }
    case .stderr(let text):
      diagnostics = String((diagnostics + text).suffix(4000))
    case .exited(let status, _):
      notingPermissions { transcript.processExited() }
      process = nil
      permissionMode = nil
      appliedEffort = nil
      appliedModel = nil
      if case .failed = phase { return }
      phase = .exited(status: status)
      onStopped?()
    }
  }

  private func receive(_ line: AgentProcess.Line) {
    guard let process else { return }
    let output = backend.receive(line, from: process, at: .now)
    for signal in output.signals { handle(signal) }
    let waiting = transcript.pendingPermissions.count
    var turnEnded = false
    for event in output.events {
      transcript.apply(event)
      if case .turnEnded = event { turnEnded = true }
    }
    if unsentName != nil { sendUnsentName() }
    if transcript.pendingPermissions.count > waiting,
      let pending = transcript.pendingPermissions.last
    {
      onPermissionRequested?(pending)
    }
    permissionsMayHaveChanged(from: waiting)
    if turnEndDeferred, output.signals.contains(.queueChanged) {
      if transcript.isRunning {
        turnEndDeferred = false
      } else if transcript.queuedPrompts.isEmpty {
        turnEndDeferred = false
        onTurnEnded?()
      }
    }
    if turnEnded {
      if !features.picksApplyAtOnce { pillNote = nil }
      if savedTarget == nil { savedTarget = locateTarget() }
      // Not while a queued prompt is about to start the next one: said once the queue
      // empties without a turn, should it be cancelled or refused instead.
      if transcript.queuedPrompts.isEmpty { onTurnEnded?() } else { turnEndDeferred = true }
    }
  }

  private func handle(_ signal: SessionSignal) {
    switch signal {
    case .rateLimit(let info):
      if let account { accountStore.record(info, for: account) }
    case .models(let models):
      if agent == .codex {
        catalog.recordCodex(models)
      } else if let account {
        catalog.record(models, for: account)
      }
    case .modeAdopted(let mode):
      adopt(mode: mode)
    case .initialized(let reply):
      onInitialized?(reply)
    case .commandsChanged(let commands):
      onCommandsChanged?(commands)
    case .settingsApplied(let effort, let model):
      appliedEffort = effort
      appliedModel = model
    case .contextReported(let reply):
      reportedContext = reply
    case .changeAnswered(let id, let refusal):
      changeAnswered(id, refusal: refusal)
    case .queueChanged:
      break
    case .skillsChanged:
      CodexSkillStore.shared.skills(for: folder).refreshIfLoaded()
    case .unusable(let message):
      stop()
      phase = .failed(message)
      // As an exit says it: the window refreshes its attention and marks a background row.
      onStopped?()
    }
  }

  /// The transcript lands under whichever account the shell selected; look for it in each.
  /// It exists from the first prompt on, which is when the session gave its id.
  private func locateTarget() -> ResumeTarget? {
    guard let id = sessionID else { return nil }
    return backend.locateTarget(
      sessionID: id, cwd: transcript.session?.cwd ?? folder.path(percentEncoded: false),
      in: accounts())
  }

  private func write(_ command: AgentCommand) {
    guard let process else { return }
    do {
      try backend.send(command, to: process)
    } catch {
      phase = .failed(error.localizedDescription)
    }
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

/// A mode, model or effort switch sent and not yet answered.
private struct UnansweredChange {
  enum Pill { case mode, model, effort }

  var id: String
  var pill: Pill
  var revert: () -> Void
}
