import CryptoKit
import DrakarKit
import Foundation

/// A pending request as the tools name it: `<raw>:<fingerprint>`, the agent's own id and a
/// short hash of what the request asks.
///
/// The raw id alone is not enough. Codex numbers its requests from "0" again in each
/// `codex app-server` process, so after End Session and a resume an id an agent read earlier
/// can name another request; answering it would answer a tool call that agent never saw. The
/// fingerprint tells the two apart: an answer whose fingerprint is not the waiting request's
/// is refused as no longer waiting. One rule for Claude Code and Codex alike.
public struct RequestID: Sendable, Hashable, CustomStringConvertible {
  /// The agent's own id, which the app answers by.
  public var raw: String
  /// `fingerprint(of:)` of the request the caller read.
  public var fingerprint: String

  /// How many hex digits a fingerprint has.
  static let fingerprintLength = 8

  public init(raw: String, fingerprint: String) {
    self.raw = raw
    self.fingerprint = fingerprint
  }

  /// The id the tools give out for `item`.
  public init(_ item: PendingItem) {
    self.init(raw: item.requestID, fingerprint: Self.fingerprint(of: item))
  }

  /// An id a caller gave back, nil when it has no fingerprint. The raw id is everything
  /// before the last colon, so one holding a colon of its own reads back whole.
  public init?(parsing text: String) {
    guard let colon = text.lastIndex(of: ":") else { return nil }
    let raw = String(text[..<colon])
    let fingerprint = String(text[text.index(after: colon)...])
    guard !raw.isEmpty, fingerprint.count == Self.fingerprintLength,
      fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { return nil }
    self.init(raw: raw, fingerprint: fingerprint)
  }

  public var description: String { "\(raw):\(fingerprint)" }

  /// Whether `item` is the request this id was read from: the same raw id, asking the same.
  public func names(_ item: PendingItem) -> Bool {
    item.requestID == raw && Self.fingerprint(of: item) == fingerprint
  }

  /// The first 8 hex digits of the SHA-256 of what `item` asks, encoded with sorted keys: a
  /// permission's tool name and input; an MCP server's question, its server and message.
  /// The app and the tools compute it alike, so either can tell a request was replaced.
  public static func fingerprint(of item: PendingItem) -> String {
    let asked: DrakarKit.JSONValue =
      switch item {
      case .permission(_, let request):
        .array([.string("permission"), .string(request.toolName), request.input])
      case .elicitation(_, let elicitation):
        .array([
          .string("elicitation"), .string(elicitation.serverName), .string(elicitation.message),
        ])
      }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(asked)) ?? Data()
    let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(fingerprintLength))
  }
}
