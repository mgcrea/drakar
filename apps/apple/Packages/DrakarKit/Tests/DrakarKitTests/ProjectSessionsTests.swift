import DrakarKit
import Foundation
import Testing

@Suite("A project's sessions")
struct ProjectSessionsTests {

  private let account = ClaudeAccount(directory: URL(filePath: "/a/.claude"), isDefault: true)
  private let other = ClaudeAccount(directory: URL(filePath: "/a/.claude-work"), isDefault: false)

  private func summary(
    _ id: String, cwd: String, minutesAgo: Double, live: Bool = false,
    account: ClaudeAccount? = nil
  ) -> SessionSummary {
    let account = account ?? self.account
    var summary = SessionSummary(
      sessionID: id, account: account,
      file: account.directory.appending(path: "projects/x/\(id).jsonl"),
      modified: Date(timeIntervalSinceNow: -minutesAgo * 60), size: 1)
    summary.cwd = cwd
    summary.live = live ? LiveSession(pid: 7, sessionID: id, status: "busy") : nil
    return summary
  }

  @Test func splitsLiveFromEndedAndLeavesTheAttachedOut() {
    let groups = ProjectSessions.group(
      [
        summary("old", cwd: "/w/drakar", minutesAgo: 90),
        summary("live", cwd: "/w/drakar/apps", minutesAgo: 5, live: true),
        summary("here", cwd: "/w/drakar", minutesAgo: 1),
        summary("new", cwd: "/w/drakar", minutesAgo: 2),
        summary("elsewhere", cwd: "/w/other", minutesAgo: 1),
      ],
      folder: "/w/drakar", otherFolders: [], attached: ["here"], inOtherWindows: [])
    #expect(groups.elsewhere.map(\.sessionID) == ["live"])
    #expect(groups.ended.map(\.sessionID) == ["new", "old"])
  }

  @Test func aDeeperWindowTakesItsSessions() {
    let groups = ProjectSessions.group(
      [summary("deep", cwd: "/w/drakar/apps/apple", minutesAgo: 1)],
      folder: "/w/drakar", otherFolders: ["/w/drakar/apps/apple"], attached: [],
      inOtherWindows: [])
    #expect(groups.ended.isEmpty && groups.elsewhere.isEmpty)
  }

  /// Open in another Drakar window: Drakar's children are not in the registry, so the
  /// window index says it is live.
  @Test func anotherDrakarWindowCountsAsElsewhere() {
    let groups = ProjectSessions.group(
      [summary("theirs", cwd: "/w/drakar", minutesAgo: 30)], folder: "/w/drakar",
      otherFolders: [], attached: [], inOtherWindows: ["theirs"])
    #expect(groups.elsewhere.map(\.sessionID) == ["theirs"])
  }

  /// One id under two accounts is one conversation: one row, the newer transcript.
  @Test func oneRowPerSessionID() {
    let groups = ProjectSessions.group(
      [
        summary("s", cwd: "/w/drakar", minutesAgo: 10),
        summary("s", cwd: "/w/drakar", minutesAgo: 3, account: other),
      ],
      folder: "/w/drakar", otherFolders: [], attached: [], inOtherWindows: [])
    #expect(groups.ended.count == 1)
    #expect(groups.ended.first?.account == other)
  }

  /// The index lists only folders encoded under the project, confirms by cwd, and reads
  /// each one's context from the same mapped file.
  @Test func listsAFoldersSessionsWithTheirContext() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "index-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    defer { try? FileManager.default.removeItem(at: home) }
    func write(_ folder: String, _ id: String, cwd: String) throws {
      let dir = account.directory.appending(path: "projects/\(folder)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let lines = [
        #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":"go"}}"#,
        #"{"type":"assistant","cwd":"\#(cwd)","message":{"id":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}"#,
      ]
      try Data(lines.joined(separator: "\n").utf8).write(to: dir.appending(path: "\(id).jsonl"))
    }
    try write("-w-drakar", "a", cwd: "/w/drakar")
    try write("-w-drakar-apps", "b", cwd: "/w/drakar/apps")
    try write("-w-drakar-old", "c", cwd: "/w/drakar-old")
    try write("-w-other", "d", cwd: "/w/other")
    let listed = SessionIndex.list(accounts: [account], under: "/w/drakar", isAlive: { _ in false })
    #expect(Set(listed.map(\.sessionID)) == ["a", "b"])
    #expect(listed.first?.context?.total == 6)
    #expect(listed.allSatisfy { !$0.awaitsToolResult })
  }

  /// Whether the newest turn waits on a tool is read with the summary, once.
  @Test func aSummaryKnowsAnUnansweredToolCall() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "tool-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let account = ClaudeAccount(directory: FileManager.default.temporaryDirectory, isDefault: true)
    let calling =
      #"{"type":"assistant","cwd":"/w","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#
    try Data(calling.utf8).write(to: file)
    #expect(SessionIndex.summary(of: file, account: account)?.awaitsToolResult == true)
    let answered =
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#
    try Data((calling + "\n" + answered).utf8).write(to: file)
    #expect(SessionIndex.summary(of: file, account: account)?.awaitsToolResult == false)
  }
}
