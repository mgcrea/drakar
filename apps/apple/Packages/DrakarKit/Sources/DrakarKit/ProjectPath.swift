import Foundation

/// Folders as projects compare them: normalised, matched on whole path components, the
/// deepest open project owning a session. Ported from Armada's `ProjectPath`, where a raw
/// prefix once counted `armada-old`'s sessions as `armada`'s.
public enum ProjectPath {
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
  /// every `/` a `-`, or every character but letters and digits a `-`. A subfolder's name
  /// starts with its parent's, so these are prefixes to list, then confirm by `cwd`.
  public static func encodedPrefixes(for folder: String) -> [String] {
    let path = normalize(folder)
    let slashes = path.replacingOccurrences(of: "/", with: "-")
    let alphanumeric = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    return slashes == alphanumeric ? [slashes] : [slashes, alphanumeric]
  }
}
