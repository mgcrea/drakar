import DrakarKit
import DrakarMCP
import Foundation

// How each place a session is found in becomes a `SessionRow` and its `AttentionItem`s: a
// window's `ProjectSession`, a process a session host holds with no window (its `SessionMeta`),
// and a summary the monitor read of a transcript. One vocabulary for all of them (spec §3).

@MainActor
extension SessionMCPSource {
  // MARK: - Windows

  /// A window's row. One that only follows a session another process runs (a terminal's,
  /// VS Code's) reads as that process's registry says, as the session's banner does.
  func windowRow(
    _ item: ProjectSession, in project: Project, summary: SessionSummary?
  ) -> SessionRow {
    let session = item.session
    let id = item.sessionID ?? ""
    let gauge = item.gauge(
      accountModel: session.resuming.flatMap { monitor.accountModel(for: $0.account) })
    var row = SessionRow(
      id: id, title: item.knownTitle, agent: session.agent == .codex ? .codex : .claude,
      folder: ProjectPath.normalize(project.folder), runner: project.runnerName,
      state: Self.state(of: session), waitingFor: item.waitingFor ?? item.closingAsk?.text,
      model: session.runningModel ?? item.preview?.modelID, contextUsed: gauge?.used,
      contextLimit: gauge?.window.limit, lastActivity: item.lastActivity, place: .window,
      readOnly: session.isReadOnly || session.heldElsewhere != nil)
    if session.heldElsewhere != nil {
      row.heldBy = session.belongsTo ?? "another Drakar window"
    } else if session.isReadOnly {
      row.heldBy = summary.map { monitor.host(of: $0, excluding: project) } ?? "another app"
    }
    if let followed = Self.followed(item, summary: summary) {
      row.state = Self.state(of: followed.live)
      let dismissed = item.dismissedAsk ?? project.dismissedElsewhere[id]
      row.waitingFor = level(of: followed, dismissed: dismissed)?.wants(of: followed)
    }
    return row
  }

  /// A window's session folded into the one vocabulary: a connection lost or a process out
  /// of reach before what the transcript says, then waiting on the person, then a turn.
  static func state(of session: AgentSession) -> SessionState {
    if session.isReconnecting { return .reconnecting }
    if session.isOutOfReach || session.isGoneOnRunner { return .unreachable }
    if session.status.isWaitingOnPerson { return .waiting }
    if session.status.isRunning { return .working }
    return .idle
  }

  /// The summary of the process a read-only row follows, while the registry has it open.
  /// Not one another Drakar holds (`heldElsewhere`), which no registry lists as another app.
  static func followed(_ item: ProjectSession, summary: SessionSummary?) -> SessionSummary? {
    guard item.session.isReadOnly, item.session.heldElsewhere == nil, let summary,
      summary.live != nil
    else { return nil }
    return summary
  }

  /// What a window's session waits on, permissions before MCP servers' questions, each in
  /// arrival order.
  static func pending(of item: ProjectSession) -> [PendingItem] {
    let status = item.session.status
    return status.pendingPermissions.map {
      PendingItem.permission(requestID: $0.requestID, request: $0.request)
    }
      + status.pendingElicitations.map {
        PendingItem.elicitation(requestID: $0.requestID, elicitation: $0.elicitation)
      }
  }

  /// One item per request a window's session waits on; with none, the ask its turn ended on.
  static func attentionItems(of item: ProjectSession, row: SessionRow) -> [AttentionItem] {
    let waiting = pending(of: item).map {
      AttentionItem(session: row, kind: kind(of: $0), pending: $0)
    }
    guard waiting.isEmpty, let ask = item.closingAsk else { return waiting }
    let kind: AttentionKind = ask.kind == .question ? .askedInText : .offeredInText
    return [AttentionItem(session: row, kind: kind, text: ask.text)]
  }

  /// An `AskUserQuestion` is a question, `ExitPlanMode` a plan, any other tool a permission.
  static func kind(of pending: PendingItem) -> AttentionKind {
    switch pending {
    case .permission(_, let request):
      request.isChoice ? .question : request.isPlan ? .plan : .permission
    case .elicitation: .elicitation
    }
  }

  // MARK: - The session hosts

  /// A process a session host holds with no window, and what its row was made from.
  @MainActor struct Background {
    var row: SessionRow
    var meta: SessionMeta

    /// What it resumes or was saved as, which names its transcript and account.
    private var target: ResumeTarget? { meta.savedTarget ?? meta.start.resuming }

    /// Its Claude Code transcript on this Mac, when its meta names one.
    var transcriptFile: URL? {
      guard row.runner == nil, meta.agent == .claude, let target, !target.file.isEmpty else {
        return nil
      }
      return target.transcriptFile
    }

    /// The account it runs under, for this Mac's Claude Code sessions.
    var accountFolder: String? {
      guard row.runner == nil, meta.agent == .claude else { return nil }
      return target?.accountDirectory ?? meta.accountPick?.directory.path(percentEncoded: false)
    }
  }

  /// The processes `held` lists that run with no app attached and are this Mac's to take
  /// (`SessionMeta.mayBeTaken`, as Home counts them), once each by session id, none of
  /// `listed`. A process with no session id yet is none. `runner`: the runner's name for its
  /// host's, nil for this Mac's, whose `live` registry says busy or waiting; a runner's have
  /// no registry here, and read as idle.
  static func backgroundRows(
    _ held: [HeldProcess], runner: String?, live: [LiveSession], excluding listed: Set<String>,
    summary summaryOf: (String) -> SessionSummary? = { _ in nil },
    accountModel: (ClaudeAccount) -> String? = { _ in nil }
  ) -> [Background] {
    let registry = Dictionary(live.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
    var seen = listed
    var rows: [Background] = []
    for process in held where process.running && process.attachedApp == nil {
      guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta),
        meta.mayBeTaken(by: ThisMac.name, onRunner: runner != nil),
        let id = meta.sessionID, seen.insert(id).inserted
      else { continue }
      let summary = runner == nil ? summaryOf(id) : nil
      let live = runner == nil ? registry[id] : nil
      let gauge = summary.flatMap { Self.gauge(of: $0, accountModel: accountModel($0.account)) }
      let state = Self.state(of: live)
      let row = SessionRow(
        id: id, title: meta.name ?? summary.flatMap(Self.title(of:)),
        agent: meta.agent == .codex ? .codex : .claude,
        folder: ProjectPath.normalize(meta.windowFolder), runner: runner, state: state,
        waitingFor: state == .waiting ? live?.waitingFor : nil,
        model: meta.modelPick ?? summary?.modelID, contextUsed: gauge?.used,
        contextLimit: gauge?.window.limit,
        lastActivity: live?.updatedAt ?? summary?.modified, place: .background)
      rows.append(Background(row: row, meta: meta))
    }
    return rows
  }

  // MARK: - The monitor

  /// A session live in another process: read-only, where it runs, in the state its registry
  /// says, wanting what its level says.
  func elsewhereRow(_ summary: SessionSummary, dismissed: String?) -> SessionRow {
    var row = endedRow(summary)
    row.state = Self.state(of: summary.live)
    row.waitingFor = level(of: summary, dismissed: dismissed)?.wants(of: summary)
    row.lastActivity = summary.live?.updatedAt.map { max($0, summary.modified) } ?? summary.modified
    row.readOnly = true
    row.heldBy = monitor.host(of: summary)
    return row
  }

  /// A session no process has open, from its transcript's summary, under the project that
  /// owns its folder.
  func endedRow(_ summary: SessionSummary) -> SessionRow {
    let gauge = Self.gauge(of: summary, accountModel: monitor.accountModel(for: summary.account))
    return SessionRow(
      id: summary.sessionID, title: Self.title(of: summary), agent: .claude,
      folder: summary.cwd.map { openSessions.ownerFolder(forCwd: $0) } ?? "", state: .ended,
      model: summary.modelID ?? summary.context?.modelID, contextUsed: gauge?.used,
      contextLimit: gauge?.window.limit, lastActivity: summary.modified, place: .elsewhere)
  }

  /// How much a session elsewhere wants the person, as its window's sidebar and the Dock say.
  func level(of summary: SessionSummary, dismissed: String?) -> Urgency? {
    Urgency.of(summary, recognisesAsks: AttentionChoice.recognisesAsks, dismissed: dismissed)
  }

  /// The asks dismissed in each open window for the sessions it lists elsewhere.
  func dismissedElsewhere() -> [String: String] {
    openSessions.projects.values.reduce(into: [:]) { all, project in
      all.merge(project.dismissedElsewhere) { first, _ in first }
    }
  }

  /// A session elsewhere at `level`: nothing to answer here, only what it wants.
  static func elsewhereItem(
    _ summary: SessionSummary, level: Urgency?, row: SessionRow
  ) -> AttentionItem? {
    switch level {
    case .permission: AttentionItem(session: row, kind: .permission)
    case .choice: AttentionItem(session: row, kind: .question)
    case .question: AttentionItem(session: row, kind: .askedInText, text: summary.closingAsk?.text)
    case .offer: AttentionItem(session: row, kind: .offeredInText, text: summary.closingAsk?.text)
    case nil: nil
    }
  }

  static func state(of live: LiveSession?) -> SessionState {
    switch live?.status {
    case "busy": .working
    case "waiting": .waiting
    default: .idle
    }
  }

  static func title(of summary: SessionSummary) -> String? {
    summary.title ?? summary.lastPrompt.map { String($0.prefix(80)) }
  }

  static func gauge(of summary: SessionSummary, accountModel: String?) -> ContextGauge? {
    ContextGauge.make(
      usage: summary.context?.usage, reportedLimit: nil, initModelID: nil,
      attachmentModelID: summary.modelID, accountModelID: accountModel,
      messageModelID: summary.context?.modelID)
  }

  // MARK: - Order

  /// Most urgent first, Drakar's `Urgency` order (permission, choice, question, offer); in the
  /// order found within a level.
  static func mostUrgentFirst(_ items: [AttentionItem]) -> [AttentionItem] {
    items.enumerated().sorted { lhs, rhs in
      let (left, right) = (urgency(of: lhs.element.kind), urgency(of: rhs.element.kind))
      return left != right ? left > right : lhs.offset < rhs.offset
    }.map(\.element)
  }

  /// The level each kind stands at: an MCP server's question blocks its tool as a permission
  /// does (`ProjectSession.urgency`), and a plan waits as a choice.
  static func urgency(of kind: AttentionKind) -> Urgency {
    switch kind {
    case .permission, .elicitation: .permission
    case .question, .plan: .choice
    case .askedInText: .question
    case .offeredInText: .offer
    }
  }
}
