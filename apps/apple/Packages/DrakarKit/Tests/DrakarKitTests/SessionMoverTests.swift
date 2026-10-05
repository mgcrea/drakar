import DrakarKit
import Foundation
import Testing

@Suite("Moving a session's files to another account")
struct SessionMoverTests {

  private let root: URL
  private let source: ClaudeAccount
  private let target: ClaudeAccount
  private let folderName = "-Users-me-Projects-app"
  private let id = "11111111-2222-3333-4444-555555555555"

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-move-\(UUID().uuidString)", directoryHint: .isDirectory)
    source = ClaudeAccount(
      directory: root.appending(path: ".claude-a", directoryHint: .isDirectory), isDefault: false)
    target = ClaudeAccount(
      directory: root.appending(path: ".claude-b", directoryHint: .isDirectory), isDefault: false)
    for account in [source, target] {
      try FileManager.default.createDirectory(
        at: account.directory, withIntermediateDirectories: true)
    }
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  /// The transcript and, as asked, each sidecar, under `account`.
  @discardableResult
  private func write(
    in account: ClaudeAccount, folder: String? = nil, text: String = "{\"type\":\"user\"}\n",
    subagents: Bool = false, fileHistory: Bool = false, sessionEnv: Bool = false
  ) throws -> URL {
    let projects = account.directory.appending(
      path: "projects/\(folder ?? folderName)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let transcript = projects.appending(path: "\(id).jsonl")
    try Data(text.utf8).write(to: transcript)
    if subagents {
      let folder = projects.appending(path: "\(id)/subagents", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("{}\n".utf8).write(to: folder.appending(path: "agent-1.jsonl"))
    }
    if fileHistory {
      let folder = account.directory.appending(
        path: "file-history/\(id)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("v1".utf8).write(to: folder.appending(path: "abc@v1"))
    }
    if sessionEnv {
      let folder = account.directory.appending(path: "session-env", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: folder.appending(path: id, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    return transcript
  }

  @Test func movesTheTranscriptAndEverySidecar() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, subagents: true, fileHistory: true, sessionEnv: true)
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)

    let destination = SessionMover.destination(of: transcript, to: target)
    #expect(
      destination.path(percentEncoded: false).hasSuffix(
        ".claude-b/projects/\(folderName)/\(id).jsonl"))
    #expect(exists(destination))
    #expect(exists(destination.deletingPathExtension().appending(path: "subagents/agent-1.jsonl")))
    #expect(exists(target.directory.appending(path: "file-history/\(id)/abc@v1")))
    #expect(exists(target.directory.appending(path: "session-env/\(id)")))
    #expect(!exists(transcript))
    #expect(!exists(transcript.deletingPathExtension()))
    #expect(!exists(source.directory.appending(path: "file-history/\(id)")))
    #expect(!exists(source.directory.appending(path: "session-env/\(id)")))
  }

  @Test func movesWhicheverSidecarsThereAre() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, fileHistory: true)
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)
    #expect(exists(target.directory.appending(path: "file-history/\(id)")))
    #expect(!exists(target.directory.appending(path: "session-env/\(id)")))
  }

  @Test func neverOverwritesATranscriptAlreadyThere() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, text: "source\n")
    let existing = try write(in: target, text: "target\n")
    #expect(
      SessionMover.move(transcript: transcript, from: source, to: target) == .skipped(.alreadyThere)
    )
    #expect(try String(contentsOf: transcript, encoding: .utf8) == "source\n")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "target\n")
  }

  /// A worktree's folder name is not what encoding the project path would give.
  @Test func reusesTheFolderNameExactly() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let odd = "-Users-me-Projects-app--claude-worktrees-Feat.X"
    let transcript = try write(in: source, folder: odd)
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)
    #expect(exists(target.directory.appending(path: "projects/\(odd)/\(id).jsonl")))
  }

  @Test func refusesWhenTheTargetFolderIsGone() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source)
    try FileManager.default.removeItem(at: target.directory)
    guard case .failed = SessionMover.move(transcript: transcript, from: source, to: target) else {
      Issue.record("moved into a missing account")
      return
    }
    #expect(exists(transcript))
  }

  /// The transcript decides the account: a failure on it leaves the session usable where it
  /// was, and a second move finishes the job.
  @Test func aFailedTranscriptMoveLeavesTheSessionWhereItWas() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try write(in: source, fileHistory: true)
    guard
      case .failed = SessionMover.move(
        transcript: transcript, from: source, to: target, fileManager: RefusesTranscripts())
    else {
      Issue.record("the refusing file manager moved the transcript")
      return
    }
    #expect(exists(transcript))
    #expect(exists(target.directory.appending(path: "file-history/\(id)")))
    #expect(SessionMover.move(transcript: transcript, from: source, to: target) == .moved)
    #expect(exists(SessionMover.destination(of: transcript, to: target)))
  }
}

/// Moves everything but a transcript.
private final class RefusesTranscripts: FileManager, @unchecked Sendable {
  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if srcURL.pathExtension == "jsonl" { throw CocoaError(.fileWriteNoPermission) }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}
