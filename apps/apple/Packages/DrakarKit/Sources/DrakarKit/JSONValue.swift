import Foundation

/// Any JSON value, kept as it arrived.
///
/// The stream-json protocol is undocumented and grows a field most releases, so the
/// decoder never maps a line straight onto a struct that would throw on a surprise. A line
/// is parsed into a `JSONValue` first and the typed messages read what they know out of
/// it; everything else (a tool's input, a permission suggestion, an unknown message) stays
/// a `JSONValue` and can be shown or sent back unchanged.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    numberValue.flatMap { Int(exactly: $0) }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var isNull: Bool { self == .null }
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Bool before number: Foundation's decoder refuses a number as a Bool and a Bool as a
    // number, so the order only matters for speed, but it is the common case in this stream.
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      // A tool input echoed back in a permission answer must not turn `"limit": 5` into
      // `5.0`; whole numbers go back out as integers.
      if let integer = Int64(exactly: value) {
        try container.encode(integer)
      } else {
        try container.encode(value)
      }
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue {
  /// Parses one line of the protocol.
  public static func parse(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// One line of the protocol: compact, keys sorted so an encoding is reproducible, and
  /// terminated by the newline the CLI splits its input on.
  public func line() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(self)
    data.append(0x0A)
    return data
  }
}
