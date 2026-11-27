import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("How the sidebar sorts its sessions")
struct SessionOrderTests {

  /// A row as the sort sees it, named for the expectations.
  private struct Row {
    var name: String
    var state: RowState = .working
    var activity: Date?
    var folder = ""
  }

  private func names(_ rows: [Row], _ order: SessionOrder) -> [String] {
    order.sorted(rows) { .init(state: $0.state, activity: $0.activity, folder: $0.folder) }
      .map(\.name)
  }

  private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

  @Test func openedKeepsTheWindowsOrder() {
    let rows = [
      Row(name: "a", state: .working), Row(name: "b", state: .waiting),
      Row(name: "c", state: .asked),
    ]
    #expect(names(rows, .opened) == ["a", "b", "c"])
  }

  @Test func needsMeFirstPutsWhatWantsThePersonOnTopMostUrgentFirst() {
    let rows = [
      Row(name: "ended", state: .ended), Row(name: "working", state: .working),
      Row(name: "tool", state: .runningTool), Row(name: "stopped", state: .stopped),
      Row(name: "idle", state: .idle), Row(name: "offered", state: .offered),
      Row(name: "asked", state: .asked), Row(name: "choosing", state: .choosing),
      Row(name: "waiting", state: .waiting), Row(name: "notStarted", state: .notStarted),
    ]
    #expect(
      names(rows, .needsMe) == [
        "waiting", "choosing", "asked", "offered", "idle", "stopped", "working", "tool",
        "ended", "notStarted",
      ])
  }

  @Test func needsMeFirstPutsWhatHasWaitedLongestFirst() {
    let rows = [
      Row(name: "recent", state: .asked, activity: at(300)),
      Row(name: "undated", state: .asked),
      Row(name: "oldest", state: .asked, activity: at(100)),
      Row(name: "older", state: .asked, activity: at(200)),
    ]
    #expect(names(rows, .needsMe) == ["oldest", "older", "recent", "undated"])
  }

  @Test func needsMeFirstLeavesBusyRowsInTheWindowsOrder() {
    let rows = [
      Row(name: "a", state: .working, activity: at(300)),
      Row(name: "b", state: .working, activity: at(100)),
    ]
    #expect(names(rows, .needsMe) == ["a", "b"])
  }

  @Test func recentActivityPutsTheNewestFirstAndTheUndatedLast() {
    let rows = [
      Row(name: "undated"), Row(name: "old", activity: at(100)),
      Row(name: "new", activity: at(300)), Row(name: "mid", activity: at(200)),
    ]
    #expect(names(rows, .recent) == ["new", "mid", "old", "undated"])
  }

  @Test func folderSortsAToZAsFinderDoesAndKeepsTiesInTheWindowsOrder() {
    let rows = [
      Row(name: "b2", folder: "/p/bravo"), Row(name: "ten", folder: "/p/folder10"),
      Row(name: "two", folder: "/p/folder2"), Row(name: "b1", folder: "/p/bravo"),
      Row(name: "alpha", folder: "/p/Alpha"),
    ]
    #expect(names(rows, .folder) == ["alpha", "b2", "b1", "two", "ten"])
  }

  @Test func theOrderIsKeptWithTheWindow() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-order-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(folder: folder)
    #expect(project.sessionOrder == .opened)
    #expect(project.stored.sessionOrder == nil)
    project.sessionOrder = .needsMe
    let stored = project.stored
    #expect(stored.sessionOrder == .needsMe)
    #expect(!stored.isEmpty)
    let data = try JSONEncoder().encode(stored)
    let restored = try JSONDecoder().decode(StoredProject.self, from: data)
    #expect(Project(folder: folder, restoring: restored).sessionOrder == .needsMe)
  }

  @Test func aWindowStoredBeforeSortingDecodesAsOpened() throws {
    let old = Data(#"{"sessions":[]}"#.utf8)
    let stored = try JSONDecoder().decode(StoredProject.self, from: old)
    #expect(stored.sessionOrder == nil)
  }

  /// `listedHeld` includes every agent's open tabs (Claude, Codex, Antigravity), excludes a
  /// watched preview, and follows `sessionOrder`.
  @Test func listedHeldIncludesAllAgentsAndRespectsOrder() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-listed-held-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(folder: folder)
    let claude = project.newSession(agent: .claude)
    let agy = project.newSession(agent: .agy)
    let codex = project.newSession(agent: .codex)
    #expect(project.listedHeld.map(\.id) == [claude.id, agy.id, codex.id])

    // Folder order sorts by each session's subfolder A–Z.
    let zFolder = folder.appending(path: "z-sub", directoryHint: .isDirectory)
    let aFolder = folder.appending(path: "a-sub", directoryHint: .isDirectory)
    let zSession = project.newSession(agent: .agy, folder: zFolder)
    let aSession = project.newSession(agent: .agy, folder: aFolder)
    project.sessionOrder = .folder
    let ids = project.listedHeld.map(\.id)
    let aIndex = try #require(ids.firstIndex(of: aSession.id))
    let zIndex = try #require(ids.firstIndex(of: zSession.id))
    #expect(aIndex < zIndex)
  }
}
