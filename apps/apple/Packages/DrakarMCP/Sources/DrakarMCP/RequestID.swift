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
  /// A request whose content cannot be encoded is named by no id.
  public func names(_ item: PendingItem) -> Bool {
    guard item.requestID == raw, let hash = Self.hash(of: item) else { return false }
    return hash == fingerprint
  }

  /// What `fingerprint(of:)` gives a request whose content cannot be encoded: not 8 hex
  /// digits, so it never parses back and never equals a request's hash.
  static let unhashable = "unhashable"

  /// The first 8 hex digits of the SHA-256 of everything `item` presents and acts on, encoded
  /// with sorted keys (`content(of:)`). The app and the tools compute it alike, so either can
  /// tell a request was replaced. `unhashable` when the content cannot be encoded, which
  /// `names` refuses rather than letting two such requests share an empty hash.
  public static func fingerprint(of item: PendingItem) -> String {
    hash(of: item) ?? unhashable
  }

  private static func hash(of item: PendingItem) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(content(of: item)) else { return nil }
    let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(fingerprintLength))
  }

  /// Everything a request presents and acts on, in a fixed order. A permission: its tool,
  /// input, description, the call it asks about (Claude's tool_use id, Codex's itemId), what
  /// the call does (a file change's path and every edit), and the "always" answers it offers,
  /// in order. Codex's file changes all have the tool "Edit" and an empty input, so without
  /// the edits every patch prompt would hash alike. An MCP server's question: its server,
  /// message and what it shows (a form's fields, a link).
  static func content(of item: PendingItem) -> DrakarKit.JSONValue {
    switch item {
    case .permission(_, let request):
      return .array([
        .string("permission"), .string(request.toolName), optional(request.displayName),
        request.input, optional(request.description), optional(request.toolUseID),
        optional(request.blockedPath), .bool(request.requiresUserInteraction),
        kind(request.kind), .array(request.suggestions),
      ])
    case .elicitation(_, let elicitation):
      return .array([
        .string("elicitation"), .string(elicitation.serverName),
        optional(elicitation.displayName), .string(elicitation.message),
        optional(elicitation.elicitationID), optional(elicitation.title),
        optional(elicitation.description), content(elicitation.content),
      ])
    }
  }

  private static func optional(_ text: String?) -> DrakarKit.JSONValue {
    text.map(DrakarKit.JSONValue.string) ?? .null
  }

  private static func kind(_ kind: ToolKind) -> DrakarKit.JSONValue {
    switch kind {
    case .shell(let command): .array([.string("shell"), .string(command)])
    case .read(let path): .array([.string("read"), .string(path)])
    case .search(let pattern): .array([.string("search"), .string(pattern)])
    case .fileChange(let path, let edits):
      .array([.string("fileChange"), .string(path), .array(edits.map(edit))])
    case .web(let target): .array([.string("web"), .string(target)])
    case .subagent(let description): .array([.string("subagent"), optional(description)])
    case .question: .array([.string("question")])
    case .planApproval: .array([.string("planApproval")])
    case .todos: .array([.string("todos")])
    case .mcp(let server, let tool): .array([.string("mcp"), .string(server), .string(tool)])
    case .other: .array([.string("other")])
    }
  }

  private static func edit(_ edit: FileEdit) -> DrakarKit.JSONValue {
    let change: [DrakarKit.JSONValue] =
      switch edit.change {
      case .replace(let old, let new): [.string("replace"), .string(old), .string(new)]
      case .write(let content): [.string("write"), .string(content)]
      case .patch(let patch): [.string("patch"), .string(patch)]
      case .delete(let content): [.string("delete"), .string(content)]
      case .move(let target, let patch): [.string("move"), .string(target), .string(patch)]
      }
    return .array([.string(edit.path)] + change)
  }

  private static func content(_ content: Elicitation.Content) -> DrakarKit.JSONValue {
    switch content {
    case .form(let form): .array([.string("form"), .array(form.fields.map(field))])
    case .url(let url): .array([.string("url"), .string(url.absoluteString)])
    case .nonWebLink(let link): .array([.string("nonWebLink"), .string(link)])
    case .unsupported: .array([.string("unsupported")])
    }
  }

  private static func field(_ field: ElicitationField) -> DrakarKit.JSONValue {
    func number(_ value: Double?) -> DrakarKit.JSONValue { value.map { .number($0) } ?? .null }
    func int(_ value: Int?) -> DrakarKit.JSONValue { value.map { .number(Double($0)) } ?? .null }
    func options(_ options: [ElicitationField.Option]) -> DrakarKit.JSONValue {
      .array(options.map { .array([.string($0.value), .string($0.title)]) })
    }
    let kind: DrakarKit.JSONValue =
      switch field.kind {
      case .text(let minLength, let maxLength, let format):
        .array([.string("text"), int(minLength), int(maxLength), optional(format)])
      case .number(let isInteger, let minimum, let maximum):
        .array([.string("number"), .bool(isInteger), number(minimum), number(maximum)])
      case .flag: .array([.string("flag")])
      case .choice(let list): .array([.string("choice"), options(list)])
      case .choices(let list, let minItems, let maxItems):
        .array([.string("choices"), options(list), int(minItems), int(maxItems)])
      }
    return .array([
      .string(field.key), .string(field.title), optional(field.description),
      .bool(field.isRequired), kind,
    ])
  }
}
