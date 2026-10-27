import DrakarKit
import Foundation
import Testing

/// An MCP server's question stays on the transcript until the person answers it, the CLI
/// withdraws it, or the turn or the process ends. What it notes names the server and the
/// question, never an answer.
@Suite("A question from an MCP server waits")
struct TranscriptElicitationTests {

  private static func question(_ id: String, server: String = "linear") -> String {
    #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"elicitation","mcp_server_name":"\#(server)","message":"Which team?","mode":"form","requested_schema":{"type":"object","properties":{"api_token":{"type":"string"}}}}}"#
  }

  private static let link =
    #"{"type":"control_request","request_id":"u1","request":{"subtype":"elicitation","mcp_server_name":"linear","message":"Sign in to continue","mode":"url","url":"https://example.com/auth?x=1","elicitation_id":"el-1"}}"#

  private static func call(_ id: String, name: String) -> String {
    #"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]},"parent_tool_use_id":null,"session_id":"s"}"#
  }

  private static func result(_ id: String) -> String {
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]},"parent_tool_use_id":null,"session_id":"s"}"#
  }

  private func feed(_ lines: [String]) throws -> ClaudeFeed {
    var feed = ClaudeFeed()
    feed.addPrompt("Run it")
    for line in lines { feed.apply(try StreamMessage(line: Data(line.utf8))) }
    return feed
  }

  private func lastNotice(_ feed: ClaudeFeed) -> String? {
    if case .notice(let note) = feed.entries.last?.kind { return note }
    return nil
  }

  @Test func notesTheAnswerWithoutItsValues() throws {
    var feed = try feed([Self.question("e1")])
    feed.resolveElicitation(requestID: "e1", with: .accept(["api_token": .string("SECRET")]))
    #expect(feed.pendingElicitations.isEmpty)
    #expect(lastNotice(feed) == "Answered linear's question: Which team?")
    #expect(!feed.entries.contains { String(describing: $0).contains("SECRET") })
  }

  @Test func notesADecline() throws {
    var feed = try feed([Self.question("e1")])
    feed.resolveElicitation(requestID: "e1", with: .decline)
    #expect(feed.pendingElicitations.isEmpty)
    #expect(lastNotice(feed) == "Declined linear's question: Which team?")
  }

  @Test func notesACancel() throws {
    var feed = try feed([Self.question("e1")])
    feed.resolveElicitation(requestID: "e1", with: .cancel)
    #expect(feed.pendingElicitations.isEmpty)
    #expect(lastNotice(feed) == "Cancelled linear's question: Which team?")
  }

  @Test func notesALinkOpened() throws {
    var feed = try feed([Self.link])
    feed.resolveElicitation(requestID: "u1", with: .accept(nil))
    #expect(feed.pendingElicitations.isEmpty)
    #expect(lastNotice(feed) == "Opened linear's link to example.com")
  }

  @Test func notesAWithdrawal() throws {
    let feed = try feed([
      Self.question("e1"), #"{"type":"control_cancel_request","request_id":"e1"}"#,
    ])
    #expect(feed.pendingElicitations.isEmpty)
    #expect(lastNotice(feed) == "linear withdrew its question: Which team?")
  }

  /// An answer to a question no longer waiting notes nothing.
  @Test func anAnswerToNothingNotesNothing() throws {
    var feed = try feed([])
    feed.resolveElicitation(requestID: "e1", with: .decline)
    #expect(feed.entries.map(\.kind) == [.prompt("Run it")])
  }

  @Test func aWithdrawnFirstLeavesTheSecond() throws {
    let feed = try feed([
      Self.question("e1"), Self.question("e2"),
      #"{"type":"control_cancel_request","request_id":"e1"}"#,
    ])
    #expect(feed.pendingElicitations.map(\.requestID) == ["e2"])
    #expect(feed.waitingCount == 1)
  }

  @Test func countsBothKindsOfWaiting() throws {
    let permission =
      #"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t1"}}"#
    let feed = try feed([Self.question("e1"), permission])
    #expect(feed.pendingPermissions.count == 1)
    #expect(feed.waitingCount == 2)
    #expect(feed.isWaitingOnPerson)
  }

  @Test func aTurnEndClearsTheQuestions() throws {
    let feed = try feed([
      Self.question("e1"),
      #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#,
    ])
    #expect(feed.pendingElicitations.isEmpty)
    #expect(!feed.isWaitingOnPerson)
  }

  @Test func anExitClearsTheQuestions() throws {
    var feed = try feed([Self.question("e1")])
    feed.processExited()
    #expect(feed.pendingElicitations.isEmpty)
    #expect(!feed.isWaitingOnPerson)
  }

  @Test func anchorsToTheOpenCall() throws {
    let feed = try feed([
      Self.call("a", name: "mcp__linear__a"), Self.result("a"),
      Self.call("b", name: "mcp__linear__b"),
    ])
    #expect(feed.transcript.elicitationAnchor(for: "linear") == "b")
    let answered = try self.feed([
      Self.call("a", name: "mcp__linear__a"), Self.result("a"),
    ])
    #expect(answered.transcript.elicitationAnchor(for: "linear") == nil)
  }

  /// A call an earlier turn left without a result, interrupted, is not the one asking: only
  /// the current turn's calls are.
  @Test func anchorsOnlyInTheCurrentTurn() throws {
    var feed = try feed([Self.call("old", name: "mcp__linear__a")])
    feed.addPrompt("Again")
    #expect(feed.transcript.elicitationAnchor(for: "linear") == nil)
    feed.apply(try StreamMessage(line: Data(Self.call("new", name: "mcp__linear__a").utf8)))
    #expect(feed.transcript.elicitationAnchor(for: "linear") == "new")
  }

  /// Claude Code names a server's tools after its name with every character outside
  /// `[A-Za-z0-9_-]` made `_`.
  @Test func anchorsToACallWhoseServerNameWasNormalised() throws {
    let feed = try feed([Self.call("f", name: "mcp__my_server_v2__find")])
    #expect(feed.transcript.elicitationAnchor(for: "my server.v2") == "f")
  }
}
