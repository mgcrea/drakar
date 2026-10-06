import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A prompt typed while a turn runs, against a stand-in `claude` that never ends its turn
/// and records its stdin.
@MainActor
@Suite("Queueing behind a turn")
struct ClaudeSessionQueueTests {

  private let folder: URL
  private let script: URL
  private var stdin: URL { script.appendingPathExtension("stdin") }

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat >> \"$0.stdin\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  }

  /// A session mid-turn, its process up.
  private func running() async throws -> ClaudeSession {
    let session = ClaudeSession(folder: folder)
    session.executableOverride = script
    session.send("first")
    for _ in 0..<50 where !session.isProcessRunning {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.canQueue)
    return session
  }

  private func line(containing marker: String) async throws -> String? {
    for _ in 0..<50 {
      let text = (try? String(contentsOf: stdin, encoding: .utf8)) ?? ""
      if let line = text.split(separator: "\n").map(String.init).first(where: {
        $0.contains(marker)
      }) {
        return line
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  @Test func aPromptMidTurnGoesNowAndWaitsApart() async throws {
    let session = try await running()
    defer { session.stop() }
    session.send("second")
    let queued = try #require(session.transcript.queuedPrompts.first)
    #expect(queued.text == "second")
    #expect(!session.transcript.entries.contains { $0.kind == .prompt("second") })
    let sent = try await line(containing: "second")
    #expect(sent?.contains(#""uuid":"\#(queued.uuid)""#) == true)
  }

  @Test func cancellingAQueuedPromptAsksTheCLI() async throws {
    let session = try await running()
    defer { session.stop() }
    session.send("second")
    let queued = try #require(session.transcript.queuedPrompts.first)
    session.cancelQueued(queued)
    let cancel = try await line(containing: "cancel_async_message")
    #expect(cancel?.contains(#""message_uuid":"\#(queued.uuid)""#) == true)
  }

  @Test func stopDropsTheQueueToo() async throws {
    let session = try await running()
    defer { session.stop() }
    session.interrupt()
    let interrupt = try await line(containing: #""subtype":"interrupt""#)
    #expect(interrupt?.contains(#""cancel_queued":true"#) == true)
  }

  /// Every prompt is named, so the CLI's lifecycle lines can be matched to it.
  @Test func theFirstPromptIsNamedToo() async throws {
    let session = try await running()
    defer { session.stop() }
    #expect(try await line(containing: "first")?.contains(#""uuid":""#) == true)
  }
}
