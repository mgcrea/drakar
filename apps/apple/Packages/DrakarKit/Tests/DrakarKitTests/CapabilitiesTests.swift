import DrakarKit
import Foundation
import Testing

@Suite("What a project's claude would load")
struct CapabilitiesTests {

  private func reply(_ id: String) throws -> JSONValue? {
    let responses = try Fixture.capabilities.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message { return response }
      return nil
    }
    return try #require(responses.first { $0.requestID == id }).response
  }

  private func skills() throws -> [SkillEntry] {
    try #require(ProjectCapabilities.skills(fromInitialize: try reply("probe-init")))
  }

  private func servers() throws -> [MCPServerEntry] {
    try #require(ProjectCapabilities.servers(fromMCPStatus: try reply("probe-mcp")))
  }

  /// The CLI's own commands, `/compact` and the bundled `/simplify` alike, are not skills
  /// the project brings.
  @Test func listsSkillsWithoutTheCLIsOwn() throws {
    #expect(
      Set(try skills().map(\.name))
        == ["check", "superpowers:brainstorming", "marketing:seo-audit", "distill"])
  }

  /// An empty hint is a skill a click sends at once.
  @Test func anEmptyHintTakesNoArguments() throws {
    let skills = try skills()
    let check = try #require(skills.first { $0.name == "check" })
    let audit = try #require(skills.first { $0.name == "marketing:seo-audit" })
    #expect(!check.takesArguments)
    #expect(audit.takesArguments)
    #expect(audit.argumentHint == "<url or topic> [audit type]")
  }

  /// No `commands` is not an empty list: the CLI did not say, and the pane says so.
  @Test func aReplyWithoutCommandsListsNothing() {
    #expect(ProjectCapabilities.skills(fromInitialize: nil) == nil)
    #expect(ProjectCapabilities.skills(fromInitialize: .object([:])) == nil)
    #expect(ProjectCapabilities.skills(fromInitialize: .object(["commands": .array([])])) == [])
    #expect(ProjectCapabilities.servers(fromMCPStatus: .object([:])) == nil)
  }

  @Test func readsEveryServerStatus() throws {
    let status = Dictionary(uniqueKeysWithValues: try servers().map { ($0.name, $0.status) })
    #expect(status["armada"] == .connected)
    #expect(status["tracker"] == .failed)
    #expect(status["plugin:stripe:stripe"] == .needsAuth)
    #expect(status["claude.ai Gmail"] == .needsAuth)
    #expect(status["claude.ai Claude Docs"] == .pending)
    #expect(status["later"] == .other("disabled"))
  }

  /// A server without a name is dropped, not shown as a blank row.
  @Test func skipsAServerWithoutAName() throws {
    #expect(try servers().count == 7)
  }

  @Test func readsToolsVersionSourceAndError() throws {
    let servers = try servers()
    let armada = try #require(servers.first { $0.name == "armada" })
    #expect(armada.version == "1.9.0")
    #expect(armada.source == "user")
    #expect(
      armada.tools == [
        MCPTool(name: "armada_get_fleet", isReadOnly: true, isDestructive: false),
        MCPTool(name: "armada_close_session", isReadOnly: false, isDestructive: true),
        MCPTool(name: "armada_send_message", isReadOnly: false, isDestructive: false),
      ])
    let tracker = try #require(servers.first { $0.name == "tracker" })
    #expect(tracker.error == "the token request failed: Grant not found")
    #expect(tracker.tools.isEmpty)
  }

  /// `config` holds headers, env values and URLs with tokens in them, in clear. Nothing
  /// decoded may hold any of it.
  @Test func neverKeepsAServersConfig() throws {
    let kept = String(describing: try servers())
    #expect(!kept.contains("drakar-fixture-secret"))
    #expect(!kept.contains("Bearer"))
    #expect(!kept.contains("127.0.0.1"))
    #expect(!kept.contains("cupertino-bridge"))
  }

  // MARK: Names, filter, order

  @Test func splitsANamespaceOffTheName() {
    #expect(CapabilityName.namespace(of: "superpowers:brainstorming") == "superpowers")
    #expect(CapabilityName.shortName(of: "superpowers:brainstorming") == "brainstorming")
    #expect(CapabilityName.namespace(of: "plugin:stripe:stripe") == "plugin:stripe")
    #expect(CapabilityName.shortName(of: "plugin:stripe:stripe") == "stripe")
    #expect(CapabilityName.namespace(of: "check") == nil)
    #expect(CapabilityName.shortName(of: "check") == "check")
    // A trailing colon leaves no short name to show: the whole name stands.
    #expect(CapabilityName.shortName(of: "odd:") == "odd:")
    #expect(CapabilityName.namespace(of: "odd:") == nil)
  }

  /// The row shows the namespace already; its description does not repeat it.
  @Test func dropsTheNamespaceFromThePluginsDescription() throws {
    let skill = try #require(try skills().first { $0.name == "superpowers:brainstorming" })
    #expect(skill.displayDescription.hasPrefix("You MUST use this"))
    let check = try #require(try skills().first { $0.name == "check" })
    #expect(check.displayDescription == check.description)
  }

  /// Case, accents and stray spaces do not matter; a blank filter keeps everything.
  @Test func filtersAsAPersonTypes() {
    let skill = SkillEntry(
      name: "superpowers:brainstorming", description: "Explores intent before the design")
    #expect(skill.matches(""))
    #expect(skill.matches("   "))
    #expect(skill.matches("  BRAIN"))
    #expect(skill.matches("intent"))
    #expect(!skill.matches("deploy"))
    let audit = SkillEntry(name: "marketing:seo-audit", description: "Audit the site")
    #expect(audit.matches("sèo"))
    let server = MCPServerEntry(name: "plugin:stripe:stripe", status: .needsAuth)
    #expect(server.matches("Stripe"))
    #expect(!server.matches("armada"))
  }

  @Test func sortsSkillsByTheirShortName() throws {
    #expect(
      try skills().map(\.name)
        == ["superpowers:brainstorming", "check", "distill", "marketing:seo-audit"])
  }

  /// What needs the person comes first.
  @Test func sortsServersByWhatNeedsThePersonFirst() throws {
    #expect(
      try servers().map(\.name) == [
        "tracker", "claude.ai Gmail", "plugin:stripe:stripe", "armada", "claude.ai Claude Docs",
        "cupertino-calendar", "later",
      ])
  }

  // MARK: Changes

  private func lists(_ skills: [String], _ servers: [(String, MCPServerStatus)])
    -> ProjectCapabilities
  {
    ProjectCapabilities(
      skills: skills.map { SkillEntry(name: $0) },
      mcpServers: servers.map { MCPServerEntry(name: $0.0, status: $0.1) })
  }

  /// The first reading of a list is not news.
  @Test func aFirstReadingMarksNothing() {
    let new = lists(["a"], [("s", .failed)])
    #expect(CapabilityChanges.diff(from: nil, to: new).isEmpty)
    #expect(CapabilityChanges.diff(from: ProjectCapabilities(), to: new).isEmpty)
  }

  @Test func marksAddedSkillsAndServersGoneWrong() {
    let old = lists(["a"], [("up", .connected), ("waiting", .pending), ("bad", .failed)])
    let new = lists(
      ["a", "b"],
      [
        ("up", .failed), ("waiting", .needsAuth), ("bad", .connected), ("fresh", .needsAuth),
        ("fine", .connected),
      ])
    let changes = CapabilityChanges.diff(from: old, to: new)
    #expect(changes.addedSkills == ["b"])
    // `waiting` was never connected, `bad` got better, `fine` is new and well: no mark.
    #expect(changes.worsenedServers == ["up", "fresh"])
  }

  @Test func aRemovedRowMarksNothing() {
    let changes = CapabilityChanges.diff(
      from: lists(["a", "b"], [("s", .connected)]), to: lists(["a"], []))
    #expect(changes.isEmpty)
  }

  // MARK: The probe's replies

  private func response(_ line: String) throws -> ControlResponse {
    guard case .controlResponse(let response) = try StreamMessage(line: Data(line.utf8)) else {
      Issue.record("not a control response: \(line)")
      throw CancellationError()
    }
    return response
  }

  @Test func collectsBothRepliesByTheirIDs() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    for message in try Fixture.capabilities.messages {
      if case .controlResponse(let response) = message { replies.take(response) }
    }
    #expect(replies.isComplete)
    #expect(replies.capabilities.skills?.count == 4)
    #expect(replies.capabilities.mcpServers?.count == 7)
  }

  /// A session's own context reply, or anything else, is not the probe's.
  @Test func ignoresOtherReplies() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    replies.take(
      try response(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"context-1","response":{"commands":[]}}}"#
      ))
    #expect(!replies.hasInitialize)
    #expect(replies.capabilities == ProjectCapabilities())
  }

  /// An older CLI that refuses `mcp_status` answers with an error: kept, for the pane.
  @Test func anErrorAnswerIsKept() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    replies.take(
      try response(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"probe-mcp","error":"Unknown request subtype: mcp_status"}}"#
      ))
    #expect(replies.hasStatus)
    #expect(replies.capabilities.mcpServers == nil)
    #expect(replies.statusError == "Unknown request subtype: mcp_status")
  }

  private func status(_ id: String, _ server: String, _ state: String) throws -> ControlResponse {
    try response(
      #"{"type":"control_response","response":{"subtype":"success","request_id":""#
        + id + #"","response":{"mcpServers":[{"name":""# + server + #"","status":""# + state
        + #""}]}}}"#)
  }

  /// A server still connecting at the first `mcp_status`: asked again under a new id, the
  /// later reply's servers replace the first's.
  @Test func takesALaterStatusUnderANewID() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    replies.take(try status("probe-mcp", "armada", "pending"))
    #expect(replies.hasPendingServers)
    let again = replies.askStatusAgain()
    #expect(again == "probe-mcp-2")
    #expect(replies.askStatusAgain() == "probe-mcp-3")
    replies.take(try status(again, "armada", "connected"))
    #expect(!replies.hasPendingServers)
    #expect(replies.capabilities.mcpServers?.map(\.status) == [.connected])
    // An id never asked is still not the probe's.
    replies.take(try status("probe-mcp-9", "armada", "failed"))
    #expect(replies.capabilities.mcpServers?.map(\.status) == [.connected])
  }

  /// A later status that fails, or answers late behind a newer one, keeps the newest list.
  @Test func keepsTheLatestSuccessfulStatus() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    replies.take(try status("probe-mcp", "armada", "pending"))
    let second = replies.askStatusAgain()
    let third = replies.askStatusAgain()
    replies.take(try status(third, "armada", "connected"))
    replies.take(try status(second, "armada", "pending"))
    replies.take(
      try response(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"probe-mcp-3","error":"busy"}}"#
      ))
    #expect(replies.capabilities.mcpServers?.map(\.status) == [.connected])
    #expect(replies.statusError == nil)
  }
}
