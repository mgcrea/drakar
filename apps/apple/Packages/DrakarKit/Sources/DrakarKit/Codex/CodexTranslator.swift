import Foundation

/// Codex's app-server (docs/codex-app-server.md) as agent events: only what was verified
/// against codex-cli 0.160.1 on 2026-10-06. The fit check of slice 1: nothing in the app
/// uses it yet; slice 2 starts from it.
///
/// Codex is item-based: `item/started`, deltas by item id, `item/completed`. A tool's result
/// is its own item's completion. Approvals are JSON-RPC requests whose id answers them.
public struct CodexTranslator: Sendable {
  /// File changes by item id, which an approval request names without describing.
  private var fileChanges: [String: ToolKind] = [:]

  public init() {}

  public mutating func translate(_ message: JSONValue, at time: Date?) -> [AgentEvent] {
    guard let method = message["method"]?.stringValue else { return [] }
    let params = message["params"] ?? .null
    switch method {
    case "thread/started":
      guard let thread = params["thread"], let id = thread["id"]?.stringValue else { return [] }
      return [
        .sessionStarted(
          SessionInfo(
            sessionID: id, cwd: thread["cwd"]?.stringValue, model: thread["model"]?.stringValue,
            agentVersion: thread["cliVersion"]?.stringValue))
      ]
    case "item/started":
      return item(params["item"], completed: false)
    case "item/completed":
      return item(params["item"], completed: true)
    case "item/agentMessage/delta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { return [] }
      return [.itemDelta(id: id, .text(delta))]
    case "item/reasoning/summaryPartAdded":
      guard let id = params["itemId"]?.stringValue, let index = params["summaryIndex"]?.intValue,
        index > 0
      else { return [] }
      return [.itemDelta(id: id, .thinking("\n\n"))]
    case "item/reasoning/summaryTextDelta":
      guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue
      else { return [] }
      return [.itemDelta(id: id, .thinking(delta))]
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      return approval(method: method, id: message["id"], params: params)
    case "serverRequest/resolved":
      guard let id = params["requestId"].flatMap(Self.requestID) else { return [] }
      return [.permissionWithdrawn(requestID: id)]
    case "thread/tokenUsage/updated":
      guard let usage = params["tokenUsage"], let last = usage["last"],
        let input = last["inputTokens"]?.intValue, let output = last["outputTokens"]?.intValue
      else { return [] }
      let cached = last["cachedInputTokens"]?.intValue ?? 0
      return [
        .usage(
          .init(
            messageID: params["turnId"]?.stringValue ?? "",
            usage: TokenUsage(
              input: input - cached, cacheCreation: last["cacheWriteInputTokens"]?.intValue ?? 0,
              cacheRead: cached, output: output),
            model: nil, window: usage["modelContextWindow"]?.intValue, at: nil))
      ]
    case "turn/completed":
      let turn = params["turn"] ?? .null
      let outcome: Transcript.TurnEnd =
        switch turn["status"]?.stringValue {
        case "interrupted": .interrupted
        case "failed": .failed
        default: .completed
        }
      return [
        .turnEnded(
          TurnSummary(
            outcome: outcome, failureText: turn["error"]?["message"]?.stringValue,
            durationMS: turn["durationMs"]?.intValue))
      ]
    default:
      return []
    }
  }

  private mutating func item(_ item: JSONValue?, completed: Bool) -> [AgentEvent] {
    guard let item, let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else {
      return []
    }
    func placed(_ kind: Transcript.Kind) -> AgentEvent {
      let item = AgentEvent.Item(id: id, parent: nil, kind: kind)
      return completed ? .itemCompleted(item) : .itemStarted(item)
    }
    switch type {
    case "agentMessage":
      return [placed(.text(item["text"]?.stringValue ?? ""))]
    case "reasoning":
      let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue)
      return [placed(.thinking(summary.joined(separator: "\n\n")))]
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
              content: item["aggregatedOutput"]?.stringValue ?? status ?? "",
              isError: status != "completed" || (item["exitCode"]?.intValue ?? 0) != 0)))
      }
      return events
    case "fileChange":
      let changes = item["changes"]?.arrayValue ?? []
      let edits = changes.compactMap { change -> FileEdit? in
        guard let path = change["path"]?.stringValue, let diff = change["diff"]?.stringValue
        else { return nil }
        return FileEdit(path: path, change: .patch(diff))
      }
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
      // `userMessage` is the session's own prompt, already shown; the rest is unverified.
      return []
    }
  }

  private func approval(method: String, id: JSONValue?, params: JSONValue) -> [AgentEvent] {
    guard let requestID = id.flatMap(Self.requestID) else { return [] }
    let itemID = params["itemId"]?.stringValue
    let request: PermissionRequest
    if method == "item/fileChange/requestApproval" {
      request = PermissionRequest(
        toolName: "Edit", input: .object([:]), description: params["reason"]?.stringValue,
        toolUseID: itemID, kind: itemID.flatMap { fileChanges[$0] } ?? .other)
    } else {
      let command = params["command"]?.stringValue ?? ""
      let kind = Self.kind(command: command, actions: params["commandActions"]?.arrayValue ?? [])
      request = PermissionRequest(
        toolName: "Shell", input: .object(["command": .string(command)]),
        description: params["reason"]?.stringValue, toolUseID: itemID, kind: kind)
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
        if let query = (action["query"] ?? action["path"])?.stringValue {
          return .search(pattern: query)
        }
      default: break
      }
      if let asked = action["command"]?.stringValue { return .shell(command: asked) }
    }
    return .shell(command: command)
  }

  /// A JSON-RPC id, which may be a number or a string.
  static func requestID(_ id: JSONValue) -> String? {
    id.intValue.map(String.init) ?? id.stringValue
  }
}
