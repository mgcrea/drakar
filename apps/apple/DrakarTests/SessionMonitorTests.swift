import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Watching sessions on disk")
struct SessionMonitorTests {

  @Test func aTranscriptWrittenAppearsUnderItsProject() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: account.directory.appending(path: "sessions"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.summaries(under: "/w/drakar").isEmpty)

    try Data(#"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#.utf8)
      .write(to: projects.appending(path: "s1.jsonl"))
    for _ in 0..<40 where monitor.summaries(under: "/w/drakar").isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID) == ["s1"])
    monitor.stop()
  }

  private func fixture() throws -> (home: URL, account: ClaudeAccount, projects: URL) {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: account.directory.appending(path: "sessions"), withIntermediateDirectories: true)
    return (home, account, projects)
  }

  private static let line =
    #"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#

  @Test func aRegistryWriteUpdatesTheLiveIDs() async throws {
    let (home, account, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.liveIDs.isEmpty)
    let json =
      #"{"pid":\#(getpid()),"sessionId":"live1","cwd":"/w/drakar","entrypoint":"cli","status":"idle"}"#
    try Data(json.utf8).write(
      to: account.directory.appending(path: "sessions/\(getpid()).json"))
    for _ in 0..<40 where monitor.liveIDs.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(monitor.liveIDs == ["live1"])
    monitor.stop()
  }

  @Test func aDeletedTranscriptDisappears() async throws {
    let (home, account, projects) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = projects.appending(path: "gone.jsonl")
    try Data(Self.line.utf8).write(to: file)
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID) == ["gone"])
    try FileManager.default.removeItem(at: file)
    for _ in 0..<40 where !monitor.summaries(under: "/w/drakar").isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(monitor.summaries(under: "/w/drakar").isEmpty)
    monitor.stop()
  }

  /// `~/.claude` may be a link: the listing spells paths through it, FSEvents reports them
  /// resolved. One transcript is still one row.
  @Test func aTranscriptListedThenWrittenIsOneRow() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let real = home.appending(path: "claude-real", directoryHint: .isDirectory)
    let projects = real.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: real.appending(path: "sessions"), withIntermediateDirectories: true)
    let link = home.appending(path: ".claude")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let account = ClaudeAccount(directory: link, isDefault: true)
    let file = projects.appending(path: "once.jsonl")
    try Data(Self.line.utf8).write(to: file)
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.summaries(under: "/w/drakar").count == 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + #"{"type":"ai-title","aiTitle":"Again"}"#).utf8))
    try handle.close()
    for _ in 0..<40
    where !monitor.summaries(under: "/w/drakar").contains(where: { $0.title == "Again" }) {
      try await Task.sleep(for: .milliseconds(100))
    }
    // Long enough for a second, differently spelled entry to land too.
    try await Task.sleep(for: .milliseconds(500))
    #expect(monitor.summaries(under: "/w/drakar").map(\.title) == ["Again"])
    monitor.stop()
  }

  @Test func includeWaitsForAccountDiscovery() async throws {
    let (home, account, projects) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data(Self.line.utf8).write(to: projects.appending(path: "old.jsonl"))
    let monitor = SessionMonitor(discover: {
      try? await Task.sleep(for: .milliseconds(300))
      return [account]
    })
    await monitor.include(folder: "/w/drakar")
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID) == ["old"])
  }
}
