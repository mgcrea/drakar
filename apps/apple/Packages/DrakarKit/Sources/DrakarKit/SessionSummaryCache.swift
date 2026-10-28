import Foundation

/// The summaries one launch read, kept for the next: a transcript whose size and date have
/// not moved since says the same thing, so `SessionIndex.list` takes its summary from here
/// instead of opening it. Without it, every launch reads the newest 500 transcripts again,
/// most of them end to end since a session nobody named has no title to stop the search.
public struct SessionSummaryCache: Sendable {
  /// Bumped whenever `SessionIndex.summarize` reads something new or reads it differently:
  /// a file saved under another version is dropped whole.
  public static let version = 1

  private var byFile: [String: SessionSummary] = [:]

  public init(_ summaries: [SessionSummary] = []) {
    for summary in summaries { byFile[summary.id] = summary }
  }

  /// The saved summary of `file`, while it still has the size and date it was read at.
  public func summary(of file: URL, modified: Date, size: Int) -> SessionSummary? {
    guard let summary = byFile[file.path(percentEncoded: false)],
      summary.size == size, summary.modified == modified
    else { return nil }
    return summary
  }

  /// `<home>/Library/Application Support/<id>/session-summaries.plist`.
  public static func file(bundleID: String, home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support", isDirectory: true)
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("session-summaries.plist")
  }

  private struct Saved: Codable {
    var version: Int
    var summaries: [SessionSummary]
  }

  /// Empty when the file is missing, unreadable, or of another version: the listing then
  /// reads every transcript, as it would with no cache.
  public static func load(from url: URL) -> SessionSummaryCache {
    guard let data = try? Data(contentsOf: url),
      let saved = try? PropertyListDecoder().decode(Saved.self, from: data),
      saved.version == version
    else { return SessionSummaryCache() }
    return SessionSummaryCache(saved.summaries)
  }

  /// `version` for tests, which write a file another version left.
  public func save(to url: URL, version: Int = version) throws {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(Saved(version: version, summaries: Array(byFile.values)))
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}
