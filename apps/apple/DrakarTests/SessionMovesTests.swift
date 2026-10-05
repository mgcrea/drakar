import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Which sessions move, and what came of it")
struct SessionMovesTests {

  private let a = ClaudeAccount(
    directory: URL(filePath: "/u/.claude-a/", directoryHint: .isDirectory), isDefault: false)
  private let b = ClaudeAccount(
    directory: URL(filePath: "/u/.claude-b/", directoryHint: .isDirectory), isDefault: false)

  private func summary(_ id: String, on account: ClaudeAccount, title: String? = nil)
    -> SessionSummary
  {
    var summary = SessionSummary(
      sessionID: id, account: account,
      file: account.directory.appending(path: "projects/-p/\(id).jsonl"), modified: .now, size: 1)
    summary.title = title
    summary.cwd = "/p"
    return summary
  }

  @Test func onlySessionsOnAnotherAccount() {
    let candidates = SessionMoves.candidates(
      summaries: [summary("s1", on: a), summary("s2", on: b)], held: [], notOn: b)
    #expect(candidates.map(\.sessionID) == ["s1"])
  }

  /// A held row's transcript can be newer than the list; it counts once, as the window has it.
  @Test func oneCandidatePerSessionTheWindowsWins() {
    let target = ResumeTarget(
      sessionID: "s1", cwd: "/p", file: "/u/.claude-a/projects/-p/s1.jsonl",
      accountDirectory: a.key, accountIsDefault: false)
    let candidates = SessionMoves.candidates(
      summaries: [summary("s1", on: a, title: "Listed")],
      held: [
        (target: target, title: "Held"),
        (
          target: ResumeTarget(
            sessionID: "s3", cwd: "/p", file: "/u/.claude-a/projects/-p/s3.jsonl",
            accountDirectory: a.key, accountIsDefault: false), title: "New"
        ),
      ],
      notOn: b)
    #expect(candidates.map(\.sessionID).sorted() == ["s1", "s3"])
    #expect(candidates.first { $0.sessionID == "s1" }?.title == "Held")
  }

  @Test func classifies() {
    let idle = SessionMoves.Held(hasProcess: true, isBusy: false)
    let busy = SessionMoves.Held(hasProcess: true, isBusy: true)
    let stopped = SessionMoves.Held(hasProcess: false, isBusy: false)
    #expect(
      SessionMoves.classify(sessionID: "s", held: nil, liveIDs: [], host: "x")
        == .move(stopping: false))
    #expect(
      SessionMoves.classify(sessionID: "s", held: stopped, liveIDs: [], host: "x")
        == .move(stopping: false))
    #expect(
      SessionMoves.classify(sessionID: "s", held: idle, liveIDs: ["s"], host: "x")
        == .move(stopping: true))
    #expect(
      SessionMoves.classify(sessionID: "s", held: busy, liveIDs: [], host: "x") == .skip(.busy))
    // Watched read-only in a window, open in a terminal: not held.
    #expect(
      SessionMoves.classify(sessionID: "s", held: nil, liveIDs: ["s"], host: "VS Code")
        == .skip(.runningElsewhere("VS Code")))
  }

  @Test func summarises() {
    func report(_ outcome: MoveOutcome, _ title: String = "T") -> SessionMoves.Report {
      SessionMoves.Report(title: title, outcome: outcome)
    }
    #expect(
      SessionMoves.summary([report(.moved)], to: "Skitrust") == "Moved 1 session to Skitrust.")
    #expect(
      SessionMoves.summary(
        [
          report(.moved), report(.moved), report(.skipped(.runningElsewhere("VS Code"))),
          report(.skipped(.runningElsewhere("VS Code"))), report(.skipped(.alreadyThere)),
        ],
        to: "Skitrust")
        == "Moved 2 sessions to Skitrust. Not moved: 2 running in VS Code, 1 already on Skitrust.")
    #expect(
      SessionMoves.summary(
        [report(.skipped(.busy)), report(.failed("disk full"), "Fix it")], to: "Skitrust")
        == "Moved no session to Skitrust. Not moved: 1 busy. Failed: “Fix it”: disk full.")
  }
}

/// The run against real files and a stand-in `claude`.
@MainActor
@Suite("Moving sessions for real")
struct SessionMovesRunTests {

  private let root: URL
  private let a: ClaudeAccount
  private let b: ClaudeAccount
  private let fake: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-moves-\(UUID().uuidString)", directoryHint: .isDirectory)
    a = ClaudeAccount(
      directory: root.appending(path: ".claude-a", directoryHint: .isDirectory), isDefault: false)
    b = ClaudeAccount(
      directory: root.appending(path: ".claude-b", directoryHint: .isDirectory), isDefault: false)
    for account in [a, b] {
      try FileManager.default.createDirectory(
        at: account.directory, withIntermediateDirectories: true)
    }
    fake = root.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  private func heldSession(_ id: String) throws -> (ClaudeSession, SessionMoves.Candidate) {
    let folder = a.directory.appending(path: "projects/-p", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "\(id).jsonl")
    try Data(#"{"type":"user","message":{"role":"user","content":"hi"}}"#.appending("\n").utf8)
      .write(to: file)
    let target = ResumeTarget(
      sessionID: id, cwd: root.path(percentEncoded: false), file: file.path(percentEncoded: false),
      accountDirectory: a.key, accountIsDefault: false)
    let session = ClaudeSession(folder: root, resuming: target)
    session.executableOverride = fake
    let candidate = SessionMoves.Candidate(
      sessionID: id, title: id, transcript: file, account: a, cwd: target.cwd)
    return (session, candidate)
  }

  @Test func anIdleSessionIsStoppedMovedAndRelocated() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, candidate) = try heldSession("s1")
    await session.spawn()
    #expect(session.isProcessRunning)

    let reports = await SessionMoves.run(
      [candidate], to: b, locate: { $0 == "s1" ? session : nil }, liveIDs: { ["s1"] },
      host: { _ in "x" })
    #expect(reports == [SessionMoves.Report(title: "s1", outcome: .moved)])
    #expect(!session.isProcessRunning)
    #expect(session.savedTarget?.accountDirectory == b.key)
    #expect(
      session.savedTarget?.file
        == SessionMover.destination(of: candidate.transcript, to: b).path(percentEncoded: false))
    #expect(
      !FileManager.default.fileExists(atPath: candidate.transcript.path(percentEncoded: false)))
  }

  /// Prompted between the question and the move: left alone.
  @Test func aBusySessionIsSkipped() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, candidate) = try heldSession("s2")
    session.send("keep going")
    defer { session.stop() }
    #expect(session.transcript.isRunning)

    let reports = await SessionMoves.run(
      [candidate], to: b, locate: { $0 == "s2" ? session : nil }, liveIDs: { [] },
      host: { _ in "x" })
    #expect(reports == [SessionMoves.Report(title: "s2", outcome: .skipped(.busy))])
    #expect(
      FileManager.default.fileExists(atPath: candidate.transcript.path(percentEncoded: false)))
  }
}
