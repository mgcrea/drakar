import DrakarKit
import Foundation
import Observation

/// One session in a project window: its history from disk, and its agent's process from its
/// first prompt on.
///
/// Main-actor state over a `ProcessTransport` and an `AgentBackend`: lines are parsed off the
/// main thread, interpreted by the backend, and applied here, which is all the view observes.
/// What it does to the process it notes there too (`SessionNote`), so that a log of the
/// process rebuilds it (`init(replaying:meta:)`).
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
  /// The account picked for this session alone (Run in Each Subfolder's), over its folder's;
  /// it starts there, then resumes where it wrote.
  let accountPick: ClaudeAccount?
  /// The account the session runs, or will resume or start, under; nil for a new session
  /// not yet started and given none, which takes the window's.
  /// Claude Code's only: a Codex target's account fields are placeholders.
  var effectiveAccount: ClaudeAccount? {
    features.showsAccount ? account ?? resuming?.account ?? accountPick : nil
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
  /// The place in a batch this session was started for, kept in its meta.
  var fanOut: FanOutMark?
  /// The earlier question the person closed without answering, so it is not offered again.
  private(set) var dismissedQuestionID: String?
  /// Stands in for the located binary, in tests.
  @ObservationIgnored var executableOverride: URL?
  /// The accounts a new session's transcript is looked for in; the discovered ones, or a
  /// test's.
  @ObservationIgnored var accounts: () -> [ClaudeAccount] = { ClaudeAccount.discover() }
  /// Where the session's `rate_limit_event`s go; tests give it their own.
  @ObservationIgnored var accountStore: AccountStore = .shared

  /// For the window's attention: a turn ended, a permission request or an MCP server's
  /// question arrived, the process stopped on its own.
  @ObservationIgnored var onTurnEnded: (() -> Void)?
  @ObservationIgnored var onPermissionRequested: (() -> Void)?
  @ObservationIgnored var onStopped: (() -> Void)?
  /// A start that failed before any process ran (folder gone, no CLI): no stop is reported.
  @ObservationIgnored var onFailed: (() -> Void)?
  /// The number of permission requests and questions waiting changed: asked, answered,
  /// cancelled, or gone with the process.
  @ObservationIgnored var onPermissionsChanged: (() -> Void)?
  /// A prompt was sent: whatever the last turn asked is answered.
  @ObservationIgnored var onPromptSent: (() -> Void)?
  /// The person answered what the session waited on: a permission request, a question, or
  /// the turn that ended with a prompt. Not a session's first prompt, nor one queued mid-turn.
  @ObservationIgnored var onReplied: (() -> Void)?
  /// The process answered `initialize`: its reply, which lists the skills.
  @ObservationIgnored var onInitialized: ((JSONValue?) -> Void)?
  /// The commands and skills changed mid-session: the new list, as `initialize` lists them.
  @ObservationIgnored var onCommandsChanged: ((JSONValue) -> Void)?
  /// A turn ended with prompts queued, and nobody was told yet: the next lifecycle line says
  /// whether one starts a turn or the queue empties without one.
  @ObservationIgnored private var turnEndDeferred = false

  /// The process, or after a replay the `ReplayTransport` it wrote to.
  @ObservationIgnored private(set) var process: (any ProcessTransport)?
  /// What a spawn runs on; nil for the session host's, or an `AgentProcess` when there is no
  /// host to have. Tests give a recorder.
  @ObservationIgnored var makeTransport:
    ((AgentProcess.Configuration) async -> any ProcessTransport)?
  /// The host a spawn tries first; tests give their own.
  @ObservationIgnored var sessionHost = SessionHost.shared
  /// The project window the session belongs to, which its folder need not be (a subfolder,
  /// a worktree): a relaunched app reopens it from the meta.
  @ObservationIgnored var windowFolder: URL?
  /// What the last process was launched with and where the history stood then: the parts of
  /// `meta()` only a start sets.
  @ObservationIgnored private var launched: (start: AgentStart, history: HistoryMark)?
  /// The meta the host holds for the process, so that only a change is sent.
  @ObservationIgnored private var sentMeta: SessionMeta?
  /// Rebuilding from a log: what happened was told when it happened, so no callback runs.
  @ObservationIgnored private var isReplaying = false
  /// The skills and commands the replayed process listed, which no callback said: for
  /// `reportReplayedCommands()`.
  @ObservationIgnored private var replayedInitialize: JSONValue??
  @ObservationIgnored private var replayedCommands: JSONValue?
  /// Whether the replay read the process's start. A quit before the host answered the spawn
  /// logged none, and the process is started once live.
  @ObservationIgnored private var replayedStart = false
  /// The connection to the session host ended under the running process: nothing is sent
  /// until a new one is up and the process attached again (spec §5).
  private(set) var isReconnecting = false
  /// The session host may hold this session's process, which the window is taking back:
  /// nothing is sent and no process starts until it has, or one would run beside it.
  var waitsForHost = false
  /// Its process runs on in the session host out of this app's reach: another Drakar holds
  /// it (`heldElsewhere`), or it could not be taken back. Nothing is sent and no process
  /// starts, which would run the session twice, until it is taken back.
  private(set) var isOutOfReach = false
  /// The session host's id for the process another Drakar holds (spec §4), or a host of an
  /// older protocol: the session is shown read-only, and its row takes the process back once
  /// that app lets it go (`released`).
  private(set) var heldElsewhere: String?
  /// The longest a replay held the main actor between two of its waits; for tests.
  @ObservationIgnored private(set) var longestReplayHold = Duration.zero
  /// The turns Codex's thread holds, as `throughTurns` counts them.
  @ObservationIgnored private var codexTurns = 0
  /// Those its process found there: where a replay cuts the thread's history
  /// (`HistoryMark.codexTurns`), the rest being in the process's log.
  @ObservationIgnored private(set) var codexTurnsBeforeProcess = 0
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var historyLoad: Task<Void, Never>?
  /// True from the start for a session with a transcript, until its history is read.
  @ObservationIgnored private var isLoadingHistory = false
  @ObservationIgnored private var promptsDuringLoad:
    [(text: String, context: String?, attachments: [AttachmentPreview])] = []
  /// The history could not be read: the reason stays in `phase` and nothing is sent.
  @ObservationIgnored private var historyFailed = false
  @ObservationIgnored private var follower: TranscriptFollower?
  /// A prompt sent before the process existed, written right after `initialize`, and what
  /// the transcript showed of it.
  @ObservationIgnored private var pendingPrompt: AgentCommand?
  @ObservationIgnored private var pendingEffect: NoteEffect = .none
  /// A name the CLI has not recorded yet: passed with `--name` to the next start, or sent
  /// once a running process has said which session it is.
  @ObservationIgnored private var unsentName: String?
  /// Bumped by every `stop()`: a spawn that started before one must not start a process
  /// after it, for a window that closed or a row that was removed meanwhile.
  @ObservationIgnored private var stopCount = 0

  /// `agent` nil takes the target's, else Claude Code. `backend` stands in for tests.
  init(
    folder: URL, resuming: ResumeTarget? = nil, agent: AgentKind? = nil,
    account: ClaudeAccount? = nil, backend: AgentBackend? = nil
  ) {
    self.folder = folder
    self.resuming = resuming
    accountPick = account
    self.backend = backend ?? (agent ?? resuming?.agentKind ?? .claude).makeBackend()
    savedTarget = resuming?.forks == true ? nil : resuming
    isLoadingHistory = resuming != nil
  }

  /// The session a process's log rebuilds: the history from before the process, then
  /// `records` replayed. Its process stands in for the one the log came from, so nothing
  /// reaches the CLI, and what the replay owes it waits in its `ReplayTransport`.
  convenience init(
    replaying records: [HostRecord], meta: SessionMeta, backend: AgentBackend? = nil
  ) async {
    self.init(
      folder: meta.start.folder, resuming: meta.savedTarget ?? meta.start.resuming,
      agent: meta.agent, account: meta.accountPick, backend: backend)
    modePick = meta.modePick
    modelPick = meta.modelPick
    effortPick = meta.effortPick
    name = meta.name
    fanOut = meta.fanOut
    executableOverride = meta.start.executableOverride
    windowFolder = URL(filePath: meta.windowFolder, directoryHint: .isDirectory)
    launched = (meta.start, meta.history)
    let started = records.first?.time ?? .now
    historyLoad = Task { await self.readHistory(meta.history, at: started) }
    await historyLoad?.value
    let launch = self.backend.launch(meta.start)
    account = launch.account
    executable = launch.executable
    launchedWithBypass = meta.start.allowsBypass
    process = ReplayTransport()
    if !historyFailed { phase = .ready }
    await replay(records)
  }

  /// A process the session host holds, after a relaunch (spec §3): rebuilt from its meta and
  /// its log as `init(replaying:meta:)` rebuilds one, then live on it, what the replay owes
  /// it sent first. One that ended meanwhile shows its end as it would live, and lets the
  /// host forget it. Nil for a meta this app cannot read.
  convenience init?(reattaching held: HeldProcess, client: HostClient) async {
    guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: held.meta) else {
      return nil
    }
    let hosted = HostedProcess(client: client, held: held)
    let replayed: Result<[HostRecord], any Error>
    do {
      replayed = .success(try await hosted.replay().records)
    } catch {
      replayed = .failure(error)
    }
    await self.init(replaying: (try? replayed.get()) ?? [], meta: meta)
    sentMeta = meta
    switch replayed {
    case .success:
      goLive(on: hosted)
    case .failure(let error):
      // Its process carries on in the host, out of reach: not shown alive and silent.
      process = nil
      isOutOfReach = true
      notingPermissions { transcript.processExited() }
      phase = .failed(Self.message(forReattachFailure: error))
    }
  }

  /// A process another Drakar holds, or an older host (spec §4, §5), shown as a session live
  /// elsewhere is: read-only, Claude Code's transcript file followed. Codex has no file to
  /// follow, so its thread is read up to the process, and a line says where the rest runs.
  /// Nil for a meta this app cannot read.
  convenience init?(heldElsewhere held: HeldProcess) async {
    guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: held.meta) else {
      return nil
    }
    let resumed = meta.start.resuming?.forks == true ? nil : meta.start.resuming
    self.init(
      folder: meta.start.folder, resuming: meta.savedTarget ?? resumed, agent: meta.agent,
      account: meta.accountPick)
    name = meta.name
    modePick = meta.modePick
    modelPick = meta.modelPick
    effortPick = meta.effortPick
    executableOverride = meta.start.executableOverride
    windowFolder = URL(filePath: meta.windowFolder, directoryHint: .isDirectory)
    heldElsewhere = held.id
    isOutOfReach = true
    isReadOnly = true
    if agent == .codex {
      historyLoad = Task { await self.readHistory(meta.history, at: .now) }
      await historyLoad?.value
      transcript.apply(.note(.init(text: Self.runsInAnotherWindow)))
    } else {
      // A first turn not yet finished has no saved target, but has its file.
      if resuming == nil, let id = meta.sessionID,
        let target = backend.locateTarget(
          sessionID: id, cwd: meta.start.folder.path(percentEncoded: false), in: accounts())
      {
        resuming = target
        savedTarget = target
        isLoadingHistory = true
      }
      await loadHistory()
    }
  }

  /// What a Codex row whose process another Drakar holds ends on: nothing of it is live here.
  static let runsInAnotherWindow = String(localized: "Running in another Drakar window.")

  /// From the replay to the process it stood for: its start if the log held none, then the
  /// replies the replay owes, once, then what the process does next as it comes.
  private func goLive(on hosted: HostedProcess) {
    let owed = (process as? ReplayTransport)?.owed ?? []
    process = hosted
    if !replayedStart {
      note(.started(first: nil, effect: .none), to: hosted)
      try? backend.started(hosted, then: nil)
    }
    for line in owed { try? hosted.send(line: line) }
    sendMeta()
    follow(hosted.live(), of: hosted)
  }

  /// The skills and commands a replayed process listed, which the replay told nobody: said
  /// once the window holds the session, as a live start says them.
  func reportReplayedCommands() {
    if let reply = replayedInitialize { onInitialized?(reply) }
    if let commands = replayedCommands { onCommandsChanged?(commands) }
    replayedInitialize = nil
    replayedCommands = nil
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

  /// Its process runs in the session host, so it can outlive the app.
  var isHosted: Bool { process is HostedProcess }

  /// The session host's id for the process, while it has one there.
  var hostID: String? { (process as? HostedProcess)?.id }

  /// Its host keeps an answer to an MCP server's question whole in its log, what was typed
  /// among it: a host older than minor 3, from an earlier build still running. False on a
  /// pipe, which logs nothing.
  var hostLogsAnswersInFull: Bool {
    guard let minor = (process as? HostedProcess)?.hostMinor else { return false }
    return minor < 3
  }

  /// Mid-turn, or waiting on the person: what a quit hands to the host rather than ends.
  var isAtWork: Bool { transcript.isRunning || transcript.isWaitingOnPerson }

  /// The record a relaunched app rebuilds the session from, for its last process; nil before
  /// one was launched.
  func meta() -> SessionMeta? {
    launched.map { meta(start: $0.start, history: $0.history) }
  }

  private func meta(start: AgentStart, history: HistoryMark) -> SessionMeta {
    SessionMeta(
      start: start, windowFolder: (windowFolder ?? folder).path(percentEncoded: false),
      name: name, modePick: modePick, modelPick: modelPick, effortPick: effortPick,
      accountPick: accountPick, sessionID: sessionID, savedTarget: savedTarget,
      fanOut: fanOut, history: history)
  }

  /// Hands the host the meta when it changed; only a hosted process keeps one.
  private func sendMeta() {
    guard let hosted = process as? HostedProcess, let meta = meta(), meta != sentMeta,
      let bytes = try? JSONEncoder().encode(meta)
    else { return }
    sentMeta = meta
    hosted.setMeta(bytes)
  }

  var canSend: Bool {
    !isReadOnly && !isMoving && !historyFailed && !isReconnecting && !waitsForHost
      && !isOutOfReach && !transcript.isRunning && phase != .starting
  }

  /// A prompt typed while a turn runs goes now, and waits in the CLI until it can be taken:
  /// at the next tool boundary, or once the turn ends.
  var canQueue: Bool {
    !isReadOnly && !isMoving && !historyFailed && !isReconnecting && !waitsForHost
      && !isOutOfReach && transcript.isRunning && process != nil
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
    guard let id = try? sendNoted(.setMode(mode.rawValue), to: process) else { return }
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
    guard let id = try? sendNoted(.setModel(value), to: process) else { return }
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
    guard let id = try? sendNoted(.setEffort(level), to: process) else { return }
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
    await readHistory(file, upTo: .max, at: .now)
  }

  /// The history from before a replayed process, as `mark` says it stood. Codex's thread
  /// holds the process's turns too, so it is cut where the process found it; with none
  /// there, it has nothing the log does not.
  private func readHistory(_ mark: HistoryMark, at time: Date) async {
    switch mark {
    case .claudeFile(let path, let length):
      await readHistory(URL(filePath: path), upTo: length, at: time)
    case .codexTurns(let count):
      codexTurnsBeforeProcess = count
      if count > 0, let resuming, resuming.agentKind == .codex {
        await readCodexHistory(resuming, throughTurns: count)
      } else {
        isLoadingHistory = false
      }
      codexTurns = count
    case .none:
      isLoadingHistory = false
    }
  }

  /// `file` up to `length` bytes; `time` is when the next message goes, which says whether
  /// the cache went cold.
  private func readHistory(_ file: URL, upTo length: UInt64, at time: Date) async {
    let loaded = await Task.detached { () -> (Transcript, TranscriptFollower)? in
      var follower = TranscriptFollower(file: file)
      var transcript = Transcript()
      guard (try? follower.catchUp(&transcript, upTo: length)) != nil else { return nil }
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
    if !isReadOnly, features.showsPromptCache { self.transcript.noteColdCache(at: time) }
    // Prompts typed while the history was being read go after it.
    for prompt in promptsDuringLoad {
      self.transcript.addPrompt(
        prompt.text, context: prompt.context, attachments: prompt.attachments)
    }
    promptsDuringLoad = []
  }

  /// A Codex session's history, from a short-lived `codex app-server`, through its `count`th
  /// turn when one is given. Unreadable, the session opens empty with a note and still
  /// resumes its thread on the next prompt.
  private func readCodexHistory(_ target: ResumeTarget, throughTurns count: Int? = nil) async {
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
    if let count { loaded = loaded.throughTurns(count) }
    codexTurns = loaded.turnsEnded
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
      let queued = QueuedPrompt(uuid: uuid, text: text, context: label, attachments: previews)
      transcript.queue(queued)
      onPromptSent?()
      write(command, effect: .queued(queued))
      return
    }
    let answersTurn = !transcript.entries.isEmpty
    transcript.addPrompt(text, context: label, attachments: previews)
    onPromptSent?()
    if answersTurn { onReplied?() }
    if isLoadingHistory { promptsDuringLoad.append((text, label, previews)) }
    let effect = NoteEffect.prompt(text: text, context: label, attachments: previews)
    if process == nil {
      pendingPrompt = command
      pendingEffect = effect
      // Counted now, not when the task runs: a `stop()` before then cancels it too.
      let stops = stopCount
      Task { await spawn(unlessStoppedSince: stops) }
    } else {
      write(command, effect: effect)
    }
  }

  /// Starts `claude`, resuming this session if it has a transcript.
  func spawn() async {
    await spawn(unlessStoppedSince: stopCount)
  }

  /// Every await is a point where the window may have closed (`stop()`) or another process
  /// may have opened the session (`isReadOnly`): after each, either ends the spawn.
  private func spawn(unlessStoppedSince stops: Int) async {
    guard stopCount == stops, process == nil, phase != .starting, !isMoving, !waitsForHost,
      !isOutOfReach
    else { return }
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
      allowsBypass: allowsBypass, name: unsentName,
      account: resuming == nil ? accountPick : nil)
    let launch = backend.launch(start)
    account = launch.account
    guard let configuration = launch.configuration else { return fail(backend.notFoundMessage) }
    executable = launch.executable
    let history = historyMark()
    let meta = meta(start: start, history: history)
    let process = await transport(for: configuration, meta: meta)
    guard stillWanted(since: stops) else { return }
    // The last word before the process starts, with no await after it: a session live in
    // another process now is followed, not written to. The monitor may not have read the
    // registries yet at launch, so the account's own registry is read here too.
    if let resuming, resuming.forks != true, isLiveElsewhere(resuming) {
      isReadOnly = true
      _ = stillWanted(since: stops)
      return
    }
    do {
      let stream = try process.start()
      self.process = process
      launched = (start, history)
      sentMeta = meta
      // A switch the previous process never answered never will be.
      unansweredChanges.removeAll()
      launchedWithBypass = start.allowsBypass
      unsentName = nil
      codexTurnsBeforeProcess = codexTurns
      note(.started(first: pendingPrompt, effect: pendingEffect), to: process)
      try backend.started(process, then: pendingPrompt)
      pendingPrompt = nil
      pendingEffect = .none
      phase = .ready
      // What changed while the host was being reached.
      sendMeta()
      follow(stream, of: process)
    } catch {
      fail(error.localizedDescription)
    }
  }

  /// The session host's process when there is a host, else the app's own child (spec §5).
  /// Nothing spawns until `start()`: the session may still let it go unstarted.
  private func transport(for configuration: AgentProcess.Configuration, meta: SessionMeta)
    async -> any ProcessTransport
  {
    if let makeTransport { return await makeTransport(configuration) }
    guard let client = await sessionHost.client(), let bytes = try? JSONEncoder().encode(meta)
    else { return AgentProcess(configuration) }
    return HostedProcess(client: client, configuration: configuration, meta: bytes)
  }

  /// Where the history stands as a process starts, the rest being in its log: Codex's
  /// thread in turns, Claude Code's transcript file in bytes. A new Claude Code session has
  /// none, and keeps none for that process's life: its file holds only what the log does.
  private func historyMark() -> HistoryMark {
    if agent == .codex { return .codexTurns(codexTurns) }
    guard let resuming, resuming.agentKind == .claude else { return .none }
    let file = resuming.transcriptFile
    let size =
      try? FileManager.default.attributesOfItem(
        atPath: file.path(percentEncoded: false))[.size] as? UInt64
    return .claudeFile(path: file.path(percentEncoded: false), length: size ?? 0)
  }

  /// False when a `stop()` came since `stops` (which already settled the phase), or when
  /// the session became read-only, which leaves it as it was before the prompt.
  private func stillWanted(since stops: Int) -> Bool {
    guard stopCount == stops else { return false }
    guard isReadOnly else { return true }
    phase = .idle
    pendingPrompt = nil
    pendingEffect = .none
    notingPermissions { transcript.processExited() }
    return false
  }

  private func isLiveElsewhere(_ target: ResumeTarget) -> Bool {
    guard target.agentKind == .claude else { return false }
    let monitor = SessionMonitor.shared
    if monitor.hasReadRegistries, monitor.liveIDs.contains(target.sessionID) { return true }
    // What a session host runs counts here, unless one of this app's rows runs it: this
    // session has no process yet, so one there is another app's, even under a host this app
    // started.
    let hosts = Set([sessionHost.hostPID].compactMap { $0 })
    return LiveSession.read(
      account: target.account, hosts: hosts, hostedHere: OpenSessions.shared.hostedHere
    ).contains { $0.sessionID == target.sessionID }
  }

  /// Runs the plan: with edits accepted, in auto mode when `autoMode`, the mode switched
  /// first as the extension switches it; or each edit approved, which leaves plan mode for
  /// the default one.
  func approvePlan(_ pending: Transcript.PendingPermission, editsManually: Bool, autoMode: Bool) {
    if !editsManually { setMode(autoMode ? .auto : .acceptEdits) }
    answer(pending, PlanApproval.approve(pending.request.input, editsManually: editsManually))
  }

  func answer(_ pending: Transcript.PendingPermission, _ decision: PermissionDecision) {
    // Kept waiting: an answer now would reach nobody.
    guard !isReconnecting else { return }
    write(
      .answer(requestID: pending.requestID, decision: decision),
      effect: .answered(requestID: pending.requestID))
    notingPermissions { transcript.resolvePermission(requestID: pending.requestID) }
    onReplied?()
  }

  /// What the person did with an MCP server's question, which goes back to the server.
  func answer(_ pending: Transcript.PendingElicitation, _ answer: ElicitationAnswer) {
    guard !isReconnecting else { return }
    send(answer, to: pending)
    onReplied?()
  }

  private func send(_ answer: ElicitationAnswer, to pending: Transcript.PendingElicitation) {
    write(
      .answerElicitation(requestID: pending.requestID, NotedAnswer(answer)),
      effect: .answeredElicitation(requestID: pending.requestID, action: ElicitationAction(answer)))
    notingPermissions {
      transcript.resolveElicitation(requestID: pending.requestID, with: answer)
    }
  }

  /// The question the conversation ends on, which its process ended before it was answered
  /// (`Transcript.unansweredQuestion`): offered again in place of the composer, as the
  /// extension offers it, while nothing runs or waits and until it is dismissed.
  var earlierQuestion: Transcript.ToolCall? {
    guard canSend, !transcript.isWaitingOnPerson,
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
    sendMeta()
    return true
  }

  /// This window's process is done writing the transcript: once another process has the
  /// session (`catchUp()`), it is read on from here, so the turns run here, already in
  /// memory, aren't read again, and a session started here, which read no history, has a
  /// follower at all.
  private func followFromHere() {
    // As `ownTarget()` finds it, without saving it: a first turn that never finished keeps
    // no saved target.
    let own = savedTarget ?? (resuming?.forks == true ? nil : resuming) ?? locateTarget()
    guard let target = own, target.agentKind == .claude else { return }
    let file = target.transcriptFile
    guard
      let size = try? FileManager.default.attributesOfItem(
        atPath: file.path(percentEncoded: false))[.size] as? UInt64
    else { return }
    follower = TranscriptFollower(file: file, from: size)
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
    _ = try? sendNoted(.rename(title: title, sessionID: id), to: process)
  }

  /// Stops the turn, and drops what was queued behind it: stop means stop. Esc keeps the
  /// queue, as the extension's does: what was queued runs next. A question an MCP server
  /// waits on is cancelled first, so that the server is not left waiting on it.
  func interrupt(keepingQueued: Bool = false) {
    guard transcript.isRunning else { return }
    // Kept waiting while reconnecting, as `answer` keeps them: a cancel now would reach nobody.
    if !isReconnecting {
      for pending in transcript.pendingElicitations { send(.cancel, to: pending) }
    }
    write(.interrupt(cancelQueued: !keepingQueued))
  }

  /// Takes back a prompt sent while a turn ran, unless the CLI took it already; it leaves
  /// the queue on the CLI's `cancelled`.
  func cancelQueued(_ prompt: QueuedPrompt) {
    if let process { _ = try? sendNoted(.cancelQueued(uuid: prompt.uuid), to: process) }
  }

  /// Ends the process: input closed so it can finish cleanly, then terminated, so that End
  /// Session or a removed row leaves no `claude` working on nobody's behalf. When its window
  /// goes (`handingOver`, a closed window or project) or the app quits, one at work in the
  /// session host is let go instead: it carries on there, sent nothing, for the project's
  /// next window to pick up. An idle one ends then too, and the host forgets it by itself
  /// once it has: the app may be gone by then.
  func stop(handingOver: Bool = false) {
    let waiting = transcript.waitingCount
    defer { permissionsMayHaveChanged(from: waiting) }
    stopCount += 1
    pendingPrompt = nil
    pendingEffect = .none
    let wasRunning = process != nil
    if let hosted = process as? HostedProcess {
      if handingOver || AppLifecycle.isTerminating, isAtWork {
        hosted.detach()
      } else if isReconnecting {
        end(hosted, onceReconnected: sessionHost)
      } else {
        if let id = hosted.id { sessionHost.ending(id) }
        hosted.closeInput()
        // Done with it: the host forgets it once it ends, so no later launch shows it again.
        hosted.forgetWhenEnded()
        hosted.terminate()
      }
    } else {
      process?.closeInput()
      process?.terminate()
    }
    events?.cancel()
    isReconnecting = false
    // The cancelled event task will not report the exit, so it is recorded here.
    process = nil
    if wasRunning { followFromHere() }
    permissionMode = nil
    appliedEffort = nil
    appliedModel = nil
    transcript.processExited()
    if case .failed = phase { return }
    if phase == .ready || phase == .starting { phase = .exited(status: 0) }
  }

  /// A stop asked while the host was out of reach goes once it is back: no process is left
  /// working for nobody.
  private func end(_ hosted: HostedProcess, onceReconnected host: SessionHost) {
    Task {
      guard let client = await host.reconnect() else { return }
      _ = hosted.reattach(on: client)
      if let id = hosted.id { host.ending(id) }
      hosted.forgetWhenEnded()
      hosted.closeInput()
      hosted.terminate()
    }
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
    // `SessionMover` moves the transcript whole, so a watched row reads on from there.
    follower = follower?.moved(to: target.transcriptFile)
    // The process that ran under the old account is gone; until the next one starts, the
    // session is on the account its files are under.
    account = nil
  }

  /// `message` nil keeps the reason already in `phase`.
  private func fail(_ message: String?) {
    if let message { phase = .failed(message) }
    pendingPrompt = nil
    pendingEffect = .none
    notingPermissions { transcript.processExited() }
    onFailed?()
  }

  private func notingPermissions(_ change: () -> Void) {
    let waiting = transcript.waitingCount
    change()
    permissionsMayHaveChanged(from: waiting)
  }

  private func permissionsMayHaveChanged(from waiting: Int) {
    if !isReplaying, transcript.waitingCount != waiting { onPermissionsChanged?() }
  }

  private func handle(_ event: AgentProcess.Event) {
    switch event {
    case .lines(let lines, let time):
      for line in lines { receive(line, at: time) }
      sendMeta()
    case .stderr(let text):
      diagnostics = String((diagnostics + text).suffix(4000))
    case .exited(let status, _):
      if let hosted = process as? HostedProcess {
        if let failure = hosted.startFailure {
          process = nil
          return fail(Self.message(forHostFailure: failure))
        }
        // Its exit is all the app needed of it.
        hosted.forgetWhenEnded()
      }
      notingPermissions { transcript.processExited() }
      process = nil
      followFromHere()
      permissionMode = nil
      appliedEffort = nil
      appliedModel = nil
      if case .failed = phase { return }
      phase = .exited(status: status)
      onStopped?()
    }
  }

  /// Takes `stream`'s events. A hosted process's that end with no exit lost their
  /// connection, the process running on in the host.
  private func follow(_ stream: AsyncStream<AgentProcess.Event>, of transport: any ProcessTransport)
  {
    events = Task { [weak self] in
      for await event in stream { self?.handle(event) }
      guard !Task.isCancelled, let hosted = transport as? HostedProcess else { return }
      self?.connectionLost(hosted)
    }
  }

  /// Nothing is sent until a connection is back, then the process is attached again from
  /// where its log was read (spec §5).
  private func connectionLost(_ hosted: HostedProcess) {
    guard process === hosted, hosted.isRunning else { return }
    isReconnecting = true
    let stops = stopCount
    Task { [weak self, sessionHost] in
      let client = await sessionHost.reconnect()
      guard let self, self.stopCount == stops, self.process === hosted else { return }
      self.isReconnecting = false
      guard let client else {
        self.process = nil
        return self.fail(
          String(localized: "Drakar lost the session host, and this session's process with it."))
      }
      self.follow(hosted.reattach(on: client), of: hosted)
    }
  }

  private func receive(_ line: AgentProcess.Line, at time: Date) {
    guard let process else { return }
    let output = backend.receive(line, from: process, at: time)
    for signal in output.signals { handle(signal, at: time) }
    let waiting = transcript.waitingCount
    var turnEnded = false
    let known = sessionID
    for event in output.events {
      transcript.apply(event, at: time)
      if case .turnEnded = event { turnEnded = true }
    }
    // A new or forked session has no id until `system/init`: a registry read before it
    // listed this row's own process as another app's, and nothing else would read it again.
    if isHosted, !isReplaying, sessionID != known { SessionMonitor.shared.hostedChanged() }
    if agent == .codex { codexTurns += output.events.turnsEnded }
    if unsentName != nil { sendUnsentName() }
    if !isReplaying, transcript.waitingCount > waiting { onPermissionRequested?() }
    permissionsMayHaveChanged(from: waiting)
    if turnEndDeferred, output.signals.contains(.queueChanged) {
      if transcript.isRunning {
        turnEndDeferred = false
      } else if transcript.queuedPrompts.isEmpty {
        turnEndDeferred = false
        if !isReplaying { onTurnEnded?() }
      }
    }
    if turnEnded {
      if !features.picksApplyAtOnce { pillNote = nil }
      if savedTarget == nil { savedTarget = locateTarget() }
      // Not while a queued prompt is about to start the next one: said once the queue
      // empties without a turn, should it be cancelled or refused instead.
      if !transcript.queuedPrompts.isEmpty {
        turnEndDeferred = true
      } else if !isReplaying {
        onTurnEnded?()
      }
    }
  }

  /// Takes `records` as the live session took them, writing nothing: a note down the path
  /// its command took, a line the process wrote as it was received. A reply to such a line
  /// that no later logged write matches never reached the CLI, so it is owed.
  ///
  /// A long log is megabytes of JSON: its lines are parsed off the main actor, a few
  /// batches at once ahead of the one being taken, and the main actor is let go between
  /// slices of the taking.
  func replay(_ records: [HostRecord]) async {
    guard let transport = process as? ReplayTransport else { return }
    isReplaying = true
    defer {
      isReplaying = false
      transport.mode = .muted
    }
    let batch = 1_000
    var parsing: [Task<[AgentProcess.Line?], Never>] = []
    var handed = 0
    var start = 0
    var slice = ContinuousClock.now
    while true {
      while parsing.count < 4, handed < records.count {
        parsing.append(Self.lines(of: records, from: handed, count: batch))
        handed += batch
      }
      let held = ContinuousClock.now - slice
      longestReplayHold = max(longestReplayHold, held)
      guard !parsing.isEmpty else { return }
      let lines = await parsing.removeFirst().value
      slice = .now
      let end = start + lines.count
      for (record, line) in zip(records[start..<end], lines) {
        take(record, line, to: transport)
        let held = ContinuousClock.now - slice
        if held > Self.replaySlice {
          longestReplayHold = max(longestReplayHold, held)
          await Task.yield()
          slice = .now
        }
      }
      start = end
    }
  }

  /// How long the replay holds the main actor before letting it go.
  private static let replaySlice = Duration.milliseconds(20)

  /// The lines of `count` records from `start`, parsed off the main actor; nil for a record
  /// that is not one the CLI wrote.
  nonisolated static func lines(of records: [HostRecord], from start: Int, count: Int)
    -> Task<[AgentProcess.Line?], Never>
  {
    Task.detached {
      records[start..<min(start + count, records.count)].map { record in
        guard record.kind == .out else { return nil }
        // The host keeps each line's `\n`, which a pipe's reader takes off.
        let bytes = record.bytes.last == 0x0A ? record.bytes.dropLast() : record.bytes
        return AgentProcess.parse(bytes)
      }
    }
  }

  private func take(_ record: HostRecord, _ line: AgentProcess.Line?, to transport: ReplayTransport)
  {
    switch record.kind {
    case .note:
      guard let note = try? JSONDecoder().decode(SessionNote.self, from: record.bytes) else {
        return
      }
      transport.mode = .muted
      replay(note, at: record.time, to: transport)
    case .out:
      guard let line else { return }
      transport.mode = .owed
      receive(line, at: record.time)
    case .in:
      transport.logged(record.bytes)
    }
  }

  private func replay(_ note: SessionNote, at time: Date, to transport: ReplayTransport) {
    switch note {
    case .started(let first, let effect):
      replayedStart = true
      apply(effect, at: time)
      try? backend.started(transport, then: first)
    case .sent(let command, let effect):
      apply(effect, at: time)
      _ = try? backend.send(command, to: transport)
    }
  }

  private func apply(_ effect: NoteEffect, at time: Date) {
    switch effect {
    case .prompt(let text, let context, let attachments):
      transcript.addPrompt(text, context: context, attachments: attachments, at: time)
    case .queued(let prompt):
      transcript.queue(prompt)
    case .answered(let id):
      notingPermissions { transcript.resolvePermission(requestID: id) }
    case .answeredElicitation(let id, let action):
      notingPermissions { transcript.resolveElicitation(requestID: id, with: action.answer) }
    case .none:
      break
    }
  }

  /// `time` is when its line came, a replay's from the log.
  private func handle(_ signal: SessionSignal, at time: Date) {
    switch signal {
    case .rateLimit(let info):
      if let account { accountStore.record(info, for: account, at: time) }
    case .models(let models):
      if agent == .codex {
        catalog.recordCodex(models)
      } else if let account {
        catalog.record(models, for: account)
      }
    case .modeAdopted(let mode):
      adopt(mode: mode)
    case .initialized(let reply):
      if isReplaying {
        replayedInitialize = .some(reply)
        replayedCommands = nil
      } else {
        onInitialized?(reply)
      }
    case .commandsChanged(let commands):
      if isReplaying { replayedCommands = commands } else { onCommandsChanged?(commands) }
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
      if !isReplaying { onStopped?() }
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

  private func write(_ command: AgentCommand, effect: NoteEffect = .none) {
    guard let process, !isReconnecting else { return }
    do {
      try sendNoted(command, effect: effect, to: process)
    } catch HostClient.Failure.disconnected {
      // The connection to the session host just ended: the session reconnects, not fails.
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// `backend.send`, after the note a replay takes it from, with what the transcript showed
  /// of it.
  @discardableResult private func sendNoted(
    _ command: AgentCommand, effect: NoteEffect = .none, to process: any ProcessTransport
  ) throws -> String? {
    // Nothing reaches the host until it is back.
    if isReconnecting { throw AgentProcess.Failure.notRunning }
    note(.sent(command, effect: effect), to: process)
    defer { sendMeta() }
    return try backend.send(command, to: process)
  }

  /// A start the session host could not make, said as a child's failed start says it.
  private static func message(forHostFailure error: any Error) -> String {
    switch error {
    case HostClient.Failure.refused(let reason):
      String(localized: "The session host could not start the process: \(reason)")
    case HostedProcess.Failure.noAnswer:
      String(localized: "The session host did not start the process in time.")
    case HostedProcess.Failure.lost(let reason):
      String(localized: "The session host no longer has this session's process: \(reason)")
    case HostClient.Failure.disconnected:
      String(localized: "The session host went away before the process started.")
    default:
      String(
        localized: "The session host could not start the process: \(error.localizedDescription)")
    }
  }

  /// A held process that could not be replayed, said as its row shows it.
  private static func message(forReattachFailure error: any Error) -> String {
    switch error {
    case HostClient.Failure.refused(let reason):
      String(
        localized:
          "The session host would not give this session's process back: \(reason). It runs on there, and Drakar takes it back at its next launch."
      )
    default:
      String(
        localized:
          "This session's process could not be read back from the session host. It runs on there, and Drakar takes it back at its next launch."
      )
    }
  }

  /// Only a transport that logs keeps notes (a session host's); a replay's keeps none.
  private func note(_ note: SessionNote, to process: any ProcessTransport) {
    guard let sink = process as? NoteSink, let bytes = try? JSONEncoder().encode(note) else {
      return
    }
    sink.note(bytes)
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
