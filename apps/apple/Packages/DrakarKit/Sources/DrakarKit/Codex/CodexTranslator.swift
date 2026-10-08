import Foundation

/// Codex's app-server (docs/codex-app-server.md) as agent events: live lines through
/// `translate`, a thread's stored items through `history`. Only what was verified against
/// codex-cli 0.160.1 on 2026-10-06 and 2026-10-07, except `error`, from the types.
///
/// Codex is item-based: `item/started`, deltas by item id, `item/completed`. A tool's result
/// is its own item's completion. Approvals are JSON-RPC requests whose id answers them.
public struct CodexTranslator: Sendable {
  /// File changes by item id, which an approval request names without describing.
  private var fileChanges: [String: ToolKind] = [:]
  /// Reasoning items that started empty, placed only once their summary streams: at low
  /// effort they arrive empty and stay so (docs/codex-app-server.md).
  private var unplacedReasoning: Set<String> = []
  /// Reasoning items the transcript has, until they complete.
  private var placedReasoning: Set<String> = []
  /// An `error` said Codex retries: the next line says it is over.
  private var isRetrying = false

  public init() {}

  public mutating func translate(_ message: JSONValue, at time: Date?) -> [AgentEvent] {
    guard let method = message["method"]?.stringValue else { return [] }
    let params = message["params"] ?? .null
    if method == "error" {
      let text = params["error"]?["message"]?.stringValue ?? String(localized: "Codex failed.")
      guard params["willRetry"]?.boolValue == true else {
        isRetrying = false
        return [.retrying(nil), .note(.init(text: text, isFailure: true))]
      }
      isRetrying = true
      return [.retrying(APIRetry(attempt: nil, maxRetries: nil, delayMS: nil))]
    }
    var events: [AgentEvent] = []
    if isRetrying {
      isRetrying = false
      events.append(.retrying(nil))
    }
    switch method {
    case "thread/started":
      guard let thread = params["thread"], let id = thread["id"]?.stringValue else { break }
      events.append(
        .sessionStarted(
          SessionInfo(
            sessionID: id, cwd: thread["cwd"]?.stringValue, model: thread["model"]?.stringValue,
            agentVersion: thread["cliVersion"]?.stringValue)))
    case "item/started":
      events += item(params["item"], completed: false)
    case "item/completed":
      events += item(params["item"], completed: true)
    case "item/agentMessage/delta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { break }
      events.append(.itemDelta(id: id, .text(delta)))
    case "item/reasoning/summaryPartAdded":
      guard let id = params["itemId"]?.stringValue, let index = params["summaryIndex"]?.intValue,
        index > 0
      else { break }
      events.append(.itemDelta(id: id, .thinking("\n\n")))
    case "item/reasoning/summaryTextDelta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { break }
      if unplacedReasoning.remove(id) != nil {
        placedReasoning.insert(id)
        events.append(.itemStarted(AgentEvent.Item(id: id, parent: nil, kind: .thinking(""))))
      }
      events.append(.itemDelta(id: id, .thinking(delta)))
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      events += approval(method: method, id: message["id"], params: params)
    case "serverRequest/resolved":
      guard let id = CodexRPC.ID(params["requestId"]) else { break }
      events.append(.permissionWithdrawn(requestID: id.text))
    case "thread/tokenUsage/updated":
      guard let usage = params["tokenUsage"], let last = usage["last"],
        let input = last["inputTokens"]?.intValue, let output = last["outputTokens"]?.intValue
      else { break }
      let cached = last["cachedInputTokens"]?.intValue ?? 0
      events.append(
        .usage(
          .init(
            messageID: params["turnId"]?.stringValue ?? "",
            usage: TokenUsage(
              input: input - cached, cacheCreation: last["cacheWriteInputTokens"]?.intValue ?? 0,
              cacheRead: cached, output: output),
            model: nil, window: usage["modelContextWindow"]?.intValue, at: nil)))
    case "turn/completed":
      let turn = params["turn"] ?? .null
      let outcome: Transcript.TurnEnd =
        switch turn["status"]?.stringValue {
        case "interrupted": .interrupted
        case "failed": .failed
        default: .completed
        }
      events.append(
        .turnEnded(
          TurnSummary(
            outcome: outcome, failureText: turn["error"]?["message"]?.stringValue,
            durationMS: turn["durationMs"]?.intValue)))
    default:
      break
    }
    return events
  }

  /// A thread's stored items (`thread/items/list` entries, `{turnId, item, …}`), oldest
  /// first, as a finished conversation: each turn opened by its prompt and closed as
  /// completed. Codex keeps no declined command, which a notice says once.
  public static func history(_ entries: [JSONValue]) -> [AgentEvent] {
    guard !entries.isEmpty else { return [] }
    var translator = CodexTranslator()
    var events: [AgentEvent] = [
      .note(.init(text: String(localized: "Codex keeps no record of commands that were declined.")))
    ]
    var turn: String?
    for entry in entries {
      let id = entry["turnId"]?.stringValue
      if let turn, id != turn { events.append(.turnOutcome(.completed)) }
      turn = id
      guard let item = entry["item"] else { continue }
      if item["type"] == .string("userMessage") {
        events.append(.prompt(prompt(item["content"]?.arrayValue ?? []), running: false))
      } else {
        events += translator.item(item, completed: true)
      }
    }
    events.append(.turnOutcome(.completed))
    return events
  }

  /// A stored prompt's input read back: the editor's context as its label, `<attachment>`
  /// text and images as previews, the rest as the prompt.
  private static func prompt(_ content: [JSONValue]) -> AgentEvent.Prompt {
    var texts: [String] = []
    var labels: [String] = []
    var attachments: [AttachmentPreview] = []
    for input in content {
      switch input["type"]?.stringValue {
      case "text":
        let text = input["text"]?.stringValue ?? ""
        if let label = EditorSelection.label(context: text) {
          labels.append(label)
        } else if text.hasPrefix("<attachment name=\"") {
          let name = text.dropFirst("<attachment name=\"".count).prefix { $0 != "\"" }
          attachments.append(AttachmentPreview(kind: .text, name: String(name), thumbnail: nil))
        } else {
          texts.append(text)
        }
      case "image", "localImage":
        attachments.append(AttachmentPreview(kind: .image, name: nil, thumbnail: nil))
      default:
        break
      }
    }
    return AgentEvent.Prompt(
      text: texts.joined(separator: "\n\n"),
      context: labels.isEmpty ? nil : labels.joined(separator: ", "), attachments: attachments)
  }

  private mutating func item(_ item: JSONValue?, completed: Bool) -> [AgentEvent] {
    guard let item, let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else {
      return []
    }
    func placed(_ kind: AgentEvent.ItemKind) -> AgentEvent {
      let item = AgentEvent.Item(id: id, parent: nil, kind: kind)
      return completed ? .itemCompleted(item) : .itemStarted(item)
    }
    switch type {
    case "userMessage":
      // The session's own prompt is shown already; one it steered into a running turn
      // leaves the queue when Codex takes it, which the echoed id says.
      guard !completed, let client = item["clientId"]?.stringValue else { return [] }
      return [.queue(id: client, .started)]
    case "agentMessage":
      return [placed(.text(item["text"]?.stringValue ?? ""))]
    case "reasoning":
      let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue)
      let text = summary.joined(separator: "\n\n")
      if completed {
        unplacedReasoning.remove(id)
        // An empty completion still ends one that streamed: the transcript keeps its text.
        guard placedReasoning.remove(id) != nil || !text.isEmpty else { return [] }
      } else if text.isEmpty {
        unplacedReasoning.insert(id)
        return []
      } else {
        placedReasoning.insert(id)
      }
      return [placed(.thinking(text))]
    case "commandExecution":
      let command = item["command"]?.stringValue ?? ""
      let kind = Self.kind(command: command, actions: item["commandActions"]?.arrayValue ?? [])
      var events = [
        placed(
          .tool(
            .init(id: id, name: "Shell", input: .object(["command": .string(command)]), kind: kind))
        )
      ]
      if completed {
        let status = item["status"]?.stringValue
        events.append(
          .toolResult(
            callID: id,
            .init(
              content: item["aggregatedOutput"]?.stringValue
                ?? (status == "completed" ? "" : status ?? ""),
              isError: status != "completed" || (item["exitCode"]?.intValue ?? 0) != 0)))
      }
      return events
    case "fileChange":
      let changes = item["changes"]?.arrayValue ?? []
      let edits = changes.compactMap(Self.edit)
      let kind: ToolKind = edits.first.map { .fileChange(path: $0.path, edits: edits) } ?? .other
      fileChanges[id] = kind
      var events = [
        placed(.tool(.init(id: id, name: "Edit", input: .array(changes), kind: kind)))
      ]
      if completed {
        let status = item["status"]?.stringValue
        events.append(
          .toolResult(callID: id, .init(content: status ?? "", isError: status != "completed")))
      }
      return events
    case "contextCompaction":
      return [
        .compaction(
          completed
            ? .finished(note: String(localized: "Conversation compacted"), at: nil) : .started)
      ]
    default:
      // The rest is unverified.
      return []
    }
  }

  /// One file of a patch (verified 2026-10-07): an add's diff is the new content, an
  /// update's header-less hunks, a delete's the old content, a pure rename's the line
  /// "Moved to: <path>" and no hunks.
  static func edit(_ change: JSONValue) -> FileEdit? {
    guard let path = change["path"]?.stringValue, let diff = change["diff"]?.stringValue else {
      return nil
    }
    let kind = change["kind"]
    switch kind?["type"]?.stringValue {
    case "delete":
      return FileEdit(path: path, change: .delete(content: diff))
    case "update":
      if let target = kind?["move_path"]?.stringValue {
        let hunks =
          diff.range(of: "\n\nMoved to: ", options: .backwards).map {
            String(diff[..<$0.lowerBound])
          }
          ?? diff
        return FileEdit(path: path, change: .move(to: target, patch: hunks))
      }
      return FileEdit(path: path, change: .patch(diff))
    default:
      return FileEdit(path: path, change: .patch(diff))
    }
  }

  private func approval(method: String, id: JSONValue?, params: JSONValue) -> [AgentEvent] {
    guard let requestID = CodexRPC.ID(id)?.text else { return [] }
    let itemID = params["itemId"]?.stringValue
    var request: PermissionRequest
    if method == "item/fileChange/requestApproval" {
      request = PermissionRequest(
        toolName: "Edit", input: .object([:]), description: params["reason"]?.stringValue,
        toolUseID: itemID, kind: itemID.flatMap { fileChanges[$0] } ?? .other)
      // File changes take `acceptForSession` (types); requests list none (verified).
      request.suggestions = [CodexPolicy.acceptForSession]
    } else {
      let command = params["command"]?.stringValue ?? ""
      let kind = Self.kind(command: command, actions: params["commandActions"]?.arrayValue ?? [])
      request = PermissionRequest(
        toolName: "Shell", input: .object(["command": .string(command)]),
        description: params["reason"]?.stringValue, toolUseID: itemID, kind: kind)
      if params["availableDecisions"]?.arrayValue?.contains(.string("acceptForSession")) == true {
        request.suggestions = [CodexPolicy.acceptForSession]
      }
    }
    return [.permissionRequested(.init(requestID: requestID, request: request))]
  }

  /// A single parsed action says what the command is for; anything else is the command,
  /// as it was asked for rather than as the shell wraps it.
  static func kind(command: String, actions: [JSONValue]) -> ToolKind {
    if actions.count == 1, let action = actions.first {
      switch action["type"]?.stringValue {
      case "read":
        if let path = action["path"]?.stringValue { return .read(path: path) }
      case "search", "listFiles":
        if let query = action["query"]?.stringValue ?? action["path"]?.stringValue {
          return .search(pattern: query)
        }
      default: break
      }
      if let asked = action["command"]?.stringValue { return .shell(command: asked) }
    }
    return .shell(command: command)
  }
}
