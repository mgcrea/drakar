import DrakarKit
import Foundation
import MCPKit
import Testing

@testable import DrakarMCP

@Suite("Write tools")
struct WriteToolsTests {
  let source = FakeSessionSource()
  var table: ToolTable { Tools.table(source: source, pollInterval: .milliseconds(5)) }

  static let id = "aaaaaaaa-1111"
  static let names = [
    "drakar_start_session", "drakar_send_message", "drakar_interrupt", "drakar_end_session",
    "drakar_answer_question",
  ]

  private func call(_ name: String, _ arguments: MCPKit.JSONValue = [:]) async -> ToolResult {
    await table.call(name: name, arguments: arguments, allowWrites: true)
  }

  private static func row(_ id: String = id, state: SessionState = .idle) -> SessionRow {
    SessionRow(
      id: id, title: "Row", agent: .claude, folder: "/Users/me/app", state: state, place: .window)
  }

  /// One live session, waiting on `pending`.
  private func live(pending: [PendingItem] = []) {
    source.sessions = [Self.row()]
    source.details = [Self.id: SessionDetail(row: Self.row(), pending: pending)]
  }

  private static func request(_ toolName: String, _ input: DrakarKit.JSONValue)
    -> PermissionRequest
  {
    PermissionRequest(
      toolName: toolName, input: input, toolUseID: "toolu_1",
      kind: ClaudeTools.kind(name: toolName, input: input))
  }

  static let questionInput: DrakarKit.JSONValue = .object([
    "questions": .array([
      .object([
        "question": .string("Which?"),
        "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])]),
      ])
    ])
  ])

  private static func elicitation() throws -> Elicitation {
    try #require(
      Elicitation(
        claudeRequest: .object([
          "mcp_server_name": .string("github"),
          "message": .string("Pick a repo"),
          "requested_schema": .object([
            "type": .string("object"),
            "properties": .object(["repo": .object(["type": .string("string")])]),
          ]),
        ])))
  }

  // MARK: - The gate

  @Test("Without writes none of the write tools is listed; with writes all are")
  func writesHiddenWithoutGate() {
    let without = table.listing(allowWrites: false).map(\.name)
    #expect(Self.names.allSatisfy { !without.contains($0) })
    let with = table.listing(allowWrites: true).map(\.name)
    #expect(Self.names.allSatisfy { with.contains($0) })
  }

  @Test("writeTools is every tool gated on writes, in table order")
  func writeToolsMatchesGates() {
    let gated = table.listing(allowWrites: true).filter(\.mutates).map(\.name)
    #expect(Tools.writeTools == gated)
    #expect(Set(Self.names).isSubset(of: Set(Tools.writeTools)))
  }

  @Test("Starting and sending are not destructive; interrupting and ending are")
  func annotations() throws {
    for name in ["drakar_start_session", "drakar_send_message", "drakar_answer_question"] {
      let tool = try #require(table.tool(named: name))
      #expect(!tool.annotations.readOnlyHint, "\(name)")
      #expect(tool.annotations.destructiveHint == false, "\(name)")
    }
    for name in ["drakar_interrupt", "drakar_end_session"] {
      let tool = try #require(table.tool(named: name))
      #expect(!tool.annotations.readOnlyHint, "\(name)")
      #expect(tool.annotations.destructiveHint == true, "\(name)")
    }
  }

  // MARK: - drakar_start_session

  @Test("A licence that refuses work refuses the start with its own sentence")
  func startRefusedByLicence() async {
    source.refusal = "Your trial has ended."
    let result = await call(
      "drakar_start_session", ["folder": "/Users/me/app", "prompt": "Fix the build"])
    #expect(result.isError)
    #expect(result.text == "Your trial has ended.")
    #expect(source.calls.isEmpty)
  }

  @Test("Codex on the runner is refused")
  func codexOnRunnerRefused() async {
    let result = await call(
      "drakar_start_session",
      ["folder": "/Users/me/app", "runner": "eva", "prompt": "Go", "agent": "codex"])
    #expect(result.isError)
    #expect(
      result.text == "A runner's sessions are Claude Code's: leave agent out or pass \"claude\".")
    #expect(source.calls.isEmpty)
  }

  @Test("A relative folder is refused; ~/ is taken as given")
  func relativeFolderRefused() async {
    var result = await call("drakar_start_session", ["folder": "app", "prompt": "Go"])
    #expect(result.isError)
    #expect(result.text.contains("absolute"))
    #expect(source.calls.isEmpty)

    source.details = ["new-session": SessionDetail(row: Self.row("new-session"))]
    result = await call("drakar_start_session", ["folder": "~/app", "prompt": "Go"])
    #expect(!result.isError)
    #expect(source.started?.folder == "~/app")
  }

  @Test("A start passes what was asked and answers the new session's row")
  func startAnswersRow() async throws {
    source.startedID = "bbbbbbbb-2222"
    source.details = ["bbbbbbbb-2222": SessionDetail(row: Self.row("bbbbbbbb-2222"))]
    let result = await call(
      "drakar_start_session",
      [
        "folder": "/srv/app", "runner": "eva", "prompt": "Fix the build", "agent": "claude",
        "model": "opus",
      ])
    #expect(!result.isError)
    #expect(
      source.started
        == StartRequest(
          folder: "/srv/app", runner: "eva", prompt: "Fix the build", agent: .claude,
          model: "opus"))
    #expect(result.text == "Started bbbbbbbb-2222 in /srv/app.")
    #expect(result.structuredContent?["session"]?["id"] == "bbbbbbbb-2222")
    #expect(result.structuredContent?["session"]?["state"] == "idle")
  }

  // MARK: - drakar_send_message

  @Test("A message behind a running turn answers queued")
  func sendQueued() async {
    live()
    source.sendOutcome = .queued
    let result = await call("drakar_send_message", ["session": "aaaaaaaa", "text": "And tests"])
    #expect(!result.isError)
    #expect(result.structuredContent?["outcome"] == "queued")
    #expect(source.calls == ["send \(Self.id) And tests"])
  }

  @Test("An empty message, or a licence that refuses work, sends nothing")
  func sendRefused() async {
    live()
    var result = await call("drakar_send_message", ["session": .string(Self.id), "text": "  "])
    #expect(result.isError)

    source.refusal = "Your trial has ended."
    result = await call("drakar_send_message", ["session": .string(Self.id), "text": "Go"])
    #expect(result.isError)
    #expect(result.text == "Your trial has ended.")
    #expect(source.calls.isEmpty)
  }

  // MARK: - drakar_interrupt, drakar_end_session

  @Test("Interrupt and end pass through, even when the licence refuses work")
  func interruptAndEnd() async {
    live()
    source.refusal = "Your trial has ended."
    var result = await call("drakar_interrupt", ["session": .string(Self.id)])
    #expect(result.structuredContent == ["ok": true])
    result = await call("drakar_end_session", ["session": .string(Self.id)])
    #expect(result.structuredContent == ["ok": true])
    #expect(source.calls == ["interrupt \(Self.id)", "end \(Self.id)"])
  }

  @Test("A source's refusal reaches the caller as a tool error")
  func writeErrorSurfaces() async {
    live()
    source.writeError = SessionError("That session is held by another Drakar.")
    let result = await call("drakar_end_session", ["session": .string(Self.id)])
    #expect(result.isError)
    #expect(result.text == "That session is held by another Drakar.")
  }

  // MARK: - drakar_answer_question

  @Test("Answers become the allow's updatedInput, built by Drakar")
  func answerQuestionBuildsInput() async {
    let request = Self.request(UserQuestion.toolName, Self.questionInput)
    live(pending: [.permission(requestID: "q1", request: request)])
    let result = await call(
      "drakar_answer_question",
      ["session": .string(Self.id), "request_id": "q1", "answers": ["Which?": "B"]])
    #expect(!result.isError)
    #expect(source.calls == ["permission \(Self.id) q1"])
    #expect(
      source.decision
        == .allow(
          updatedInput: UserQuestion.answering(Self.questionInput, with: ["Which?": "B"])))
  }

  @Test("A question needs answers, each one naming a question it asks")
  func answerQuestionNeedsAnswers() async {
    let request = Self.request(UserQuestion.toolName, Self.questionInput)
    live(pending: [.permission(requestID: "q1", request: request)])
    var result = await call(
      "drakar_answer_question", ["session": .string(Self.id), "request_id": "q1"])
    #expect(result.isError)
    result = await call(
      "drakar_answer_question",
      ["session": .string(Self.id), "request_id": "q1", "answers": ["Where?": "B"]])
    #expect(result.isError)
    #expect(result.text.contains("Where?"))
    result = await call(
      "drakar_answer_question", ["session": .string(Self.id), "request_id": "q1", "answers": [:]])
    #expect(result.text == "Answer every question: \"Which?\" has no answer.")
    #expect(source.calls.isEmpty)
  }

  @Test("A request no longer pending is already answered")
  func answerQuestionAlreadyAnswered() async {
    live()
    let result = await call(
      "drakar_answer_question",
      ["session": .string(Self.id), "request_id": "q1", "answers": ["Which?": "B"]])
    #expect(result.isError)
    #expect(
      result.text == "Request q1 is no longer waiting: already answered, or the turn ended.")
    #expect(source.calls.isEmpty)
  }

  @Test("A permission prompt is not a question")
  func answerQuestionOnPermissionRefused() async {
    let request = Self.request("Bash", .object(["command": .string("ls")]))
    live(pending: [.permission(requestID: "p1", request: request)])
    let result = await call(
      "drakar_answer_question",
      ["session": .string(Self.id), "request_id": "p1", "action": "accept"])
    #expect(result.isError)
    #expect(result.text == "Request p1 is a permission prompt: use drakar_answer_permission.")
    #expect(source.calls.isEmpty)
  }

  @Test("An elicitation declined is declined")
  func elicitationDecline() async throws {
    live(pending: [.elicitation(requestID: "e1", elicitation: try Self.elicitation())])
    let result = await call(
      "drakar_answer_question",
      ["session": .string(Self.id), "request_id": "e1", "action": "decline"])
    #expect(!result.isError)
    #expect(source.calls == ["elicitation \(Self.id) e1"])
    #expect(source.elicitationAnswer == .decline)
  }

  @Test("An elicitation accepted carries its content across; one with no action is refused")
  func elicitationAccept() async throws {
    live(pending: [.elicitation(requestID: "e1", elicitation: try Self.elicitation())])
    var result = await call(
      "drakar_answer_question", ["session": .string(Self.id), "request_id": "e1"])
    #expect(result.isError)

    result = await call(
      "drakar_answer_question",
      [
        "session": .string(Self.id), "request_id": "e1", "action": "accept",
        "content": ["repo": "drakar", "stars": 3],
      ])
    #expect(!result.isError)
    #expect(
      source.elicitationAnswer == .accept(["repo": .string("drakar"), "stars": .number(3)]))
  }
}
