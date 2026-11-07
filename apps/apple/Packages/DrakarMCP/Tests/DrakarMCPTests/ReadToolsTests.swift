import DrakarKit
import Foundation
import MCPKit
import Testing

@testable import DrakarMCP

@Suite("Read tools")
struct ReadToolsTests {
  let source = FakeSessionSource()
  var table: ToolTable { Tools.table(source: source, pollInterval: .milliseconds(5)) }

  private func call(_ name: String, _ arguments: MCPKit.JSONValue = [:]) async -> ToolResult {
    await table.call(name: name, arguments: arguments, allowWrites: false)
  }

  private static func row(
    _ id: String, runner: String? = nil, state: SessionState = .idle
  ) -> SessionRow {
    SessionRow(
      id: id, title: "Row \(id.prefix(4))", agent: .claude, folder: "/Users/me/app",
      runner: runner, state: state, place: .window)
  }

  private static func request(_ toolName: String, _ input: DrakarKit.JSONValue)
    -> PermissionRequest
  {
    PermissionRequest(
      toolName: toolName, input: input, toolUseID: "toolu_1",
      kind: ClaudeTools.kind(name: toolName, input: input))
  }

  // MARK: - The listing

  @Test("Without writes, the read tools are listed in their order")
  func listingWithoutWrites() {
    #expect(
      table.listing(allowWrites: false).map(\.name) == [
        "drakar_list_sessions", "drakar_needs_attention", "drakar_get_session",
        "drakar_read_transcript", "drakar_wait", "drakar_list_projects",
      ])
  }

  // MARK: - drakar_list_sessions

  @Test("runner filters by this Mac or the runner's name, case ignored")
  func filtersByRunner() async throws {
    source.sessions = [Self.row("aaaaaaaa-1"), Self.row("bbbbbbbb-1", runner: "eva")]

    var result = await call("drakar_list_sessions", ["runner": "this-mac"])
    var rows = try #require(result.structuredContent?["sessions"]?.arrayValue)
    #expect(rows.map { $0["id"] } == ["aaaaaaaa-1"])
    #expect(rows[0]["runner"] == .null)

    result = await call("drakar_list_sessions", ["runner": "EVA"])
    rows = try #require(result.structuredContent?["sessions"]?.arrayValue)
    #expect(rows.map { $0["id"] } == ["bbbbbbbb-1"])
    #expect(rows[0]["runner"] == "eva")
  }

  @Test("Ended sessions only when asked, at most 100")
  func endedOnlyWhenAsked() async throws {
    source.sessions = [Self.row("aaaaaaaa-1", state: .working)]
    source.ended = (0..<150).map { Self.row("ended-\($0)", state: .ended) }

    var result = await call("drakar_list_sessions")
    var rows = try #require(result.structuredContent?["sessions"]?.arrayValue)
    #expect(rows.map { $0["id"] } == ["aaaaaaaa-1"])
    #expect(result.text == "1 live session.")

    // The fake serves `endedLimit` ended rows, so 100 of them means the tool asked for 100.
    result = await call("drakar_list_sessions", ["include_ended": true, "limit": 500])
    rows = try #require(result.structuredContent?["sessions"]?.arrayValue)
    #expect(rows.count == 101)
    #expect(rows.last?["state"] == "ended")

    result = await call("drakar_list_sessions", ["include_ended": true])
    #expect(result.structuredContent?["sessions"]?.arrayValue?.count == 21)

    result = await call("drakar_list_sessions", ["state": "ended"])
    #expect(result.structuredContent?["sessions"]?.arrayValue?.count == 20)
    #expect(result.text == "0 live sessions, 20 ended.")
  }

  @Test("With a filter, the ended limit counts the matching sessions")
  func endedLimitAfterFilter() async throws {
    source.sessions = [Self.row("aaaaaaaa-1", state: .working)]
    source.ended = (0..<30).map { index in
      SessionRow(
        id: "ended-\(index)", agent: .claude, folder: index == 24 ? "/x" : "/Users/me/app",
        state: .ended, place: .window)
    }
    var result = await call("drakar_list_sessions", ["include_ended": true, "folder": "/x"])
    #expect(result.structuredContent?["sessions"]?.arrayValue?.map { $0["id"] } == ["ended-24"])

    // A filter that matches many still keeps at most `limit` ended rows, live rows apart.
    result = await call(
      "drakar_list_sessions", ["include_ended": true, "runner": "this-mac", "limit": 5])
    let rows = try #require(result.structuredContent?["sessions"]?.arrayValue)
    #expect(rows.count == 6)
    #expect(rows.first?["id"] == "aaaaaaaa-1")
    #expect(rows.last?["id"] == "ended-4")
  }

  @Test("state and folder filter; an unknown state is refused")
  func filtersByStateAndFolder() async throws {
    source.sessions = [
      Self.row("aaaaaaaa-1", state: .waiting),
      SessionRow(
        id: "bbbbbbbb-1", agent: .codex, folder: "/Users/me/other", state: .working,
        place: .background),
    ]
    var result = await call("drakar_list_sessions", ["state": "waiting"])
    #expect(result.structuredContent?["sessions"]?.arrayValue?.map { $0["id"] } == ["aaaaaaaa-1"])
    #expect(result.text == "1 live session, 1 waiting.")

    result = await call("drakar_list_sessions", ["folder": "/Users/me/other/"])
    #expect(result.structuredContent?["sessions"]?.arrayValue?.map { $0["id"] } == ["bbbbbbbb-1"])

    result = await call("drakar_list_sessions", ["state": "sleeping"])
    #expect(result.isError)
    #expect(result.text.contains("working, waiting, idle"))
  }

  @Test("A row carries every field, context left out when unknown")
  func rowFields() {
    let row = SessionRow(
      id: "aaaaaaaa-1", title: "Fix the build", agent: .codex, folder: "/Users/me/app",
      runner: "eva", state: .waiting, waitingFor: "Bash", model: "gpt-5", contextUsed: 1200,
      contextLimit: 200_000, lastActivity: Date(timeIntervalSince1970: 0), place: .elsewhere,
      readOnly: true, heldBy: "Terminal")
    let encoded = Encoding.row(row)
    #expect(encoded["id"] == "aaaaaaaa-1")
    #expect(encoded["title"] == "Fix the build")
    #expect(encoded["agent"] == "codex")
    #expect(encoded["folder"] == "/Users/me/app")
    #expect(encoded["runner"] == "eva")
    #expect(encoded["state"] == "waiting")
    #expect(encoded["waitingFor"] == "Bash")
    #expect(encoded["model"] == "gpt-5")
    #expect(encoded["context"] == ["used": 1200, "limit": 200_000])
    #expect(encoded["lastActivity"] == "1970-01-01T00:00:00Z")
    #expect(encoded["where"] == "elsewhere")
    #expect(encoded["readOnly"] == true)
    #expect(encoded["heldBy"] == "Terminal")

    let bare = Encoding.row(Self.row("bbbbbbbb-1"))
    #expect(bare["context"] == nil)
    #expect(bare["model"] == .null)
  }

  // MARK: - Naming a session

  @Test("A unique prefix of 8 resolves; a shared one and a short one are refused")
  func prefixResolves() async throws {
    let first = "aaaaaaaa-1111-4000-8000-000000000001"
    let second = "aaaaaaaa-2222-4000-8000-000000000002"
    let third = "bbbbbbbb-3333-4000-8000-000000000003"
    source.sessions = [Self.row(first), Self.row(second), Self.row(third)]
    source.details = [third: SessionDetail(row: Self.row(third), queued: ["next"])]

    var result = await call("drakar_get_session", ["session": "bbbbbbbb"])
    #expect(!result.isError)
    #expect(result.structuredContent?["id"] == .string(third))
    #expect(result.structuredContent?["queued"] == ["next"])

    result = await call("drakar_get_session", ["session": "aaaaaaaa"])
    #expect(result.isError)
    #expect(result.text.contains(first))
    #expect(result.text.contains(second))
    #expect(result.text.hasPrefix("\"aaaaaaaa\" names 2 sessions:"))

    result = await call("drakar_get_session", ["session": "bbbb"])
    #expect(
      result.text
        == "\"bbbb\" is too short to name a session: give 8 characters or more.")

    result = await call("drakar_get_session", ["session": "cccccccc"])
    #expect(result.text == "No session cccccccc. drakar_list_sessions lists them.")
  }

  @Test("An exact id resolves however short, and ended sessions are named too")
  func exactAndEnded() async throws {
    #expect(try SessionIDs.resolve("abc", among: ["abc", "abcdefgh"]) == "abc")
    #expect(throws: SessionError.self) { try SessionIDs.resolve("abcd", among: ["abcdefgh"]) }

    let ended = Self.row("eeeeeeee-5555", state: .ended)
    source.ended = [ended]
    source.details = [ended.id: SessionDetail(row: ended)]
    let result = await call("drakar_get_session", ["session": "eeeeeeee"])
    #expect(result.structuredContent?["state"] == "ended")
  }

  // MARK: - Pending items

  @Test("A permission's input is cut at 4 KB per string, and says so")
  func permissionInputTruncated() throws {
    let input: DrakarKit.JSONValue = .object([
      "file_path": .string("/tmp/a.txt"),
      "content": .string(String(repeating: "x", count: 10_000)),
    ])
    let encoded = Encoding.pending(
      .permission(requestID: "req-1", request: Self.request("Write", input)))
    #expect(encoded["kind"] == "permission")
    #expect(encoded["requestId"] == "req-1")
    #expect(encoded["tool"] == "Write")
    #expect(encoded["summary"] == "/tmp/a.txt")
    #expect(encoded["input"]?["content"]?.stringValue?.utf8.count == 4096)
    #expect(encoded["input"]?["file_path"] == "/tmp/a.txt")
    #expect(encoded["inputTruncated"] == true)
    #expect(encoded["suggestions"] == [])
  }

  @Test("A cut never splits a character")
  func truncatingKeepsWholeScalars() {
    let (value, truncated) = Encoding.truncating(.string("aé"), limit: 2)
    #expect(value == "a")
    #expect(truncated)
    let (short, cut) = Encoding.truncating(["a": ["bc"]], limit: 2)
    #expect(short == ["a": ["bc"]])
    #expect(!cut)
  }

  @Test("AskUserQuestion is a question with its options; ExitPlanMode a plan with its text")
  func questionAndPlanKinds() throws {
    let questionInput: DrakarKit.JSONValue = .object([
      "questions": .array([
        .object([
          "question": .string("Which?"),
          "options": .array([
            .object(["label": .string("A")]), .object(["label": .string("B")]),
          ]),
        ])
      ])
    ])
    let question = Encoding.pending(
      .permission(requestID: "q", request: Self.request("AskUserQuestion", questionInput)))
    #expect(question["kind"] == "question")
    #expect(question["questions"] == [["question": "Which?", "options": ["A", "B"]]])
    #expect(question["inputTruncated"] == nil)

    let plan = Encoding.pending(
      .permission(
        requestID: "p",
        request: Self.request("ExitPlanMode", .object(["plan": .string("# Plan\n1. Do it")]))))
    #expect(plan["kind"] == "plan")
    #expect(plan["plan"] == "# Plan\n1. Do it")
  }

  @Test("An elicitation gives its server, message and form fields")
  func elicitationFields() throws {
    let elicitation = try #require(
      Elicitation(
        claudeRequest: .object([
          "mcp_server_name": .string("github"),
          "message": .string("Pick a repo"),
          "requested_schema": .object([
            "type": .string("object"),
            "properties": .object([
              "repo": .object(["type": .string("string"), "enum": .array([.string("a")])])
            ]),
            "required": .array([.string("repo")]),
          ]),
        ])))
    let encoded = Encoding.pending(.elicitation(requestID: "e", elicitation: elicitation))
    #expect(encoded["kind"] == "elicitation")
    #expect(encoded["requestId"] == "e")
    #expect(encoded["server"] == "github")
    #expect(encoded["message"] == "Pick a repo")
    let field = try #require(encoded["fields"]?[0])
    #expect(field["key"] == "repo")
    #expect(field["type"] == "choice")
    #expect(field["required"] == true)
    #expect(field["options"] == [["value": "a", "title": "a"]])
  }

  // MARK: - drakar_needs_attention

  @Test("Attention keeps the source's order; in-text kinds carry their text")
  func attentionOrderKept() async throws {
    let request = Self.request("Bash", .object(["command": .string("ls")]))
    source.attentionItems = [
      AttentionItem(
        session: Self.row("bbbbbbbb-1"), kind: .permission,
        pending: .permission(requestID: "r1", request: request)),
      AttentionItem(session: Self.row("aaaaaaaa-1"), kind: .askedInText, text: "Ship it?"),
      AttentionItem(
        session: Self.row("cccccccc-1"), kind: .offeredInText, text: "Want me to push?"),
    ]
    let result = await call("drakar_needs_attention")
    let rows = try #require(result.structuredContent?["sessions"]?.arrayValue)
    #expect(rows.map { $0["id"] } == ["bbbbbbbb-1", "aaaaaaaa-1", "cccccccc-1"])
    #expect(rows.map { $0["kind"] } == ["permission", "asked_in_text", "offered_in_text"])
    #expect(rows[0]["wants"]?["requestId"] == "r1")
    #expect(rows[0]["wants"]?["summary"] == "ls")
    #expect(rows[1]["wants"] == ["text": "Ship it?"])
    #expect(rows[2]["wants"]?["text"] == "Want me to push?")
  }

  // MARK: - drakar_get_session

  @Test("A session's detail adds its pending items, queue, mode and account")
  func sessionDetail() async throws {
    let id = "aaaaaaaa-1111"
    let request = Self.request("Bash", .object(["command": .string("make")]))
    source.sessions = [Self.row(id, state: .waiting)]
    source.details = [
      id: SessionDetail(
        row: Self.row(id, state: .waiting),
        pending: [.permission(requestID: "r1", request: request)], queued: ["then this"],
        permissionMode: "default", accountFolder: "/Users/me/.claude")
    ]
    let result = await call("drakar_get_session", ["session": .string(id)])
    let detail = try #require(result.structuredContent)
    #expect(detail["state"] == "waiting")
    #expect(detail["pending"]?[0]?["requestId"] == "r1")
    #expect(detail["queued"] == ["then this"])
    #expect(detail["permissionMode"] == "default")
    #expect(detail["accountFolder"] == "/Users/me/.claude")
  }

  @Test("A session listed but with no detail any more reads as unknown")
  func sessionGoneBetweenCalls() async {
    source.sessions = [Self.row("aaaaaaaa-1")]
    let result = await call("drakar_get_session", ["session": "aaaaaaaa-1"])
    #expect(result.isError)
    #expect(result.text == "No session aaaaaaaa-1. drakar_list_sessions lists them.")
  }

  // MARK: - drakar_list_projects

  @Test("Projects and the runner")
  func projectsAndRunner() async throws {
    source.projectRows = [
      ProjectRow(folder: "/Users/me/app", isOpen: true),
      ProjectRow(folder: "/Users/eva/app", runner: "eva", isOpen: false),
    ]
    var result = await call("drakar_list_projects")
    var answer = try #require(result.structuredContent)
    #expect(answer["runner"] == .null)
    #expect(
      answer["projects"] == [
        ["folder": "/Users/me/app", "runner": nil, "isOpen": true],
        ["folder": "/Users/eva/app", "runner": "eva", "isOpen": false],
      ])

    source.runnerStatus = RunnerStatus(
      name: "eva", isConnected: false, claudeVersion: "2.1.300", lastError: "Host unreachable")
    result = await call("drakar_list_projects")
    answer = try #require(result.structuredContent)
    #expect(
      answer["runner"] == [
        "name": "eva", "isConnected": false, "drakarVersion": nil, "claudeVersion": "2.1.300",
        "lastError": "Host unreachable",
      ])
  }
}
