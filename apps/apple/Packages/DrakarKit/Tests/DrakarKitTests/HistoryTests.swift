import DrakarKit
import Foundation
import Testing

@Suite("Reading a session's history")
struct HistoryTests {

  private func history(_ lines: [String]) -> Transcript {
    Transcript.history(lines: lines.map { Data($0.utf8) })
  }

  /// A real transcript, written by Claude Code 2.1.288 for a session Drakar ran.
  @Test func replaysTheCapturedSession() throws {
    let transcript = Transcript.history(lines: try Fixture.historyWithTool.lines)
    #expect(transcript.title == "Create ahoy.txt")
    #expect(!transcript.isRunning)
    let kinds = transcript.entries.map(\.kind)
    #expect(kinds.count == 3)
    guard kinds.count == 3 else { return }
    #expect(
      kinds[0]
        == .prompt(
          "Use the Bash tool to run: touch ahoy.txt — then reply with the single word: done"))
    guard case .tool(let call) = kinds[1] else {
      Issue.record("entry 1 is \(kinds[1])")
      return
    }
    #expect(call.summary == "touch ahoy.txt")
    #expect(call.result?.isError == false)
    #expect(kinds[2] == .text("done"))
  }

  /// A resumed session goes on from its history: the next prompt and the live stream
  /// land after it.
  @Test func carriesOnLiveAfterTheHistory() throws {
    var transcript = Transcript.history(lines: try Fixture.historyWithTool.lines)
    transcript.addPrompt("Again")
    #expect(transcript.isRunning)
    #expect(transcript.entries.count == 4)
    #expect(transcript.entries.last?.kind == .prompt("Again"))
  }

  /// The shapes surveyed across real transcripts, one each.
  @Test func readsWhatTheHostWroteIntoTheUserTurn() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>The user opened a.swift</ide_opened_file>"},{"type":"text","text":"Fix the bug"}]}}"#,
      #"{"type":"user","message":{"role":"user","content":"<command-message>commit</command-message>\n<command-name>/commit</command-name>\n<command-args>fast</command-args>"}}"#,
      #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Done</local-command-stdout>"}}"#,
      #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Build finished</summary>\n</task-notification>"}}"#,
      #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
      #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}"#,
      #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}"#,
      #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued…"}}"#,
      #"{"type":"attachment","attachment":{}}"#,
    ])
    #expect(
      transcript.entries.map(\.kind) == [
        .prompt("Fix the bug"),
        .prompt("/commit fast"),
        .notice("Done"),
        .notice("Background task: Build finished"),
        .notice("Request interrupted by user"),
        .notice("Earlier conversation compacted"),
      ])
  }

  @Test func takesTheNewestTitle() {
    let transcript = history([
      #"{"type":"ai-title","aiTitle":"Draft"}"#,
      #"{"type":"ai-title","aiTitle":"Refined"}"#,
    ])
    #expect(transcript.title == "Refined")
  }
  /// A transcript has no `result`: a turn that ended says so on its message, block by block.
  @Test func historyKnowsATurnThatEnded() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""}]}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Built. Want me to commit it?"}]}}"#,
    ])
    #expect(transcript.turnEnd == .completed)
    #expect(transcript.closingText?.messageID == "m1")
    #expect(transcript.closingText?.text == "Built. Want me to commit it?")
  }

  @Test func historyWithoutAStopReasonDoesNotGuess() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
    ])
    #expect(transcript.closingText == nil)
  }

  @Test func anInterruptInHistoryHasNone() {
    let transcript = history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Want me to commit it?"}]}}"#,
      #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#,
    ])
    #expect(transcript.closingText == nil)
  }

}

@Suite("Listing sessions on disk")
struct SessionIndexTests {

  /// A home with two accounts, written to a temporary directory.
  private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "drakar-\(UUID().uuidString)")
    func write(_ path: String, _ lines: [String], age: TimeInterval) throws {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }
    try write(
      ".claude/projects/-p-one/aaa.jsonl",
      [
        #"{"type":"ai-title","aiTitle":"Old title"}"#,
        #"{"type":"user","cwd":"/p/one","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"ai-title","aiTitle":"New title"}"#,
        #"{"type":"assistant","cwd":"/p/one","message":{"id":"m","content":[{"type":"text","text":"\"aiTitle\":\"decoy\""}]}}"#,
      ], age: 60)
    try write(
      ".claude-work/projects/-p-two/bbb.jsonl",
      [
        #"{"type":"user","cwd":"/p/two","message":{"role":"user","content":"ship it"}}"#,
        #"{"type":"last-prompt","lastPrompt":"ship it"}"#,
      ], age: 10)
    // Not sessions: a subagent's transcript in a folder, and a file of another kind.
    try write(".claude/projects/-p-one/aaa/subagents/x.jsonl", ["{}"], age: 1)
    try write(".claude/projects/-p-one/notes.txt", ["x"], age: 1)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".claude-empty"), withIntermediateDirectories: true)
    // The registry: one live process for aaa, and a stale file a crash left for bbb.
    try write(
      ".claude/sessions/101.json",
      [#"{"pid":101,"sessionId":"aaa","entrypoint":"claude-vscode","status":"busy"}"#], age: 1)
    try write(".claude-work/sessions/202.json", [#"{"pid":202,"sessionId":"bbb"}"#], age: 1)
    return home
  }

  @Test func findsEveryAccountWithSessions() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let accounts = ClaudeAccount.discover(home: home)
    #expect(accounts.map(\.name) == ["default", "work"])
    #expect(accounts.map(\.isDefault) == [true, false])
    let base = ["CLAUDE_CONFIG_DIR": "/elsewhere", "PATH": "/bin"]
    #expect(accounts[0].environment(base)["CLAUDE_CONFIG_DIR"] == nil)
    #expect(accounts[1].environment(base)["CLAUDE_CONFIG_DIR"]?.hasSuffix(".claude-work/") == true)
  }

  @Test func listsNewestFirstWithTitlesAndFolders() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = SessionIndex.list(accounts: ClaudeAccount.discover(home: home))
    #expect(sessions.map(\.sessionID) == ["bbb", "aaa"])
    #expect(sessions.map(\.cwd) == ["/p/two", "/p/one"])
    // The newest real title, not the decoy inside a message nor the older title.
    #expect(sessions[1].title == "New title")
    // No title yet: the last prompt stands in.
    #expect(sessions[0].title == nil)
    #expect(sessions[0].displayTitle == "ship it")
    #expect(sessions[0].account.name == "work")
  }
}

@Suite("Knowing which sessions are open")
struct LiveSessionTests {

  @Test func marksOnlySessionsWhoseProcessIsAlive() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "drakar-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    for (path, line) in [
      (".claude/projects/-p/aaa.jsonl", #"{"type":"user","cwd":"/p","message":{"content":"x"}}"#),
      (".claude/projects/-p/bbb.jsonl", #"{"type":"user","cwd":"/p","message":{"content":"y"}}"#),
      (".claude/sessions/101.json", #"{"pid":101,"sessionId":"aaa","entrypoint":"claude-vscode"}"#),
      (".claude/sessions/202.json", #"{"pid":202,"sessionId":"bbb"}"#),
    ] {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try line.write(to: url, atomically: true, encoding: .utf8)
    }
    let sessions = SessionIndex.list(
      accounts: ClaudeAccount.discover(home: home), isAlive: { $0 == 101 })
    let live = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0.live) })
    #expect(live["aaa"]??.entrypoint == "claude-vscode")
    #expect(live["bbb"]! == nil)
  }

  /// The same id under a second account is a different transcript, and not open just
  /// because its namesake is.
  @Test func judgesLivenessPerAccount() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "drakar-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    for (path, line) in [
      (".claude/projects/-p/aaa.jsonl", #"{"type":"user","cwd":"/p","message":{"content":"x"}}"#),
      (
        ".claude-work/projects/-p/aaa.jsonl",
        #"{"type":"user","cwd":"/p","message":{"content":"x"}}"#
      ),
      (".claude/sessions/101.json", #"{"pid":101,"sessionId":"aaa"}"#),
    ] {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try line.write(to: url, atomically: true, encoding: .utf8)
    }
    let sessions = SessionIndex.list(
      accounts: ClaudeAccount.discover(home: home), isAlive: { $0 == 101 })
    #expect(sessions.count == 2)
    #expect(Set(sessions.map(\.id)).count == 2)
    #expect(sessions.filter { $0.live != nil }.map(\.account.name) == ["default"])
  }

  @Test func checksTheRealProcessTable() {
    #expect(LiveSession.isAlive(getpid()))
    #expect(!LiveSession.isAlive(0))
  }

  @Test func forksWhenAsked() {
    var command = ClaudeCommand(resumeSessionID: "abc")
    command.forksSession = true
    #expect(command.arguments.suffix(2) == ["--resume=abc", "--fork-session"])
    #expect(
      !ClaudeCommand(forksSessionIgnoredWithoutResume: ()).arguments.contains("--fork-session"))
  }
}

extension ClaudeCommand {
  /// A fork flag with nothing to resume must not reach the command line.
  fileprivate init(forksSessionIgnoredWithoutResume: Void) {
    self.init()
    forksSession = true
  }
}
