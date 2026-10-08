import DrakarKit
import Foundation

/// One agent's wire format, behind which `AgentSession` runs it: how to start its CLI, what
/// its lines mean, how a command is written. Claude Code's is `ClaudeBackend`.
///
/// Stateless about the process, which the session owns and passes in; stateful about the
/// stream (its translator, its request ids).
protocol AgentBackend: AnyObject {
  /// Shown when the agent's CLI was not found.
  var notFoundMessage: String { get }
  /// What its sessions can do beyond a conversation.
  var features: AgentFeatures { get }
  /// What to run for `start`; no executable when the CLI was not found.
  func launch(_ start: AgentStart) -> AgentLaunch
  /// Everything owed right after the process started, then `first`, the prompt typed before
  /// it existed.
  func started(_ process: AgentProcess, then first: AgentCommand?) throws
  /// One line the process wrote. A reply the agent waits for is written here.
  func receive(_ line: AgentProcess.Line, from process: AgentProcess, at time: Date)
    -> BackendOutput
  /// Writes `command`; the request id, where an answer can come back (mode, model, effort).
  @discardableResult func send(_ command: AgentCommand, to process: AgentProcess) throws
    -> String?
  /// Where a session's own transcript is, once it has an id. Disk-side, Claude-typed until
  /// Codex history (slice 3).
  func locateTarget(sessionID: String, cwd: String, in accounts: [ClaudeAccount]) -> ResumeTarget?
}

/// What a session asks to start with: its folder, what it resumes, and its pills' picks,
/// frozen for this process.
struct AgentStart {
  var folder: URL
  var resuming: ResumeTarget?
  /// The login shell's.
  var environment: [String: String]
  var executableOverride: URL?
  /// Nil or `default`: the agent's own.
  var model: String?
  var mode: PermissionMode?
  var effort: String?
  var allowsBypass: Bool
  /// A name not yet recorded.
  var name: String?
}

struct AgentLaunch {
  /// Nil when the CLI was not found.
  var configuration: AgentProcess.Configuration?
  var executable: URL?
  var account: ClaudeAccount?
}

/// What the person does, in no agent's words.
enum AgentCommand {
  case prompt(text: String, context: [EditorSelection], uuid: String, attachments: [Attachment])
  case answer(requestID: String, decision: PermissionDecision)
  case interrupt(cancelQueued: Bool)
  case cancelQueued(uuid: String)
  case setMode(String)
  case setModel(String)
  case setEffort(String)
  case rename(title: String, sessionID: String)
}

struct BackendOutput {
  /// What the conversation shows.
  var events: [AgentEvent] = []
  /// What the session learns, never shown as conversation.
  var signals: [SessionSignal] = []
}

enum SessionSignal: Equatable {
  /// The handshake's answer, which lists the skills.
  case initialized(JSONValue?)
  case commandsChanged(JSONValue)
  case models([ModelOption])
  case modeAdopted(String)
  case settingsApplied(effort: String?, model: String?)
  case contextReported(ContextUsageReply)
  case rateLimit(JSONValue)
  /// A mode, model or effort change was answered: `refusal` nil when it took.
  case changeAnswered(requestID: String, refusal: String?)
  /// A queued prompt moved: taken, cancelled, dropped, or only acknowledged.
  case queueChanged
  /// Nothing can go through this process: not signed in, or its session held by another
  /// process. The session stops and says why.
  case unusable(String)
  /// The agent's skills changed: a list read before is stale.
  case skillsChanged
}
