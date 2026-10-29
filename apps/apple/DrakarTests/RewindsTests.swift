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

  /// A folder reached through a link (`/var` is `/private/var`): a path the CLI gives
  /// either way is inside it.
  @Test func aLinkedFolderStillHoldsItsFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-rewind-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (rewinds, _) = rewinds()
    rewinds.folder = folder
    let resolved = folder.resolvingSymlinksInPath().path(percentEncoded: false)
    let plain = folder.path(percentEncoded: false)
    #expect(rewinds.shownPath(plain + "a.txt") == "a.txt")
    let real = resolved.hasSuffix("/") ? resolved : resolved + "/"
    #expect(rewinds.shownPath(real + "a.txt") == "a.txt")
  }

  // MARK: Through a session

  /// A stand-in `claude` that answers each `rewind_files` as a process started without
  /// checkpoints does, and nothing else.
  private func fakeClaude() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-rewind-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fake = folder.appending(path: "claude")
    let script = #"""
      #!/bin/sh
      while read -r line; do
        case "$line" in
          *'"rewind_files"'*)
            id=${line#*\"request_id\":\"}; id=${id%%\"*}
            printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{\"canRewind\":false,\"error\":\"File rewinding is not enabled.\"}}}"
            ;;
        esac
      done

      """#
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
  }

  private func session() throws -> AgentSession {
    let fake = try fakeClaude()
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
}
