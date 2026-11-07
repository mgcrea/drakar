import DrakarKit
import MCPKit
import Testing

@testable import DrakarMCP

@Suite("JSON bridge")
struct JSONBridgeTests {
  // DrakarKit's `JSONValue` has no literal conformances, so the value is spelled in cases.
  @Test("A nested value crosses both ways unchanged")
  func roundTrip() {
    let value: DrakarKit.JSONValue = .object([
      "a": .array([.number(1), .number(2.5), .string("x"), .bool(true), .null]),
      "b": .object(["c": .string("d")]),
    ])
    #expect(JSONBridge.drakar(JSONBridge.mcp(value)) == value)
  }

  // DrakarKit has one `number` case; MCPKit splits `int` from `double`, and a schema's
  // `"maxLength": 200` must not come out as `200.0`.
  @Test("Integers stay integers")
  func ints() {
    #expect(JSONBridge.mcp(DrakarKit.JSONValue.number(3)) == MCPKit.JSONValue.int(3))
    #expect(JSONBridge.mcp(DrakarKit.JSONValue.number(2.5)) == MCPKit.JSONValue.double(2.5))
    #expect(JSONBridge.drakar(MCPKit.JSONValue.int(3)) == DrakarKit.JSONValue.number(3))
  }
}
