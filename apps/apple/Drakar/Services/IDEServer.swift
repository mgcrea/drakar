import DrakarKit
import Foundation
import Network

/// The WebSocket a terminal `claude` connects to when Drakar is its editor
/// (`docs/claude-ide-bridge.md`).
///
/// The rules, each asserted by `scripts/audit-network.sh` and in the commit that opened the
/// socket rather than in a hardening pass afterwards:
///
/// 1. **Loopback only.** The listener is bound to 127.0.0.1 (`requiredLocalEndpoint`) and
///    refuses anything not local (`acceptLocalOnly`). No address is ever "any".
/// 2. **A token before anything else.** The upgrade is refused unless
///    `x-claude-code-ide-authorization` carries this launch's random token, which exists
///    only in memory and in lock files readable by the user alone (0600; a folder Drakar
///    creates is 0700, one another tool created is left as it is, and the audit checks
///    nobody else can write it).
///    A refused client never reaches the MCP layer, so it learns nothing about it.
/// 3. **One listener.** This is the only `NWListener` in Drakar. The only other socket is the
///    session host's, a Unix socket (DrakarKit's `UnixSocket`), not a network one.
///
/// Everything runs on the main queue: a few small JSON messages per edit, and the replies
/// depend on UI the user answers there anyway.
final class IDEServer {
  /// A fresh secret per launch. A lock file left by a crash names a token nothing accepts.
  let token = UUID().uuidString

  private var listener: NWListener?
  private var connections: [ObjectIdentifier: IDEConnection] = [:]
  private let onMessage: @MainActor (IDEConnection, IDEMessage) -> Void
  private let onClose: @MainActor (IDEConnection) -> Void

  init(
    onMessage: @escaping @MainActor (IDEConnection, IDEMessage) -> Void,
    onClose: @escaping @MainActor (IDEConnection) -> Void
  ) {
    self.onMessage = onMessage
    self.onClose = onClose
  }

  var connectionCount: Int { connections.count }

  /// Every connected `claude` that has finished its handshake.
  var clients: [IDEConnection] { connections.values.filter(\.isInitialized) }

  /// Starts listening on a free loopback port; `ready` gets the port.
  func start(
    ready: @escaping @MainActor (UInt16) -> Void, failed: @escaping @MainActor (String) -> Void
  ) throws {
    let token = token
    let webSocket = NWProtocolWebSocket.Options()
    webSocket.autoReplyPing = true
    webSocket.setClientRequestHandler(.main) { subprotocols, headers in
      let authorized = headers.contains {
        $0.name.lowercased() == "x-claude-code-ide-authorization" && $0.value == token
      }
      guard authorized else {
        return NWProtocolWebSocket.Response(
          status: .reject, subprotocol: nil, additionalHeaders: nil)
      }
      return NWProtocolWebSocket.Response(
        status: .accept, subprotocol: subprotocols.contains("mcp") ? "mcp" : nil,
        additionalHeaders: nil)
    }

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.acceptLocalOnly = true
    parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

    let listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { [weak listener] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready:
          if let port = listener?.port?.rawValue { ready(port) }
        case .failed(let error):
          failed(error.localizedDescription)
        default:
          break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated { self?.accept(connection) }
    }
    listener.start(queue: .main)
    self.listener = listener
  }

  func stop() {
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.close() }
    connections = [:]
  }

  private func accept(_ connection: NWConnection) {
    let client = IDEConnection(connection)
    connections[ObjectIdentifier(client)] = client
    client.start(
      onMessage: { [weak self, weak client] data in
        guard let self, let client, let message = IDEMessage(data) else { return }
        self.onMessage(client, message)
      },
      onClose: { [weak self, weak client] in
        guard let self, let client else { return }
        self.connections[ObjectIdentifier(client)] = nil
        self.onClose(client)
      })
  }
}

/// One connected `claude`.
final class IDEConnection {
  private let connection: NWConnection
  /// The CLI's pid, from its `ide_connected` notification.
  var claudePID: Int32?
  /// Past `notifications/initialized`: it may be sent notifications.
  var isInitialized = false
  private var isClosed = false

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  func start(
    onMessage: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor () -> Void
  ) {
    connection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        switch state {
        case .failed, .cancelled:
          guard let self, !self.isClosed else { return }
          self.isClosed = true
          onClose()
        default:
          break
        }
      }
    }
    connection.start(queue: .main)
    receive(onMessage: onMessage)
  }

  func send(_ message: JSONValue) {
    guard !isClosed else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(message) else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "mcp", metadata: [metadata])
    connection.send(
      content: data, contentContext: context, isComplete: true, completion: .idempotent)
  }

  func close() {
    connection.cancel()
  }

  private func receive(onMessage: @escaping @MainActor (Data) -> Void) {
    connection.receiveMessage { [weak self] data, context, _, error in
      MainActor.assumeIsolated {
        guard let self, error == nil, !self.isClosed else { return }
        let metadata =
          context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
          as? NWProtocolWebSocket.Metadata
        switch metadata?.opcode {
        case .text?, .binary?:
          if let data { onMessage(data) }
        case .close?:
          self.close()
          return
        default:
          break
        }
        self.receive(onMessage: onMessage)
      }
    }
  }
}
