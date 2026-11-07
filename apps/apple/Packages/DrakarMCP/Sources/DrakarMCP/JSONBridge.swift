import DrakarKit
import MCPKit

/// Crosses a value between DrakarKit's `JSONValue` and MCPKit's.
///
/// Two types because each package keeps its own: DrakarKit has no dependencies, so it cannot
/// take the kit's. They differ in one place. DrakarKit has a single `number`, as the stream
/// carries it; MCPKit splits `int` from `double`, so a whole number goes out as `.int` (a
/// tool input's `"limit": 5` must not reach a caller as `5.0`) and anything else as `.double`.
public enum JSONBridge {
  public static func mcp(_ value: DrakarKit.JSONValue) -> MCPKit.JSONValue {
    switch value {
    case .null: .null
    case .bool(let bool): .bool(bool)
    case .number(let number):
      if let integer = Int(exactly: number) { .int(integer) } else { .double(number) }
    case .string(let string): .string(string)
    case .array(let items): .array(items.map(mcp))
    case .object(let fields): .object(fields.mapValues(mcp))
    }
  }

  public static func drakar(_ value: MCPKit.JSONValue) -> DrakarKit.JSONValue {
    switch value {
    case .null: .null
    case .bool(let bool): .bool(bool)
    case .int(let integer): .number(Double(integer))
    case .double(let double): .number(double)
    case .string(let string): .string(string)
    case .array(let items): .array(items.map(drakar))
    case .object(let fields): .object(fields.mapValues(drakar))
    }
  }
}
