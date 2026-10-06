import Foundation

/// The one place that knows Claude Code's tool names and the arguments each is known by
/// (docs/claude-stream-json.md).
public enum ClaudeTools {
  public static func kind(name: String, input: JSONValue) -> ToolKind {
    func string(_ key: String) -> String? { input[key]?.stringValue }
    switch name {
    case "Bash": return string("command").map { .shell(command: $0) } ?? .other
    case "Read": return string("file_path").map { .read(path: $0) } ?? .other
    case "Grep", "Glob": return string("pattern").map { .search(pattern: $0) } ?? .other
    case "WebFetch": return string("url").map(ToolKind.web) ?? .other
    case "WebSearch": return string("query").map(ToolKind.web) ?? .other
    case "Task", "Agent": return .subagent(description: string("description"))
    case UserQuestion.toolName: return .question
    case PlanApproval.toolName: return .planApproval
    case TodoList.toolName: return .todos
    case "Edit", "MultiEdit", "Write":
      guard let path = string("file_path") else { return .other }
      return .fileChange(path: path, edits: edits(name: name, input: input, path: path))
    default:
      let parts = name.components(separatedBy: "__")
      if parts.count >= 3, parts[0] == "mcp" {
        return .mcp(server: parts[1], tool: parts[2...].joined(separator: "__"))
      }
      return .other
    }
  }

  private static func edits(name: String, input: JSONValue, path: String) -> [FileEdit] {
    func replace(_ edit: JSONValue) -> FileEdit? {
      guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue
      else { return nil }
      return FileEdit(path: path, change: .replace(old: old, new: new))
    }
    switch name {
    case "Edit": return replace(input).map { [$0] } ?? []
    case "MultiEdit": return (input["edits"]?.arrayValue ?? []).compactMap(replace)
    default:
      return input["content"]?.stringValue.map {
        [FileEdit(path: path, change: .write(content: $0))]
      } ?? []
    }
  }
}

extension FileChange {
  /// What a Claude Edit, MultiEdit or Write call does; nil for any other tool.
  public init?(toolName: String, input: JSONValue, existing: String? = nil) {
    guard case .fileChange(let path, let edits) = ClaudeTools.kind(name: toolName, input: input)
    else { return nil }
    self.init(path: path, edits: edits, existing: existing)
  }
}
