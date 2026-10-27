import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Answering an MCP server's question in its card")
struct ElicitationPanelTests {

  private static func question(server: String = "elicit", mode: String = #""mode":"form""#)
    -> String
  {
    #"{"type":"control_request","request_id":"e1","request":{"subtype":"elicitation","mcp_server_name":"\#(server)","message":"Which team?",\#(mode),"requested_schema":{"type":"object","properties":{"api_token":{"type":"string"},"notify":{"type":"boolean"},"size":{"type":"integer"},"team":{"type":"string"}},"required":["team"]}}}"#
  }

  private static func call(_ id: String, name: String, parent: String? = nil) -> String {
    let parent = parent.map { #""\#($0)""# } ?? "null"
    return
      #"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]},"parent_tool_use_id":\#(parent),"session_id":"s"}"#
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

  private func anchor(_ lines: [String]) throws -> String? {
    let feed = try feed(lines + [Self.question()])
    let pending = try #require(feed.pendingElicitations.first)
    return AskedElicitation.anchor(for: pending.elicitation, in: feed.transcript)
  }

  /// The card is the server's newest call still running.
  @Test func anchorsInTheServersRunningCall() throws {
    #expect(
      try anchor([
        Self.call("t1", name: "mcp__elicit__ask_team"), Self.result("t1"),
        Self.call("t2", name: "mcp__elicit__ask_team"), Self.call("t3", name: "mcp__other__x"),
      ]) == "t2")
  }

  /// No call of the server's still running, or one inside a subagent's card, which may be
  /// folded: the question waits in the composer's place instead.
  @Test func docksWithoutACallInSight() throws {
    #expect(try anchor([Self.call("t1", name: "mcp__elicit__ask_team"), Self.result("t1")]) == nil)
    #expect(
      try anchor([
        Self.call("a1", name: "Agent"),
        Self.call("t1", name: "mcp__elicit__ask_team", parent: "a1"),
      ]) == nil)
  }

  @Test func showsItsPlaceOnlyAmongSeveral() {
    #expect(ElicitationPanel.positionText(nil) == nil)
    #expect(ElicitationPanel.positionText((1, 1)) == nil)
    #expect(ElicitationPanel.positionText((1, 3)) == "1 of 3")
  }

  @Test func namesTheLinksHost() throws {
    let url = try #require(URL(string: "https://example.com/auth?x=1"))
    #expect(ElicitationPanel.hostText(url) == "example.com")
  }

  /// A field says what is wrong with it once it was changed, not before.
  @Test func showsProblemsOnlyOfFieldsChanged() throws {
    let feed = try feed([Self.question()])
    guard case .form(let form) = try #require(feed.pendingElicitations.first).elicitation.content
    else {
      Issue.record("not a form")
      return
    }
    let problems = form.problems(in: form.initialInputs)
    #expect(problems["team"] != nil)
    #expect(ElicitationPanel.shownProblems(problems, edited: []).isEmpty)
    #expect(ElicitationPanel.shownProblems(problems, edited: ["team"]) == ["team": "Required"])
  }

  /// The keys go to the first field typed in; a link has none, so the panel takes them.
  @Test func focusesTheFirstTypedField() throws {
    let feed = try feed([Self.question()])
    let elicitation = try #require(feed.pendingElicitations.first).elicitation
    #expect(ElicitationPanel.firstTypedField(elicitation.content) == "team")
    let link = try self.feed([
      #"{"type":"control_request","request_id":"u1","request":{"subtype":"elicitation","mcp_server_name":"elicit","message":"Sign in","mode":"url","url":"https://example.com/auth","elicitation_id":"el-1"}}"#
    ])
    let url = try #require(link.pendingElicitations.first).elicitation
    #expect(ElicitationPanel.firstTypedField(url.content) == nil)
  }

  /// Under a form whose session's host logs answers whole, a line says so; never under a
  /// link, whose answer holds nothing typed, nor for a host that keeps it out of its log.
  @Test func saysWhenAnOlderHostLogsTheAnswer() throws {
    let form = try #require(feed([Self.question()]).pendingElicitations.first).elicitation.content
    let link = Elicitation.Content.url(try #require(URL(string: "https://example.com")))
    #expect(
      ElicitationPanel.hostCaveat(form, hostLogsAnswers: true)
        == "This session's host is from an earlier build and keeps what you send here in its log until it restarts."
    )
    #expect(ElicitationPanel.hostCaveat(form, hostLogsAnswers: false) == nil)
    #expect(ElicitationPanel.hostCaveat(link, hostLogsAnswers: true) == nil)
    #expect(ElicitationPanel.hostCaveat(.unsupported, hostLogsAnswers: true) == nil)
  }

  /// While the session reconnects an answer would reach nobody: the buttons wait, and the
  /// footer says why in place of its keys.
  @Test func waitsWhileReconnecting() throws {
    let form = try #require(feed([Self.question()]).pendingElicitations.first).elicitation.content
    let link = Elicitation.Content.url(try #require(URL(string: "https://example.com")))
    #expect(ElicitationPanel.hint(form, isReconnecting: false) == "⌘↩ to submit, Esc to decline")
    #expect(ElicitationPanel.hint(link, isReconnecting: false) == "⌘↩ to open, Esc to decline")
    for content in [form, link, .unsupported] {
      #expect(ElicitationPanel.hint(content, isReconnecting: true) == "Reconnecting…")
    }
  }

  @Test func picksAndUnpicksAmongSeveral() {
    let one = ElicitationPanel.picking("core", true, in: nil)
    #expect(one == .picks(["core"]))
    let two = ElicitationPanel.picking("web", true, in: one)
    #expect(two == .picks(["core", "web"]))
    #expect(ElicitationPanel.picking("core", false, in: two) == .picks(["web"]))
  }
}
