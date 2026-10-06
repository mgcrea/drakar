import DrakarKit
import Foundation

/// Everything a transcript shows, as plain values a golden file can hold: the refactor's
/// contract (docs/superpowers/specs/2026-10-06-agent-backend-design.md, "Testing"). Built
/// from public properties only, so it reads the same before and after the transcript's
/// insides move. `revision` is left out: it counts changes, not what they made.
struct TranscriptSnapshot: Codable, Equatable {
  struct Entry: Codable, Equatable {
    var id: String
    var kind: String
    var text: String?
    var tool: Tool?
    var parent: String?
    var context: String?
    var attachments: [String]
    var thinkingLive: Bool
    var thinkingTimed: Bool
  }

  struct Tool: Codable, Equatable {
    var id: String
    var name: String
    var input: String
    var summary: String
    var result: String?
    var isError: Bool?
    var answers: [String: String]?
    var agentReport: String?
    var earlierAnswers: [String: String]?
  }

  var entries: [Entry]
  var session: String?
  var pending: [String]
  var turnEnd: String?
  var lastTurn: String?
  var title: String?
  var customTitle: String?
  var aiTitle: String?
  var writerVersion: String?
  var historyPermissionMode: String?
  var historyEffort: String?
  var contextUsage: String?
  var contextModelID: String?
  var promptCache: String
  var isRunning: Bool
  var isCompacting: Bool
  var retry: String?
  var queued: [String]
  var todos: [String]?
  var agentTasks: [String]
  var closingText: String?
  var unansweredQuestion: String?

  init(_ t: Transcript, now: Date) {
    entries = t.entries.map(Self.entry)
    session = t.session.map {
      [
        $0.sessionID, $0.cwd ?? "-", $0.model ?? "-", $0.permissionMode ?? "-",
        $0.agentVersion ?? "-", $0.apiKeySource ?? "-", $0.tools.joined(separator: ","),
      ]
      .joined(separator: "|")
    }
    pending = t.pendingPermissions.map { "\($0.requestID)|\($0.request.toolName)" }
    turnEnd = t.turnEnd.map { "\($0)" }
    lastTurn = t.lastResult.map {
      "text=\($0.text ?? "-")|cost=\($0.totalCostUSD.map { "\($0)" } ?? "-")"
        + "|duration=\($0.durationMS.map(String.init) ?? "-")"
    }
    title = t.title
    customTitle = t.customTitle
    aiTitle = t.aiTitle
    writerVersion = t.writerVersion
    historyPermissionMode = t.historyPermissionMode
    historyEffort = t.historyEffort
    contextUsage = t.contextUsage.map {
      "\($0.input)/\($0.cacheCreation)/\($0.cacheRead)/\($0.output)/\($0.cacheWriteTTL.map { "\($0)" } ?? "-")"
    }
    contextModelID = t.contextModelID
    promptCache = "\(t.promptCache.state(at: now))"
    isRunning = t.isRunning
    isCompacting = t.isCompacting
    retry = t.retry.map { "\($0.attempt ?? -1)/\($0.maxRetries ?? -1)/\($0.delayMS ?? -1)" }
    queued = t.queuedPrompts.map { "\($0.uuid)|\($0.text)" }
    todos = t.todos?.map { "\($0.status.rawValue)|\($0.content)" }
    agentTasks = t.agentTasks.keys.sorted().map { call in
      let task = t.agentTasks[call]!
      return [
        call, "\(task.status)", task.description ?? "-", task.prompt ?? "-",
        "\(task.isBackgrounded)", task.summary ?? "-", task.progressLine ?? "-",
      ]
      .joined(separator: "|")
    }
    closingText = t.closingText.map { "\($0.messageID)|\($0.text)" }
    unansweredQuestion = t.unansweredQuestion?.id
  }

  private static func attachment(_ a: AttachmentPreview) -> String {
    let kind =
      switch a.kind {
      case .image: "image"
      case .pdf: "pdf"
      case .text: "text"
      }
    return [kind, a.name ?? "-", a.thumbnail.map { "\($0.count)" } ?? "-"].joined(separator: "|")
  }

  private static func entry(_ e: Transcript.Entry) -> Entry {
    var kind = ""
    var text: String?
    var tool: Tool?
    switch e.kind {
    case .prompt(let s): (kind, text) = ("prompt", s)
    case .text(let s): (kind, text) = ("text", s)
    case .thinking(let s): (kind, text) = ("thinking", s)
    case .notice(let s): (kind, text) = ("notice", s)
    case .failure(let s): (kind, text) = ("failure", s)
    case .tool(let call):
      kind = "tool"
      tool = Tool(
        id: call.id, name: call.name, input: call.input.prettyPrinted, summary: call.summary,
        result: call.result?.content, isError: call.result?.isError,
        answers: call.result?.answers,
        agentReport: call.result?.agentReport.map { "\($0.status)|\($0.text ?? "-")" },
        earlierAnswers: call.earlierAnswers)
    }
    return Entry(
      id: e.id, kind: kind, text: text, tool: tool, parent: e.parentToolUseID,
      context: e.context, attachments: e.attachments.map(Self.attachment),
      thinkingLive: e.thinkingSince != nil, thinkingTimed: e.thinkingDuration != nil)
  }
}
