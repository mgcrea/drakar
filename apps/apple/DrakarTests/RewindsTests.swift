import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Rewinding a session's code")
struct RewindsTests {
  /// What the rewinds sent, in order, and whether a process took it.
  private final class Sent {
    var commands: [AgentCommand] = []
    var takes = true
  }

  private func rewinds(timeout: Duration = .seconds(10)) -> (Rewinds, Sent) {
    let sent = Sent()
    let rewinds = Rewinds(
      timeout: timeout,
      send: {
        sent.commands.append($0)
        return sent.takes
      })
    return (rewinds, sent)
  }

  private static let request = Rewinds.Request(messageID: "u-a", thenFork: false)

  private static func dryRun(files: [String] = ["/p/a/x.swift"]) -> RewindResult {
    RewindResult(
      .object([
        "canRewind": .bool(true), "filesChanged": .array(files.map(JSONValue.string)),
        "insertions": .number(1), "deletions": .number(2),
      ]))!
  }

  private static let rewound = RewindResult(
    .object(["canRewind": .bool(true), "skippedLinks": .number(0)]))!

  @Test func aDryRunThenARewind() {
    let (rewinds, sent) = rewinds()
    rewinds.start(Self.request)
    #expect(rewinds.request == Self.request)
    #expect(rewinds.phase == .checking)
    #expect(sent.commands == [.rewindFiles(userMessageID: "u-a", dryRun: true)])
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    #expect(rewinds.phase == .ready(Self.dryRun()))
    rewinds.confirm()
    #expect(rewinds.phase == .rewinding)
    #expect(sent.commands.last == .rewindFiles(userMessageID: "u-a", dryRun: false))
    // A reply for another message, or a second dry run's, is not this one's.
    rewinds.answered(.rewindAnswered(userMessageID: "u-b", dryRun: false, Self.rewound))
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    #expect(rewinds.phase == .rewinding)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound))
    #expect(rewinds.phase == .done)
    #expect(rewinds.request == Self.request)
    #expect(sent.commands.count == 2)
  }

  /// The dry run is the authority on a prompt's checkpoint: no Rewind follows its refusal.
  @Test func noCheckpointFails() {
    let (rewinds, sent) = rewinds()
    rewinds.start(Self.request)
    let refusal = RewindResult(
      .object([
        "canRewind": .bool(false), "error": .string("No file checkpoint found for this message."),
      ]))
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, refusal))
    #expect(rewinds.phase == .failed(RewindCopy.noCheckpoint))
    rewinds.confirm()
    #expect(rewinds.phase == .failed(RewindCopy.noCheckpoint))
    #expect(sent.commands == [.rewindFiles(userMessageID: "u-a", dryRun: true)])
  }

  /// A real rewind refused for want of a checkpoint says so too.
  @Test func aRewindWithNoCheckpointSaysSo() {
    let (rewinds, _) = rewinds()
    rewinds.start(Self.request)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    rewinds.confirm()
    rewinds.answered(
      .rewindAnswered(
        userMessageID: "u-a", dryRun: false,
        RewindResult(refusal: "No file checkpoint found for this message.")))
    #expect(rewinds.phase == .failed(RewindCopy.noCheckpoint))
  }

  /// A turn that starts while the sheet waits makes its list stale: no Rewind follows, and the
  /// sheet says why rather than that a rewind failed.
  @Test func aTurnFailsTheSheet() {
    let (rewinds, sent) = rewinds()
    rewinds.start(Self.request)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    rewinds.turnStarted()
    #expect(rewinds.phase == .failed(RewindCopy.turnStarted))
    rewinds.confirm()
    #expect(sent.commands == [.rewindFiles(userMessageID: "u-a", dryRun: true)])
    // A dry run still out: its late reply shows nothing either.
    rewinds.start(Self.request)
    rewinds.turnStarted()
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    #expect(rewinds.phase == .failed(RewindCopy.turnStarted))
    // A rewind already sent is left to its reply.
    rewinds.cancel()
    rewinds.start(Self.request)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    rewinds.confirm()
    rewinds.turnStarted()
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound))
    #expect(rewinds.phase == .done)
  }

  /// Any other refusal is the plain failure line, the CLI's words kept beside it.
  @Test func anotherRefusalFailsWithItsWords() {
    let (rewinds, _) = rewinds()
    rewinds.start(Self.request)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    rewinds.confirm()
    rewinds.answered(
      .rewindAnswered(
        userMessageID: "u-a", dryRun: false, RewindResult(refusal: "Failed to rewind: EACCES")))
    #expect(rewinds.phase == .failed(RewindCopy.failed))
    #expect(rewinds.detail == "Failed to rewind: EACCES")
  }

  /// The process went between the dry run and Rewind: nothing took the request.
  @Test func aRewindWithNoProcessFails() {
    let (rewinds, sent) = rewinds()
    rewinds.start(Self.request)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    sent.takes = false
    rewinds.confirm()
    #expect(rewinds.phase == .failed(RewindCopy.failed))
    // Nothing waits on a reply: a late one changes nothing.
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound))
    #expect(rewinds.phase == .failed(RewindCopy.failed))
    // Nor does a dry run with no process spin.
    let (other, refused) = self.rewinds()
    refused.takes = false
    other.start(Self.request)
    #expect(other.phase == .failed(RewindCopy.failed))
  }

  /// A reply that never comes, to the dry run or to Rewind, ends in the failure line.
  @Test func noReplyFails() async throws {
    let (rewinds, _) = rewinds(timeout: .milliseconds(50))
    rewinds.start(Self.request)
    #expect(rewinds.phase == .checking)
    // Polled: the main actor is shared with the other suites, so the timeout runs late.
    for _ in 0..<100 where rewinds.phase == .checking {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(rewinds.phase == .failed(RewindCopy.failed))
    // Too late: the sheet already said it failed.
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    #expect(rewinds.phase == .failed(RewindCopy.failed))

    let (real, _) = self.rewinds(timeout: .milliseconds(50))
    real.start(Self.request)
    real.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    real.confirm()
    for _ in 0..<100 where real.phase == .rewinding {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(real.phase == .failed(RewindCopy.failed))
  }

  /// A rewind's success after its timeout: the files were written all the same. The sheet
  /// still on its failure moves on to done (so a fork that waits on it follows), and the
  /// session is told a rewind took; a dry run's late reply stays ignored.
  @Test func aLateRewindSuccessStillTakes() async throws {
    let (rewinds, _) = rewinds(timeout: .milliseconds(50))
    rewinds.start(Rewinds.Request(messageID: "u-a", thenFork: true))
    #expect(!rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun())))
    rewinds.confirm()
    // Polled: the main actor is shared with the other suites, so the timeout runs late.
    for _ in 0..<100 where rewinds.phase == .rewinding {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(rewinds.phase == .failed(RewindCopy.failed))
    // A dry run's reply, or another message's, is not the rewind's.
    #expect(!rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun())))
    #expect(!rewinds.answered(.rewindAnswered(userMessageID: "u-b", dryRun: false, Self.rewound)))
    #expect(rewinds.phase == .failed(RewindCopy.failed))
    #expect(rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound)))
    #expect(rewinds.phase == .done)
    #expect(rewinds.request == Rewinds.Request(messageID: "u-a", thenFork: true))
    // Once only.
    #expect(!rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound)))

    // The sheet closed on the failure: still a rewind that took, and nothing reopens.
    let (closed, _) = self.rewinds(timeout: .milliseconds(50))
    closed.start(Self.request)
    closed.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    closed.confirm()
    for _ in 0..<100 where closed.phase == .rewinding {
      try await Task.sleep(for: .milliseconds(50))
    }
    closed.cancel()
    #expect(closed.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound)))
    #expect(closed.phase == nil)
    #expect(closed.request == nil)

    // A sheet started again since, its list shown: the files just changed under it, so no
    // Rewind follows from that list.
    let (again, sent) = self.rewinds(timeout: .milliseconds(50))
    again.start(Self.request)
    again.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    again.confirm()
    for _ in 0..<100 where again.phase == .rewinding {
      try await Task.sleep(for: .milliseconds(50))
    }
    again.cancel()
    again.start(Self.request)
    again.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    #expect(again.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound)))
    #expect(again.phase == .failed(RewindCopy.failed))
    again.confirm()
    #expect(sent.commands.count == 3)

    // A late refusal changes nothing, and a process gone answers nothing late.
    let (refused, _) = self.rewinds(timeout: .milliseconds(50))
    refused.start(Self.request)
    refused.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    refused.confirm()
    for _ in 0..<100 where refused.phase == .rewinding {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(
      !refused.answered(
        .rewindAnswered(
          userMessageID: "u-a", dryRun: false, RewindResult(refusal: "Failed to rewind: EACCES"))))
    #expect(refused.phase == .failed(RewindCopy.failed))
    #expect(refused.detail == nil)
    let (gone, _) = self.rewinds(timeout: .milliseconds(50))
    gone.start(Self.request)
    gone.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    gone.confirm()
    for _ in 0..<100 where gone.phase == .rewinding {
      try await Task.sleep(for: .milliseconds(50))
    }
    gone.processEnded()
    #expect(!gone.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound)))
    #expect(gone.phase == .failed(RewindCopy.failed))
  }

  /// The dry run's own timeout never fails a rewind that followed it.
  @Test func aDryRunsTimeoutLeavesTheRewindAlone() async throws {
    // Wide margins: the main actor is shared with the other suites.
    let (rewinds, _) = rewinds(timeout: .seconds(2))
    rewinds.start(Self.request)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    try await Task.sleep(for: .seconds(1))
    rewinds.confirm()
    // Past the dry run's deadline (2 s), short of the rewind's (3 s).
    try await Task.sleep(for: .milliseconds(1400))
    #expect(rewinds.phase == .rewinding)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: false, Self.rewound))
    #expect(rewinds.phase == .done)
  }

  @Test func cancelSendsNothingMore() {
    let (rewinds, sent) = rewinds()
    rewinds.start(Self.request)
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    rewinds.cancel()
    #expect(rewinds.phase == nil)
    #expect(rewinds.request == nil)
    rewinds.confirm()
    #expect(sent.commands == [.rewindFiles(userMessageID: "u-a", dryRun: true)])
    // A dry run cancelled while out: its late reply opens nothing.
    rewinds.start(Self.request)
    rewinds.cancel()
    rewinds.answered(.rewindAnswered(userMessageID: "u-a", dryRun: true, Self.dryRun()))
    #expect(rewinds.phase == nil)
    #expect(rewinds.request == nil)
  }

  @Test func pathsOutsideTheFolderStayWhole() {
    let (rewinds, _) = rewinds()
    #expect(rewinds.shownPath("/p/a/x.swift") == "/p/a/x.swift")
    rewinds.folder = URL(filePath: "/p/a", directoryHint: .isDirectory)
    #expect(rewinds.shownPath("/p/a/x.swift") == "x.swift")
    #expect(rewinds.shownPath("/p/a/Sources/y.swift") == "Sources/y.swift")
    #expect(rewinds.shownPath("/p/a/../a/z.swift") == "z.swift")
    // A sibling whose name starts like the folder's is not inside it.
    #expect(rewinds.shownPath("/p/ab/y.swift") == "/p/ab/y.swift")
    #expect(rewinds.shownPath("/Users/me/.zshrc") == "/Users/me/.zshrc")
    #expect(rewinds.shownPath("/p/a/../b/w.swift") == "/p/b/w.swift")
    rewinds.folder = URL(filePath: "/p/a")
    #expect(rewinds.shownPath("/p/a/x.swift") == "x.swift")
  }

  /// A session folder reached through a link: a file the CLI names by the real folder is
  /// inside it, a missing one (what a rewind restores) too, and the other way round.
  @Test func aLinkedFolderStillHoldsItsFiles() throws {
    let scratch = FileManager.default.temporaryDirectory.appending(
      path: "drakar-rewind-\(UUID().uuidString)", directoryHint: .isDirectory)
    let real = scratch.appending(path: "real", directoryHint: .isDirectory)
    let link = scratch.appending(path: "link", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: scratch) }
    try Data("a".utf8).write(to: real.appending(path: "a.txt"))
    let realPath = real.path(percentEncoded: false)
    let linkPath = link.path(percentEncoded: false)
    let (rewinds, _) = rewinds()
    rewinds.folder = link
    #expect(rewinds.shownPath(realPath + "a.txt") == "a.txt")
    #expect(rewinds.shownPath(realPath + "gone/b.txt") == "gone/b.txt")
    // `/var` is `/private/var`: the temporary folder is reached through a link too.
    if realPath.hasPrefix("/var/") {
      #expect(rewinds.shownPath("/private" + realPath + "gone.txt") == "gone.txt")
    }
    #expect(rewinds.shownPath(scratch.path(percentEncoded: false) + "c.txt").hasSuffix("/c.txt"))
    rewinds.folder = real
    #expect(rewinds.shownPath(linkPath + "gone.txt") == "gone.txt")
  }

  // MARK: Through a session

  private static let notEnabledReply =
    #"{\"canRewind\":false,\"error\":\"File rewinding is not enabled.\"}"#
  private static let filesReply =
    #"{\"canRewind\":true,\"filesChanged\":[\"/p/a.txt\"],\"insertions\":0,\"deletions\":1}"#

  /// A stand-in `claude` that answers each `rewind_files` with `reply` (by default as a
  /// process started without checkpoints does), and nothing else. Every line it is sent goes
  /// to `$0.stdin`.
  private func fakeClaude(reply: String = notEnabledReply) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-rewind-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fake = folder.appending(path: "claude")
    let script = #"""
      #!/bin/sh
      while read -r line; do
        printf '%s\n' "$line" >> "$0.stdin"
        case "$line" in
          *'"rewind_files"'*)
            id=${line#*\"request_id\":\"}; id=${id%%\"*}
            printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":REPLY}}"
            ;;
        esac
      done

      """#.replacingOccurrences(of: "REPLY", with: reply)
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  private func session(reply: String = notEnabledReply) throws -> AgentSession {
    let fake = try fakeClaude(reply: reply)
    let session = AgentSession(folder: fake.deletingLastPathComponent())
    session.executableOverride = fake
    session.accounts = { [] }
    session.makeTransport = { AgentProcess($0) }
    return session
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// A process that says rewinding is off offers no code rewind again.
  @Test func notEnabledIsRemembered() async throws {
    let session = try session()
    defer { session.stop() }
    await session.spawn()
    #expect(!session.rewindNotEnabled)
    session.rewinds.start(Self.request)
    #expect(session.rewinds.phase == .checking)
    try await waitFor { session.rewinds.phase != .checking }
    #expect(session.rewinds.phase == .failed(RewindCopy.failed))
    #expect(session.rewinds.detail == "File rewinding is not enabled.")
    #expect(session.rewindNotEnabled)
    #expect(!session.canRewindCode("u-a"))
  }

  @Test func codeNeedsALiveProcess() async throws {
    let session = try session()
    defer { session.stop() }
    #expect(!session.canRewindCode("u-a"))
    // Driven before any turn: a resumed process answers for earlier prompts.
    await session.spawn()
    #expect(session.canRewindCode("u-a"))
    session.rewinds.start(Self.request)
    try await waitFor { session.rewindNotEnabled }
    #expect(!session.canRewindCode("u-a"))
    // A new process has said nothing yet.
    session.stop()
    #expect(!session.canRewindCode("u-a"))
    await session.spawn()
    #expect(!session.rewindNotEnabled)
    #expect(session.canRewindCode("u-a"))
    // The stand-in never ends the turn.
    session.send("hi")
    #expect(session.transcript.isRunning)
    #expect(!session.canRewindCode("u-a"))
  }

  /// A rewind that took leaves the extension's line in the transcript, once.
  @Test func aRewindThatTookLeavesANote() async throws {
    let session = try session(reply: Self.filesReply)
    defer { session.stop() }
    await session.spawn()
    session.rewinds.start(Self.request)
    try await waitFor { session.rewinds.phase != .checking }
    session.rewinds.confirm()
    try await waitFor { session.rewinds.phase == .done }
    #expect(session.rewinds.phase == .done)
    let notes = session.transcript.entries.filter { $0.kind == .notice(RewindCopy.succeeded) }
    #expect(notes.count == 1)
  }

  /// The code items stay offered through a turn, for the menu to show them disabled.
  @Test func aTurnKeepsTheCodeOffered() async throws {
    let session = try session()
    defer { session.stop() }
    #expect(!session.offersCodeRewind)
    await session.spawn()
    #expect(session.offersCodeRewind)
    // The stand-in never ends the turn.
    session.send("hi")
    #expect(session.offersCodeRewind)
    #expect(!session.canRewindCode("u-a"))
  }

  /// A prompt sent while the sheet shows its list fails the sheet, and Rewind sends nothing.
  @Test func aPromptFailsAReadySheet() async throws {
    let session = try session(reply: Self.filesReply)
    defer { session.stop() }
    await session.spawn()
    session.rewinds.start(Self.request)
    try await waitFor { session.rewinds.phase != .checking }
    guard case .ready = session.rewinds.phase else {
      Issue.record("not ready: \(String(describing: session.rewinds.phase))")
      return
    }
    session.send("hi")
    #expect(session.rewinds.phase == .failed(RewindCopy.turnStarted))
    session.rewinds.confirm()
    // Given time to arrive, the stand-in got the dry run alone.
    try await Task.sleep(for: .milliseconds(300))
    let fake = try #require(session.executableOverride)
    let received =
      (try? String(contentsOf: fake.appendingPathExtension("stdin"), encoding: .utf8)) ?? ""
    #expect(received.components(separatedBy: "rewind_files").count - 1 == 1)
  }
}
