import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A session against a stand-in `claude`: a script that writes whatever it is sent to a
/// file beside itself, so the order of the lines can be read back.
@MainActor
@Suite("A session started on demand")
struct ClaudeSessionTests {

  private let folder: URL
  private let fake: URL
  private var received: URL { fake.appendingPathExtension("stdin") }

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat >> \"$0.stdin\"\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private func lines(count: Int) async throws -> [String] {
    for _ in 0..<50 {
      let text = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
      let lines = text.split(separator: "\n").map(String.init)
      if lines.count >= count { return lines }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("the stand-in received fewer than \(count) lines")
    return []
  }

  @Test func nothingRunsUntilTheFirstPrompt() {
    let session = ClaudeSession(folder: folder)
    #expect(session.phase == .idle)
    #expect(session.canSend)
    #expect(!session.isProcessRunning)
  }

  /// The prompt typed before the process exists goes out after `initialize`, never before.
  @Test func theFirstPromptFollowsInitialize() async throws {
    let session = ClaudeSession(folder: folder)
    session.executableOverride = fake
    session.send("hello")
    #expect(session.transcript.isRunning)
    let lines = try await lines(count: 2)
    session.stop()
    #expect(lines.first?.contains(#""subtype":"initialize""#) == true)
    #expect(lines.last?.contains(#""type":"user""#) == true)
    #expect(lines.last?.contains("hello") == true)
  }

  /// A restored window whose transcript is gone still opens, and says why it cannot resume.
  @Test func aMissingTranscriptStopsWithAReason() async {
    let target = ResumeTarget(
      sessionID: "gone", cwd: folder.path(percentEncoded: false),
      file: folder.appending(path: "gone.jsonl").path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let session = ClaudeSession(folder: folder, resuming: target)
    await session.loadHistory()
    guard case .failed(let reason) = session.phase else {
      Issue.record("phase is \(session.phase)")
      return
    }
    #expect(reason.contains("transcript"))
  }

  @Test func historyLoadsWithoutAProcess() async throws {
    let file = folder.appending(path: "s1.jsonl")
    try Data(
      [
        #"{"type":"user","message":{"role":"user","content":"Make it so"}}"#,
        #"{"type":"ai-title","aiTitle":"Make it so"}"#,
      ].joined(separator: "\n").appending("\n").utf8
    ).write(to: file)
    let target = ResumeTarget(
      sessionID: "s1", cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let session = ClaudeSession(folder: folder, resuming: target)
    await session.loadHistory()
    #expect(session.title == "Make it so")
    #expect(session.phase == .idle)
    #expect(session.savedTarget == target)
  }

  @Test func aReadOnlySessionSendsNothing() {
    let session = ClaudeSession(folder: folder)
    session.isReadOnly = true
    #expect(!session.canSend)
    session.send("hello")
    #expect(session.transcript.entries.isEmpty)
  }

  /// A prompt typed while the history is still being read is kept, after that history.
  @Test func aPromptDuringTheHistoryLoadIsKept() async throws {
    let file = folder.appending(path: "s2.jsonl")
    try Data(
      #"{"type":"user","message":{"role":"user","content":"Earlier"}}"#.appending("\n").utf8
    ).write(to: file)
    let target = ResumeTarget(
      sessionID: "s2", cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let session = ClaudeSession(folder: folder, resuming: target)
    session.executableOverride = fake
    async let load: Void = session.loadHistory()
    session.send("hello")
    await load
    let lines = try await lines(count: 2)
    session.stop()
    #expect(session.transcript.entries.count == 2)
    #expect(lines.first?.contains(#""subtype":"initialize""#) == true)
    #expect(lines.last?.contains("hello") == true)
  }

  /// An ended session starts again on the next prompt.
  @Test func anEndedSessionStartsAgain() async throws {
    let session = ClaudeSession(folder: folder)
    session.executableOverride = fake
    session.send("one")
    _ = try await lines(count: 2)
    session.stop()
    #expect(!session.isProcessRunning)
    #expect(session.canSend)
    session.send("two")
    let lines = try await lines(count: 4)
    session.stop()
    #expect(lines.filter { $0.contains(#""subtype":"initialize""#) }.count == 2)
  }

  @Test func aMissingTranscriptDisablesTheComposer() async {
    let target = ResumeTarget(
      sessionID: "gone", cwd: folder.path(percentEncoded: false),
      file: folder.appending(path: "gone.jsonl").path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let session = ClaudeSession(folder: folder, resuming: target)
    await session.loadHistory()
    #expect(!session.canSend)
  }
}
