import Foundation

/// A subagent's life as the CLI reports it (2.1.288): `task_started`, `task_progress` while it
/// works, `task_updated` with a new status, `task_notification` once it ends, each naming the
/// `Agent` call that started it, except `task_updated`, which names only the task.
public struct TaskEvent: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case started = "task_started"
    case progress = "task_progress"
    case updated = "task_updated"
    case notification = "task_notification"
  }

  public var kind: Kind
  public var taskID: String
  public var toolUseID: String?
  public var description: String?
  public var isBackgrounded: Bool?
  /// `completed`, `failed`, `stopped`…; from `patch.status` on `task_updated`.
  public var status: String?
  public var summary: String?
  public var lastToolName: String?
  public var toolUses: Int?
  public var totalTokens: Int?
  public var durationMS: Int?

  init?(_ json: JSONValue, subtype: String) {
    guard let kind = Kind(rawValue: subtype), let taskID = json["task_id"]?.stringValue else {
      return nil
    }
    self.kind = kind
    self.taskID = taskID
    toolUseID = json["tool_use_id"]?.stringValue
    description = json["description"]?.stringValue
    isBackgrounded = json["is_backgrounded"]?.boolValue
    status = (json["status"] ?? json["patch"]?["status"])?.stringValue
    summary = json["summary"]?.stringValue
    lastToolName = json["last_tool_name"]?.stringValue
    toolUses = json["usage"]?["tool_uses"]?.intValue
    totalTokens = json["usage"]?["total_tokens"]?.intValue
    durationMS = json["usage"]?["duration_ms"]?.intValue
  }
}

extension Transcript {
  /// The entries the view lists, and those it draws inside the card of the call they ran
  /// under, by its id. Only a listed call's card holds lines: a line whose call is not in the
  /// transcript, or is itself inside a card (a subagent's subagent), is listed.
  public func grouped() -> (top: [Entry], children: [String: [Entry]]) {
    var top: [Entry] = []
    var children: [String: [Entry]] = [:]
    let calls = Set(
      entries.compactMap { entry -> String? in
        if case .tool(let call) = entry.kind, entry.parentToolUseID == nil { return call.id }
        return nil
      })
    for entry in entries {
      if let parent = entry.parentToolUseID, calls.contains(parent) {
        children[parent, default: []].append(entry)
      } else {
        top.append(entry)
      }
    }
    return (top, children)
  }
}

/// A subagent, by the `Agent` call that started it.
public struct AgentTask: Sendable, Equatable {
  public enum Status: Sendable, Equatable {
    case running, completed, failed
    /// Stopped, killed, or a status this build does not know.
    case ended(String)

    init(_ status: String) {
      switch status {
      case "running", "pending": self = .running
      case "completed": self = .completed
      case "failed": self = .failed
      default: self = .ended(status)
      }
    }
  }

  public var status: Status = .running
  public var description: String?
  /// What it was asked, forwarded from inside it while it runs in the foreground.
  public var prompt: String?
  public var isBackgrounded = false
  public var lastToolName: String?
  public var toolUses: Int?
  public var totalTokens: Int?
  public var durationMS: Int?
  /// Its report, from the notification that it ended.
  public var summary: String?

  public init() {}

  /// "Bash · 3 tools · 34K tokens · 6s": what it has done so far, as far as it is known.
  public var progressLine: String? {
    var parts: [String] = []
    if let lastToolName { parts.append(lastToolName) }
    if let toolUses {
      parts.append(
        toolUses == 1 ? String(localized: "1 tool") : String(localized: "\(toolUses) tools"))
    }
    if let totalTokens {
      parts.append(
        String(localized: "\(totalTokens.formatted(.number.notation(.compactName))) tokens"))
    }
    if let durationMS { parts.append("\(Int((Double(durationMS) / 1000).rounded()))s") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  mutating func apply(_ event: TaskEvent) {
    if let description = event.description, event.kind == .started || self.description == nil {
      self.description = description
    }
    if let isBackgrounded = event.isBackgrounded { self.isBackgrounded = isBackgrounded }
    if let status = event.status { self.status = Status(status) }
    if let summary = event.summary { self.summary = summary }
    lastToolName = event.lastToolName ?? lastToolName
    toolUses = event.toolUses ?? toolUses
    totalTokens = event.totalTokens ?? totalTokens
    durationMS = event.durationMS ?? durationMS
  }
}

/// The structured result beside an `Agent` call's: its report without the frame the model
/// reads around it, or the note that it went to the background.
public struct AgentReport: Sendable, Equatable {
  /// `completed`, or `async_launched` for one sent to the background.
  public var status: String
  public var text: String?
  public var totalTokens: Int?
  public var toolUses: Int?
  public var durationMS: Int?

  public var isBackgrounded: Bool { status == "async_launched" }

  init?(_ json: JSONValue?) {
    guard let json, json["agentId"] != nil, let status = json["status"]?.stringValue else {
      return nil
    }
    self.status = status
    let texts = (json["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
    text = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    totalTokens = json["totalTokens"]?.intValue
    toolUses = json["totalToolUseCount"]?.intValue
    durationMS = json["totalDurationMs"]?.intValue
  }
}
