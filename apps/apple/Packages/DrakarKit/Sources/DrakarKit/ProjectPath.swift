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
    var best: (folder: String, length: Int)?
    for folder in folders {
      let normalized = normalize(folder)
      for key in Set([normalized, resolved(normalized)]) where contains(key, cwd) {
        if let current = best, key.count <= current.length { continue }
        best = (normalized, key.count)
      }
    }
    return best?.folder
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
