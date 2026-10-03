import Foundation

/// Text searched across a folder's files, as ⇧⌘F does: plain text, not a pattern, case
/// ignored unless the query has a capital (smart case, as ripgrep and Zed do).
public enum ProjectSearch {
  public struct Hit: Sendable, Equatable, Identifiable {
    /// Relative to the searched folder.
    public var path: String
    /// From 1, as shown.
    public var line: Int
    /// The match within the whole file, in UTF-16 offsets, to select it when opened.
    public var range: Range<Int>
    /// The line, trimmed, and where the match sits in it.
    public var preview: String
    public var previewRange: Range<Int>

    public var id: String { "\(path):\(range.lowerBound)" }
  }

  /// Past this many hits the search stops: the list is for reading, not for counting.
  public static let maximumHits = 2_000
  /// Files larger than this are skipped, as the editor would refuse them.
  static let maximumFileSize = 2_000_000

  /// Searches `files` (relative to `root`) in order. `isCancelled` is asked between files,
  /// so typing on can abandon a search of a large folder.
  public static func search(
    _ query: String, in files: [String], under root: URL, limit: Int = maximumHits,
    isCancelled: () -> Bool = { false }
  ) -> [Hit] {
    guard !query.isEmpty else { return [] }
    let options: NSString.CompareOptions =
      query.contains(where: \.isUppercase) ? [.literal] : [.literal, .caseInsensitive]
    var hits: [Hit] = []
    for path in files {
      if isCancelled() || hits.count >= limit { break }
      let url = root.appending(path: path)
      guard
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= maximumFileSize, let data = try? Data(contentsOf: url),
        case .success(let text) = TextFile.decode(data)
      else { continue }
      hits += search(query, options: options, in: text, path: path, limit: limit - hits.count)
    }
    return hits
  }

  static func search(
    _ query: String, options: NSString.CompareOptions, in text: String, path: String, limit: Int
  ) -> [Hit] {
    let contents = text as NSString
    var hits: [Hit] = []
    var searchRange = NSRange(location: 0, length: contents.length)
    var lines: LineIndex?
    while hits.count < limit {
      let found = contents.range(of: query, options: options, range: searchRange)
      guard found.location != NSNotFound else { break }
      let index = lines ?? LineIndex(text)
      lines = index
      let line = index.line(containing: found.location)
      let lineRange = contents.lineRange(for: NSRange(location: found.location, length: 0))
      let raw = contents.substring(with: lineRange) as NSString
      // Leading whitespace dropped, and long lines cut around the match.
      let leading = raw.rangeOfCharacter(from: CharacterSet.whitespaces.inverted).location
      let start = leading == NSNotFound ? 0 : min(leading, found.location - lineRange.location)
      var preview = raw.substring(from: start).trimmingCharacters(in: .newlines)
      var matchStart = found.location - lineRange.location - start
      if matchStart > 60 {
        let cut = matchStart - 40
        preview = "…" + (preview as NSString).substring(from: cut)
        matchStart = matchStart - cut + 1
      }
      if (preview as NSString).length > 200 {
        preview = (preview as NSString).substring(to: 200) + "…"
      }
      hits.append(
        Hit(
          path: path, line: line + 1, range: found.location..<NSMaxRange(found),
          preview: preview, previewRange: matchStart..<(matchStart + found.length)))
      let next = NSMaxRange(found)
      searchRange = NSRange(location: next, length: contents.length - next)
    }
    return hits
  }
}
