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
  private(set) var resuming: ResumeTarget? {
    didSet { syncTranscriptFile() }
  }
  /// Stop, Run in background and task output for the cards: sent straight to the process,
  /// never noted, so a replay never sends one again.
  @ObservationIgnored let tasks = TaskControls()
  /// A code rewind's dry run, confirmation and outcome for the sheet: sent straight to the
  /// process, never noted, as `tasks` is.
  @ObservationIgnored let rewinds = Rewinds()
  /// The process's MCP servers for the Skills & MCP tab, and their reconnects: asked of the
  /// process, never noted, as `tasks` is.
  @ObservationIgnored let servers = SessionServers()
  /// This process answered "File rewinding is not enabled.": it offers no code rewind again.
  /// Reset with `process`.
  private(set) var rewindNotEnabled = false
  /// Bumped when an answer added permission rules ("always allow"), so that a rules listing
  /// shown reads them again.
  private(set) var rulesRevision = 0
  /// How long `listPermissionRules()` and `readPlan()` wait for the process; tests shorten it.
  @ObservationIgnored var controlReplyTimeout: Duration = .seconds(10)
  /// How long a server's reconnect may take: the CLI answers once its attempt is over, which
  /// for a server that never answers is its own connect timeout.
  @ObservationIgnored var reconnectTimeout: Duration = .seconds(60)
  /// Those reads waiting on the process, by request id: resumed by the answer, by their
  /// timeout, or with nil when the process goes.
  @ObservationIgnored private var controlReplies:
    [String: (reply: CheckedContinuation<SessionSignal?, Never>, timeout: Task<Void, Never>)] =
      [:]
  private(set) var transcript = Transcript() {
    // Never `oldValue`: reading it would copy the whole transcript on every token.
    didSet { transcriptChanged() }
  }
  /// What the rest of the app reads about this session: its row, its window's counts, Home,
  /// attention, keep-awake. Assigned after every change but only observed to change when it
  /// does, so readers are not redrawn per token as readers of `transcript` are.
  private(set) var status = Transcript.Status()
  /// What the transcript view draws: `transcript`, with text growing in an entry taken at most
  /// every `displayInterval` (20 times a second) rather than per token, since each redraw lays
  /// the transcript out again. A new entry or a change of `status` (a turn starting or
  /// ending, a question, a permission) is drawn at once.
  var displayedTranscript: Transcript {
    access(keyPath: \.displayedTranscript)
    return displayed
  }
  @ObservationIgnored var displayInterval = Duration.milliseconds(50)
  @ObservationIgnored private var displayed = Transcript()
  @ObservationIgnored private var pendingDisplay: Task<Void, Never>?

  private func transcriptChanged() {
    let status = transcript.status
    let changed = status != self.status
    if changed { self.status = status }
    // Displaying keeps a second reference to the entries, so the next change copies them all:
    // at most every `displayInterval` while a log replays, a new entry on every line.
    // A prompt queued mid-turn leaves the composer, and is drawn in its place at once.
    if !isReplaying,
      changed || transcript.entries.count != displayed.entries.count
        || transcript.queuedPrompts.count != displayed.queuedPrompts.count
    {
      display()
    } else if pendingDisplay == nil {
      pendingDisplay = Task { [weak self, displayInterval] in
        try? await Task.sleep(for: displayInterval)
        guard !Task.isCancelled else { return }
        self?.display()
      }
    }
  }

  /// Notified without comparing the old and new transcripts, which would walk every entry.
  private func display() {
    pendingDisplay?.cancel()
    pendingDisplay = nil
    withMutation(keyPath: \.displayedTranscript) { displayed = transcript }
  }
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
  /// Claude Code's only: a Codex target's account fields are placeholders. A runner session's
  /// is the one it runs under there alone: it never starts under one picked here (Ruling 11).
  var effectiveAccount: ClaudeAccount? {
    guard features.showsAccount else { return nil }
    if isOnRunner { return account }
    return account ?? resuming?.account ?? accountPick
  }
  /// The end of the CLI's stderr, shown when the process fails.
  private(set) var diagnostics = ""
  /// The process's answer to `get_context_usage` after its last turn: the exact window.
  private(set) var reportedContext: ContextUsageReply?
  /// What reopening the window resumes: known from the start for a resumed session, and
  /// from its first finished turn for a new one or a fork, once its transcript exists.
  private(set) var savedTarget: ResumeTarget? {
    didSet { syncTranscriptFile() }
  }
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
  /// Settings turn auto mode off (`get_settings`), though the model takes it. As last
  /// reported: false until a process has said.
  private(set) var autoModeDisabled = false
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
  /// A runner session's account limits and models, as its process reports them: kept here,
  /// for its account is the runner's, which this Mac's `AccountStore` and `ModelCatalog` do
  /// not hold (remote sessions spec §4). Nil for a session of this Mac's.
  private(set) var usage: AccountUsage?
  private(set) var models: [ModelOption]?
  /// What a runner session's `/` menu offers: the commands and skills its own process listed,
  /// nil until it has. No probe of this Mac's lists a runner's folder.
  private(set) var reportedCommands: [SkillEntry]?

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
  @ObservationIgnored private(set) var process: (any ProcessTransport)? {
    didSet {
      guard process !== oldValue else { return }
      if process != nil {
        sawEndOnRunner = false
        couldNotEndOnRunner = false
      }
      // A refusal of the next one's attach is no stale relay of this one's.
      releasingUntil = nil
      // A new process has said nothing about rewinding yet.
      rewindNotEnabled = false
      // What the one before was asked will not be answered.
      if oldValue != nil {
        tasks.processEnded()
        rewinds.processEnded()
        servers.processEnded()
        for id in Array(controlReplies.keys) { resumeControlReply(id, with: nil) }
      }
    }
  }
  /// What a spawn runs on; nil for the session host's, or an `AgentProcess` when there is no
  /// host to have. Tests give a recorder.
  @ObservationIgnored var makeTransport:
    ((AgentProcess.Configuration) async -> any ProcessTransport)?
  /// The host a spawn tries first; tests give their own.
  @ObservationIgnored var sessionHost = SessionHost.shared
  /// A runner's session's host as its window reaches it now, asked at each spawn: a row made
  /// while the window could not reach its runner starts there once it can. Nil, or none
  /// reached, keeps `sessionHost`.
  @ObservationIgnored var currentHost: (() -> SessionHost?)?
  /// The project window the session belongs to, which its folder need not be (a subfolder,
  /// a worktree): a relaunched app reopens it from the meta.
  @ObservationIgnored var windowFolder: URL?
  /// The runner its project is on (`RunnerSettings.id`), as its window gives it; nil for a
  /// session of this Mac's (remote sessions spec §4).
  @ObservationIgnored var runner: String?
  var isOnRunner: Bool { runner != nil }
  /// What to call the runner a runner session runs on, as its window names it
  /// (`SessionHost.name(ofRunner:on:)`); nil for a session of this Mac's.
  var runnerName: String? {
    runner.map { SessionHost.name(ofRunner: $0, on: currentHost?() ?? sessionHost) }
  }
  /// A runner session this window can no longer send to: its process ended, or went out of
  /// its reach (a connection given up, a reattach refused) while it may run on there. Nothing
  /// resumes it in v1, so a prompt now would start another conversation in its place: its
  /// window offers a new session instead, and says which (`goneOnRunnerText`).
  var isGoneOnRunner: Bool { isOnRunner && launched != nil && process == nil }
  /// Its process was seen to end, or to be let go for good (End Session, taken over), rather
  /// than lost from reach. An End Session sent while reconnecting sets it only once the host
  /// has taken the end. Cleared by the next process.
  private(set) var sawEndOnRunner = false
  /// An End Session sent while reconnecting that could not be: given up on, or the runner no
  /// longer set up. Its process may run on there. Cleared by the next process.
  private(set) var couldNotEndOnRunner = false
  /// What the composer's place says of a runner session it can no longer send to.
  var goneOnRunnerText: String? {
    guard isGoneOnRunner, let name = runnerName else { return nil }
    if sawEndOnRunner { return Self.endedOnRunner(name) }
    return couldNotEndOnRunner ? Self.notEndedOnRunner(name) : Self.outOfReachOnRunner(name)
  }
  /// What the last process was launched with, where the history stood then, and where it
  /// runs and whose it is: the parts of `meta()` only a start sets, or the meta a replay
  /// rebuilt it from, so that no meta sent later drops them.
  @ObservationIgnored private var launched:
    (start: AgentStart, history: HistoryMark, placement: Placement)?
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
  /// Until when a runner's refusal to attach the process again, as attached to another app,
  /// is taken for this Mac's own stale relay still releasing it (remote sessions spec §3).
  /// Set as a connection to a runner is lost; cleared once the host takes the attach, or the
  /// process changes.
  @ObservationIgnored private var releasingUntil: ContinuousClock.Instant?
  /// How long a stale relay may hold the process: the runner's sshd hangs it up within its
  /// `ClientAliveInterval 30` × `ClientAliveCountMax 3`, with room to spare.
  private static let releasingLimit = Duration.seconds(180)
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
  /// The Mac that owns the process `heldElsewhere` names, as its meta says (remote sessions
  /// spec §5): a row on the runner's own Drakar that may take it over, never on its own.
  private(set) var belongsTo: String?
  /// The host refused to give the process back because another app holds it: what a
  /// reattach that left the session out of reach says of why.
  @ObservationIgnored private(set) var refusedAsHeldElsewhere = false
  /// A runner's session whose process the runner's host lists as no longer this Mac's: taken
  /// over on the runner while this Mac was away (remote sessions spec §5). Told once the
  /// session has let go of it, for its window to close its tab.
  @ObservationIgnored var onTakenOver: (() -> Void)?
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
    [(text: String, context: String?, attachments: [AttachmentPreview], uuid: String)] = []
  /// The history could not be read: the reason stays in `phase` and nothing is sent.
  @ObservationIgnored private var historyFailed = false
  /// Reads on in the transcript file another process writes; never one for a runner's
  /// session, whose transcript is on the runner.
  @ObservationIgnored private(set) var follower: TranscriptFollower?
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
  /// The compaction Drakar started (`compact()`, `compactIfIdle`), until the last turn it
  /// sent ends; dropped by anything the person sends or stops.
  @ObservationIgnored private var compaction: CompactionRun?
  /// The transcript's pauses as that turn started: more than its own end's, and it asked
  /// the person.
  @ObservationIgnored private var pausesAtCompaction = 0
  /// The idle compaction's timer, and the time it is set for.
  @ObservationIgnored private var idleTimer: (due: Date, task: Task<Void, Never>)?

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
    syncTranscriptFile()
    tasks.locateTranscript = { [weak self] in
      // As `ownTarget()` finds it, without saving it.
      guard let self, self.features.controlsTasks else { return nil }
      return self.locateTarget()?.transcriptFile
    }
    tasks.availability = { [weak self] in self?.controlsTasks ?? false }
    tasks.runner = { [weak self] in self?.runnerName }
    tasks.send = { [weak self] command in
      // Not `write` nor `sendNoted`: a control the process cannot take changes nothing else,
      // and a note would have a replay send it again.
      guard let self, let process = self.process else { return }
      _ = try? self.backend.send(command, to: process)
    }
    servers.ask = { [weak self] command in
      guard let self else { return nil }
      if case .reconnectServer = command {
        return await self.ask(command, timeout: self.reconnectTimeout)
      }
      return await self.ask(command)
    }
    rewinds.folder = folder
    rewinds.send = { [weak self] command in
      // As `tasks.send`, read again at each request: a turn that started since the dry run
      // holds the rewind back.
      guard let self, self.rewindsCode, let process = self.process else { return false }
      do {
        try self.backend.send(command, to: process)
        return true
      } catch {
        return false
      }
    }
  }

  /// The session a process's log rebuilds: the history from before the process, then
  /// `records` replayed. Its process stands in for the one the log came from, so nothing
  /// reaches the CLI, and what the replay owes it waits in its `ReplayTransport`.
  /// `throughRunner`: this app reaches the process's host as a runner. Otherwise a process
  /// whose meta names a runner is on this Mac, the runner's own Drakar (remote sessions spec
  /// §5): a session of this Mac's here, its transcript on this disk, taking the account it
  /// was picked only if that is one of `accounts`.
  convenience init(
    replaying records: [HostRecord], meta: SessionMeta, backend: AgentBackend? = nil,
    throughRunner: Bool = false,
    accounts: @escaping () -> [ClaudeAccount] = { ClaudeAccount.discover() }
  ) async {
    // Reached as a runner, the runner's transcript paths are none of this Mac's: a target the
    // runner's own Drakar saved while it held the session is left to it.
    self.init(
      folder: meta.start.folder,
      resuming: throughRunner ? meta.start.resuming : meta.savedTarget ?? meta.start.resuming,
      agent: meta.agent,
      account: Self.accountPick(of: meta, throughRunner: throughRunner, among: accounts),
      backend: backend)
    self.accounts = accounts
    modePick = meta.modePick
    modelPick = meta.modelPick
    effortPick = meta.effortPick
    name = meta.name
    fanOut = meta.fanOut
    executableOverride = meta.start.executableOverride
    windowFolder = URL(filePath: meta.windowFolder, directoryHint: .isDirectory)
    // A runner's from the first, when reached as one: its replay keeps what the process
    // reported to itself, and a stop before a window adopts it lets it go rather than ending
    // it. On the runner itself it is a session of this Mac's.
    runner = throughRunner ? meta.runner : nil
    launched = (meta.start, meta.history, Placement(of: meta))
    let started = records.first?.time ?? .now
    historyLoad = Task {
      await self.readHistory(meta.history, at: started, through: meta.start.resuming?.resumeAt)
    }
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
  /// host forget it. Nil for a meta this app cannot read. `throughRunner`: `client` reaches
  /// a runner's host. `accounts` as `init(replaying:meta:)` takes them.
  convenience init?(
    reattaching held: HeldProcess, client: HostClient, throughRunner: Bool = false,
    accounts: @escaping () -> [ClaudeAccount] = { ClaudeAccount.discover() }
  ) async {
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
    await self.init(
      replaying: (try? replayed.get()) ?? [], meta: meta, throughRunner: throughRunner,
      accounts: accounts)
    sentMeta = meta
    switch replayed {
    case .success:
      goLive(on: hosted)
    case .failure(let error):
      // Its process carries on in the host, out of reach: not shown alive and silent.
      process = nil
      isOutOfReach = true
      refusedAsHeldElsewhere = Self.isHeldElsewhere(error)
      notingPermissions { transcript.processExited() }
      phase = .failed(Self.message(forReattachFailure: error))
    }
  }

  /// A process another Drakar holds, or an older host (spec §4, §5), shown as a session live
  /// elsewhere is: read-only, Claude Code's transcript file followed. Codex has no file to
  /// follow, so its thread is read up to the process, and a line says where the rest runs.
  /// Nil for a meta this app cannot read.
  ///
  /// Only ever of this Mac's own host: on a runner's own Drakar, one a Mac owns says so
  /// (`belongsTo`), and its transcript, on this disk, is found in `accounts` by the id its
  /// meta gives once it is known.
  convenience init?(
    heldElsewhere held: HeldProcess,
    accounts: @escaping () -> [ClaudeAccount] = { ClaudeAccount.discover() }
  ) async {
    guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: held.meta) else {
      return nil
    }
    let resumed = meta.start.resuming?.forks == true ? nil : meta.start.resuming
    self.init(
      folder: meta.start.folder, resuming: meta.savedTarget ?? resumed, agent: meta.agent,
      account: Self.accountPick(of: meta, throughRunner: false, among: accounts))
    self.accounts = accounts
    belongsTo = meta.owner
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

  /// The account a meta's process was picked, as a session rebuilt from it takes it: a
  /// runner session's, on the runner's own Drakar, only when it is one of `accounts`, for it
  /// may be an account of the Mac that started it (remote sessions spec §5).
  private static func accountPick(
    of meta: SessionMeta, throughRunner: Bool, among accounts: () -> [ClaudeAccount]
  ) -> ClaudeAccount? {
    guard let pick = meta.accountPick, meta.runner != nil, !throughRunner else {
      return meta.accountPick
    }
    return accounts().contains { $0.key == pick.key } ? pick : nil
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
    status.session?.sessionID ?? (resuming?.forks == true ? nil : resuming?.sessionID)
  }

  /// The session's name, or the title Claude Code gave it, from its history.
  var title: String? { name ?? status.title }

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
  var isAtWork: Bool { status.isRunning || status.isWaitingOnPerson }

  /// The record a relaunched app rebuilds the session from, for its last process; nil before
  /// one was launched.
  func meta() -> SessionMeta? {
    launched.map { meta(start: $0.start, history: $0.history, placement: $0.placement) }
  }

  private func meta(start: AgentStart, history: HistoryMark, placement: Placement)
    -> SessionMeta
  {
    SessionMeta(
      start: start, windowFolder: (windowFolder ?? folder).path(percentEncoded: false),
      name: name, modePick: modePick, modelPick: modelPick, effortPick: effortPick,
      // A runner session never starts under an account picked here (Ruling 11): every path
      // its meta names is the runner's.
      accountPick: isOnRunner ? nil : accountPick, sessionID: sessionID, savedTarget: savedTarget,
      fanOut: fanOut, history: history, runner: placement.runner, origin: placement.origin,
      owner: placement.owner)
  }

  /// Hands the host the meta when it changed; only a hosted process keeps one. Every meta
  /// sent but `closeTab()`'s leaves the closed mark off. False when there was none to send.
  @discardableResult private func sendMeta(closedAtWork: Bool? = nil) -> Bool {
    guard let hosted = process as? HostedProcess, var meta = meta() else { return false }
    meta.closedAtWork = closedAtWork
    guard meta != sentMeta else { return true }
    guard let bytes = try? JSONEncoder().encode(meta) else { return false }
    sentMeta = meta
    hosted.setMeta(bytes)
    return true
  }

  /// The licence gate is the last term here and in `canQueue`, and nowhere else: every
  /// prompt goes through `send`, which reads them (`EntitlementMonitor`). What answers a
  /// turn already running (`answer`, `interrupt`, `stop`, the task controls) reads neither,
  /// so a trial that ends mid-turn refuses only the next prompt.
  var canSend: Bool {
    !isReadOnly && !isMoving && !historyFailed && !isReconnecting && !waitsForHost
      && !isOutOfReach && !isGoneOnRunner && !status.isRunning && phase != .starting
      && EntitlementMonitor.allowsWorkNow
  }

  /// A prompt typed while a turn runs goes now, and waits in the CLI until it can be taken:
  /// at the next tool boundary, or once the turn ends.
  var canQueue: Bool {
    !isReadOnly && !isMoving && !historyFailed && !isReconnecting && !waitsForHost
      && !isOutOfReach && status.isRunning && process != nil
      && EntitlementMonitor.allowsWorkNow
  }

  /// A card can stop its task or move its call, as `canQueue` reads a driven session, but
  /// without the licence gate: stopping work already running is never refused.
  private var controlsTasks: Bool {
    features.controlsTasks && !isReadOnly && !isMoving && !historyFailed && !isReconnecting
      && !waitsForHost && !isOutOfReach && process != nil
  }

  /// The prompt's files can be put back now: `features.controlsTasks`, a process Drakar
  /// drives (as the task controls read it), one that has not said rewinding is off, and no
  /// turn running. No "has run a turn" rule: a resumed process answers before its first
  /// prompt, for prompts of earlier processes too (docs/claude-stream-json.md, "Rewind").
  /// Whether the prompt has a checkpoint only the dry run says.
  func canRewindCode(_ messageID: String) -> Bool { rewindsCode }

  /// As `canRewindCode` but for the turn: a prompt's menu shows the code items through a
  /// turn, disabled, rather than taking them away.
  var offersCodeRewind: Bool { controlsTasks && !rewindNotEnabled }

  private var rewindsCode: Bool { offersCodeRewind && !status.isRunning }

  /// `listPermissionRules()`, `readPlan()` and `servers` ask a process: a Claude Code one
  /// Drakar drives, as the task controls read it. `phase` is read too, and first: the
  /// process is not observed, and the phase changes with it as one starts or ends, so what
  /// reads this redraws then.
  var hasLiveRules: Bool { phase == .ready && agent == .claude && controlsTasks }

  /// The running process's permission rules, session approvals and `--allowedTools` ones
  /// included. Nil at once without a process to ask, or after `controlReplyTimeout` or the
  /// process's end with no answer.
  func listPermissionRules() async -> PermissionRulesAnswer? {
    guard case .permissionRulesAnswered(_, let answer)? = await ask(.listPermissionRules) else {
      return nil
    }
    return answer
  }

  /// The running process's plan, as `listPermissionRules()` asks it; nil also for a refusal.
  func readPlan() async -> PlanReply? {
    guard case .planAnswered(_, let reply)? = await ask(.getPlan) else { return nil }
    return reply
  }

  /// Sends `command` and waits for the signal answering it. Not `write` nor `sendNoted`, as
  /// `tasks.send`: a read the process cannot take changes nothing else, and a note would
  /// have a replay send it again.
  private func ask(_ command: AgentCommand, timeout: Duration? = nil) async -> SessionSignal? {
    guard hasLiveRules, let process, let id = try? backend.send(command, to: process) else {
      return nil
    }
    // Registered before any line is read: the reply is handled on this actor, after this.
    return await withCheckedContinuation { continuation in
      let limit = timeout ?? controlReplyTimeout
      let timeout = Task { [weak self] in
        try? await Task.sleep(for: limit)
        guard !Task.isCancelled else { return }
        self?.resumeControlReply(id, with: nil)
      }
      controlReplies[id] = (continuation, timeout)
    }
  }

  /// Ends the wait for `id`, once: later answers for it find nothing.
  private func resumeControlReply(_ id: String, with signal: SessionSignal?) {
    guard let waiting = controlReplies.removeValue(forKey: id) else { return }
    waiting.timeout.cancel()
    waiting.reply.resume(returning: signal)
  }

  /// A rewind took: the extension's line, left in the conversation once the sheet closes.
  func noteRewound() {
    transcript.addNotice(RewindCopy.succeeded)
  }

  /// Open Plan found no plan file to open: the process has none yet, or did not say where.
  func noteNoPlan() {
    transcript.addNotice(String(localized: "No plan in this session yet."))
  }

  /// Open Plan had no answer from the process: a refusal, its end, or the timeout.
  func notePlanUnread() {
    transcript.addNotice(String(localized: "Couldn't read the plan."))
  }

  /// A fork from one of this session's prompts was not made: said here, where it was asked
  /// for. After a rewind that took, its note says both instead, so the conversation never
  /// reads as if the code stayed as it was, nor carries two notes about one request.
  func noteNotForked(afterRewind: Bool) {
    if afterRewind {
      transcript.reviseNotice(RewindCopy.succeeded, to: RewindCopy.rewoundNotForked)
    } else {
      transcript.addNotice(RewindCopy.notForked)
    }
  }

  /// Where the cards look for subagent files: beside this session's own transcript once it
  /// saved one, else beside the one it continues (a fork's original, whose folder its own
  /// sits beside). A new session's first turn has neither: `tasks.locateTranscript` finds it.
  /// Claude Code's only: no Codex card lists a folder. A target looked for and not found
  /// leaves the file the cards found.
  private func syncTranscriptFile() {
    guard features.controlsTasks else {
      tasks.transcriptFile = nil
      return
    }
    if let file = (savedTarget ?? resuming)?.transcriptFile { tasks.transcriptFile = file }
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
    let started = status.session?.model
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
    if !features.picksApplyAtOnce, status.isRunning, mode != .bypass {
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
    if !features.picksApplyAtOnce, status.isRunning {
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
    if !features.picksApplyAtOnce, status.isRunning {
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
    // A runner's session starts new and its history is the host's log: nothing to read here.
    if isOnRunner {
      isLoadingHistory = false
      hasLoadedHistory = true
      return
    }
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
    await readHistory(file, upTo: .max, at: .now, through: resuming?.resumeAt)
  }

  /// The history from before a replayed process, as `mark` says it stood. Codex's thread
  /// holds the process's turns too, so it is cut where the process found it; with none
  /// there, it has nothing the log does not. `cut` is where the process's fork resumed.
  private func readHistory(_ mark: HistoryMark, at time: Date, through cut: String? = nil) async {
    switch mark {
    case .claudeFile(let path, let length):
      await readHistory(URL(filePath: path), upTo: length, at: time, through: cut)
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
  /// the cache went cold. A fork resumed at the message `cut` keeps the history through it,
  /// and follows nothing: the rest of its original's file is not its own.
  private func readHistory(
    _ file: URL, upTo length: UInt64, at time: Date, through cut: String?
  ) async {
    let loaded = await Task.detached { () -> (Transcript, TranscriptFollower?)? in
      if let cut {
        guard let lines = try? Transcript.lines(contentsOf: file, upTo: length) else { return nil }
        return (Transcript.history(lines: lines, through: cut), nil)
      }
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
        prompt.text, context: prompt.context, attachments: prompt.attachments, uuid: prompt.uuid)
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
        prompt.text, context: prompt.context, attachments: prompt.attachments, uuid: prompt.uuid)
    }
    promptsDuringLoad = []
  }

  /// What another process appended, for a read-only session.
  func catchUp() {
    guard isReadOnly, var follower else { return }
    do {
      try follower.catchUp(&transcript)
    } catch {
      // A read that reset the transcript, then threw, skipped its `didSet`.
      transcriptChanged()
    }
    self.follower = follower
  }

  /// `context` is the editor's open file or selections, sent ahead of the text as the
  /// extension's chat sends it, and `attachments` after it. Starts the process when there is
  /// none. A prompt of attachments alone needs no text.
  func send(
    _ prompt: String, context: [EditorSelection] = [], attachments: [Attachment] = []
  ) {
    // The person's message comes before what a compaction Drakar started would send next.
    compaction = nil
    submit(prompt, context: context, attachments: attachments, byPerson: true)
  }

  /// `send`'s, and a compaction's own prompts (not `byPerson`), which are not a reply.
  private func submit(
    _ prompt: String, context: [EditorSelection] = [], attachments: [Attachment] = [],
    byPerson: Bool
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
    transcript.addPrompt(text, context: label, attachments: previews, uuid: uuid)
    rewinds.turnStarted()
    onPromptSent?()
    if answersTurn, byPerson { onReplied?() }
    if isLoadingHistory { promptsDuringLoad.append((text, label, previews, uuid)) }
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

  /// The inspector's Compact can go: a Claude Code conversation, between turns.
  var canCompact: Bool { agent == .claude && canSend && status.hasEntries }

  /// Compacts the conversation, after the command Settings runs first, if any: `/compact`
  /// once that command's turn ends, unless it stopped to ask the person.
  func compact() {
    guard canCompact else { return }
    start(CompactionRun(first: ClaudeChoice.compactionFirst, idle: false))
  }

  private func start(_ run: CompactionRun) {
    compaction = run
    pausesAtCompaction = transcript.pauses
    submit(run.prompt, byPerson: false)
  }

  /// A turn of a compaction Drakar started ended: sends what comes next, and says so.
  private func compactionTurnEnded() -> Bool {
    guard var run = compaction else { return false }
    compaction = nil
    let wasFirst = run.isRunningFirst
    // Its own end is one pause; any other was a question.
    let asked = transcript.pauses - pausesAtCompaction > 1
    guard let next = run.turnEnded(asked: asked) else {
      if wasFirst, asked, let first = run.first {
        transcript.addNotice(
          String(localized: "Not compacted: \(first) stopped to ask you something."))
      }
      return false
    }
    compaction = run
    pausesAtCompaction = transcript.pauses
    submit(next, byPerson: false)
    return true
  }

  /// Sets the idle compaction's timer for when the session's cache says, or takes it back.
  /// One that went off stays, so the same time is not set again.
  private func armIdleCompaction() {
    let due =
      agent == .claude && process != nil ? IdleCompaction.due(transcript.promptCache) : nil
    guard due != idleTimer?.due else { return }
    idleTimer?.task.cancel()
    idleTimer = due.map { due in
      let task = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
        let environment = await Self.environment.value
        guard !Task.isCancelled, let self else { return }
        self.compactIfIdle(at: .now, floor: IdleCompaction.floor(environment: environment))
      }
      return (due, task)
    }
  }

  /// The idle timer went off: compacts, unless Settings, the session or its cache says not
  /// to. The CLI's own rules (`IdleCompaction`), and nothing waiting on the person.
  func compactIfIdle(at now: Date, floor: Int) {
    let cache = transcript.promptCache
    guard ClaudeChoice.compactsIdle, agent == .claude, process != nil, phase == .ready,
      canSend, compaction == nil, !status.isWaitingOnPerson,
      transcript.queuedPrompts.isEmpty, let due = IdleCompaction.due(cache),
      let anchor = cache.anchor,
      IdleCompaction.refusal(
        at: now, due: due, contextTokens: status.contextUsage?.total,
        autoCompacts: reportedContext?.autoCompactThreshold != nil, floor: floor) == nil
    else { return }
    let idle = PromptCache.idle(now.timeIntervalSince(anchor))
    let run = CompactionRun(first: ClaudeChoice.compactionFirst, idle: true)
    transcript.addNotice(
      run.first.map {
        String(
          localized: "Idle \(idle). Running \($0), then compacting before the prompt cache expires."
        )
      } ?? String(localized: "Idle \(idle). Compacting before the prompt cache expires."))
    start(run)
  }

  /// Starts `claude`, resuming this session if it has a transcript.
  func spawn() async {
    await spawn(unlessStoppedSince: stopCount)
  }

  /// Every await is a point where the window may have closed (`stop()`) or another process
  /// may have opened the session (`isReadOnly`): after each, either ends the spawn.
  private func spawn(unlessStoppedSince stops: Int) async {
    guard stopCount == stops, process == nil, phase != .starting, !isMoving, !waitsForHost,
      !isOutOfReach, !isGoneOnRunner
    else { return }
    if resuming?.forks == true || resuming == nil {
      // A first turn that never finished (End Session, a crash) left no saved target, but
      // the transcript exists from `system/init` on: look for it.
      if savedTarget == nil, status.session?.sessionID != nil { savedTarget = locateTarget() }
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
    let start: AgentStart
    // A runner's session is started from the runner's facts, which only its connection brings,
    // and on that connection, or not at all: never on this Mac (remote sessions spec §4).
    var onRunner: (client: HostClient, facts: RunnerFacts)? = nil
    if let runner {
      // Claude Code's alone in v1, and never a Codex row a runner window was handed.
      guard agent == .claude else { return fail(Self.claudeOnlyOnRunner) }
      if let host = currentHost?() { sessionHost = host }
      onRunner = await reach(runner: runner)
      guard stillWanted(since: stops) else { return }
      guard let onRunner else { return fail(unreachable(runner)) }
      // Its folder is the runner's, which this Mac's disk says nothing of. It starts new
      // whatever it was made to resume: no resume on a runner in v1.
      // Under the runner shell's own account: one picked here (`accountPick`, a fan-out's or a
      // restored one's) is this Mac's, whatever its path (Ruling 11).
      let launch = ClaudeLaunch.make(onRunner: onRunner.facts, folder: folder, executable: nil)
      start = AgentStart(
        folder: folder, resuming: nil, environment: launch.environment,
        executableOverride: launch.executable, model: modelPick, mode: modePick, effort: effort,
        allowsBypass: allowsBypass, name: unsentName, account: launch.account, runner: runner)
    } else {
      let environment = await Self.environment.value
      guard stillWanted(since: stops) else { return }
      guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
        return fail(String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
      }
      start = AgentStart(
        folder: folder, resuming: resuming, environment: environment,
        executableOverride: executableOverride, model: modelPick, mode: modePick, effort: effort,
        allowsBypass: allowsBypass, name: unsentName,
        account: resuming == nil ? accountPick : nil)
    }
    let launch = backend.launch(start)
    account = launch.account
    guard let configuration = launch.configuration else {
      return fail(runner != nil ? notFoundOnRunner : backend.notFoundMessage)
    }
    executable = launch.executable
    let history = historyMark()
    // Whose it is, said once at the spawn: this Mac started it and holds it.
    let placement =
      runner.map { Placement(runner: $0, origin: ThisMac.name, owner: ThisMac.name) }
      ?? Placement()
    let meta = meta(start: start, history: history, placement: placement)
    let transport = await transport(for: configuration, meta: meta, onRunner: onRunner?.client)
    guard stillWanted(since: stops) else { return }
    guard let process = transport else { return fail(runner.map(unreachable)) }
    // The last word before the process starts, with no await after it: a session live in
    // another process now is followed, not written to. The monitor may not have read the
    // registries yet at launch, so the account's own registry is read here too.
    // A runner's session resumes nothing, so this Mac's registries say nothing of it.
    if !isOnRunner, let resuming, resuming.forks != true, isLiveElsewhere(resuming) {
      isReadOnly = true
      _ = stillWanted(since: stops)
      return
    }
    do {
      let stream = try process.start()
      self.process = process
      launched = (start, history, placement)
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
  /// A runner's session's is the runner's host's, on the connection `runner` its spawn was
  /// built on, and nil rather than a child of this Mac's. Nothing spawns until `start()`: the
  /// session may still let it go unstarted.
  private func transport(
    for configuration: AgentProcess.Configuration, meta: SessionMeta,
    onRunner runner: HostClient?
  ) async -> (any ProcessTransport)? {
    if let makeTransport { return await makeTransport(configuration) }
    if let runner {
      guard let bytes = try? JSONEncoder().encode(meta) else { return nil }
      return HostedProcess(client: runner, configuration: configuration, meta: bytes)
    }
    guard let client = await sessionHost.client(), let bytes = try? JSONEncoder().encode(meta)
    else { return AgentProcess(configuration) }
    return HostedProcess(client: client, configuration: configuration, meta: bytes)
  }

  /// The connection to the runner `id` names and the facts its relay stated, connecting
  /// first if need be. Nil unless this session's host is that runner's (`reaches`, never true
  /// of this Mac's host), not let go of, and reached: a runner project's session left with
  /// this Mac's host, or with a runner since cleared or replaced, is not started anywhere.
  private func reach(runner id: String) async -> (client: HostClient, facts: RunnerFacts)? {
    guard sessionHost.reaches(runner: id), let client = await sessionHost.client(),
      let facts = sessionHost.facts
    else { return nil }
    return (client, facts)
  }

  /// Why a runner's session did not start: its runner out of reach now, by name and with why
  /// when the host knows, or no longer the one set up.
  private func unreachable(_ id: String) -> String {
    guard sessionHost.reaches(runner: id), let name = sessionHost.runnerName else {
      return String(
        localized:
          "Drakar can't reach this session's runner: it is no longer set up in Settings › Runner.")
    }
    let message = String(localized: "Drakar can't reach \(name) right now.")
    guard let failure = sessionHost.failure else { return message }
    return "\(message) \(failure.message)"
  }

  /// What the composer's place says once a runner session's process has ended.
  static func endedOnRunner(_ runner: String) -> String {
    String(localized: "This session has ended on \(runner). It can't be resumed from this Mac.")
  }

  /// What it says once End Session could not end it, which may run on there.
  static func notEndedOnRunner(_ runner: String) -> String {
    String(
      localized:
        "Drakar couldn't end this session on \(runner). Its process may still be running there; Home lists it, to end from its row."
    )
  }

  /// What it says once its process went out of this window's reach, which may run on there.
  static func outOfReachOnRunner(_ runner: String) -> String {
    String(
      localized:
        "Drakar can't reach this session on \(runner). Its process may still be running there; this window can't send to it."
    )
  }

  /// What a runner's session of another agent fails with.
  static let claudeOnlyOnRunner = String(
    localized: "Only Claude Code sessions run on a runner. Start a new session to use it there.")

  /// The runner has no `claude` its relay found.
  private var notFoundOnRunner: String {
    let name = sessionHost.runnerName ?? String(localized: "the runner")
    return String(
      localized: "Claude Code was not found on \(name). Install it there, then try again.")
  }

  /// Where the history stands as a process starts, the rest being in its log: Codex's
  /// thread in turns, Claude Code's transcript file in bytes. A new Claude Code session has
  /// none, and keeps none for that process's life: its file holds only what the log does.
  private func historyMark() -> HistoryMark {
    // A runner's session starts new: everything is in the log.
    if isOnRunner { return .none }
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
    // An "always allow" added rules, which a listing shown reads again.
    if case .allow(_, let updates) = decision, !updates.isEmpty { rulesRevision += 1 }
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
    guard canSend, !status.isWaitingOnPerson,
      let call = status.unansweredQuestion, call.id != dismissedQuestionID
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
  /// starts. False when it cannot be named: read-only, moving, or its file not writable; or
  /// on a runner with no process, whose transcript is there and asked only of the process.
  @discardableResult func rename(to newName: String) -> Bool {
    guard let title = SessionTitle.clean(newName), canRename else { return false }
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
    // A runner's session writes its transcript on the runner: nothing here to follow.
    guard !isOnRunner else { return }
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
    if status.session?.sessionID != nil { savedTarget = locateTarget() }
    return savedTarget
  }

  /// Whether `rename(to:)` may name it now.
  var canRename: Bool { !isReadOnly && !isMoving && (!isOnRunner || process != nil) }

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
    guard status.isRunning else { return }
    compaction = nil
    // Kept waiting while reconnecting, as `answer` keeps them: a cancel now would reach nobody.
    if !isReconnecting {
      for pending in status.pendingElicitations { send(.cancel, to: pending) }
    }
    write(.interrupt(cancelQueued: !keepingQueued))
  }

  /// The queued card's Send now: the turn stops as Esc stops it, and the CLI takes what was
  /// queued at once, in order. Nothing queued, nothing stopped.
  func sendQueuedNow() {
    guard !transcript.queuedPrompts.isEmpty else { return }
    interrupt(keepingQueued: true)
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
  ///
  /// A runner's session is never ended that way, for nothing resumes it from this Mac
  /// (remote sessions spec §4): any stop but End Session's (`ending`) lets it go, at work or
  /// idle, and the runner's host keeps it. `lettingGo` lets any hosted one go so, for
  /// `handOver(to:)`.
  func stop(handingOver: Bool = false, ending: Bool = false, lettingGo: Bool = false) {
    let waiting = transcript.waitingCount
    defer { permissionsMayHaveChanged(from: waiting) }
    stopCount += 1
    pendingPrompt = nil
    pendingEffect = .none
    compaction = nil
    idleTimer?.task.cancel()
    idleTimer = nil
    let wasRunning = process != nil
    // Ended now, on a live connection; one sent once reconnected says so itself, once taken.
    var endedNow = false
    if let hosted = process as? HostedProcess {
      if lettingGo || (isOnRunner && !ending) {
        // Reconnecting too: the host lets it go by itself once a stale relay holding it has.
        hosted.detach()
      } else if !isOnRunner, handingOver || AppLifecycle.isTerminating, isAtWork {
        hosted.detach()
      } else if isReconnecting {
        end(hosted, onceReconnected: sessionHost, waitingOutStaleRelay: isOnRunner)
      } else {
        if let id = hosted.id { sessionHost.ending(id) }
        hosted.closeInput()
        // Done with it: the host forgets it once it ends, so no later launch shows it again.
        hosted.forgetWhenEnded()
        hosted.terminate()
        endedNow = true
      }
    } else {
      process?.closeInput()
      process?.terminate()
      endedNow = true
    }
    events?.cancel()
    isReconnecting = false
    // The cancelled event task will not report the exit, so it is recorded here.
    process = nil
    // End Session's, unlike a detach, which leaves the process to run on there.
    if isOnRunner, ending, wasRunning, endedNow { sawEndOnRunner = true }
    if wasRunning { followFromHere() }
    permissionMode = nil
    appliedEffort = nil
    appliedModel = nil
    transcript.processExited()
    if case .failed = phase { return }
    if phase == .ready || phase == .starting { phase = .exited(status: 0) }
  }

  /// Its tab closed (session tabs spec, Closing). At work in this Mac's session host, it is
  /// handed over rather than stopped: its meta says first that the tab was closed, so that no
  /// window or launch takes it back on its own, and the host is asked to end it once its turn
  /// does, then the app lets it go. With prompts queued, the turn's end is not the end of its
  /// work, so it is not ended then: it runs on in the background, listed and reopenable. A
  /// process with no meta to mark is handed over all the same, rather than lose its turn.
  /// Anything else stops as a removed row did: idle, it ends; the app's own child at work
  /// loses its turn, which the window asks about first; a runner's session carries on in its
  /// host as any stop leaves it. True when it was handed over marked closed.
  @discardableResult func closeTab() -> Bool {
    guard isAtWork, !isOnRunner, let hosted = process as? HostedProcess else {
      stop()
      return false
    }
    let marked = sendMeta(closedAtWork: true)
    if marked, transcript.queuedPrompts.isEmpty { hosted.endWhen(until: agent.turnEnds) }
    stop(handingOver: true)
    return marked
  }

  /// Taken back after its tab was closed at work: the mark comes off its meta. Its end with
  /// its turn went as the host took the attach, before the replay, so a turn that ended
  /// meanwhile did not end it.
  func reopenedAfterClose() {
    guard isHosted else { return }
    sendMeta()
  }

  /// Where its process is now, for the handoff (remote sessions spec §5): the Mac that started
  /// it on a runner (`origin`), and the Mac whose Drakar it belongs to (`owner`), nil once
  /// the runner's own Drakar has it. Both nil for a process a Mac never started.
  var origin: String? { launched?.placement.origin }
  var owner: String? { launched?.placement.owner }

  /// The process can change hands: hosted and up, and its host reached now, which a meta and
  /// a `detach` sent while reconnecting would not reach.
  var canHandOver: Bool { phase == .ready && isHosted && !isReconnecting && launched != nil }

  /// Hands the process to the Drakar of the Mac `owner` names, or to the runner's own with
  /// nil (spec §5): its meta says so first, then this app lets it go, sent nothing, and the
  /// host tells the other apps `released`, the meta already changed by then.
  func handOver(to owner: String?) {
    guard canHandOver else { return }
    place(owner: owner)
    stop(lettingGo: true)
  }

  /// The process is this app's own now: the runner's own Drakar took over one a Mac owned,
  /// which that Mac then leaves alone.
  func claim() {
    guard isHosted, owner != nil else { return }
    place(owner: nil)
  }

  private func place(owner: String?) {
    guard var launched else { return }
    launched.placement.owner = owner
    self.launched = launched
    sendMeta()
  }

  /// A stop asked while the host was out of reach goes once it is back: no process is left
  /// working for nobody. `waitingOutStaleRelay` for a runner's session (`endOnceFree`), which
  /// is marked ended at once, and under way (`SessionHost.endingOnceFree`), so that no window
  /// takes it back meanwhile and Home does not take it for an end that missed; what came of
  /// it is the window's to say once known.
  private func end(
    _ hosted: HostedProcess, onceReconnected host: SessionHost, waitingOutStaleRelay: Bool
  ) {
    guard waitingOutStaleRelay, let id = hosted.id else {
      Task {
        guard let client = await host.reconnect() else { return }
        if let id = hosted.id { host.ending(id) }
        Self.end(hosted, on: client)
      }
      return
    }
    host.endingOnceFree(id)
    let stops = stopCount
    Task { [weak self] in
      let outcome = await Self.endOnceFree(hosted, id: id, on: host)
      // Closed since, or a new process: nothing more to say here.
      guard let self, self.stopCount == stops, self.process == nil else { return }
      switch outcome {
      case .ended: self.sawEndOnRunner = true
      case .takenOver: self.takenOver()
      case .notEnded: self.couldNotEndOnRunner = true
      }
    }
  }

  /// What came of an End Session sent while a runner's session was reconnecting.
  private enum EndOnRunner {
    /// The host took the end, or lists the process no more.
    case ended
    /// No longer this Mac's: taken over on the runner meanwhile, which it is left to.
    case takenOver
    /// Given up on, or the runner no longer set up: the process may run on there.
    case notEnded
  }

  /// Ends a runner's process once this Mac can: its host reached again, however long that
  /// takes, then, from a listing that came, the process this Mac's and free. A stale relay of
  /// this Mac's may hold it still (spec §3), the host refusing anything of it until it goes,
  /// so a held one is waited on, up to `releasingLimit`. Never on a process another Drakar
  /// took over meanwhile and may have let go since, which the host would let any app end, nor
  /// on what no listing said. The id stays ended only once the end is taken.
  private static func endOnceFree(_ hosted: HostedProcess, id: String, on host: SessionHost)
    async -> EndOnRunner
  {
    // The runner no longer set up: nothing reaches it.
    guard await host.reconnect() != nil else {
      host.notEnding(id)
      return .notEnded
    }
    let deadline = ContinuousClock.now + releasingLimit
    var wait = SessionHost.firstWait
    while true {
      switch await host.ownership(of: id) {
      case .gone:
        host.endSent(id)
        return .ended
      case .notOwned:
        host.notEnding(id)
        return .takenOver
      case .owned(let held) where held.attachedApp == nil:
        // No longer ended: whoever cleared it may hold the process now, and it is not ended
        // under them.
        guard host.ended.contains(id) else {
          host.endSent(id)
          return .notEnded
        }
        guard let client = await host.reconnect(), await endTaken(hosted, on: client) else {
          // Taken by another app between the listing and the attach: it runs on.
          host.notEnding(id)
          return .notEnded
        }
        host.endSent(id)
        return .ended
      case .owned, .unknown:
        // Held by the stale relay still, or no listing came: asked again.
        break
      }
      // Given up: the stale relay outlived the limit, the host never answered, or the runner
      // is no longer set up. The process runs on there, so it is not kept as ended: Home and a
      // window's take-back still see it, and End Session on its row in Home is the way to end
      // it then.
      guard ContinuousClock.now < deadline, !host.isClosed else {
        host.notEnding(id)
        return .notEnded
      }
      try? await Task.sleep(for: min(wait, deadline - .now))
      wait = min(wait * 2, SessionHost.longestWait)
    }
  }

  /// Ends `hosted` for good on `client`, which it is attached to again first.
  private static func end(_ hosted: HostedProcess, on client: HostClient) {
    _ = hosted.reattach(on: client)
    hosted.forgetWhenEnded()
    hosted.closeInput()
    hosted.terminate()
  }

  /// `end(_:on:)`, true once the host has taken the attach, and with it the end that follows
  /// it on the same connection; false when it refused the attach, another app holding the
  /// process, or the connection went first.
  private static func endTaken(_ hosted: HostedProcess, on client: HostClient) async -> Bool {
    let (answers, answer) = AsyncStream.makeStream(of: Bool.self)
    let events = hosted.reattach(on: client, attached: { answer.yield(true) })
    hosted.forgetWhenEnded()
    hosted.closeInput()
    hosted.terminate()
    Task {
      for await _ in events {}
      answer.yield(false)
      answer.finish()
    }
    for await taken in answers { return taken }
    return false
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
          if waitsOutStaleRelay(hosted, refused: failure) { return }
          process = nil
          return fail(Self.message(forHostFailure: failure))
        }
        // Its exit is all the app needed of it.
        hosted.forgetWhenEnded()
      }
      notingPermissions { transcript.processExited() }
      process = nil
      sawEndOnRunner = isOnRunner
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
    releasingUntil = sessionHost.isRunner ? .now + Self.releasingLimit : nil
    let stops = stopCount
    Task { [weak self, sessionHost] in
      let client = await sessionHost.reconnect()
      guard let self, self.stopCount == stops, self.process === hosted else { return }
      // Taken over on the runner meanwhile, held there or let go since: not this Mac's to
      // attach, whatever the host would allow.
      if client != nil {
        guard let taken = await self.isTakenOver(hosted, stops: stops) else { return }
        if taken { return self.takenOver() }
      }
      self.isReconnecting = false
      guard let client else {
        self.process = nil
        return self.fail(
          String(localized: "Drakar lost the session host, and this session's process with it."))
      }
      // The attach sends stderr's tail again, which holds all of this and more.
      self.diagnostics = ""
      self.follow(hosted.reattach(on: client, attached: self.reattached(hosted)), of: hosted)
    }
  }

  /// A reattach a runner refused because another app holds the process, when that app is
  /// this Mac's own old connection: its relay holds the process until the runner's sshd hangs
  /// it up (spec §3, "A stale relay"). The session shows reconnecting, not lost, and the
  /// attach is tried again with `reconnect()`'s backoff once the host no longer says so, until
  /// `releasingUntil`. False for any other refusal, or a process this Mac does not own, which
  /// are lost as they always were.
  private func waitsOutStaleRelay(_ hosted: HostedProcess, refused failure: any Error) -> Bool {
    guard let deadline = releasingUntil, ContinuousClock.now < deadline,
      case HostedProcess.Failure.lost(let reason) = failure,
      SessionHost.isAttachedElsewhere(reason), let id = hosted.id
    else { return false }
    isReconnecting = true
    let stops = stopCount
    Task { [weak self, sessionHost] in
      // Asked first, so a process this Mac does not own is lost at once, as before.
      let wasReleasing = await sessionHost.reattachRefused(id)
      var releasing = wasReleasing
      var wait = SessionHost.firstWait
      while releasing, ContinuousClock.now < deadline {
        try? await Task.sleep(for: min(wait, deadline - .now))
        // Stopped, or another process since: nothing more is asked of the runner for it.
        guard let self, self.stopCount == stops, self.process === hosted else { return }
        wait = min(wait * 2, SessionHost.longestWait)
        releasing = await sessionHost.reattachRefused(id)
      }
      guard let self, self.stopCount == stops, self.process === hosted else { return }
      // Let go meanwhile: attached again. Refused again, this comes back here.
      let client = wasReleasing && !releasing ? await sessionHost.reconnect() : nil
      guard self.stopCount == stops, self.process === hosted else { return }
      // Refused because the runner's own Drakar took it over, or let go and no longer this
      // Mac's: its tab closes rather than failing in place.
      guard let taken = await self.isTakenOver(hosted, stops: stops) else { return }
      if taken { return self.takenOver() }
      self.isReconnecting = false
      guard let client else {
        self.process = nil
        return self.fail(Self.message(forHostFailure: failure))
      }
      self.diagnostics = ""
      self.follow(hosted.reattach(on: client, attached: self.reattached(hosted)), of: hosted)
    }
    return true
  }

  /// Whether the runner's host lists `hosted`'s process as no longer this Mac's
  /// (`SessionHost.ownership(of:)`). False for a session of this Mac's, and for a process the
  /// host no longer has: those go on as before. A listing that does not come says nothing of
  /// whose it is, so it is asked again with `reconnect()`'s backoff, the session reconnecting
  /// meanwhile, rather than attached unchecked: a session taken over and let go there is free,
  /// and the host would let this Mac have it. Nil once stopped (`stops`) or on another process,
  /// with nothing more to do.
  private func isTakenOver(_ hosted: HostedProcess, stops: Int) async -> Bool? {
    guard isOnRunner, sessionHost.isRunner, let id = hosted.id else { return false }
    var wait = SessionHost.firstWait
    while true {
      let ownership = await sessionHost.ownership(of: id)
      guard stopCount == stops, process === hosted else { return nil }
      switch ownership {
      case .notOwned: return true
      case .owned, .gone: return false
      case .unknown:
        // Let go of for good: no listing ever comes, and the attach fails as it would.
        if sessionHost.isClosed { return false }
        try? await Task.sleep(for: wait)
        wait = min(wait * 2, SessionHost.longestWait)
        guard stopCount == stops, process === hosted else { return nil }
      }
    }
  }

  /// Lets go of a process taken over on the runner, attached to nothing here, and says so to
  /// the window, which closes the tab.
  private func takenOver() {
    isReconnecting = false
    process = nil
    sawEndOnRunner = true
    notingPermissions { transcript.processExited() }
    if phase == .ready || phase == .starting { phase = .exited(status: 0) }
    onTakenOver?()
  }

  /// A refusal of an attach because another app holds the process.
  private static func isHeldElsewhere(_ error: any Error) -> Bool {
    switch error {
    case HostClient.Failure.refused(let reason), HostedProcess.Failure.lost(let reason):
      SessionHost.isAttachedElsewhere(reason)
    default: false
    }
  }

  /// What a reattach of `hosted` is told once the host has taken it: no stale relay holds it.
  private func reattached(_ hosted: HostedProcess) -> @Sendable () -> Void {
    { [weak self] in
      Task { @MainActor in
        guard let self, self.process === hosted else { return }
        self.releasingUntil = nil
      }
    }
  }

  private func receive(_ line: AgentProcess.Line, at time: Date) {
    guard let process else { return }
    let output = backend.receive(line, from: process, at: time)
    for signal in output.signals { handle(signal, at: time) }
    let waiting = transcript.waitingCount
    var turnEnded = false
    let known = sessionID
    var wasRunning = status.isRunning
    for event in output.events {
      transcript.apply(event, at: time)
      if case .turnEnded = event { turnEnded = true }
      // A queued prompt taken once the turn ended starts one with no `send`, which may
      // also end within these lines.
      if !wasRunning, status.isRunning { rewinds.turnStarted() }
      wasRunning = status.isRunning
    }
    // A new or forked session has no id until `system/init`: a registry read before it
    // listed this row's own process as another app's, and nothing else would read it again.
    if isHosted, !isReplaying, sessionID != known { SessionMonitor.shared.hostedChanged() }
    if agent == .codex { codexTurns += output.events.turnsEnded }
    if unsentName != nil { sendUnsentName() }
    if !isReplaying, transcript.waitingCount > waiting { onPermissionRequested?() }
    permissionsMayHaveChanged(from: waiting)
    if turnEndDeferred, output.signals.contains(.queueChanged) {
      if status.isRunning {
        turnEndDeferred = false
      } else if transcript.queuedPrompts.isEmpty {
        turnEndDeferred = false
        if !isReplaying { onTurnEnded?() }
      }
    }
    if turnEnded {
      if !features.picksApplyAtOnce { pillNote = nil }
      if savedTarget == nil { savedTarget = locateTarget() }
      // A compaction's turns are not announced while it goes on, nor at all when idle: the
      // person is likely away, and the transcript says what was done.
      let idle = compaction?.isIdle == true
      let goesOn = !isReplaying && compactionTurnEnded()
      // Not while a queued prompt is about to start the next one: said once the queue
      // empties without a turn, should it be cancelled or refused instead.
      if !transcript.queuedPrompts.isEmpty {
        turnEndDeferred = true
      } else if !isReplaying {
        if goesOn || idle { Attention.shared.refresh() } else { onTurnEnded?() }
      }
    }
    if !isReplaying { armIdleCompaction() }
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
      display()
      armIdleCompaction()
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
      apply(effect, of: first, at: time)
      try? backend.started(transport, then: first)
    case .sent(let command, let effect):
      apply(effect, of: command, at: time)
      _ = try? backend.send(command, to: transport)
    }
  }

  /// `command` is the one logged with `effect`. A prompt's carries the uuid it was sent with,
  /// so a replayed prompt keeps it, from notes written before entries kept one too.
  private func apply(_ effect: NoteEffect, of command: AgentCommand?, at time: Date) {
    switch effect {
    case .prompt(let text, let context, let attachments):
      let uuid: String? =
        if case .prompt(_, _, let uuid, _)? = command { uuid } else { nil }
      transcript.addPrompt(
        text, context: context, attachments: attachments, uuid: uuid, at: time)
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
      if isOnRunner {
        if let reading = AccountUsage(live: info, at: time) { usage = reading.merged(usage) }
      } else if let account {
        accountStore.record(info, for: account, at: time)
      }
    case .models(let models):
      if isOnRunner {
        self.models = models
      } else if agent == .codex {
        catalog.recordCodex(models)
      } else if let account {
        catalog.record(models, for: account)
      }
    case .modeAdopted(let mode):
      adopt(mode: mode)
    case .initialized(let reply):
      if isOnRunner, let commands = Self.commands(fromInitialize: reply) {
        reportedCommands = commands
      }
      if isReplaying {
        replayedInitialize = .some(reply)
        replayedCommands = nil
      } else {
        onInitialized?(reply)
      }
    case .commandsChanged(let commands):
      if isOnRunner, let listed = Self.commands(fromInitialize: commands) {
        reportedCommands = listed
      }
      if isReplaying { replayedCommands = commands } else { onCommandsChanged?(commands) }
    case .settingsApplied(let effort, let model, let autoModeDisabled):
      appliedEffort = effort
      appliedModel = model
      self.autoModeDisabled = autoModeDisabled
    case .contextReported(let reply):
      reportedContext = reply
    case .changeAnswered(let id, let refusal):
      changeAnswered(id, refusal: refusal)
    case .queueChanged:
      break
    case .skillsChanged:
      CodexSkillStore.shared.skills(for: folder).refreshIfLoaded()
    case .taskStopAnswered, .backgroundAnswered, .taskOutputAnswered:
      tasks.answered(signal)
    case .rewindAnswered(_, _, let result):
      // A dry run's refusal or a rewind's: either says it of the whole process.
      if result?.isNotEnabled == true { rewindNotEnabled = true }
      if rewinds.answered(signal) { noteRewound() }
    case .permissionRulesAnswered(let id, _), .planAnswered(let id, _),
      .serversAnswered(let id, _), .reconnectAnswered(let id, _):
      resumeControlReply(id, with: signal)
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
    // A runner's session's transcript is on the runner, never in an account of this Mac's.
    guard !isOnRunner, let id = sessionID else { return nil }
    return backend.locateTarget(
      sessionID: id, cwd: status.session?.cwd ?? folder.path(percentEncoded: false),
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

extension AgentSession {
  /// The `/` menu's list from an `initialize` reply or a `commands_changed` list: the skills
  /// and the CLI's own commands, as the project's lists take them.
  fileprivate static func commands(fromInitialize reply: JSONValue?) -> [SkillEntry]? {
    ProjectCapabilities.commands(fromInitialize: reply)
  }

  /// Where a process runs and whose it is, as its meta says them: nil throughout for a
  /// process of this Mac's.
  fileprivate struct Placement: Equatable {
    var runner: String?
    var origin: String?
    var owner: String?
  }
}

extension AgentSession.Placement {
  fileprivate init(of meta: SessionMeta) {
    self.init(runner: meta.runner, origin: meta.origin, owner: meta.owner)
  }
}

/// A mode, model or effort switch sent and not yet answered.
private struct UnansweredChange {
  enum Pill { case mode, model, effort }

  var id: String
  var pill: Pill
  var revert: () -> Void
}
