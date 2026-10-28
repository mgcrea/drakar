import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// A subagent's own file followed for its card, in a temporary projects folder holding the
/// session's transcript `s.jsonl`. The file's lines are the kit's captured `subagent-file`
/// fixture, read from the repo: its prompt, its Bash call with the stop's rejection, and the
/// interruption that ends it.
@MainActor
@Suite("A subagent card's own file")
struct SubagentFeedTests {
  private let projects: URL
  private let transcriptFile: URL

  init() throws {
    projects = FileManager.default.temporaryDirectory.appending(
      path: "drakar-feed-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    transcriptFile = projects.appending(path: "s.jsonl")
    try Data().write(to: transcriptFile)
  }

  private func cleanUp() {
    try? FileManager.default.removeItem(at: projects)
  }

  /// The fixture's lines, each with its newline.
  private static func fixtureLines() throws -> [Data] {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/subagent-file.jsonl")
    let text = try String(contentsOf: fixture, encoding: .utf8)
    return text.split(separator: "\n").map { Data(($0 + "\n").utf8) }
  }

  /// Writes `lines` at `path` under the projects folder, its folders made.
  @discardableResult
  private func plant(_ path: String, _ lines: [Data]) throws -> URL {
    let file = projects.appending(path: path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(lines.joined()).write(to: file)
    return file
  }

  private func append(_ line: Data, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  private static let prompt =
    "Run exactly this command with the Bash tool in the foreground (run_in_background: false): python3 -c 'import time; time.sleep(90)' and then reply done."

  @Test func readsTheFile() async throws {
    defer { cleanUp() }
    try plant("s/subagents/agent-x.jsonl", try Self.fixtureLines())
    let feed = SubagentFeed(agentID: "x", transcriptFile: transcriptFile)
    #expect(feed.transcript == nil)
    await feed.refresh()
    let kinds = feed.transcript?.entries.map(\.kind) ?? []
    #expect(kinds.count == 3)
    guard kinds.count == 3 else { return }
    #expect(kinds[0] == .prompt(Self.prompt))
    guard case .tool(let call) = kinds[1] else {
      Issue.record("entry 1 is \(kinds[1])")
      return
    }
    #expect(call.name == "Bash")
    #expect(call.result?.isError == true)
    #expect(kinds[2] == .notice("Request interrupted by user for tool use"))
    // The prompt it opens with is the card's own, cut short: it is not drawn again.
    #expect(feed.drawn?.top.map(\.kind) == Array(kinds.dropFirst()))
  }

  /// A file holding only its prompt has nothing the card does not show already.
  @Test func aPromptAloneIsNotDrawn() async throws {
    defer { cleanUp() }
    try plant("s/subagents/agent-x.jsonl", Array(try Self.fixtureLines().prefix(2)))
    let feed = SubagentFeed(agentID: "x", transcriptFile: transcriptFile)
    await feed.refresh()
    #expect(feed.transcript == nil)
    #expect(feed.drawn == nil)
  }

  @Test func followsAppendedLines() async throws {
    defer { cleanUp() }
    let lines = try Self.fixtureLines()
    let file = try plant("s/subagents/agent-x.jsonl", Array(lines.dropLast()))
    let feed = SubagentFeed(agentID: "x", transcriptFile: transcriptFile)
    await feed.refresh()
    #expect(feed.transcript?.entries.count == 2)
    try append(try #require(lines.last), to: file)
    await feed.refresh()
    #expect(
      feed.transcript?.entries.last?.kind == .notice("Request interrupted by user for tool use"))
    #expect(feed.transcript?.entries.count == 3)
  }

  @Test func noFileIsNil() async throws {
    defer { cleanUp() }
    let feed = SubagentFeed(agentID: "x", transcriptFile: transcriptFile)
    await feed.refresh()
    #expect(feed.transcript == nil)
  }

  /// A file found is kept; the folders beside the session's are looked through once, on the
  /// first refresh (a fork's file is already there when its card opens), and after that only
  /// the session's own folder is looked at.
  @Test func looksBesideTheSessionOnlyOnce() async throws {
    defer { cleanUp() }
    let lines = try Self.fixtureLines()
    let feed = SubagentFeed(agentID: "x", transcriptFile: transcriptFile)
    await feed.refresh()
    #expect(feed.transcript == nil)
    try plant("t/subagents/agent-x.jsonl", lines)
    await feed.refresh()
    #expect(feed.transcript == nil)
    try plant("s/subagents/agent-x.jsonl", Array(lines.prefix(3)))
    await feed.refresh()
    #expect(feed.transcript?.entries.first?.kind == .prompt(Self.prompt))
    #expect(feed.transcript?.entries.count == 2)
  }

  /// A fork's file, beside the session's folder, is found on the first refresh.
  @Test func findsAForksFileOnTheFirstRefresh() async throws {
    defer { cleanUp() }
    try plant("t/subagents/agent-x.jsonl", try Self.fixtureLines())
    let feed = SubagentFeed(agentID: "x", transcriptFile: transcriptFile)
    await feed.refresh()
    #expect(feed.transcript?.entries.count == 3)
  }

  /// A file that can no longer be read leaves what was read on the card.
  @Test func aReadErrorKeepsTheTranscript() async throws {
    defer { cleanUp() }
    let file = try plant("s/subagents/agent-x.jsonl", try Self.fixtureLines())
    let feed = SubagentFeed(agentID: "x", transcriptFile: transcriptFile)
    await feed.refresh()
    let read = feed.transcript
    #expect(read?.entries.count == 3)
    try FileManager.default.removeItem(at: file)
    await feed.refresh()
    #expect(feed.transcript == read)
  }

  /// A running subagent of a session read from its file has no task and no report yet: its
  /// call's id finds the agent once its meta file is written.
  @Test func findsTheAgentByItsCallOnceItsMetaIsThere() async throws {
    defer { cleanUp() }
    let feed = SubagentFeed(agentID: nil, toolUseID: "toolu_1", transcriptFile: transcriptFile)
    await feed.refresh()
    #expect(feed.transcript == nil)
    try plant("s/subagents/agent-x.jsonl", try Self.fixtureLines())
    let meta = try plant("s/subagents/agent-x.meta.json", [])
    try Data(#"{"agentType":"general-purpose","toolUseId":"toolu_1","spawnDepth":1}"#.utf8)
      .write(to: meta)
    await feed.refresh()
    #expect(feed.agentID == "x")
    #expect(feed.transcript?.entries.count == 3)
  }

  /// No path is built from an ID that is not a plain name, on any refresh.
  @Test func refusesAnIDThatIsNotAName() async throws {
    defer { cleanUp() }
    try plant("s/subagents/agent-../t/subagents/agent-x.jsonl", try Self.fixtureLines())
    try plant("t/subagents/agent-x.jsonl", try Self.fixtureLines())
    let feed = SubagentFeed(agentID: "../t/subagents/agent-x", transcriptFile: transcriptFile)
    await feed.refresh()
    await feed.refresh()
    #expect(feed.transcript == nil)
  }
}
