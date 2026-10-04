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
}
