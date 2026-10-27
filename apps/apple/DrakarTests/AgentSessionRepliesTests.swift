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

  private static let question =
    #"{"type":"control_request","request_id":"e1","request":{"subtype":"elicitation","mcp_server_name":"linear","message":"Which team?","mode":"form","requested_schema":{"type":"object","properties":{"team":{"type":"string"}}}}}"#

  /// What the stand-in was sent so far, a line each.
  private func sentLines(to script: URL) -> [String] {
    let stdin = script.appendingPathExtension("stdin")
    let text = (try? String(contentsOf: stdin, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// A session sent a prompt, once the stand-in's question waits on it.
  private func waitingSession(
    onRequested: (() -> Void)? = nil
  ) async throws -> (AgentSession, URL) {
    let script = try standIn(writing: Self.question)
    let session = AgentSession(folder: folder)
    session.executableOverride = script
    session.onPermissionRequested = onRequested
    session.send("hello")
    for _ in 0..<50 where session.transcript.pendingElicitations.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    return (session, script)
  }

  @Test func anElicitationWaitsForThePerson() async throws {
    var requested = 0
    let (session, script) = try await waitingSession { requested += 1 }
    defer { session.stop() }
    #expect(session.transcript.pendingElicitations.map(\.requestID) == ["e1"])
    #expect(session.isAtWork)
    #expect(requested == 1)
    try await Task.sleep(for: .seconds(1))
    #expect(!sentLines(to: script).contains { $0.contains(#""request_id":"e1""#) })
  }

  @Test func anAnsweredElicitationGoesBack() async throws {
    let (session, script) = try await waitingSession()
    defer { session.stop() }
    var replied = 0
    session.onReplied = { replied += 1 }
    let pending = try #require(session.transcript.pendingElicitations.first)
    session.answer(pending, .accept(["team": .string("core")]))
    let reply = try await sentLine(to: script, containing: #""request_id":"e1""#)
    #expect(reply?.contains(#""action":"accept""#) == true)
    #expect(reply?.contains(#""team":"core""#) == true)
    #expect(session.transcript.pendingElicitations.isEmpty)
    #expect(replied == 1)
  }

  @Test func anInterruptCancelsTheQuestion() async throws {
    let (session, script) = try await waitingSession()
    defer { session.stop() }
    #expect(session.transcript.pendingElicitations.count == 1)
    session.interrupt()
    _ = try await sentLine(to: script, containing: #""subtype":"interrupt""#)
    let lines = sentLines(to: script)
    let cancel = try #require(lines.firstIndex { $0.contains(#""request_id":"e1""#) })
    let interrupt = try #require(lines.firstIndex { $0.contains(#""subtype":"interrupt""#) })
    #expect(lines[cancel].contains(#""action":"cancel""#))
    #expect(cancel < interrupt)
    #expect(session.transcript.pendingElicitations.isEmpty)
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
