import DrakarKit
import Foundation
import Testing

@testable import DrakarMCP

@Suite("Request ids")
struct RequestIDTests {
  private static func permission(_ raw: String, _ input: DrakarKit.JSONValue) -> PendingItem {
    .permission(
      requestID: raw,
      request: PermissionRequest(toolName: "Bash", input: input, toolUseID: "t", kind: .other))
  }

  @Test("An id reads back as it was given out, a raw id with a colon of its own included")
  func roundTrip() throws {
    let item = Self.permission("abc:7", .object(["command": .string("ls")]))
    let id = RequestID(item)
    #expect(id.fingerprint.count == 8)
    #expect(id.fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(RequestID(parsing: id.description) == id)
    #expect(id.names(item))
  }

  @Test("An id without a fingerprint of 8 lowercase hex digits does not read")
  func malformed() {
    for text in ["p1", "p1:", ":0123abcd", "p1:0123abc", "p1:0123ABCD", "p1:0123abcg"] {
      #expect(RequestID(parsing: text) == nil, "\(text)")
    }
  }

  @Test("The fingerprint follows what is asked, not how its keys were ordered")
  func fingerprintIsCanonical() {
    let one = Self.permission("0", .object(["a": .number(1), "b": .string("x")]))
    let same = Self.permission("5", .object(["b": .string("x"), "a": .number(1)]))
    let other = Self.permission("0", .object(["a": .number(2), "b": .string("x")]))
    #expect(RequestID.fingerprint(of: one) == RequestID.fingerprint(of: same))
    #expect(RequestID.fingerprint(of: one) != RequestID.fingerprint(of: other))
    #expect(!RequestID(one).names(other))
  }
}
