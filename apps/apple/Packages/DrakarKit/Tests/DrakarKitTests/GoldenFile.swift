import Foundation
import Testing

/// The record-or-compare step both golden suites end with.
enum GoldenFile {
  /// Compares `golden` with the one stored at `url`. With `DRAKAR_RECORD_GOLDENS=1` it writes
  /// it instead, and the run records an issue so that a recording run never passes.
  static func check(
    _ golden: TranscriptGoldenTests.Golden, at url: URL, named name: String
  ) throws {
    if ProcessInfo.processInfo.environment["DRAKAR_RECORD_GOLDENS"] == "1" {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(golden).write(to: url)
      Issue.record("recorded \(name), not compared")
      return
    }
    let recorded = try JSONDecoder().decode(
      TranscriptGoldenTests.Golden.self, from: Data(contentsOf: url))
    #expect(golden.running == recorded.running)
    #expect(golden.exited == recorded.exited)
  }
}
