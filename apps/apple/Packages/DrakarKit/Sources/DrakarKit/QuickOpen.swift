import Foundation

/// Finding a file by a few letters of its name, as ⌘P does in VS Code and Zed.
public enum QuickOpen {
  /// Folders never searched: version control, dependencies and build output, which would
  /// drown the project's own files and cost the most to walk.
  static let skippedFolders: Set<String> = [
    ".git", ".hg", ".svn", "node_modules", ".build", "DerivedData", "Pods", ".venv", "venv",
    "__pycache__", ".next", ".nuxt", ".turbo", ".cache", "target", ".gradle", ".idea",
  ]

  /// Past this many files the walk stops: a home folder opened by mistake must not stall.
  public static let maximumFiles = 50_000

  /// Every file under `root`, as paths relative to it, in walk order.
  public static func files(under root: URL, limit: Int = maximumFiles) -> [String] {
    // The walk reports paths with the root's links resolved (`/var` as `/private/var`), so
    // either spelling of the root is cut off.
    let given = root.standardized.path(percentEncoded: false)
    let prefixes = [given, FileTree.realPath(given)].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [], errorHandler: { _, _ in true })
    else { return [] }
    var files: [String] = []
    for case let url as URL in walker {
      let name = url.lastPathComponent
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if values?.isDirectory == true {
        if skippedFolders.contains(name) { walker.skipDescendants() }
        continue
      }
      guard values?.isRegularFile == true, name != ".DS_Store" else { continue }
      let path = url.standardized.path(percentEncoded: false)
      let prefix = prefixes.first { path.hasPrefix($0) }
      files.append(prefix.map { String(path.dropFirst($0.count)) } ?? path)
      if files.count >= limit { break }
    }
    return files
  }

  public struct Match: Sendable, Equatable {
    public var path: String
    public var score: Int
    /// The matched characters' offsets in `path`, for highlighting.
    public var positions: [Int]
  }

  /// The paths matching `query`, best first, at most `limit`. Every character of the query
  /// must appear in order (case-insensitive, spaces ignored).
  public static func search(_ query: String, in paths: [String], limit: Int = 50) -> [Match] {
    let needle = Array(query.lowercased().filter { !$0.isWhitespace })
    guard !needle.isEmpty else {
      return paths.prefix(limit).map { Match(path: $0, score: 0, positions: []) }
    }
    let matches = paths.compactMap { match(needle, $0) }
    return Array(
      matches.sorted { a, b in
        if a.score != b.score { return a.score > b.score }
        // A tie goes to the shorter name (`FileTree.swift` before `FileTreeTests.swift`),
        // then to the shallower path.
        let (nameA, nameB) = (
          (a.path as NSString).lastPathComponent, (b.path as NSString).lastPathComponent
        )
        if nameA.count != nameB.count { return nameA.count < nameB.count }
        return a.path.count != b.path.count ? a.path.count < b.path.count : a.path < b.path
      }
      .prefix(limit))
  }

  /// The best placement of the query's letters in the path: each letter scores, more in
  /// the file name, at the start of a word or right after the previous letter. Searched
  /// over every placement (query length × path length), so `ftt` finds
  /// `FileTreeTests.swift` by its initials rather than by the last t's it could reach.
  static func match(_ needle: [Character], _ path: String) -> Match? {
    let original = Array(path)
    let haystack = original.map { Character($0.lowercased()) }
    let n = needle.count
    let m = haystack.count
    guard n <= m else { return nil }
    let nameStart = (haystack.lastIndex(of: "/") ?? -1) + 1

    func bonus(_ position: Int) -> Int {
      var bonus = 1
      if position >= nameStart { bonus += 3 }
      if position == nameStart { bonus += 6 }
      let previous: Character? = position > 0 ? original[position - 1] : nil
      if let previous {
        if "/_-. ".contains(previous) || (original[position].isUppercase && previous.isLowercase) {
          bonus += 4
        }
      } else {
        bonus += 4
      }
      return bonus
    }

    let none = Int.min / 2
    // best[i][j]: the best score with letter i placed at position j; from[i][j]: where
    // letter i - 1 was then.
    var best = Array(repeating: Array(repeating: none, count: m), count: n)
    var from = Array(repeating: Array(repeating: -1, count: m), count: n)
    for j in 0..<m where haystack[j] == needle[0] { best[0][j] = bonus(j) }
    if n > 1 {
      for i in 1..<n {
        // The best of row i - 1 strictly before j - 1, carried along as j grows.
        var runningBest = none
        var runningAt = -1
        for j in 1..<m {
          if j >= 2, best[i - 1][j - 2] > runningBest {
            runningBest = best[i - 1][j - 2]
            runningAt = j - 2
          }
          guard haystack[j] == needle[i] else { continue }
          let adjacent = best[i - 1][j - 1] == none ? none : best[i - 1][j - 1] + 5
          let (previous, at) =
            adjacent >= runningBest ? (adjacent, j - 1) : (runningBest, runningAt)
          guard previous > none else { continue }
          best[i][j] = previous + bonus(j)
          from[i][j] = at
        }
      }
    }
    guard let end = best[n - 1].indices.max(by: { best[n - 1][$0] < best[n - 1][$1] }),
      best[n - 1][end] > none
    else { return nil }
    var positions = [end]
    var i = n - 1
    while i > 0 {
      positions.append(from[i][positions.last!])
      i -= 1
    }
    return Match(path: path, score: best[n - 1][end], positions: positions.reversed())
  }
}
