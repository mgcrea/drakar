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

  /// A Codex file change, built anew each call, as the translator builds one per request.
  private static func codexPatch(_ raw: String, itemID: String = "item_1") -> PendingItem {
    var request = PermissionRequest(
      toolName: "Edit", input: .object([:]), description: "Fix it", toolUseID: itemID,
      kind: .fileChange(
        path: "/repo/a.swift",
        edits: [
          FileEdit(path: "/repo/a.swift", change: .replace(old: "a", new: "b")),
          FileEdit(path: "/repo/b.swift", change: .move(to: "/repo/c.swift", patch: "@@")),
        ]))
    request.suggestions = [CodexPolicy.acceptForSession]
    return .permission(requestID: raw, request: request)
  }

  @Test("The same request built twice has the same fingerprint")
  func fingerprintIsStable() {
    let one = Self.codexPatch("0")
    let again = Self.codexPatch("0")
    #expect(RequestID.fingerprint(of: one) == RequestID.fingerprint(of: again))
    #expect(RequestID.fingerprint(of: one) == RequestID.fingerprint(of: one))
    #expect(RequestID(one).names(again))
  }

  @Test("The call a request asks about is part of what it asks")
  func fingerprintFollowsToolUseID() {
    let one = Self.codexPatch("0", itemID: "item_1")
    let other = Self.codexPatch("0", itemID: "item_2")
    #expect(RequestID.fingerprint(of: one) != RequestID.fingerprint(of: other))
    #expect(!RequestID(one).names(other))
  }

  @Test("A request that cannot be encoded names nothing, itself included")
  func unencodableNeverMatches() {
    let item = Self.permission("0", .object(["n": .number(.nan)]))
    let other = Self.permission("0", .object(["n": .number(.infinity)]))
    #expect(!RequestID(item).names(item))
    #expect(RequestID(parsing: RequestID(item).description) == nil)
    #expect(!RequestID(raw: "0", fingerprint: RequestID.fingerprint(of: item)).names(other))
  }
}
