import DrakarKit
import Foundation

/// The app's own record of a process, kept beside it: with it and the process's log, a
/// relaunched app rebuilds the session without asking the CLI anything.
struct SessionMeta: Codable, Equatable {
  /// What the process was launched with.
  var start: AgentStart
  var windowFolder: String
  var name: String?
  var modePick: PermissionMode?
  var modelPick: String?
  var effortPick: String?
  var accountPick: ClaudeAccount?
  /// Once `system/init` said it.
  var sessionID: String?
  var savedTarget: ResumeTarget?
  /// The batch this session was started for. Optional so that a meta written before it
  /// existed still decodes.
  var fanOut: FanOutMark?
  /// Where the history stood when the process started: the rest is in the log.
  var history: HistoryMark

  /// The meta says it only through what it resumes and the history it marks: a Codex
  /// session's is always counted in turns, a new thread's as 0.
  var agent: AgentKind {
    if case .codexTurns = history { return .codex }
    return start.resuming?.agentKind ?? .claude
  }
}

/// Which place in a skill run in each subfolder a session was started for: kept in its meta
/// so that a relaunched window can tell it from the batch's other rows even when the
/// window never learned the host's id for it.
struct FanOutMark: Codable, Equatable {
  var batch: UUID
  var index: Int
}

/// How much of a session's history came before its process.
enum HistoryMark: Codable, Equatable {
  /// A new session: everything is in the log.
  case none
  /// Claude Code's transcript file, up to `length` bytes.
  case claudeFile(path: String, length: UInt64)
  /// The number of turns Codex's thread held (`AgentSession.codexTurnsBeforeProcess`):
  /// always a Codex session's mark, for it also says the agent.
  case codexTurns(Int)
}
