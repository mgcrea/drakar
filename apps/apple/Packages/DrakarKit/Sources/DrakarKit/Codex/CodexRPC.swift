import Foundation

/// JSON-RPC as `codex app-server` speaks it (docs/codex-app-server.md, "Framing"): one object
/// per line, no `jsonrpc` member, ids numbers or strings. The server numbers its own requests
/// from 0, so its ids and ours are never compared.
public enum CodexRPC {
  /// A request id, kept as it came so the answer echoes it.
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

    /// How the transcript names a request: a number's digits, or the string.
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
    case failure(id: ID, message: String)
    case notification(method: String, params: JSONValue)
    /// The server asking: an approval, a question, a tool call.
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
          self = .failure(id: id, message: error["message"]?.stringValue ?? "")
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
      -> JSONValue
    {
      let id = next
      next += 1
      pending[id] = purpose
      return .object([
        "id": .number(Double(id)), "method": .string(method), "params": params,
      ])
    }

    /// What the request `id` answers was for, once; nil for an id that is not ours.
    public mutating func take(_ id: ID) -> Purpose? {
      guard case .number(let number) = id else { return nil }
      return pending.removeValue(forKey: number)
    }
  }

  public static func notification(_ method: String) -> JSONValue {
    .object(["method": .string(method)])
  }

  /// Our answer to one of the server's requests.
  public static func answer(_ id: ID, result: JSONValue) -> JSONValue {
    .object(["id": id.json, "result": result])
  }

  /// A request the server made that Drakar does not answer: refused, so nothing waits on it.
  public static func refusal(_ id: ID, message: String) -> JSONValue {
    .object([
      "id": id.json,
      "error": .object(["code": .number(-32601), "message": .string(message)]),
    ])
  }
}
