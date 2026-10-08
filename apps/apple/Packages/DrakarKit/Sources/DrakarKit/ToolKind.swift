import Foundation

/// What a tool call does, whatever its agent calls it: read once, where the call is made
/// (`ClaudeTools.kind`, and Codex's item types), so nothing downstream compares tool names.
public enum ToolKind: Sendable, Equatable {
  case shell(command: String)
  case read(path: String)
  case search(pattern: String)
  /// `path` is the call's own; `edits` the changes that could be read from it, maybe none.
  case fileChange(path: String, edits: [FileEdit])
  /// A URL fetched or a query searched.
  case web(String)
  case subagent(description: String?)
  case question
  case planApproval
  case todos
  case mcp(server: String, tool: String)
  case other

  public var isSubagent: Bool { if case .subagent = self { true } else { false } }

  /// One line saying what the call does: the command, the file, the pattern. A kind that
  /// names nothing falls back to the call's first string argument, by key order, so the same
  /// call always summarises the same way.
  public func summary(input: JSONValue) -> String {
    switch self {
    case .shell(let command): return command
    case .read(let path): return path
    case .search(let pattern): return pattern
    case .fileChange(let path, _): return path
    case .web(let target): return target
    case .subagent(let description?): return description
    case .subagent(nil), .question, .planApproval, .todos, .mcp, .other: break
    }
    if case .object(let object) = input {
      for key in object.keys.sorted() {
        if let value = object[key]?.stringValue { return value }
      }
    }
    return ""
  }
}

/// One change to one file, as its agent described it.
public struct FileEdit: Sendable, Equatable {
  public enum Change: Sendable, Equatable {
    /// Claude's Edit, and each of MultiEdit's edits.
    case replace(old: String, new: String)
    /// Claude's Write: diffed against the file on disk when drawn.
    case write(content: String)
    /// Codex's `fileChange` diff: a new file's content, or header-less hunks.
    case patch(String)
    /// Codex's delete: the content the file had.
    case delete(content: String)
    /// Codex's rename: where the file went, and its hunks when it changed too (a pure
    /// rename has none).
    case move(to: String, patch: String)
  }

  public var path: String
  public var change: Change

  public init(path: String, change: Change) {
    self.path = path
    self.change = change
  }
}

/// Codex's diff text (docs/codex-app-server.md, "Items"): a new file's diff is its content,
/// an update's is `@@` hunks with no file headers.
public enum PatchText {
  public static func lines(_ text: String) -> (lines: [DiffLine], isNewFile: Bool) {
    var raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if raw.last == "" { raw.removeLast() }
    guard raw.contains(where: { $0.hasPrefix("@@") }) else {
      return (raw.map { DiffLine(.added, $0) }, true)
    }
    var lines: [DiffLine] = []
    /// The first old line after the previous hunk.
    var previousEnd: Int?
    for line in raw where !line.hasPrefix("\\") {
      if line.hasPrefix("@@") {
        guard let (start, count) = oldRange(line) else { continue }
        if let previousEnd, start > previousEnd {
          lines.append(DiffLine(.gap(start - previousEnd), ""))
        }
        previousEnd = start + count
        continue
      }
      switch line.first {
      case "+": lines.append(DiffLine(.added, String(line.dropFirst())))
      case "-": lines.append(DiffLine(.removed, String(line.dropFirst())))
      default: lines.append(DiffLine(.context, String(line.dropFirst())))
      }
    }
    return (lines, false)
  }

  /// The old side of a `@@ -a,b +c,d @@` header: its first line and how many it spans. A
  /// hunk spanning none names the line before it, so it starts one after.
  private static func oldRange(_ header: String) -> (start: Int, count: Int)? {
    guard let minus = header.split(separator: " ").first(where: { $0.hasPrefix("-") }) else {
      return nil
    }
    let parts = minus.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
    guard let start = Int(parts[0]) else { return nil }
    let count = parts.count > 1 ? Int(parts[1]) : 1
    guard let count else { return nil }
    return (count == 0 ? start + 1 : start, count)
  }
}
