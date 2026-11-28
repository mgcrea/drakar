import DrakarKit
import Foundation
import MCPKitUI
import MCPKitWiring

extension MCPSetup {
  /// Writes Drakar's server into the MCP clients on this Mac, and keeps them current: the kit's
  /// controller, given Drakar's key, address and token.
  ///
  /// Kept current unasked in both builds. Elsewhere a Debug build may not rewire, because it
  /// shares its key with the installed app but not its token. Here it shares neither:
  /// `drakar-dev` is its own key, on its own port, with its own Keychain item.
  @MainActor static let wiring = MCPClientWiring(
    appName: "Drakar", key: serverName, autoRewires: true, subsystem: "io.mgcrea.Drakar",
    clients: { clients() },
    url: { "http://127.0.0.1:\(String(storedPort))/mcp" },
    token: { MCPServerController.shared.token },
    tokenProblem: { MCPServerController.shared.tokenError })

  /// The port in Settings, not the one bound, so the address matches the listener the switch
  /// will start.
  private static var storedPort: Int {
    UserDefaults.standard.object(forKey: MCPSettingsKey.port) as? Int
      ?? MCPServerController.defaultPort
  }

  /// A Claude Code row per account Drakar runs sessions under, since a server added to one
  /// account's `.claude.json` is invisible to sessions on the others; then every other client
  /// in the kit's catalog that takes a URL and is installed.
  @MainActor static func clients(
    accounts: [ClaudeAccount] = ClaudeAccount.discover(),
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [WiringClient] {
    let claude = accounts.map { account in
      WiringClient.claudeCode(
        configURL: account.configFile, evidence: [account.directory],
        id: "claude-code:\(account.key)",
        displayName: accounts.count > 1 ? "Claude Code · \(account.name)" : "Claude Code")
    }
    let others = WiringClient.catalog(home: home)
      .filter { $0.id != "claude-code" && $0.acceptsHTTP && $0.isInstalled }
    return claude + others
  }
}
