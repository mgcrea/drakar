import AppKit
import DrakarKit
import Foundation

/// Moving a folder's sessions to another account: which ones, in what state, and what came
/// of it (`docs/superpowers/specs/2026-10-04-move-sessions-design.md`). `SessionMover` moves
/// the files; this decides, one session at a time and just before its move, whether it may.
enum SessionMoves {
  /// One session that could move.
  struct Candidate: Equatable {
    var sessionID: String
    var title: String
    var transcript: URL
    var account: ClaudeAccount
    var cwd: String?
  }

  /// A Drakar window holding the session, as the move sees it.
  struct Held: Equatable {
    var hasProcess: Bool
    /// A turn running or a permission waiting: stopping it would lose work.
    var isBusy: Bool
  }

  enum Plan: Equatable {
    case move(stopping: Bool)
    case skip(SkipReason)
  }

  struct Report: Equatable {
    var title: String
    var outcome: MoveOutcome
  }

  static func held(_ session: ClaudeSession) -> Held {
    Held(
      hasProcess: session.isProcessRunning,
      isBusy: session.transcript.isRunning || !session.transcript.pendingPermissions.isEmpty)
  }

  /// The sessions not on `target`: those listed, and the windows' own, whose transcript can
  /// be newer than the list. One per id, the window's when both have it.
  static func candidates(
    summaries: [SessionSummary], held: [(target: ResumeTarget, title: String)],
    notOn target: ClaudeAccount
  ) -> [Candidate] {
    var byID: [String: Candidate] = [:]
    var order: [String] = []
    for summary in summaries where summary.account.key != target.key {
      if byID[summary.sessionID] == nil { order.append(summary.sessionID) }
      byID[summary.sessionID] = Candidate(
        sessionID: summary.sessionID, title: summary.displayTitle, transcript: summary.file,
        account: summary.account, cwd: summary.cwd)
    }
    for (resume, title) in held where resume.account.key != target.key {
      if byID[resume.sessionID] == nil { order.append(resume.sessionID) }
      byID[resume.sessionID] = Candidate(
        sessionID: resume.sessionID, title: title, transcript: resume.transcriptFile,
        account: resume.account, cwd: resume.cwd)
    }
    return order.compactMap { byID[$0] }
  }

  /// A held session is the window's to judge; one no window holds but a process has open is
  /// running elsewhere, even when this window watches it.
  static func classify(sessionID: String, held: Held?, liveIDs: Set<String>, host: String) -> Plan {
    if let held { return held.isBusy ? .skip(.busy) : .move(stopping: held.hasProcess) }
    if liveIDs.contains(sessionID) { return .skip(.runningElsewhere(host)) }
    return .move(stopping: false)
  }

  /// One at a time, each judged just before its move: a terminal may resume one, or the
  /// person prompt one, while the others move.
  static func run(
    _ candidates: [Candidate], to target: ClaudeAccount, locate: (String) -> ClaudeSession?,
    liveIDs: () -> Set<String>, host: (Candidate) -> String
  ) async -> [Report] {
    var reports: [Report] = []
    for candidate in candidates {
      let session = locate(candidate.sessionID)
      let plan = classify(
        sessionID: candidate.sessionID, held: session.map(held), liveIDs: liveIDs(),
        host: host(candidate))
      guard case .move(let stopping) = plan else {
        if case .skip(let reason) = plan {
          reports.append(Report(title: candidate.title, outcome: .skipped(reason)))
        }
        continue
      }
      if stopping { session?.stop() }
      let transcript = candidate.transcript
      let source = candidate.account
      let outcome = await Task.detached {
        SessionMover.move(transcript: transcript, from: source, to: target)
      }.value
      if outcome == .moved, let session {
        session.relocate(
          to: ResumeTarget(
            sessionID: candidate.sessionID,
            cwd: candidate.cwd ?? session.folder.path(percentEncoded: false),
            file: SessionMover.destination(of: transcript, to: target).path(percentEncoded: false),
            accountDirectory: target.key, accountIsDefault: target.isDefault))
      }
      reports.append(Report(title: candidate.title, outcome: outcome))
    }
    return reports
  }

  /// `Moved 12 sessions to Skitrust. Not moved: 2 running in VS Code, 1 already on Skitrust.`
  static func summary(_ reports: [Report], to name: String) -> String {
    let moved = reports.count { $0.outcome == .moved }
    var text =
      switch moved {
      case 0: String(localized: "Moved no session to \(name).")
      case 1: String(localized: "Moved 1 session to \(name).")
      default: String(localized: "Moved \(moved) sessions to \(name).")
      }
    var skipped: [String] = []
    var counts: [String: Int] = [:]
    var failures: [String] = []
    for report in reports {
      let label: String
      switch report.outcome {
      case .moved: continue
      case .failed(let reason):
        failures.append("“\(report.title)”: \(reason)")
        continue
      case .skipped(.busy): label = String(localized: "busy")
      case .skipped(.alreadyThere): label = String(localized: "already on \(name)")
      case .skipped(.runningElsewhere(let host)): label = String(localized: "running in \(host)")
      }
      if counts[label] == nil { skipped.append(label) }
      counts[label, default: 0] += 1
    }
    if !skipped.isEmpty {
      text +=
        " " + String(localized: "Not moved:") + " "
        + skipped.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: ", ") + "."
    }
    if !failures.isEmpty {
      text += " " + String(localized: "Failed:") + " " + failures.joined(separator: "; ") + "."
    }
    return text
  }
}

extension SessionMoves {
  /// The app's own answers to `run`'s questions.
  private static func runInApp(_ candidates: [Candidate], to target: ClaudeAccount) async
    -> [Report]
  {
    let monitor = SessionMonitor.shared
    return await run(
      candidates, to: target, locate: { OpenSessions.shared.locate($0)?.1.session },
      liveIDs: { monitor.liveIDs }, host: { hostName(of: $0) })
  }

  private static func hostName(of candidate: Candidate) -> String {
    let monitor = SessionMonitor.shared
    return monitor.summary(forFile: candidate.transcript).map { monitor.host(of: $0) }
      ?? String(localized: "another app")
  }

  /// After the picker moved `folder` from `source` to `target`: offer to take its sessions
  /// along. Asks nothing when there is nothing to move.
  static func offer(folder: URL, from source: ClaudeAccount, to target: ClaudeAccount) {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    let held = OpenSessions.shared.projects.values
      .filter { ProjectPath.normalize($0.folder.path(percentEncoded: false)) == path }
      .flatMap(\.held)
      .compactMap { item in item.session.savedTarget.map { (target: $0, title: item.displayTitle) }
      }
    let all = candidates(
      summaries: SessionMonitor.shared.summaries(under: path), held: held, notOn: target)
    let live = SessionMonitor.shared.liveIDs
    let elsewhere = all.filter {
      OpenSessions.shared.locate($0.sessionID) == nil && live.contains($0.sessionID)
    }
    let movable = all.count - elsewhere.count
    guard movable > 0 else { return }
    let store = AccountStore.shared
    let from = store.profile(for: source).name
    let to = store.profile(for: target).name
    let alert = NSAlert()
    alert.messageText =
      movable == 1
      ? String(localized: "Move this folder's session from \(from) to \(to) too?")
      : String(localized: "Move this folder's \(movable) sessions from \(from) to \(to) too?")
    if !elsewhere.isEmpty {
      let hosts = Set(elsewhere.map(hostName(of:))).sorted().joined(separator: ", ")
      alert.informativeText = String(
        localized: "\(elsewhere.count) running in \(hosts) will stay on \(from).")
    }
    alert.addButton(
      withTitle: movable == 1
        ? String(localized: "Move Session") : String(localized: "Move \(movable) Sessions"))
    alert.addButton(withTitle: String(localized: "Not Now"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      let reports = await runInApp(all, to: target)
      let summary = NSAlert()
      summary.messageText = Self.summary(reports, to: to)
      summary.runModal()
    }
  }

  /// One session from its row. Says something only when it did not move.
  static func moveOne(_ candidate: Candidate, to target: ClaudeAccount) {
    Task {
      let reports = await runInApp([candidate], to: target)
      guard reports.first?.outcome != .moved else { return }
      let alert = NSAlert()
      alert.messageText = Self.summary(reports, to: AccountStore.shared.profile(for: target).name)
      alert.runModal()
    }
  }

  static func candidate(for summary: SessionSummary) -> Candidate {
    Candidate(
      sessionID: summary.sessionID, title: summary.displayTitle, transcript: summary.file,
      account: summary.account, cwd: summary.cwd)
  }

  /// Nil for a session never prompted: it has no files, and starts on the window's account.
  static func candidate(for item: ProjectSession) -> Candidate? {
    item.session.savedTarget.map {
      Candidate(
        sessionID: $0.sessionID, title: item.displayTitle, transcript: $0.transcriptFile,
        account: $0.account, cwd: $0.cwd)
    }
  }

  /// Every discovered account but `current`, for a "Move to" menu.
  static func destinations(from current: ClaudeAccount) -> [ClaudeAccount] {
    AccountStore.shared.accounts.filter { $0.key != current.key }
  }
}
