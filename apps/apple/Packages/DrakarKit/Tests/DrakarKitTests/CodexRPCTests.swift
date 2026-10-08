import DrakarKit
import Foundation
import Testing

@Suite("Codex's JSON-RPC lines")
struct CodexRPCTests {
  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  @Test func readsEachKindOfLine() throws {
    #expect(
      CodexRPC.Line(try json(#"{"id":3,"result":{"turn":{"id":"t"}}}"#))
        == .response(id: .number(3), result: try json(#"{"turn":{"id":"t"}}"#)))
    #expect(
      CodexRPC.Line(
        try json(#"{"id":"init-1","error":{"code":-32600,"message":"Not initialized"}}"#))
        == .failure(id: .string("init-1"), message: "Not initialized"))
    #expect(
      CodexRPC.Line(
        try json(#"{"method":"turn/started","params":{"threadId":"a"},"emittedAtMs":1}"#))
        == .notification(method: "turn/started", params: try json(#"{"threadId":"a"}"#)))
    #expect(
      CodexRPC.Line(try json(#"{"method":"item/fileChange/requestApproval","id":0,"params":{}}"#))
        == .request(id: .number(0), method: "item/fileChange/requestApproval", params: .object([:]))
    )
    #expect(CodexRPC.Line(try json(#"{"hello":1}"#)) == nil)
  }

  @Test func aResultWithNoBodyIsNull() throws {
    #expect(CodexRPC.Line(try json(#"{"id":6}"#)) == .response(id: .number(6), result: .null))
  }

  @Test func idsReadAsTheTranscriptKnowsThem() {
    #expect(CodexRPC.ID.number(0).text == "0")
    #expect(CodexRPC.ID.string("x").text == "x")
    #expect(CodexRPC.ID(.number(2)) == .number(2))
    #expect(CodexRPC.ID(.string("a")) == .string("a"))
    #expect(CodexRPC.ID(.null) == nil)
  }

  @Test func callsAreNumberedAndAnsweredOnce() throws {
    var calls = CodexRPC.Calls<String>()
    let first = calls.make("initialize", .object([:]), for: "init")
    let second = calls.make("model/list", .object([:]), for: "models")
    #expect(first["id"] == .number(1))
    #expect(first["method"] == .string("initialize"))
    #expect(first["jsonrpc"] == nil)
    #expect(second["id"] == .number(2))
    #expect(calls.take(.number(2)) == "models")
    #expect(calls.take(.number(2)) == nil)
    #expect(calls.take(.string("1")) == nil)
    #expect(calls.take(.number(1)) == "init")
  }

  @Test func writesAnswersAndRefusals() throws {
    #expect(
      CodexRPC.answer(.number(0), result: .object(["decision": .string("accept")]))
        == (try json(#"{"id":0,"result":{"decision":"accept"}}"#)))
    #expect(
      CodexRPC.refusal(.string("r"), message: "No")
        == (try json(#"{"id":"r","error":{"code":-32601,"message":"No"}}"#)))
    #expect(CodexRPC.notification("initialized") == (try json(#"{"method":"initialized"}"#)))
  }
}
