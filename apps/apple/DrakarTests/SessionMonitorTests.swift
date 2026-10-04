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
