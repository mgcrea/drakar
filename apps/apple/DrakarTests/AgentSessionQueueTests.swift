import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A prompt typed while a turn runs, against a stand-in `claude` that never ends its turn
/// and records its stdin.
@MainActor
@Suite("Queueing behind a turn")
struct AgentSessionQueueTests {

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
  private func running() async throws -> AgentSession {
    let session = AgentSession(folder: folder)
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

  /// A turn that ends with a prompt queued waits to say so, since the prompt usually starts the
  /// next one; when it is cancelled instead, the end is said after all, once.
  @Test func aTurnEndIsSaidOnceTheQueueEmptiesWithoutATurn() async throws {
    let answering = folder.appending(path: "claude-answering")
    let result =
      #"{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s"}"#
    let cancelled =
      #"{"type":"command_lifecycle","command_uuid":"%s","state":"cancelled","session_id":"s"}"#
    try Data(
      """
      #!/bin/sh
      while IFS= read -r line; do
        printf '%s\\n' "$line" >> "$0.stdin"
        case "$line" in
          *'"second"'*)
            uuid=$(printf '%s' "$line" | sed -n 's/.*"uuid":"\\([^"]*\\)".*/\\1/p')
            printf '%s\\n' '\(result)'
            printf '\(cancelled)\\n' "$uuid";;
        esac
      done

      """.utf8
    ).write(to: answering)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: answering.path)
    let session = AgentSession(folder: folder)
    session.executableOverride = answering
    var ends = 0
    session.onTurnEnded = { ends += 1 }
    session.send("first")
    for _ in 0..<50 where !session.isProcessRunning {
      try await Task.sleep(for: .milliseconds(100))
    }
    defer { session.stop() }
    session.send("second")
    #expect(session.transcript.queuedPrompts.count == 1)
    for _ in 0..<50 where !session.transcript.queuedPrompts.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.transcript.queuedPrompts.isEmpty)
    #expect(!session.transcript.isRunning)
    #expect(ends == 1)
  }

  /// Every prompt is named, so the CLI's lifecycle lines can be matched to it.
  @Test func theFirstPromptIsNamedToo() async throws {
    let session = try await running()
    defer { session.stop() }
    #expect(try await line(containing: "first")?.contains(#""uuid":""#) == true)
  }
}
