import DrakarKit
import Foundation
import Observation
import Testing

@testable import Drakar

/// What other windows read about a session (the sidebar's row, Home's counts, attention,
/// keep-awake) changes with what the session is doing, never with each token it streams:
/// every window redrew on every token of every session when they read the transcript.
@MainActor
@Suite("A session's status")
struct AgentSessionStatusTests {
  private let folder: URL
  private let fake: URL
  private var go: URL { fake.appendingPathExtension("go") }

  private static let initLine =
    #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-status","model":"m","permissionMode":"default"}"#
  private static let start =
    #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#
  private static let block =
    #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
  private static func delta(_ text: String) -> String {
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""#
      + text + #""}}}"#
  }
  private static let done =
    #"{"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Hello there"}],"stop_reason":"end_turn"},"parent_tool_use_id":null,"session_id":"s-status"}"#
  private static let result =
    #"{"type":"result","subtype":"success","is_error":false,"result":"Hello there","stop_reason":"end_turn","session_id":"s-status"}"#

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-status-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    // After the prompt: one token, then a wait for `$0.go`, then another token, then the end
    // of the turn once `$0.go` is gone again.
    let script = """
      #!/bin/sh
      read -r line
      echo '\(Self.initLine)'
      while read -r line; do case "$line" in *'"type":"user"'*) break;; esac; done
      echo '\(Self.start)'
      echo '\(Self.block)'
      echo '\(Self.delta("Hello"))'
      while [ ! -f "$0.go" ]; do sleep 0.02; done
      echo '\(Self.delta(" there"))'
      while [ -f "$0.go" ]; do sleep 0.02; done
      echo '\(Self.done)'
      echo '\(Self.result)'
      exec cat > /dev/null

      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func streamed(_ session: AgentSession) -> String {
    session.transcript.entries.compactMap {
      if case .text(let text) = $0.kind { text } else { nil }
    }.joined()
  }

  @Test func aTokenChangesTheTranscriptButNotTheStatus() async throws {
    let session = AgentSession(folder: folder)
    session.executableOverride = fake
    session.accounts = { [] }
    session.makeTransport = { AgentProcess($0) }
    defer {
      session.stop()
      try? FileManager.default.removeItem(at: folder)
    }
    session.send("hi")
    try await waitFor { streamed(session) == "Hello" }
    #expect(streamed(session) == "Hello")
    #expect(session.status.isRunning)
    #expect(session.sessionID == "s-status")

    let statusChanged = ObservedFlag()
    withObservationTracking {
      _ = (session.status, session.sessionID, session.title, session.isAtWork)
    } onChange: {
      statusChanged.value = true
    }
    let transcriptChanged = ObservedFlag()
    withObservationTracking {
      _ = session.transcript
    } onChange: {
      transcriptChanged.value = true
    }
    try Data().write(to: go)
    try await waitFor { streamed(session) == "Hello there" }
    #expect(streamed(session) == "Hello there")
    #expect(transcriptChanged.value)
    #expect(!statusChanged.value)

    try FileManager.default.removeItem(at: go)
    try await waitFor { !session.status.isRunning }
    #expect(!session.status.isRunning)
    #expect(statusChanged.value)
  }
}

/// Set from an observation callback, which may not capture a variable.
private final class ObservedFlag: @unchecked Sendable {
  var value = false
}
