import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Watching sessions on disk")
struct SessionMonitorTests {

  @Test func aTranscriptWrittenAppearsUnderItsProject() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: account.directory.appending(path: "sessions"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.summaries(under: "/w/drakar").isEmpty)

    try Data(#"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#.utf8)
      .write(to: projects.appending(path: "s1.jsonl"))
    for _ in 0..<40 where monitor.summaries(under: "/w/drakar").isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID) == ["s1"])
    monitor.stop()
  }

  private func fixture() throws -> (home: URL, account: ClaudeAccount, projects: URL) {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: account.directory.appending(path: "sessions"), withIntermediateDirectories: true)
    return (home, account, projects)
  }

  private static let line =
    #"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#

  @Test func aRegistryWriteUpdatesTheLiveIDs() async throws {
    let (home, account, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.liveIDs.isEmpty)
    let json =
      #"{"pid":\#(getpid()),"sessionId":"live1","cwd":"/w/drakar","entrypoint":"cli","status":"idle"}"#
    try Data(json.utf8).write(
      to: account.directory.appending(path: "sessions/\(getpid()).json"))
    for _ in 0..<40 where monitor.liveIDs.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(monitor.liveIDs == ["live1"])
    monitor.stop()
  }

  @Test func aDeletedTranscriptDisappears() async throws {
    let (home, account, projects) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = projects.appending(path: "gone.jsonl")
    try Data(Self.line.utf8).write(to: file)
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID) == ["gone"])
    try FileManager.default.removeItem(at: file)
    for _ in 0..<40 where !monitor.summaries(under: "/w/drakar").isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(monitor.summaries(under: "/w/drakar").isEmpty)
    monitor.stop()
  }

  /// `~/.claude` may be a link: the listing spells paths through it, FSEvents reports them
  /// resolved. One transcript is still one row.
  @Test func aTranscriptListedThenWrittenIsOneRow() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let real = home.appending(path: "claude-real", directoryHint: .isDirectory)
    let projects = real.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: real.appending(path: "sessions"), withIntermediateDirectories: true)
    let link = home.appending(path: ".claude")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let account = ClaudeAccount(directory: link, isDefault: true)
    let file = projects.appending(path: "once.jsonl")
    try Data(Self.line.utf8).write(to: file)
    let monitor = SessionMonitor(accounts: [account])
    await monitor.start()
    #expect(monitor.summaries(under: "/w/drakar").count == 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + #"{"type":"ai-title","aiTitle":"Again"}"#).utf8))
    try handle.close()
    for _ in 0..<40
    where !monitor.summaries(under: "/w/drakar").contains(where: { $0.title == "Again" }) {
      try await Task.sleep(for: .milliseconds(100))
    }
    // Long enough for a second, differently spelled entry to land too.
    try await Task.sleep(for: .milliseconds(500))
    #expect(monitor.summaries(under: "/w/drakar").map(\.title) == ["Again"])
    monitor.stop()
  }

  /// A project window opening re-reads none of the transcripts the launch already read: on a
  /// busy Mac that was up to 200 files, 0.8 s cold, before its sidebar settled.
  @Test func includeReusesTheSummariesAlreadyRead() async throws {
    let (home, account, projects) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = projects.appending(path: "kept.jsonl")
    let date = Date(timeIntervalSince1970: 1e9)
    func write(title: String) throws {
      try Data((Self.line + "\n" + #"{"type":"ai-title","aiTitle":"\#(title)"}"#).utf8)
        .write(to: file)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }
    try write(title: "Old")
    let monitor = SessionMonitor(accounts: [account])
    let listed = try #require(SessionIndex.list(accounts: [account]).first).file
    await monitor.load(listed, account: account)
    // Same size, same date: as far as any listing can tell, unchanged.
    try write(title: "New")
    await monitor.include(folder: "/w/drakar")
    #expect(monitor.summaries(under: "/w/drakar").map(\.title) == ["Old"])
  }

  /// An account only the login shell names (`CLAUDE_CONFIG_DIR`), with one session under
  /// `/w/drakar`, and a gate the test opens when the shell should answer.
  private func shellAccount(in home: URL) throws -> ClaudeAccount {
    let account = ClaudeAccount(directory: home.appending(path: "shell-config"), isDefault: false)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: account.directory.appending(path: "sessions"), withIntermediateDirectories: true)
    try Data(Self.line.utf8).write(to: projects.appending(path: "theirs.jsonl"))
    return account
  }

  private func ids(_ monitor: SessionMonitor) -> Set<String> {
    Set(monitor.summaries(under: "/w/drakar").map(\.sessionID))
  }

  /// A slow `.zshrc` held home's spinner for as long as the shell took, up to 5 s, though
  /// only an account the shell alone names needs its answer.
  @Test func startListsBeforeTheShellAnswers() async throws {
    let (home, account, projects) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data(Self.line.utf8).write(to: projects.appending(path: "mine.jsonl"))
    let other = try shellAccount(in: home)
    let (answer, answered) = AsyncStream<Void>.makeStream()
    let monitor = SessionMonitor(
      discover: { [account] },
      late: {
        for await _ in answer { break }
        return [account, other]
      })
    await monitor.start()
    #expect(monitor.isLoaded)
    #expect(ids(monitor) == ["mine"])
    answered.yield()
    for _ in 0..<40 where ids(monitor).count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ids(monitor) == ["mine", "theirs"])
    // Watched like the others: a session it writes later shows up too.
    try Data(Self.line.utf8).write(
      to: other.directory.appending(path: "projects/-w-drakar/later.jsonl"))
    for _ in 0..<40 where ids(monitor).count < 3 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ids(monitor) == ["mine", "theirs", "later"])
    monitor.stop()
  }

  /// The shell's account read once is not read again at the next launch: it goes in the
  /// saved summaries like the others, and stays there through each launch's own early
  /// save, made before the shell answered. (Checked on the file: a launch's watchers may
  /// read a transcript again whenever FSEvents reports it, so what a monitor shows after a
  /// write proves nothing about the cache.)
  @Test func theShellsAccountIsKeptForTheNextLaunch() async throws {
    let (home, account, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let other = try shellAccount(in: home)
    let cacheFile = home.appending(path: "summaries.plist")
    // A slow shell: it answers once the launch listing is done.
    func launch() async throws {
      let (answer, answered) = AsyncStream<Void>.makeStream()
      let monitor = SessionMonitor(
        discover: { [account] },
        late: {
          for await _ in answer { break }
          return [other]
        }, cacheFile: cacheFile)
      await monitor.start()
      answered.yield()
      for _ in 0..<40 where !ids(monitor).contains("theirs") {
        try await Task.sleep(for: .milliseconds(100))
      }
      monitor.stop()
      await monitor.summariesSaved()
    }
    func savesTheirs() throws -> Bool {
      let listed = try #require(SessionIndex.list(accounts: [other]).first)
      return SessionSummaryCache.load(from: cacheFile)
        .summary(of: listed.file, modified: listed.modified, size: listed.size) != nil
    }
    try await launch()
    #expect(try savesTheirs())
    try await launch()
    #expect(try savesTheirs())
  }

  @Test func anOpenProjectGetsTheShellsAccountWhenItAnswers() async throws {
    let (home, account, projects) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data(Self.line.utf8).write(to: projects.appending(path: "mine.jsonl"))
    let other = try shellAccount(in: home)
    let (answer, answered) = AsyncStream<Void>.makeStream()
    let monitor = SessionMonitor(
      discover: { [account] },
      late: {
        for await _ in answer { break }
        return [other]
      })
    await monitor.include(folder: "/w/drakar")
    #expect(ids(monitor) == ["mine"])
    answered.yield()
    for _ in 0..<40 where ids(monitor).count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ids(monitor) == ["mine", "theirs"])
  }

  @Test func includeWaitsForAccountDiscovery() async throws {
    let (home, account, projects) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data(Self.line.utf8).write(to: projects.appending(path: "old.jsonl"))
    let monitor = SessionMonitor(discover: {
      try? await Task.sleep(for: .milliseconds(300))
      return [account]
    })
    await monitor.include(folder: "/w/drakar")
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID) == ["old"])
  }
}

/// What FSEvents reports as one batch is read, merged and announced once: each announcement
/// refreshes attention across every window, and agents writing together used to cost one
/// refresh per file.
@MainActor
@Suite("Transcripts written together")
struct SessionMonitorBatchTests {
  @Test func aBatchOfWritesIsAnnouncedOnce() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID())")
    let account = ClaudeAccount(directory: home.appending(path: ".claude"), isDefault: true)
    let projects = account.directory.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    var paths: [String] = []
    for id in ["s1", "s2", "s3"] {
      let file = projects.appending(path: "\(id).jsonl")
      try Data(#"{"type":"user","cwd":"/w/drakar","message":{"role":"user","content":"go"}}"#.utf8)
        .write(to: file)
      paths.append(file.path(percentEncoded: false))
    }

    let monitor = SessionMonitor(accounts: [account])
    var announced: [[String]] = []
    monitor.written = { announced.append($0.map(\.sessionID).sorted()) }
    monitor.changed(paths, in: account)
    for _ in 0..<40 where announced.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(announced == [["s1", "s2", "s3"]])
    #expect(monitor.summaries(under: "/w/drakar").map(\.sessionID).sorted() == ["s1", "s2", "s3"])
  }
}
