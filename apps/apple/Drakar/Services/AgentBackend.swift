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
  func started(_ process: any ProcessTransport, then first: AgentCommand?) throws
  /// One line the process wrote. A reply the agent waits for is written here.
  func receive(_ line: AgentProcess.Line, from process: any ProcessTransport, at time: Date)
    -> BackendOutput
  /// Writes `command`; the request id, where an answer can come back (mode, model, effort).
  @discardableResult func send(_ command: AgentCommand, to process: any ProcessTransport) throws
    -> String?
  /// Where a session's own transcript is, once it has an id. Disk-side, Claude-typed until
  /// Codex history (slice 3).
  func locateTarget(sessionID: String, cwd: String, in accounts: [ClaudeAccount]) -> ResumeTarget?
}

/// What a session asks to start with: its folder, what it resumes, and its pills' picks,
/// frozen for this process.
struct AgentStart: Codable, Equatable {
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
  /// The account picked for this session alone, over the folder's; Claude Code's only.
  var account: ClaudeAccount? = nil
}

struct AgentLaunch {
  /// Nil when the CLI was not found.
  var configuration: AgentProcess.Configuration?
  var executable: URL?
  var account: ClaudeAccount?
}

/// What the person does, in no agent's words.
enum AgentCommand: Codable, Equatable {
  case prompt(text: String, context: [EditorSelection], uuid: String, attachments: [Attachment])
  case answer(requestID: String, decision: PermissionDecision)
  /// Its note keeps the action alone (`NotedAnswer`), never what was typed.
  case answerElicitation(requestID: String, NotedAnswer)
  case interrupt(cancelQueued: Bool)
  case cancelQueued(uuid: String)
  case setMode(String)
  case setModel(String)
  case setEffort(String)
  case rename(title: String, sessionID: String)
  /// Task controls (`TaskControls`), sent without a note: a replay never sees them.
  case stopTask(taskID: String)
  case backgroundCall(toolUseID: String)
  case taskOutput(taskID: String)
  /// A code rewind (`Rewinds`), sent without a note as the task controls are.
  case rewindFiles(userMessageID: String, dryRun: Bool)
  /// Reads of the running process for the Rules tab and Open Plan, sent without a note
  /// as `rewindFiles` is: they change nothing a replay would need.
  case listPermissionRules
  case getPlan
}

/// How a running process answered for its permission rules.
enum PermissionRulesAnswer: Equatable {
  case listed(PermissionRulesState)
  /// The CLI's error, or a sentence saying it gave no reply to read.
  case refused(String)

  /// A `list_permission_rules` reply: its listing, else the CLI's error, else a sentence
  /// saying there was nothing to read.
  init(_ response: ControlResponse) {
    if response.isSuccess, let state = PermissionRulesState(response.response) {
      self = .listed(state)
    } else {
      self = .refused(
        response.error.flatMap { $0.isEmpty ? nil : $0 }
          ?? String(localized: "Claude Code didn't answer."))
    }
  }
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
  case settingsApplied(effort: String?, model: String?, autoModeDisabled: Bool)
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
  /// A `stopTask` was answered: `error` nil when it took. Claude Code answers success for a
  /// task that had already ended too; the task's own lines say it stopped.
  case taskStopAnswered(taskID: String, error: String?)
  case backgroundAnswered(toolUseID: String, BackgroundOutcome)
  /// Nil for a reply that holds no output.
  case taskOutputAnswered(taskID: String, TaskOutput?)
  /// A `rewindFiles` was answered, for the message and kind it was sent as. A refusal comes
  /// as a result with `canRewind` false and the CLI's error; nil for one with no text.
  case rewindAnswered(userMessageID: String, dryRun: Bool, RewindResult?)
  /// A `listPermissionRules` was answered, under the id `send` returned for it.
  case permissionRulesAnswered(requestID: String, PermissionRulesAnswer)
  /// A `getPlan` was answered; nil for a refusal or a reply with nothing to read.
  case planAnswered(requestID: String, PlanReply?)
}
