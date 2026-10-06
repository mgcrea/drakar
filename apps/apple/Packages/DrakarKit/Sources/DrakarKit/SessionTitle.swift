import Foundation

/// A session's own name, as `/rename` and `--name` give it: a `custom-title` line in the
/// transcript, which the CLI, the extension and Drakar all read ahead of any `ai-title`
/// (`docs/claude-stream-json.md`, "Session titles").
public enum SessionTitle {
  /// The CLI's own limit; it drops control characters too.
  static let maximumLength = 200

  /// `title` as the CLI would keep it, or nil when nothing is left.
  public static func clean(_ title: String) -> String? {
    let printable = title.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
    }
    let cleaned = String(String.UnicodeScalarView(printable))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(maximumLength))
  }

  /// "Pineapple (fork)", then "Pineapple (fork #2)": the original's title without any fork
  /// suffix, numbered after the highest fork of it among `titles`. A fork of a fork is the
  /// next sibling, so the numbers stay flat in a flat list. The first fork is #1 unwritten.
  public static func forkName(of title: String, among titles: [String]) -> String {
    let base = base(of: title)
    let highest = titles.compactMap { forkNumber(of: $0, base: base) }.max() ?? 0
    let next = highest + 1
    return next == 1 ? "\(base) (fork)" : "\(base) (fork #\(next))"
  }

  /// `title` without a trailing "(fork)" or "(fork #N)".
  static func base(of title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard let suffix = forkSuffix(in: trimmed) else { return trimmed }
    return String(trimmed[..<suffix.range.lowerBound]).trimmingCharacters(in: .whitespaces)
  }

  /// Which fork of `base` `title` is: 1 for "(fork)", N for "(fork #N)", nil for any other.
  static func forkNumber(of title: String, base: String) -> Int? {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard let suffix = forkSuffix(in: trimmed),
      trimmed[..<suffix.range.lowerBound].trimmingCharacters(in: .whitespaces) == base
    else { return nil }
    return suffix.number
  }

  private static func forkSuffix(in title: String) -> (range: Range<String.Index>, number: Int)? {
    guard let match = title.firstMatch(of: /\s\(fork(?: #(\d+))?\)$/) else { return nil }
    let number = match.output.1.flatMap { Int($0) } ?? 1
    return (match.range, number)
  }

  /// Renames a session no process has open, as the CLI's `rename_session` does: a
  /// `custom-title` line appended to `transcript`, and the `<id>/custom-title.json` beside
  /// it. The CLI's resume list reads that file once the line is no longer near the end, so
  /// leaving it stale would bring the old name back.
  public static func write(_ title: String, sessionID: String, transcript: URL) throws {
    let line = JSONValue.object([
      "type": .string("custom-title"),
      "customTitle": .string(title),
      "sessionId": .string(sessionID),
    ])
    let handle = try FileHandle(forWritingTo: transcript)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: try line.line())

    let folder = transcript.deletingLastPathComponent().appending(
      path: sessionID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let sidecar = folder.appending(path: "custom-title.json")
    try JSONValue.object(["customTitle": .string(title)]).line().write(
      to: sidecar, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
  }
}
