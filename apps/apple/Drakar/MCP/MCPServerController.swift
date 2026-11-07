import DrakarKit
import DrakarMCP
import Foundation
import MCPKit
import MCPKitLoopback
import MCPKitWiring
import Observation
import os

private nonisolated let log = Logger(subsystem: "io.mgcrea.Drakar", category: "MCP")

/// Where Settings › MCP Server keeps its choices.
enum MCPSettingsKey {
  static let enabled = "drakar.mcp.enabled"
  static let port = "drakar.mcp.port"
  static let allowsWrites = "drakar.mcp.allowWrites"
  /// Let agents answer permission prompts: off by default, and read by the tools at each
  /// call rather than by `sync`, so moving it never restarts the listener.
  static let allowsPermissions = "drakar.mcp.allowPermissions"
}

/// Owns the listener, the token and the decision of when to be running, in Cadence's shape:
/// one reconciler, `sync`, rather than start and stop calls spread through the views.
///
/// One for the app. Closing every window leaves it running, since the sessions it serves
/// outlive their windows; turning it off stops it. Unlike Cadence's, the licence has no say
/// in whether it runs: sending work is refused at the call, with the composer's sentence.
@MainActor
@Observable
final class MCPServerController {
  static let shared = MCPServerController()

  /// The next free pair after the fleet's 8787–8810. A copy run from Xcode takes the second,
  /// so it runs beside the released one without either losing its port. Nonisolated so a
  /// test and the `@AppStorage` defaults can read it off the main actor.
  #if DEBUG
    nonisolated static let defaultPort = 8812
  #else
    nonisolated static let defaultPort = 8811
  #endif

  /// Where the token is kept. Debug keeps its own: the two builds share a bundle id but may
  /// be signed differently, and a login-keychain item one wrote would prompt when the other
  /// reads it.
  #if DEBUG
    nonisolated static let keychainService = "io.mgcrea.Drakar.mcp-dev"
  #else
    nonisolated static let keychainService = "io.mgcrea.Drakar.mcp"
  #endif

  private(set) var state: LoopbackListener.State = .stopped
  private(set) var tokenError: String?
  /// What the listener running now has heard, for the pane's light. Started afresh with each
  /// listener.
  private(set) var activity = MCPActivity()

  private let tokens = KeychainTokenStore(service: MCPServerController.keychainService)
  private var listener: LoopbackListener?
  private var boundPort: Int?
  /// Readable from a connection thread, where the main actor cannot be waited on.
  private let writesAllowed = WritesFlag()

  /// The token, made on first read. Empty when the keychain refused, which the pane shows.
  var token: String {
    do {
      let value = try tokens.current()
      tokenError = nil
      return value
    } catch {
      tokenError = error.localizedDescription
      return ""
    }
  }

  func regenerateToken() {
    do {
      _ = try tokens.regenerate()
      tokenError = nil
    } catch {
      tokenError = error.localizedDescription
    }
  }

  /// Whether the listener should be up. Pulled out so a test can call it: never under a test
  /// host, whose listener would collide with the developer's own copy.
  nonisolated static func shouldRun(isEnabled: Bool, port: Int, isHosted: Bool) -> Bool {
    isEnabled && ports.contains(port) && !isHosted
  }

  /// The ports the pane takes: above the privileged ones, which need root to bind.
  nonisolated static let ports = 1024...65_535

  /// What a port typed into the pane does.
  nonisolated enum PortDraft: Equatable {
    /// Into the preference.
    case write(Int)
    /// Nothing: it is the port stored already.
    case keep
    /// Not a port the server can take, or nothing: the stored one goes back in the field.
    case revert
  }

  /// The pane's port field, decided. The stored port is kept rather than written again,
  /// because `@AppStorage` persists any write: the field is filled from the stored port as
  /// the pane appears, and writing that back would pin this build's default into the
  /// preferences the Debug and released copies share (both are `io.mgcrea.Drakar`), so the
  /// other one would then listen on this one's port.
  nonisolated static func draft(_ typed: Int?, stored: Int) -> PortDraft {
    guard let typed, ports.contains(typed) else { return .revert }
    return typed == stored ? .keep : .write(typed)
  }

  /// Drakar's own check for a test host, as `SessionHost` and the licence make it.
  private static var isHosted: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  /// Brings the listener into line with the preferences. Driven from `DrakarApp`'s scene,
  /// which calls it whenever any part of the configuration changes, so the server follows
  /// the switch with or without a window open. Safe to call on every change: a listener
  /// already up on the right port is left alone.
  func sync(_ configuration: Configuration) {
    writesAllowed.value = configuration.allowsWrites
    guard
      Self.shouldRun(
        isEnabled: configuration.isEnabled, port: configuration.port, isHosted: Self.isHosted)
    else { return stop() }
    guard
      Self.needsStart(
        state: listener?.state ?? .stopped, boundPort: boundPort, port: configuration.port)
    else { return }
    stop()
    start(port: configuration.port)
  }

  /// Whether `sync` has to start a listener: unless one is up on `port`. One that failed to
  /// bind (a port in use) is tried again on the next sync rather than kept failed until the
  /// switch or the port is changed.
  nonisolated static func needsStart(
    state: LoopbackListener.State, boundPort: Int?, port: Int
  ) -> Bool {
    guard boundPort == port, case .running = state else { return true }
    return false
  }

  /// The server the listener answers with. Separate so a test drives the same table, short
  /// of the socket.
  static func server(source: some SessionSource) -> MCPServer {
    MCPServer(
      info: ServerInfo(name: MCPSetup.serverName, version: Bundle.appVersion, title: "Drakar"),
      instructions: Tools.instructions,
      tools: Tools.table(source: source))
  }

  private func start(port: Int) {
    let listener = LoopbackListener(
      server: Self.server(source: NotReadySource()),
      gate: RequestGate(port: port) { [tokens] presented in tokens.verdict(for: presented) },
      allowWrites: { [writesAllowed] in writesAllowed.value },
      // One line per request: method, tool, outcome, duration. Never the arguments, which
      // carry prompts, answers and folders, nor anything a tool returned.
      audit: { [weak self] entry in
        let line =
          "\(entry.method ?? "?") \(entry.name ?? "-") \(String(describing: entry.outcome)) \(entry.durationMs)ms"
        log.info("mcp \(line, privacy: .public)")
        // On the connection's thread: the light is the main actor's.
        guard let kind = MCPActivity.Kind(entry.outcome) else { return }
        let date = Date.now
        Task<Void, Never> { @MainActor in self?.activity.record(kind, at: date) }
      })
    activity = MCPActivity()
    listener.start(port: port)
    self.listener = listener
    boundPort = port
    state = listener.state
    switch listener.state {
    case .running: log.info("MCP server listening on 127.0.0.1:\(port, privacy: .public)")
    case .failed(let message): log.error("MCP server failed: \(message, privacy: .public)")
    case .stopped: break
    }
  }

  private func stop() {
    listener?.stop()
    listener = nil
    boundPort = nil
    state = .stopped
  }
}

extension MCPServerController {
  /// Everything `sync` reads from the preferences, as one value, so the app can watch it and
  /// call `sync` when any part changes. Not the permission switch: the tools read it at each
  /// call.
  struct Configuration: Hashable {
    var isEnabled: Bool
    var allowsWrites: Bool
    var port: Int
  }
}

/// One boolean, written by the main actor and read by connection threads.
private nonisolated final class WritesFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false

  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// Stands in for the app's sessions until `SessionMCPSource` answers from them: nothing to
/// read, and every write refused.
private nonisolated struct NotReadySource: SessionSource {
  func sessions(includeEnded: Bool, endedLimit: Int) async -> [SessionRow] { [] }
  func detail(of id: String) async -> SessionDetail? { nil }
  func attention() async -> [AttentionItem] { [] }
  func transcript(of id: String) async throws -> Transcript { Transcript() }
  func projects() async -> [DrakarMCP.ProjectRow] { [] }
  func runner() async -> RunnerStatus? { nil }
  func workRefusal() async -> String? { Self.notReady.message }
  func permissionsAllowed() async -> Bool { false }
  func start(_ request: StartRequest) async throws -> String { throw Self.notReady }
  func send(to id: String, text: String) async throws -> SendOutcome { throw Self.notReady }
  func interrupt(_ id: String) async throws { throw Self.notReady }
  func end(_ id: String) async throws { throw Self.notReady }
  func answer(_ id: String, requestID: String, with decision: PermissionDecision) async throws {
    throw Self.notReady
  }
  func answer(_ id: String, requestID: String, with answer: ElicitationAnswer) async throws {
    throw Self.notReady
  }

  private static let notReady = SessionError("Not ready")
}

/// The server's name and its Bastion link, which the pane hands over, so the two cannot
/// drift.
enum MCPSetup {
  /// A copy run from Xcode registers under its own name, so its entry can sit beside the
  /// released copy's in one client's config.
  static var serverName: String {
    #if DEBUG
      "drakar-dev"
    #else
      "drakar"
    #endif
  }

  static func bastionLink(port: Int, token: String) -> BastionLink {
    let server = WiredServer(key: serverName, url: "http://127.0.0.1:\(port)/mcp", token: token)
    #if DEBUG
      let name = "Drakar (Debug)"
    #else
      let name = "Drakar"
    #endif
    return BastionLink(
      server, displayName: name,
      summary:
        "Starts, reads and steers Claude Code and Codex sessions in Drakar, on this Mac and its runner.",
      writeTools: Tools.writeTools)
  }
}

extension Bundle {
  fileprivate static var appVersion: String {
    main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }
}
