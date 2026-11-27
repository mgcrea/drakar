import Foundation

/// JSON-RPC 2.0 as `agy acp` speaks it (docs/agy-acp.md): one JSON object per line with
/// `"jsonrpc": "2.0"`, ids numbers or strings. Server requests (`session/request_permission`)
/// use string ids in their own space, kept apart from ours.
public enum AgyRPC {
  /// A request id, kept as it came so the answer echoes it unchanged.
  public enum ID: Sendable, Hashable {
    case number(Int)
    case string(String)

    public init?(_ json: JSONValue?) {
      if let number = json?.intValue {
        self = .number(number)
      } else if let string = json?.stringValue {
        self = .string(string)
      } else {
        return nil
      }
    }

    public var json: JSONValue {
      switch self {
      case .number(let number): .number(Double(number))
      case .string(let string): .string(string)
      }
    }

    /// How the transcript names a request: digits or the string.
    public var text: String {
      switch self {
      case .number(let number): String(number)
      case .string(let string): string
      }
    }
  }

  /// What one line from the server is.
  public enum Line: Sendable, Equatable {
    case response(id: ID, result: JSONValue)
    case failure(id: ID, code: Int?, message: String)
    case notification(method: String, params: JSONValue)
    /// The server asking: `session/request_permission` or an unknown request.
    case request(id: ID, method: String, params: JSONValue)

    public init?(_ json: JSONValue) {
      let method = json["method"]?.stringValue
      let id = ID(json["id"])
      switch (method, id) {
      case (let method?, let id?):
        self = .request(id: id, method: method, params: json["params"] ?? .null)
      case (let method?, nil):
        self = .notification(method: method, params: json["params"] ?? .null)
      case (nil, let id?):
        if let error = json["error"] {
          self = .failure(
            id: id, code: error["code"]?.intValue, message: error["message"]?.stringValue ?? "")
        } else {
          self = .response(id: id, result: json["result"] ?? .null)
        }
      case (nil, nil):
        return nil
      }
    }
  }

  /// Our requests in flight, numbered from 1, each remembered with what it was for until its
  /// answer comes.
  public struct Calls<Purpose: Sendable>: Sendable {
    private var next = 1
    private var pending: [Int: Purpose] = [:]

    public init() {}

    public mutating func make(_ method: String, _ params: JSONValue, for purpose: Purpose)
      -> (id: String, message: JSONValue)
    {
      let id = next
      next += 1
      pending[id] = purpose
      return (
        String(id),
        .object([
          "jsonrpc": .string("2.0"),
          "id": .number(Double(id)),
          "method": .string(method),
          "params": params,
        ])
      )
    }

    /// What the request `id` answers was for, once; nil for an id that is not ours.
    public mutating func take(_ id: ID) -> Purpose? {
      guard case .number(let number) = id else { return nil }
      return pending.removeValue(forKey: number)
    }
  }

  public static func notification(_ method: String, params: JSONValue = .object([:])) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"),
      "method": .string(method),
      "params": params,
    ])
  }

  /// Our answer to one of the server's requests.
  public static func answer(_ id: ID, result: JSONValue) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "id": id.json, "result": result])
  }

  /// A request the server made that Drakar does not answer: refused so nothing waits on it.
  public static func refusal(_ id: ID, message: String) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"),
      "id": id.json,
      "error": .object(["code": .number(-32601), "message": .string(message)]),
    ])
  }
}
