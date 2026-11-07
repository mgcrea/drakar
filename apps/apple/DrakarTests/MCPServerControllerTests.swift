import DrakarKit
import DrakarMCP
import Foundation
import MCPKit
import MCPKitLoopback
import Testing

@testable import Drakar

/// When the app's server runs, on which port, and under which name: the decisions, without a
/// socket. Hosted, the controller never listens, so these are the whole of what a test sees.
@MainActor
@Suite struct MCPServerControllerTests {
  @Test func itRunsOnlyWhenOnOnAPortItCanTakeAndNotHosted() {
    #expect(MCPServerController.shouldRun(isEnabled: true, port: 8811, isHosted: false))
    #expect(!MCPServerController.shouldRun(isEnabled: false, port: 8811, isHosted: false))
    // Below 1024 needs root to bind.
    #expect(!MCPServerController.shouldRun(isEnabled: true, port: 80, isHosted: false))
    // A test host would take the developer's own copy's port.
    #expect(!MCPServerController.shouldRun(isEnabled: true, port: 8811, isHosted: true))
  }

  @Test func aListenerUpOnThePortIsKeptAndAnyOtherRestarted() {
    #expect(MCPServerController.needsStart(state: .stopped, boundPort: nil, port: 8811))
    #expect(
      MCPServerController.needsStart(state: .running(port: 8811), boundPort: 8811, port: 9000))
    #expect(
      !MCPServerController.needsStart(state: .running(port: 8811), boundPort: 8811, port: 8811))
    // A port in use is tried again on the next sync.
    #expect(MCPServerController.needsStart(state: .failed("in use"), boundPort: 8811, port: 8811))
  }

  @Test func aTypedPortIsWrittenOnlyWhenItChanges() {
    #expect(MCPServerController.draft(nil, stored: 8811) == .revert)
    #expect(MCPServerController.draft(8811, stored: 8811) == .keep)
    #expect(MCPServerController.draft(9000, stored: 8811) == .write(9000))
    #expect(MCPServerController.draft(22, stored: 8811) == .revert)
  }

  @Test func theDebugCopyHasItsOwnPortKeychainAndName() {
    #if DEBUG
      #expect(MCPServerController.defaultPort == 8812)
      #expect(MCPServerController.keychainService == "io.mgcrea.Drakar.mcp-dev")
      #expect(MCPSetup.serverName == "drakar-dev")
    #else
      #expect(MCPServerController.defaultPort == 8811)
      #expect(MCPServerController.keychainService == "io.mgcrea.Drakar.mcp")
      #expect(MCPSetup.serverName == "drakar")
    #endif
  }

  @Test func everyWriteToolBastionHoldsBackIsInTheServersTable() {
    let server = MCPServerController.server(source: NoSessions())
    let names = server.tools.listing(allowWrites: true).map(\.name)
    #expect(Set(Tools.writeTools).isSubset(of: Set(names)))
    #expect(server.info.name == MCPSetup.serverName)
  }

  /// Settings › MCP Server closes the configuration section, after Runner.
  @Test func settingsPaneListed() throws {
    let panes = SettingsPane.allCases
    let mcp = try #require(panes.firstIndex(of: .mcp))
    let runner = try #require(panes.firstIndex(of: .runner))
    #expect(mcp == runner + 1)
    #expect(SettingsPane.mcp.group == .configuration)
    #expect(panes.last { $0.group == .configuration } == .mcp)
    #expect(SettingsPane.mcp.title == "MCP Server")
    #expect(SettingsPane.mcp.systemImage == "point.3.connected.trianglepath.dotted")
  }
}

/// A source with nothing in it: the table is built from the source's type, not its answers.
private nonisolated struct NoSessions: SessionSource {
  func sessions(includeEnded: Bool, endedLimit: Int) async -> [SessionRow] { [] }
  func detail(of id: String) async -> SessionDetail? { nil }
  func attention() async -> [AttentionItem] { [] }
  func transcript(of id: String) async throws -> Transcript { Transcript() }
  func projects() async -> [DrakarMCP.ProjectRow] { [] }
  func runner() async -> RunnerStatus? { nil }
  func workRefusal() async -> String? { nil }
  func permissionsAllowed() async -> Bool { false }
  func start(_ request: StartRequest) async throws -> String { "" }
  func send(to id: String, text: String) async throws -> SendOutcome { .sent }
  func interrupt(_ id: String) async throws {}
  func end(_ id: String) async throws {}
  func answer(_ id: String, requestID: String, with decision: PermissionDecision) async throws {}
  func answer(_ id: String, requestID: String, with answer: ElicitationAnswer) async throws {}
}
