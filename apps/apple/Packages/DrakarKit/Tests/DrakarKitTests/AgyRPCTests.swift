import DrakarKit
import Foundation
import Testing

@Suite("Agy ACP JSON-RPC framing")
struct AgyRPCTests {
  private func json(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8))
  }

  @Test func parsesEveryLineKind() throws {
    #expect(
      AgyRPC.Line(try json(#"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s-1"}}"#))
        == .response(id: .number(1), result: .object(["sessionId": .string("s-1")])))
    #expect(
      AgyRPC.Line(
        try json(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"failed"}}"#))
        == .failure(id: .number(2), code: -32603, message: "failed"))
    #expect(
      AgyRPC.Line(
        try json(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-1"}}"#))
        == .notification(method: "session/update", params: .object(["sessionId": .string("s-1")])))
    #expect(
      AgyRPC.Line(
        try json(#"{"jsonrpc":"2.0","id":"2","method":"session/request_permission","params":{}}"#))
        == .request(id: .string("2"), method: "session/request_permission", params: .object([:])))
    #expect(AgyRPC.Line(try json(#"{"hello":1}"#)) == nil)
  }

  @Test func numbersRequestsAndMatchesResponses() throws {
    var calls = AgyRPC.Calls<String>()
    let first = calls.make("initialize", .object(["protocolVersion": .number(1)]), for: "init")
    let second = calls.make("session/new", .object(["cwd": .string("/tmp")]), for: "new")
    #expect(first.id == "1")
    #expect(first.message["jsonrpc"] == .string("2.0"))
    #expect(first.message["id"] == .number(1))
    #expect(second.id == "2")
    #expect(calls.take(.string("1")) == nil)
    #expect(calls.take(.number(1)) == "init")
    #expect(calls.take(.number(1)) == nil)
    #expect(calls.take(.number(2)) == "new")
  }

  @Test func formatsNotificationsAnswersAndRefusals() throws {
    #expect(
      AgyRPC.notification("session/cancel", params: .object(["sessionId": .string("s-1")]))
        == (try json(
          #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s-1"}}"#)))
    #expect(
      AgyRPC.answer(.string("2"), result: AgyPolicy.selected("allow"))
        == (try json(
          #"{"jsonrpc":"2.0","id":"2","result":{"outcome":{"outcome":"selected","optionId":"allow"}}}"#
        )))
    let refusal = AgyRPC.refusal(.string("9"), message: "Unsupported")
    #expect(refusal["jsonrpc"] == .string("2.0"))
    #expect(refusal["id"] == .string("9"))
    #expect(refusal["error"]?["code"] == .number(-32601))
  }
}
