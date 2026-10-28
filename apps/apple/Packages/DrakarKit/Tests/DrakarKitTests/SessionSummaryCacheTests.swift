import DrakarKit
import Foundation
import Testing

@Suite("Keeping session summaries between launches")
struct SessionSummaryCacheTests {
  /// A home with one account and one session, its title given by `title`.
  private func makeHome(title: String = "Real title") throws -> (URL, ClaudeAccount, URL) {
    let home = FileManager.default.temporaryDirectory.appending(path: "drakar-\(UUID().uuidString)")
    let file = home.appending(path: ".claude/projects/-p-one/aaa.jsonl")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try write(
      [
        #"{"type":"user","cwd":"/p/one","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"ai-title","aiTitle":"\#(title)"}"#,
      ], to: file)
    return (home, ClaudeAccount.discover(home: home)[0], file)
  }

  private func write(_ lines: [String], to file: URL, date: Date = Date(timeIntervalSince1970: 1e9))
    throws
  {
    try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
  }

  /// A cache claiming `file` is titled "Cached title", at the size and date it has now.
  private func staleTitleCache(for file: URL, account: ClaudeAccount) throws -> SessionSummaryCache
  {
    var summary = try #require(SessionIndex.list(accounts: [account]).first)
    summary.title = "Cached title"
    return SessionSummaryCache([summary])
  }

  @Test func reusesASummaryWhoseFileHasNotChanged() throws {
    let (home, account, file) = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let cache = try staleTitleCache(for: file, account: account)
    let listed = SessionIndex.list(accounts: [account], cache: cache)
    #expect(listed.map(\.title) == ["Cached title"])
  }

  @Test func readsAFileAgainWhenItsSizeChanged() throws {
    let (home, account, file) = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let cache = try staleTitleCache(for: file, account: account)
    // Same date, one more line.
    try write(
      [
        #"{"type":"user","cwd":"/p/one","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"ai-title","aiTitle":"Real title"}"#,
        #"{"type":"ai-title","aiTitle":"Newer title"}"#,
      ], to: file)
    #expect(SessionIndex.list(accounts: [account], cache: cache).map(\.title) == ["Newer title"])
  }

  @Test func readsAFileAgainWhenItsDateChanged() throws {
    let (home, account, file) = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let cache = try staleTitleCache(for: file, account: account)
    // Same size: only the date tells.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2e9)], ofItemAtPath: file.path)
    #expect(SessionIndex.list(accounts: [account], cache: cache).map(\.title) == ["Real title"])
  }

  @Test func carriesTheLiveStateFromTheRegistryNotTheCache() throws {
    let (home, account, _) = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    var summary = try #require(SessionIndex.list(accounts: [account]).first)
    summary.title = "Cached title"
    summary.live = LiveSession(pid: 1, sessionID: "aaa")
    let listed = SessionIndex.list(
      accounts: [account], cache: SessionSummaryCache([summary]), isAlive: { _ in false })
    #expect(listed.map(\.title) == ["Cached title"])
    #expect(listed[0].live == nil)
  }

  @Test func savesAndLoadsEverythingButTheLiveState() throws {
    let (home, account, _) = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    var summary = try #require(SessionIndex.list(accounts: [account]).first)
    summary.lastPrompt = "ship it"
    summary.context = ContextReading(
      usage: TokenUsage(
        input: 1, cacheCreation: 2, cacheRead: 3, output: 4, cacheWriteTTL: .oneHour),
      modelID: "claude-opus-5-5", at: Date(timeIntervalSince1970: 1.5e9))
    summary.modelID = "claude-opus-5-5[1m]"
    summary.awaitsToolResult = true
    summary.pendingQuestion = "Which one?"
    summary.closingAsk = ClosingAsk(kind: .question, text: "Go?", isYesOrNo: true)
    summary.closingMessageID = "m1"
    var live = summary
    live.live = LiveSession(pid: 1, sessionID: "aaa")
    let saved = home.appending(path: "nested/summaries.plist")
    try SessionSummaryCache([live]).save(to: saved)
    let loaded = SessionSummaryCache.load(from: saved)
    #expect(
      loaded.summary(of: summary.file, modified: summary.modified, size: summary.size) == summary)
  }

  @Test func startsEmptyFromAMissingOrUnreadableFile() throws {
    let (home, account, _) = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let summary = try #require(SessionIndex.list(accounts: [account]).first)
    let missing = SessionSummaryCache.load(from: home.appending(path: "none.plist"))
    #expect(
      missing.summary(of: summary.file, modified: summary.modified, size: summary.size) == nil)
    let garbage = home.appending(path: "garbage.plist")
    try Data("not a plist".utf8).write(to: garbage)
    let unreadable = SessionSummaryCache.load(from: garbage)
    #expect(
      unreadable.summary(of: summary.file, modified: summary.modified, size: summary.size) == nil)
  }

  @Test func dropsAFileWrittenByAnotherVersion() throws {
    let (home, account, _) = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let summary = try #require(SessionIndex.list(accounts: [account]).first)
    let saved = home.appending(path: "summaries.plist")
    try SessionSummaryCache([summary]).save(to: saved, version: SessionSummaryCache.version + 1)
    let loaded = SessionSummaryCache.load(from: saved)
    #expect(loaded.summary(of: summary.file, modified: summary.modified, size: summary.size) == nil)
  }
}
