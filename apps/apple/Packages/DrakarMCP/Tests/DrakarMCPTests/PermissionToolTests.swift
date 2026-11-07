import DrakarKit
import Foundation
import MCPKit
import Testing

@testable import DrakarMCP

@Suite("drakar_answer_permission")
struct PermissionToolTests {
  let source = FakeSessionSource()
  var table: ToolTable { Tools.table(source: source, pollInterval: .milliseconds(5)) }

  static let id = "aaaaaaaa-1111"
  static let name = "drakar_answer_permission"

  init() {
    source.allowsPermissions = true
  }

  private func call(_ arguments: MCPKit.JSONValue) async -> ToolResult {
    await table.call(name: Self.name, arguments: arguments, allowWrites: true)
  }

  private static func row() -> SessionRow {
    SessionRow(
      id: id, title: "Row", agent: .claude, folder: "/Users/me/app", state: .waiting, place: .window
    )
  }

  /// One live session, waiting on `pending`.
  private func live(pending: [PendingItem] = []) {
    source.sessions = [Self.row()]
    source.details = [Self.id: SessionDetail(row: Self.row(), pending: pending)]
  }

  /// The id the tools give out for the request `raw` the session waits on, as a caller reads
  /// it; `raw` itself when it waits on none.
  private func requestID(_ raw: String) -> MCPKit.JSONValue {
    let item = source.details[Self.id]?.pending.first { $0.requestID == raw }
    return .string(item.map { RequestID($0).description } ?? raw)
  }

  private static func request(
    _ toolName: String, _ input: DrakarKit.JSONValue, suggestions: [DrakarKit.JSONValue] = []
  ) -> PermissionRequest {
    var request = PermissionRequest(
      toolName: toolName, input: input, toolUseID: "toolu_1",
      kind: ClaudeTools.kind(name: toolName, input: input))
    request.suggestions = suggestions
    return request
  }

  static let bashInput: DrakarKit.JSONValue = .object(["command": .string("ls -la")])
  static let planInput: DrakarKit.JSONValue = .object(["plan": .string("# Fix the build\n1. …")])

  /// An allow rule for `ls`, remembered where `destination` says.
  static func addRules(_ destination: String) -> DrakarKit.JSONValue {
    .object([
      "type": .string("addRules"),
      "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("ls:*")])]),
      "behavior": .string("allow"),
      "destination": .string(destination),
    ])
  }

  static let setMode: DrakarKit.JSONValue = .object([
    "type": .string("setMode"), "mode": .string("acceptEdits"),
    "destination": .string("session"),
  ])

  /// The three a Bash prompt can offer: for the session (0), in settings (1), a mode (2).
  static let suggestions = [addRules("session"), addRules("localSettings"), setMode]

  // MARK: - The switch

  @Test("With the switch off, the tool refuses and answers nothing")
  func refusedWhenSwitchOff() async {
    source.allowsPermissions = false
    live(pending: [.permission(requestID: "p1", request: Self.request("Bash", Self.bashInput))])
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "allow",
    ])
    #expect(result.isError)
    #expect(
      result.text
        == "Answering permission prompts is off. The person can turn on \"Let agents answer permission prompts\" in Drakar's Settings › MCP Server."
    )
    #expect(source.calls.isEmpty)
  }

  @Test("The tool is listed under Allow writes, whatever the switch says")
  func listedWithWritesEvenWhenSwitchOff() throws {
    source.allowsPermissions = false
    #expect(table.listing(allowWrites: true).map(\.name).contains(Self.name))
    #expect(!table.listing(allowWrites: false).map(\.name).contains(Self.name))
    let tool = try #require(table.tool(named: Self.name))
    #expect(tool.mutates)
    #expect(tool.annotations.destructiveHint == false)
  }

  // MARK: - Allow and deny

  @Test("An allow runs the request's own input; an input from the caller is ignored")
  func allowPassesInputThrough() async {
    live(pending: [.permission(requestID: "p1", request: Self.request("Bash", Self.bashInput))])
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "allow",
      "updated_input": ["command": "rm -rf /"],
    ])
    #expect(!result.isError)
    #expect(source.calls == ["permission \(Self.id) p1"])
    #expect(source.decision == .allow(updatedInput: Self.bashInput))
  }

  @Test("A deny carries the message and interrupt; with no message, a sentence of Drakar's")
  func denyCarriesMessageAndInterrupt() async {
    live(pending: [.permission(requestID: "p1", request: Self.request("Bash", Self.bashInput))])
    var result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "deny",
      "message": "Not in this folder.", "interrupt": true,
    ])
    #expect(!result.isError)
    #expect(source.decision == .deny(message: "Not in this folder.", interrupt: true))

    result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "deny",
    ])
    #expect(!result.isError)
    #expect(
      source.decision
        == .deny(message: "Denied by an agent through Drakar's MCP server.", interrupt: false))
  }

  @Test("A decision other than allow or deny is refused")
  func decisionRequired() async {
    live(pending: [.permission(requestID: "p1", request: Self.request("Bash", Self.bashInput))])
    var result = await call(["session": .string(Self.id), "request_id": requestID("p1")])
    #expect(result.isError)
    result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "always",
    ])
    #expect(result.isError)
    #expect(source.calls.isEmpty)
  }

  // MARK: - always

  @Test("Only rules for the session are offered, and only those may be applied")
  func onlySessionRulesOffered() async throws {
    let request = Self.request("Bash", Self.bashInput, suggestions: Self.suggestions)
    #expect(AlwaysOffer.offered(request).map(\.id) == [0])

    #expect(throws: SessionError.self) {
      try PermissionAnswer.decision(
        for: request, verdict: .allow, message: nil, interrupt: false, always: [1])
    }
    #expect(throws: SessionError.self) {
      try PermissionAnswer.decision(
        for: request, verdict: .allow, message: nil, interrupt: false, always: [2])
    }
    #expect(throws: SessionError.self) {
      try PermissionAnswer.decision(
        for: request, verdict: .allow, message: nil, interrupt: false, always: [7])
    }

    live(pending: [.permission(requestID: "p1", request: request)])
    var result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "allow",
      "always": [1],
    ])
    #expect(result.isError)
    #expect(source.calls.isEmpty)

    result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "allow",
      "always": [0],
    ])
    #expect(!result.isError)
    #expect(
      source.decision
        == .allow(updatedInput: Self.bashInput, updatedPermissions: [Self.addRules("session")]))
  }

  @Test("Pending suggestions are the offered ones, by index, with their rules")
  func suggestionsEncoded() {
    let request = Self.request("Bash", Self.bashInput, suggestions: Self.suggestions)
    let encoded = Encoding.pending(.permission(requestID: "p1", request: request))
    #expect(encoded["suggestions"] == [["index": 0, "rules": ["Bash(ls:*)"]]])
  }

  @Test("A deny applies nothing: always with it is refused")
  func denyTakesNoAlways() {
    let request = Self.request("Bash", Self.bashInput, suggestions: Self.suggestions)
    #expect(throws: SessionError.self) {
      try PermissionAnswer.decision(
        for: request, verdict: .deny, message: nil, interrupt: false, always: [0])
    }
  }

  // MARK: - Plans

  @Test("A plan is approved with every edit still asking")
  func planApprovedManually() async {
    let request = Self.request(PlanApproval.toolName, Self.planInput)
    live(pending: [.permission(requestID: "p1", request: request)])
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "allow",
    ])
    #expect(!result.isError)
    #expect(source.decision == PlanApproval.approve(Self.planInput, editsManually: true))
  }

  @Test("A plan denied keeps planning, the message its feedback")
  func planDeniedKeepsPlanning() async {
    let request = Self.request(PlanApproval.toolName, Self.planInput)
    live(pending: [.permission(requestID: "p1", request: request)])
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "deny",
      "message": "tighter",
    ])
    #expect(!result.isError)
    #expect(source.decision == PlanApproval.keepPlanning(feedback: "tighter"))
  }

  @Test("A plan takes no always")
  func planTakesNoAlways() {
    let request = Self.request(
      PlanApproval.toolName, Self.planInput, suggestions: [Self.addRules("session")])
    #expect(throws: SessionError.self) {
      try PermissionAnswer.decision(
        for: request, verdict: .allow, message: nil, interrupt: false, always: [0])
    }
  }

  // MARK: - What is not a permission prompt

  @Test("A question is sent to drakar_answer_question")
  func questionRedirected() async {
    let input: DrakarKit.JSONValue = .object([
      "questions": .array([
        .object([
          "question": .string("Which?"),
          "options": .array([.object(["label": .string("A")])]),
        ])
      ])
    ])
    live(pending: [
      .permission(requestID: "q1", request: Self.request(UserQuestion.toolName, input))
    ])
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("q1"), "decision": "allow",
    ])
    #expect(result.isError)
    #expect(result.text.contains("drakar_answer_question"))
    #expect(source.calls.isEmpty)
  }

  @Test("An MCP server's form is sent to drakar_answer_question")
  func elicitationRedirected() async throws {
    let elicitation = try #require(
      Elicitation(
        claudeRequest: .object([
          "mcp_server_name": .string("github"), "message": .string("Open this"),
          "mode": .string("url"), "url": .string("https://example.com"),
        ])))
    live(pending: [.elicitation(requestID: "e1", elicitation: elicitation)])
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("e1"), "decision": "allow",
    ])
    #expect(result.isError)
    #expect(result.text.contains("drakar_answer_question"))
    #expect(source.calls.isEmpty)
  }

  @Test("A request no longer pending is already answered")
  func alreadyAnswered() async {
    live()
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("p1"), "decision": "allow",
    ])
    #expect(result.isError)
    #expect(
      result.text == "Request p1 is no longer waiting: already answered, or the turn ended.")
    #expect(source.calls.isEmpty)
  }

  /// A Codex process numbers its requests from "0" again: after End Session and a resume, the
  /// id an agent read can name a request it never saw. That one is not answered.
  @Test("A request replaced by another under the same raw id is no longer waiting")
  func replacedUnderTheSameRawID() async {
    live(pending: [.permission(requestID: "0", request: Self.request("Bash", Self.bashInput))])
    let read = requestID("0")
    let other = Self.request("Bash", .object(["command": .string("git push --force")]))
    live(pending: [.permission(requestID: "0", request: other)])
    #expect(read != requestID("0"))

    let result = await call(["session": .string(Self.id), "request_id": read, "decision": "allow"])
    #expect(result.isError)
    #expect(
      result.text
        == "Request \(read.stringValue ?? "") is no longer waiting: already answered, or the turn ended."
    )
    #expect(source.calls.isEmpty)
    #expect(source.decision == nil)
  }

  @Test("A raw id without its fingerprint is refused; the answer names the request read")
  func rawIDRefusedAndFingerprintPassedOn() async {
    let item = PendingItem.permission(
      requestID: "p1", request: Self.request("Bash", Self.bashInput))
    live(pending: [item])
    var result = await call(["session": .string(Self.id), "request_id": "p1", "decision": "allow"])
    #expect(result.isError)
    #expect(source.calls.isEmpty)

    result = await call(
      ["session": .string(Self.id), "request_id": requestID("p1"), "decision": "allow"])
    #expect(!result.isError)
    #expect(source.answered == RequestID(item))
  }

  // MARK: - Codex

  /// A Codex file-change approval as `CodexTranslator` builds it: tool "Edit", an empty
  /// input, the patch only in its kind.
  private static func codexPatch(
    _ edits: [FileEdit], reason: String? = nil, itemID: String = "item_1"
  ) -> PermissionRequest {
    var request = PermissionRequest(
      toolName: "Edit", input: .object([:]), description: reason, toolUseID: itemID,
      kind: .fileChange(path: edits.first?.path ?? "", edits: edits))
    request.suggestions = [CodexPolicy.acceptForSession]
    return request
  }

  /// Reads `first` as raw id "0", then puts `second` in its place under the same raw id, as a
  /// new `codex app-server` process does after End Session and a resume, and answers the id
  /// read with `always`.
  private func answerReadIDAfterReplacement(
    _ first: PermissionRequest, _ second: PermissionRequest, always: MCPKit.JSONValue? = nil
  ) async -> (read: MCPKit.JSONValue, result: ToolResult) {
    live(pending: [.permission(requestID: "0", request: first)])
    let read = requestID("0")
    live(pending: [.permission(requestID: "0", request: second)])
    var arguments: [String: MCPKit.JSONValue] = [
      "session": .string(Self.id), "request_id": read, "decision": "allow",
    ]
    if let always { arguments["always"] = always }
    return (read, await call(.object(arguments)))
  }

  private func expectNoLongerWaiting(_ read: MCPKit.JSONValue, _ result: ToolResult) {
    #expect(result.isError)
    #expect(
      result.text
        == "Request \(read.stringValue ?? "") is no longer waiting: already answered, or the turn ended."
    )
    #expect(source.calls.isEmpty)
    #expect(source.decision == nil)
  }

  @Test("Two Codex patches under raw id 0 differing only in their edits are told apart")
  func codexPatchesDifferingInEdits() async {
    let first = Self.codexPatch([
      FileEdit(path: "/repo/a.swift", change: .patch("@@ -1 +1 @@\n-old\n+new"))
    ])
    let second = Self.codexPatch([
      FileEdit(path: "/repo/a.swift", change: .patch("@@ -1 +1 @@\n-old\n+rm -rf ~"))
    ])
    #expect(
      RequestID.fingerprint(of: .permission(requestID: "0", request: first))
        != RequestID.fingerprint(of: .permission(requestID: "0", request: second)))
    let (read, result) = await answerReadIDAfterReplacement(first, second)
    expectNoLongerWaiting(read, result)
  }

  @Test("Two Codex requests under raw id 0 differing only in their reason are told apart")
  func codexRequestsDifferingInDescription() async {
    let edits = [FileEdit(path: "/repo/a.swift", change: .patch("@@ -1 +1 @@\n-a\n+b"))]
    let first = Self.codexPatch(edits, reason: "Fix the typo")
    let second = Self.codexPatch(edits, reason: "Write outside the workspace")
    #expect(
      RequestID.fingerprint(of: .permission(requestID: "0", request: first))
        != RequestID.fingerprint(of: .permission(requestID: "0", request: second)))
    let (read, result) = await answerReadIDAfterReplacement(first, second)
    expectNoLongerWaiting(read, result)
  }

  @Test("Two requests under raw id 0 differing only in their suggestions are told apart")
  func requestsDifferingInSuggestions() async {
    let rule = { (content: String) -> DrakarKit.JSONValue in
      .object([
        "type": .string("addRules"),
        "rules": .array([
          .object(["toolName": .string("Bash"), "ruleContent": .string(content)])
        ]),
        "behavior": .string("allow"),
        "destination": .string("session"),
      ])
    }
    let first = Self.request("Bash", Self.bashInput, suggestions: [rule("ls:*")])
    let second = Self.request("Bash", Self.bashInput, suggestions: [rule("rm:*")])
    #expect(
      RequestID.fingerprint(of: .permission(requestID: "0", request: first))
        != RequestID.fingerprint(of: .permission(requestID: "0", request: second)))
    let (read, result) = await answerReadIDAfterReplacement(first, second, always: [0])
    expectNoLongerWaiting(read, result)
  }

  @Test("Codex's session-long yes is the decision the permission sheet sends")
  func codexDecisionMatchesSheet() async throws {
    var request = PermissionRequest(
      toolName: "Shell", input: .object(["command": .string("make test")]), toolUseID: "item_1",
      kind: .other)
    request.suggestions = [CodexPolicy.acceptForSession]
    let suggestion = try #require(request.parsedSuggestions.first)
    #expect(AlwaysOffer.offered(request) == [suggestion])
    #expect(
      Encoding.pending(.permission(requestID: "c1", request: request))["suggestions"]
        == [["index": 0, "decision": "acceptForSession"]])

    live(pending: [.permission(requestID: "c1", request: request)])
    let result = await call([
      "session": .string(Self.id), "request_id": requestID("c1"), "decision": "allow",
      "always": [0],
    ])
    #expect(!result.isError)
    // PermissionSheet's suggestion button.
    #expect(
      source.decision
        == .allow(updatedInput: request.input, updatedPermissions: [suggestion.raw]))
  }
}
