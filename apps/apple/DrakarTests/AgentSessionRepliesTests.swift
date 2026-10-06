import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A request from the CLI that only the client can answer is answered, so that the turn
/// never waits on it: against a stand-in `claude` that writes one, then records its stdin.
@MainActor
@Suite("A session answers the CLI's own requests")
struct AgentSessionRepliesTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-replies-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A stand-in that writes `line` on start, then appends whatever it is sent to its stdin file.
  private func standIn(writing line: String) throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\nprintf '%s\\n' '\(line)'\ncat >> \"$0.stdin\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func sentLine(to script: URL, containing marker: String) async throws -> String? {
    let stdin = script.appendingPathExtension("stdin")
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

  @Test func anElicitationIsDeclined() async throws {
    let script = try standIn(
      writing:
        #"{"type":"control_request","request_id":"e1","request":{"subtype":"elicitation","mcp_server_name":"linear","message":"Which team?"}}"#
    )
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.send("hello")
    defer { session.stop() }
    let reply = try await sentLine(to: script, containing: #""request_id":"e1""#)
    #expect(reply?.contains(#""action":"decline""#) == true)
    #expect(session.transcript.pendingPermissions.isEmpty)
  }

  @Test func aRequestItCannotServeIsRefused() async throws {
    let script = try standIn(
      writing:
        #"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback","callback_id":"c"}}"#
    )
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.send("hello")
    defer { session.stop() }
    let reply = try await sentLine(to: script, containing: #""request_id":"h1""#)
    #expect(reply?.contains(#""subtype":"error""#) == true)
  }
}
