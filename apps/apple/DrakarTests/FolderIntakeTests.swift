import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Folders handed to Drakar from outside")
struct FolderIntakeTests {

  private let list: ProjectList
  private let root: URL

  init() throws {
    let suite = "drakar-folder-intake-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    list = ProjectList(defaults: defaults)
    root = FileManager.default.temporaryDirectory.appending(path: "intake-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func folder(_ name: String) throws -> URL {
    let url = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// `drakar ~/Projects/app` with Drakar running: on home, and open.
  @Test func aFolderIsTrackedAndOpened() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try folder("app")
    let intake = FolderIntake(list: list)
    var opened: [URL] = []
    intake.receive([app]) { opened.append($0) }
    #expect(opened.map(\.lastPathComponent) == ["app"])
    #expect(list.tracked.paths.map { URL(filePath: $0).lastPathComponent } == ["app"])
  }

  @Test func aFileOrAMissingPathIsLeftOut() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "notes.txt")
    try Data("x".utf8).write(to: file)
    let intake = FolderIntake(list: list)
    var opened: [URL] = []
    intake.receive([file, root.appending(path: "gone", directoryHint: .isDirectory)]) {
      opened.append($0)
    }
    #expect(opened.isEmpty)
    #expect(list.tracked.paths.isEmpty)
  }

  /// A launch by `drakar <dir>`: the folder arrives before any window can open one. The
  /// first window home would show becomes it instead, and any further folder opens beside.
  @Test func beforeAnyWindowTheFoldersWaitForTheFirst() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (first, second) = (try folder("first"), try folder("second"))
    let intake = FolderIntake(list: list)
    intake.receive([first, second], open: nil)
    #expect(intake.takeFirst()?.lastPathComponent == "first")
    var opened: [URL] = []
    intake.flush { opened.append($0) }
    #expect(opened.map(\.lastPathComponent) == ["second"])
    intake.flush { opened.append($0) }
    #expect(opened.count == 1)
    #expect(intake.takeFirst() == nil)
  }
}
