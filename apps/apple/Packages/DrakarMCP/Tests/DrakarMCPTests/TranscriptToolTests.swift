import DrakarKit
import Foundation
import MCPKit
import Testing

@testable import DrakarMCP

@Suite("drakar_read_transcript")
struct TranscriptToolTests {
  let source = FakeSessionSource()
  var table: ToolTable { Tools.table(source: source, pollInterval: .milliseconds(5)) }

  static let id = "e3c56568-636a-4c34-ab80-dba1392d6034"

  private func call(_ arguments: MCPKit.JSONValue) async -> ToolResult {
    await table.call(name: "drakar_read_transcript", arguments: arguments, allowWrites: false)
  }

  /// A session that has `transcript`.
  private func serve(_ transcript: Transcript) {
    source.sessions = [
      SessionRow(
        id: Self.id, agent: .claude, folder: "/Users/me/project", state: .idle, place: .window)
    ]
    source.transcripts = [Self.id: transcript]
  }

  private static func history(_ lines: [String]) -> Transcript {
    Transcript.history(lines: lines.map { Data($0.utf8) })
  }

  /// DrakarKit's `history-with-tool` capture: `touch ahoy.txt` through Bash, then "done".
  private static func capturedSession() throws -> Transcript {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../DrakarKit/Tests/DrakarKitTests/Fixtures/history-with-tool.jsonl")
      .standardizedFileURL
    let lines = try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).map { Data($0) }
    return Transcript.history(lines: lines)
  }

  @Test("last gives the newest entries, and the cursor reads on from the end")
  func pagesWithCursor() async throws {
    let transcript = try Self.capturedSession()
    try #require(transcript.entries.count == 3)
    serve(transcript)

    var result = await call(["session": "e3c56568", "last": 2])
    #expect(!result.isError)
    var answer = try #require(result.structuredContent)
    #expect(answer["cursor"] == .int(transcript.entries.count))
    let entries = try #require(answer["entries"]?.arrayValue)
    #expect(entries.map { $0["index"] } == [1, 2])
    #expect(entries[0]["role"] == "tool")
    #expect(entries[0]["name"] == "Bash")
    #expect(entries[0]["summary"] == "touch ahoy.txt")
    #expect(entries[0]["status"] == "done")
    #expect(entries[0]["result"] == "(Bash completed with no output)")
    #expect(entries[0]["resultTruncated"] == nil)
    #expect(entries[1] == ["index": 2, "role": "assistant", "text": "done"])
    #expect(result.text == "2 entries.")

    result = await call(["session": .string(Self.id), "after": answer["cursor"] ?? .null])
    answer = try #require(result.structuredContent)
    #expect(answer["entries"] == [])
    #expect(answer["cursor"] == .int(transcript.entries.count))
    #expect(result.text == "Nothing new.")

    // Read on from the start, a page of one at a time: each cursor is where the next begins.
    result = await call(["session": .string(Self.id), "after": 0, "last": 1])
    answer = try #require(result.structuredContent)
    #expect(answer["entries"]?[0]?["role"] == "user")
    #expect(answer["cursor"] == 1)
    result = await call(["session": .string(Self.id), "after": 1, "last": 1])
    #expect(result.structuredContent?["entries"]?[0]?["index"] == 1)
    #expect(result.structuredContent?["cursor"] == 2)
  }

  @Test("A tool's result is cut at 2 KB, and says so")
  func toolResultTruncated() async throws {
    let output = String(repeating: "x", count: 5000)
    serve(
      Self.history([
        #"{"type":"user","message":{"role":"user","content":"Print it"}}"#,
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cat big.txt"}}],"stop_reason":"tool_use"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":""#
          + output + #"","is_error":true}]}}"#,
      ]))

    let result = await call(["session": .string(Self.id)])
    let tool = try #require(result.structuredContent?["entries"]?[1])
    #expect(tool["role"] == "tool")
    #expect(tool["summary"] == "cat big.txt")
    #expect(tool["status"] == "error")
    #expect(tool["result"]?.stringValue?.utf8.count == 2048)
    #expect(tool["resultTruncated"] == true)
  }

  @Test("Thinking is never given, and does not count against last")
  func thinkingSkipped() async throws {
    let transcript = Self.history([
      #"{"type":"user","message":{"role":"user","content":"Build it"}}"#,
      #"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"Plan the build."}]}}"#,
      #"{"type":"assistant","message":{"id":"m1","stop_reason":"end_turn","content":[{"type":"text","text":"Built."}]}}"#,
    ])
    try #require(
      transcript.entries.contains {
        if case .thinking = $0.kind { true } else { false }
      })
    serve(transcript)

    let result = await call(["session": .string(Self.id), "last": 2])
    let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
    #expect(entries.map { $0["role"] } == ["user", "assistant"])
    #expect(entries.map { $0["index"] } == [0, 2])
  }

  // MARK: - Entries that still change

  /// A live transcript: a prompt whose turn runs.
  private static func running() -> Transcript {
    var transcript = Transcript()
    transcript.addPrompt("Build it")
    return transcript
  }

  private static func call(_ id: String, _ name: String, parent: String? = nil)
    -> AgentEvent
  {
    let input: DrakarKit.JSONValue = .object(["command": .string("make")])
    return .itemStarted(
      AgentEvent.Item(
        id: id, parent: parent,
        kind: .tool(
          Transcript.ToolCall(
            id: id, name: name, input: input, kind: ClaudeTools.kind(name: name, input: input)))))
  }

  private static func text(_ id: String, _ text: String, parent: String? = nil) -> AgentEvent {
    .itemStarted(AgentEvent.Item(id: id, parent: parent, kind: .text(text)))
  }

  @Test("A running tool is read past and listed unsettled until its result comes")
  func runningToolIsUnsettled() async throws {
    var transcript = Self.running()
    transcript.apply(Self.call("t1", "Bash"))
    serve(transcript)
    var answer = try #require(await call(["session": .string(Self.id)]).structuredContent)
    #expect(answer["entries"]?[1]?["status"] == "running")
    #expect(answer["cursor"] == 2)
    #expect(answer["unsettled"] == [1])

    transcript.apply(.toolResult(callID: "t1", .init(content: "Built.", isError: false)))
    serve(transcript)
    answer = try #require(await call(["session": .string(Self.id)]).structuredContent)
    #expect(answer["unsettled"] == [])
    answer = try #require(
      await call(["session": .string(Self.id), "after": 1, "last": 1]).structuredContent)
    #expect(answer["entries"]?[0]?["index"] == 1)
    #expect(answer["entries"]?[0]?["status"] == "done")
    #expect(answer["entries"]?[0]?["result"] == "Built.")
  }

  @Test("A cut page moves the cursor past a running Agent call, which stays unsettled")
  func agentCallUnderSubagentEntries() {
    var transcript = Self.running()
    transcript.apply(Self.call("agent", "Agent"))
    for step in 0..<25 {
      transcript.apply(Self.text("sub-\(step)", "Step \(step)", parent: "agent"))
    }
    let page = TranscriptEncoding.page(transcript, after: 0, last: 20)
    #expect(page.entries.count == 20)
    #expect(page.cursor == 20)
    #expect(page.unsettled == [1])
  }

  @Test("A transcript with no turn running has nothing unsettled")
  func exitedTranscriptIsSettled() {
    var transcript = Self.running()
    transcript.apply(Self.call("t1", "Bash"))
    transcript.processExited()
    let page = TranscriptEncoding.page(transcript, after: nil, last: 20)
    #expect(page.unsettled.isEmpty)
    #expect(page.cursor == transcript.entries.count)
  }

  @Test("The newest main-thread text stays unsettled behind a subagent's entry")
  func streamingTextBehindSubagentEntry() {
    var transcript = Self.running()
    transcript.apply(Self.call("agent", "Agent"))
    transcript.apply(.toolResult(callID: "agent", .init(content: "Done.", isError: false)))
    transcript.apply(Self.text("m1", "Here is"))
    transcript.apply(Self.text("sub-1", "Working", parent: "agent"))
    let page = TranscriptEncoding.page(transcript, after: nil, last: 20)
    #expect(page.unsettled == [2])
  }

  /// DrakarKit's `fork-subagent` capture: a fork started in the background, its turn ended,
  /// then the fork's Bash call (line 9) and its result (line 11) arrived.
  private static func forkSession(lines count: Int) throws -> Transcript {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../DrakarKit/Tests/DrakarKitTests/Fixtures/fork-subagent.jsonl")
      .standardizedFileURL
    let lines = try Data(contentsOf: url).split(separator: UInt8(ascii: "\n"))
    var feed = ClaudeFeed()
    feed.addPrompt("Fork it")
    for line in lines.prefix(count) { feed.apply(try StreamMessage(line: Data(line))) }
    return feed.transcript
  }

  @Test("A fork's call stays unsettled after its turn ended, until its result comes")
  func forkCallUnsettledBetweenTurns() throws {
    let started = try Self.forkSession(lines: 9)
    #expect(!started.isRunning)
    let call = try #require(
      started.entries.indices.first { index in
        guard case .tool(let call) = started.entries[index].kind else { return false }
        return call.name == "Bash"
      })
    #expect(TranscriptEncoding.page(started, after: nil, last: 20).unsettled == [call])

    let answered = try Self.forkSession(lines: 11)
    #expect(!TranscriptEncoding.page(answered, after: nil, last: 20).unsettled.contains(call))
  }

  @Test("A transcript the source cannot read is refused with its sentence")
  func unreadableTranscript() async {
    serve(Transcript())
    source.transcripts = [:]
    let result = await call(["session": .string(Self.id)])
    #expect(result.isError)
    #expect(result.text == FakeSessionSource.transcriptMissing.message)
  }
}
