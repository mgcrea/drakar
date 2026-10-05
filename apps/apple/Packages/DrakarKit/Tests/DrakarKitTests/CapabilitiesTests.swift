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
}
