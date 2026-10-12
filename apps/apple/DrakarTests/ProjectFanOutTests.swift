import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Running a skill in each subfolder")
struct ProjectFanOutTests {
  private let parent: URL
  private let folders: [URL]
  private let check = SkillEntry(name: "check", description: "Fix it")
  private let audit = SkillEntry(name: "audit", argumentHint: "<area>")

  init() throws {
    let parent = FileManager.default.temporaryDirectory.appending(
      path: "drakar-fanout-\(UUID().uuidString)", directoryHint: .isDirectory)
    self.parent = parent
    folders = ["alpha", "beta", "gamma"].map {
      parent.appending(path: $0, directoryHint: .isDirectory)
    }
    for folder in folders {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  /// A stand-in CLI that reads forever (`cat`), or one that exits at once.
  private func standIn(exits: Bool = false) throws -> URL {
    let script = parent.appending(path: exits ? "claude-exits" : "claude")
    try Data((exits ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\ncat > /dev/null\n").utf8)
      .write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func prompts(_ item: ProjectSession) -> [String] {
    item.session.transcript.entries.compactMap {
      if case .prompt(let text) = $0.kind { text } else { nil }
    }
  }

  /// One session per folder, named after the skill and the folder, on top in folder order,
  /// the first shown; unlimited, each is sent the skill.
  @Test func oneSessionPerFolder() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: nil)
    #expect(
      project.sessions.prefix(3).map(\.displayTitle)
        == ["/check · alpha", "/check · beta", "/check · gamma"])
    #expect(
      project.sessions.prefix(3).map(\.session.folder.lastPathComponent)
        == ["alpha", "beta", "gamma"])
    #expect(project.selected?.id == project.sessions.first?.id)
    for item in project.sessions.prefix(3) { #expect(prompts(item) == ["/check"]) }
    #expect(project.fanOuts.count == 1)
  }

  /// Arguments follow the name; blank ones are left out.
  @Test func argumentsFollowTheName() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(
      audit, folders: [folders[0]], arguments: "  auth  ", mode: nil, limit: nil)
    #expect(prompts(try #require(project.sessions.first)) == ["/audit auth"])
  }

  /// The mode picked goes to every session.
  @Test func theModeGoesToEach() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: .plan, limit: 1)
    for item in project.sessions.prefix(3) { #expect(item.session.startingMode == .plan) }
  }

  /// With a limit, that many are sent; a turn end sends the next.
  @Test func aLimitSendsTheNextOnATurnEnd() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 2)
    let items = Array(project.sessions.prefix(3))
    #expect(items.map { prompts($0).count } == [1, 1, 0])
    items[0].session.onTurnEnded?()
    #expect(prompts(items[2]) == ["/check"])
  }

  /// A session that stops without a turn end (it could not start) frees its slot too.
  @Test func aSessionThatStopsFreesItsSlot() async throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn(exits: true)
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let last = try #require(project.sessions.dropFirst(2).first)
    // Each stand-in exits at once; the stops walk the queue to the last.
    for _ in 0..<100 where prompts(last).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(prompts(last) == ["/check"])
  }

  /// A folder gone before its session starts fails it at once: its slot goes to the next.
  @Test func aFolderGoneFreesItsSlot() async throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    let gone = parent.appending(path: "gone", directoryHint: .isDirectory)
    project.runInSubfolders(
      check, folders: [gone] + folders.prefix(1), arguments: "", mode: nil, limit: 1)
    let next = try #require(project.sessions.dropFirst().first)
    for _ in 0..<100 where prompts(next).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(prompts(next) == ["/check"])
  }

  /// A waiting session closed before its turn is skipped, not waited for.
  @Test func aClosedWaitingSessionIsSkipped() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.remove(items[1])
    items[0].session.onTurnEnded?()
    #expect(prompts(items[2]) == ["/check"])
  }

  /// Cancel leaves the waiting ones unsent; the batch goes once the running one is done.
  @Test func cancelLeavesTheWaitingUnsent() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.cancelFanOut(try #require(project.fanOuts.first))
    items[0].session.onTurnEnded?()
    #expect(prompts(items[1]).isEmpty)
    #expect(prompts(items[2]).isEmpty)
    #expect(project.fanOuts.isEmpty)
  }

  /// Ending or removing a running session frees its slot: the next one is sent the skill.
  @Test func endingOrRemovingARunningOneFreesItsSlot() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.end(items[0])
    #expect(prompts(items[1]) == ["/check"])
    project.remove(items[1])
    #expect(prompts(items[2]) == ["/check"])
  }

  /// One taken up in another process gives way here, and its slot with it.
  @Test func oneTakenUpElsewhereFreesItsSlot() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    defer { project.stopAll() }
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(2))
    project.gaveWay(items[0])
    #expect(prompts(items[1]) == ["/check"])
  }

  /// Closing the window stops every session without sending the waiting ones.
  @Test func stopAllSendsNothingMore() throws {
    let project = Project(folder: parent)
    project.executableOverride = try standIn()
    project.runInSubfolders(check, folders: folders, arguments: "", mode: nil, limit: 1)
    let items = Array(project.sessions.prefix(3))
    project.stopAll()
    #expect(prompts(items[1]).isEmpty)
    #expect(prompts(items[2]).isEmpty)
  }
}
