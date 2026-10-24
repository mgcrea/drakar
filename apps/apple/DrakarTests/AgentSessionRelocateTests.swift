import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A session whose files moved")
struct AgentSessionRelocateTests {

  private let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-relocate-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func transcript(in account: URL) throws -> URL {
    let folder = account.appending(path: "projects/-p", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "s1.jsonl")
    try Data(
      [
        #"{"type":"user","message":{"role":"user","content":"Make it so"}}"#,
        #"{"type":"ai-title","aiTitle":"Make it so"}"#,
      ].joined(separator: "\n").appending("\n").utf8
    ).write(to: file)
    return file
  }

  private func target(_ file: URL, account: URL) -> ResumeTarget {
    ResumeTarget(
      sessionID: "s1", cwd: root.path(percentEncoded: false),
      file: file.path(percentEncoded: false),
      accountDirectory: ClaudeAccount(directory: account, isDefault: false).key,
      accountIsDefault: false)
  }

  /// A session watched read-only keeps following its transcript at the new place: the move
  /// keeps the file whole, so what was read stays read.
  @Test func aWatchedSessionFollowsItsTranscriptToTheNewAccount() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appending(path: ".claude-a", directoryHint: .isDirectory)
    let new = root.appending(path: ".claude-b", directoryHint: .isDirectory)
    let oldFile = try transcript(in: old)
    let session = AgentSession(folder: root, resuming: target(oldFile, account: old))
    await session.loadHistory()
    let folder = new.appending(path: "projects/-p", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let newFile = folder.appending(path: "s1.jsonl")
    try FileManager.default.moveItem(at: oldFile, to: newFile)
    session.relocate(to: target(newFile, account: new))

    session.isReadOnly = true
    let handle = try FileHandle(forWritingTo: newFile)
    try handle.seekToEnd()
    try handle.write(
      contentsOf: Data(
        (#"{"type":"user","message":{"role":"user","content":"And again"}}"# + "\n").utf8))
    try handle.close()
    session.catchUp()
    let prompts = session.transcript.entries.compactMap {
      if case .prompt(let text) = $0.kind { text } else { nil }
    }
    #expect(prompts == ["Make it so", "And again"])
  }

  /// The window's stored project and the next process both follow the move.
  @Test func theNextStartResumesUnderTheNewAccount() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appending(path: ".claude-a", directoryHint: .isDirectory)
    let new = root.appending(path: ".claude-b", directoryHint: .isDirectory)
    let oldFile = try transcript(in: old)
    let newFile = try transcript(in: new)
    let fake = root.appending(path: "claude")
    try Data(
      "#!/bin/sh\nprintf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$@\" > \"$0.args\"\ncat > /dev/null\n"
        .utf8
    ).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let session = AgentSession(folder: root, resuming: target(oldFile, account: old))
    session.executableOverride = fake
    let moved = target(newFile, account: new)
    session.relocate(to: moved)
    #expect(session.savedTarget == moved)
    #expect(session.effectiveAccount?.key == ClaudeAccount(directory: new, isDefault: false).key)

    await session.spawn()
    defer { session.stop() }
    let written = fake.appendingPathExtension("args")
    var lines: [String] = []
    for _ in 0..<50 {
      lines = ((try? String(contentsOf: written, encoding: .utf8)) ?? "").split(separator: "\n")
        .map(String.init)
      if !lines.isEmpty { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(lines.first == ClaudeAccount(directory: new, isDefault: false).key)
    #expect(lines.contains("--resume=s1"))
  }
}
