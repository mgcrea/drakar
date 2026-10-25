import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Watching a folder")
struct FolderWatcherTests {
  /// A file written in the folder is reported, whether the folder's URL ends in a slash
  /// (`directoryHint: .isDirectory`, as `SkillPlaces` builds its roots) or not.
  @Test(arguments: [true, false])
  func aFileWrittenIsReported(asDirectory: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-watch-\(UUID().uuidString)",
      directoryHint: asDirectory ? .isDirectory : .notDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var changed: [String] = []
    let watcher = try #require(FolderWatcher(folder: folder) { changed += $0 })
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))
    try Data("skill".utf8).write(to: folder.appending(path: "SKILL.md"))
    for _ in 0..<100 where !changed.contains(where: { $0.hasSuffix("/SKILL.md") }) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(changed.contains { $0.hasSuffix("/SKILL.md") })
  }
}
