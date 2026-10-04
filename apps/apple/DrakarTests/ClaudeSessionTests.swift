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

  /// What Settings › General picks reaches the process: the `claude` it runs and the
  /// account it runs under. Nothing else fails if the spawn stops reading them.
  @Test func runsTheClaudeAndAccountPickedInSettings() async throws {
    let picked = folder.appending(path: "picked-claude")
    try Data(
      "#!/bin/sh\nprintf '%s' \"$CLAUDE_CONFIG_DIR\" > \"$0.account\"\ncat > /dev/null\n".utf8
    )
    .write(to: picked)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: picked.path)
    let account = folder.appending(path: ".claude-picked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)

    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(picked.path(percentEncoded: false), forKey: PreferenceKey.claudePath)
    defaults.set(account.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    ClaudeChoice.defaults = defaults
    defer {
      ClaudeChoice.defaults = .standard
      defaults.removePersistentDomain(forName: suite)
    }

    let session = ClaudeSession(folder: folder)
    await session.spawn()
    defer { session.stop() }
    #expect(session.executable == picked)
    #expect(session.account?.name == "picked")

    let written = picked.appendingPathExtension("account")
    var configDirectory: String?
    for _ in 0..<50 {
      configDirectory = try? String(contentsOf: written, encoding: .utf8)
      if configDirectory != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(configDirectory == account.path(percentEncoded: false))
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

  /// Yields until the spawn the first prompt started is suspended in one of its awaits.
  private func untilStarting(_ session: ClaudeSession) async {
    for _ in 0..<1000 where session.phase != .starting { await Task.yield() }
    #expect(session.phase == .starting)
  }

  /// Nothing reached the stand-in: no process was started, or none was written to.
  private func expectNothingStarted(_ session: ClaudeSession) async throws {
    try await Task.sleep(for: .seconds(1))
    #expect(!session.isProcessRunning)
    #expect(!FileManager.default.fileExists(atPath: received.path(percentEncoded: false)))
  }

  /// A window closed right after its first prompt leaves no `claude` behind.
  @Test func aStopBeforeTheSpawnRunsStartsNothing() async throws {
    let session = ClaudeSession(folder: folder)
    session.executableOverride = fake
    session.send("hello")
    session.stop()
    try await expectNothingStarted(session)
  }

  /// Closed while the spawn waited on the history or the shell's environment.
  @Test func aStopDuringTheStartStartsNothing() async throws {
    let session = ClaudeSession(folder: folder)
    session.executableOverride = fake
    session.send("hello")
    await untilStarting(session)
    session.stop()
    try await expectNothingStarted(session)
    #expect(session.phase == .exited(status: 0))
  }

  /// Another process opened the session while this one was starting: it is followed, never
  /// written to.
  @Test func aSessionOpenedElsewhereDuringTheStartIsNotWritten() async throws {
    let session = ClaudeSession(folder: folder)
    session.executableOverride = fake
    session.send("hello")
    await untilStarting(session)
    session.isReadOnly = true
    try await expectNothingStarted(session)
    #expect(session.phase == .idle)
    #expect(!session.transcript.isRunning)
  }

  /// A restored row live in a terminal, prompted before the monitor read the registries:
  /// the account's own registry refuses the resume.
  @Test func aSessionLiveInAnotherProcessIsNotResumed() async throws {
    let account = folder.appending(path: ".claude-other", directoryHint: .isDirectory)
    let sessions = account.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let pid = getpid()
    try Data(#"{"pid":\#(pid),"sessionId":"s-live","entrypoint":"cli","status":"idle"}"#.utf8)
      .write(to: sessions.appending(path: "\(pid).json"))
    let file = folder.appending(path: "s-live.jsonl")
    try Data(
      #"{"type":"user","message":{"role":"user","content":"Earlier"}}"#.appending("\n").utf8
    ).write(to: file)
    let target = ResumeTarget(
      sessionID: "s-live", cwd: folder.path(percentEncoded: false),
      file: file.path(percentEncoded: false),
      accountDirectory: account.path(percentEncoded: false), accountIsDefault: false)
    let session = ClaudeSession(folder: folder, resuming: target)
    session.executableOverride = fake
    await session.loadHistory()
    session.send("hello")
    try await expectNothingStarted(session)
    #expect(session.isReadOnly)
    #expect(!session.canSend)
  }

  /// A new session ended during its first turn has no saved target yet; its next prompt
  /// resumes it by the id `system/init` gave, rather than starting another.
  @Test func aFirstTurnThatNeverFinishedResumesItsOwnSession() async throws {
    let script = folder.appending(path: "claude-init")
    let initLine =
      #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-new","model":"m"}"#
    try Data(
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$0.args\"\nprintf '%s\\n' '\(initLine)'\ncat > /dev/null\n"
        .utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let account = folder.appending(path: ".claude-new", directoryHint: .isDirectory)
    let project = account.appending(path: "projects/-tmp", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data(
      #"{"type":"user","message":{"role":"user","content":"one"}}"#.appending("\n").utf8
    ).write(to: project.appending(path: "s-new.jsonl"))

    let session = ClaudeSession(folder: folder)
    session.executableOverride = script
    session.accounts = { [ClaudeAccount(directory: account, isDefault: false)] }
    session.send("one")
    for _ in 0..<50 where session.sessionID != "s-new" {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.sessionID == "s-new")
    session.stop()
    #expect(session.savedTarget == nil)
    session.send("two")
    let args = script.appendingPathExtension("args")
    var runs: [String] = []
    for _ in 0..<50 {
      runs = ((try? String(contentsOf: args, encoding: .utf8)) ?? "").split(separator: "\n")
        .map(String.init)
      if runs.count >= 2 { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    session.stop()
    #expect(runs.count == 2)
    #expect(runs.first?.contains("--resume") == false)
    #expect(runs.last?.contains("--resume=s-new") == true)
    #expect(runs.last?.contains("--fork-session") == false)
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
