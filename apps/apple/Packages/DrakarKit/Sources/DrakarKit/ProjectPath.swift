import Foundation

/// Folders as projects compare them: normalised, matched on whole path components, the
/// deepest open project owning a session. Ported from Armada's `ProjectPath`, where a raw
/// prefix once counted `armada-old`'s sessions as `armada`'s.
public enum ProjectPath {
  /// `url`'s path as written, not percent-encoded, normalized.
  public static func normalize(_ url: URL) -> String {
    normalize(url.path(percentEncoded: false))
  }

  /// No trailing slash (except the root's), `.` and `..` resolved on the string.
  public static func normalize(_ raw: String) -> String {
    var path = raw
    if path.contains("/.") || path.contains("//") {
      path = URL(filePath: path, directoryHint: .inferFromPath).standardized
        .path(percentEncoded: false)
    }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// Whether `path` is `root` or below it.
  public static func contains(_ root: String, _ path: String) -> Bool {
    let root = normalize(root)
    let path = normalize(path)
    guard !root.isEmpty, !path.isEmpty else { return false }
    if root == "/" { return path.hasPrefix("/") }
    return path == root || path.hasPrefix(root + "/")
  }

  /// The first component of `path` below `root`: the subfolder a session runs in. Nil for
  /// `root` itself, a path outside it, or one below a hidden folder (a worktree in
  /// `.claude/worktrees` is labelled by its own name).
  public static func child(of path: String, below root: String) -> String? {
    let (path, root) = (normalize(path), normalize(root))
    guard path != root, contains(root, path) else { return nil }
    let rest = path.dropFirst(root.count).drop { $0 == "/" }
    guard let first = rest.split(separator: "/").first, !first.hasPrefix(".") else {
      return nil
    }
    return String(first)
  }

  /// How the toolbar names the folder a session runs in, for a window on `root`: nil for
  /// `root` itself, a worktree's own name, the path down from `root`, or the folder's name
  /// when it is outside `root`. A worktree `root` is in is the window's own, not named. Two
  /// paths that only meet once resolved (a link, `/tmp`) are compared that way, as `owner`
  /// compares them.
  public static func label(of path: String, in root: String) -> String? {
    let (path, root) = (normalize(path), normalize(root))
    guard path != root else { return nil }
    let inside = contains(root, path)
    if !inside {
      let (real, realRoot) = (resolved(path), resolved(root))
      if contains(realRoot, real) { return label(of: real, in: realRoot) }
    }
    let below = inside ? "/" + path.dropFirst(root == "/" ? 1 : root.count + 1) : path
    if let range = below.range(of: "/.claude/worktrees/") {
      return String(below[range.upperBound...].prefix { $0 != "/" })
    }
    if inside { return String(below.dropFirst()) }
    return URL(filePath: path).lastPathComponent
  }

  /// The path with its symbolic links resolved, as Claude Code records a `cwd`: a folder
  /// under `/tmp` is `/private/tmp/…` there. `realpath`, because `URL` leaves `/var` alone.
  public static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return normalize(path) }
    defer { free(real) }
    return normalize(String(cString: real))
  }

  /// The folder among `folders` that owns `cwd`: the deepest containing it, by its own
  /// spelling or its resolved one. Returned as `normalize` writes it.
  public static func owner(of cwd: String, among folders: [String]) -> String? {
    Owners(folders).owner(of: cwd)
  }

  /// `owner(of:among:)` with the folders resolved once, for a loop over many sessions:
  /// `realpath` per session per folder is file-system work on every redraw.
  public struct Owners: Sendable {
    private let keys: [(folder: String, key: String)]

    public init(_ folders: [String]) {
      keys = folders.flatMap { folder in
        let normalized = normalize(folder)
        return Set([normalized, resolved(normalized)]).map { (normalized, $0) }
      }
    }

    public func owner(of cwd: String) -> String? {
      var best: (folder: String, length: Int)?
      for (folder, key) in keys where contains(key, cwd) {
        if let current = best, key.count <= current.length { continue }
        best = (folder, key.count)
      }
      return best?.folder
    }
  }

  /// How Claude Code names the transcript folder of `folder`, in the two encodings seen:
  /// every `/` a `-`, or every character but ASCII letters and digits a `-` (Claude Code
  /// 2.1.308: `replace(/[^a-zA-Z0-9]/g,"-")`). A subfolder's name
  /// starts with its parent's, so these are prefixes to list, then confirm by `cwd`. A name
  /// over 200 characters is cut there and given a hash of the whole path, so the prefix is
  /// its first 200.
  public static func encodedPrefixes(for folder: String) -> [String] {
    let path = normalize(folder)
    let slashes = String(path.replacingOccurrences(of: "/", with: "-").prefix(nameLimit))
    let alphanumeric = String(
      path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(nameLimit))
    return slashes == alphanumeric ? [slashes] : [slashes, alphanumeric]
  }

  /// Where Claude Code cuts a transcript folder's name (`K_e`, in 2.1.308).
  private static let nameLimit = 200
}
