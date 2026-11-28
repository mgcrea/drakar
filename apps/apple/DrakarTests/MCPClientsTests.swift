import DrakarKit
import Foundation
import MCPKitWiring
import Testing

@testable import Drakar

/// Which clients Settings › MCP Server lists, and what the entry names. The writing itself is
/// the kit's and tested there.
@MainActor
@Suite struct MCPClientsTests {
  private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

  private func account(_ folder: String, isDefault: Bool = false) -> ClaudeAccount {
    ClaudeAccount(
      directory: home.appending(path: folder, directoryHint: .isDirectory), isDefault: isDefault)
  }

  @Test func oneAccountIsPlainClaudeCodeWritingTheFileBesideItsFolder() {
    let clients = MCPSetup.clients(accounts: [account(".claude", isDefault: true)], home: home)
    #expect(clients.first?.displayName == "Claude Code")
    #expect(clients.first?.configURL.path == "/Users/someone/.claude.json")
  }

  @Test func everyAccountGetsItsOwnRowAndFile() {
    let clients = MCPSetup.clients(
      accounts: [account(".claude", isDefault: true), account(".claude-work")], home: home)
    let claude = clients.filter { $0.id.hasPrefix("claude-code") }
    #expect(claude.map(\.displayName) == ["Claude Code · default", "Claude Code · work"])
    #expect(claude.last?.configURL.path == "/Users/someone/.claude-work/.claude.json")
    #expect(Set(claude.map(\.id)).count == 2)
  }

  /// Claude Desktop, LM Studio and Windsurf only start servers they launch themselves, and the
  /// catalog's own Claude Code row would write the default account's file a second time.
  @Test func noClientThatTakesNoURLAndNoSecondDefaultClaudeCode() {
    let clients = MCPSetup.clients(accounts: [account(".claude", isDefault: true)], home: home)
    #expect(clients.allSatisfy { $0.acceptsHTTP })
    #expect(!clients.contains { $0.id == "claude-code" })
  }

  @Test func theEntryIsFiledUnderThisBuildsKey() {
    #expect(MCPSetup.wiring.key == MCPSetup.serverName)
  }
}
