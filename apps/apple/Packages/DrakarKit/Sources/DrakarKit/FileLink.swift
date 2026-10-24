import Foundation

/// A link in an agent's message that names a file, as Claude writes them for the extension
/// (`src/a.ts#L42`, `#L42-L51`) and Codex does (`/abs/a.swift:42`, `a.swift:42:7`): a path,
/// absolute or from the session's folder, and the line to show. Handed to the system as is,
/// a link with no scheme fails with -50.
public struct FileLink: Sendable, Equatable {
  public var path: String
  /// 1-based, as both agents count.
  public var line: Int?
  public var column: Int?

  public init(path: String, line: Int? = nil, column: Int? = nil) {
    self.path = path
    self.line = line
    self.column = column
  }

  /// nil for a link that names no file: a web page, a mail address, another app's scheme.
  /// A relative path is taken from `folder`.
  public init?(_ url: URL, relativeTo folder: URL?) {
    var raw = url.absoluteString
    if let scheme = url.scheme?.lowercased() {
      if scheme == "file" {
        raw = String(raw.dropFirst("file://".count))
      } else if raw.wholeMatch(of: /[^\/:]+:\d+(:\d+)?(#.*)?/) == nil {
        // `a.swift:42` reads as the scheme `a.swift`; anything else is a scheme.
        return nil
      }
    }
    var fragment: Substring?
    if let hash = raw.firstIndex(of: "#") {
      fragment = raw[raw.index(after: hash)...]
      raw = String(raw[..<hash])
    }
    guard var path = raw.removingPercentEncoding, !path.isEmpty else { return nil }
    if let match = fragment?.wholeMatch(of: /L?(\d+)(?:C(\d+))?(?:-.*)?/) {
      line = Int(match.1)
      column = match.2.flatMap { Int($0) }
    } else if let match = path.firstMatch(of: /:(\d+):(\d+)$/) {
      line = Int(match.1)
      column = Int(match.2)
      path = String(path[..<match.range.lowerBound])
    } else if let match = path.firstMatch(of: /:(\d+)(?:-\d+)?$/) {
      line = Int(match.1)
      path = String(path[..<match.range.lowerBound])
    }
    if path.hasPrefix("~/") {
      path = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: String(path.dropFirst(2))).path(percentEncoded: false)
    } else if !path.hasPrefix("/") {
      guard let folder else { return nil }
      path = folder.appending(path: path).path(percentEncoded: false)
    }
    self.path = ProjectPath.normalize(path)
  }

  /// Where `line` and `column` fall in `text`, in UTF-16 offsets as a text view counts;
  /// past the end, the end. nil when the link names no line.
  public func offset(in text: String) -> Int? {
    guard let line else { return nil }
    let units = text.utf16
    var index = units.startIndex
    var remaining = line - 1
    while remaining > 0, let newline = units[index...].firstIndex(of: 0x0A) {
      index = units.index(after: newline)
      remaining -= 1
    }
    if remaining > 0 { return units.count }
    let start = units.distance(from: units.startIndex, to: index)
    let lineEnd =
      units[index...].firstIndex(of: 0x0A).map {
        units.distance(from: units.startIndex, to: $0)
      } ?? units.count
    return min(start + max((column ?? 1) - 1, 0), lineEnd)
  }
}
