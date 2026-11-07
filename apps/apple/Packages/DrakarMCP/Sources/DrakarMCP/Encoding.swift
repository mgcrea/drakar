import DrakarKit
import Foundation
import MCPKit

/// How sessions go out: camelCase keys, dates in ISO 8601. Every field a row names is always
/// there, null when unknown, so a caller reads one shape; `context` alone is left out when
/// neither half is known.
enum Encoding {

  /// The most of a tool input's string a pending permission carries, in UTF-8 bytes. A Write
  /// of a 2 MB file must not reach the caller whole.
  static let inputLimit = 4096

  static func date(_ date: Date) -> String {
    date.formatted(.iso8601)
  }

  static func string(_ value: String?) -> MCPKit.JSONValue {
    value.map(MCPKit.JSONValue.string) ?? .null
  }

  static func int(_ value: Int?) -> MCPKit.JSONValue {
    value.map(MCPKit.JSONValue.int) ?? .null
  }

  // MARK: - Sessions

  static func row(_ row: SessionRow) -> MCPKit.JSONValue {
    var fields: [String: MCPKit.JSONValue] = [
      "id": .string(row.id),
      "title": string(row.title),
      "agent": .string(row.agent.rawValue),
      "folder": .string(row.folder),
      "runner": string(row.runner),
      "state": .string(row.state.rawValue),
      "waitingFor": string(row.waitingFor),
      "model": string(row.model),
      "lastActivity": string(row.lastActivity.map(date)),
      "where": .string(row.place.rawValue),
      "readOnly": .bool(row.readOnly),
      "heldBy": string(row.heldBy),
    ]
    if row.contextUsed != nil || row.contextLimit != nil {
      fields["context"] = ["used": int(row.contextUsed), "limit": int(row.contextLimit)]
    }
    return .object(fields)
  }

  static func detail(_ detail: SessionDetail) -> MCPKit.JSONValue {
    row(detail.row).merging([
      "pending": .array(detail.pending.map(pending)),
      "queued": .array(detail.queued.map(MCPKit.JSONValue.string)),
      "permissionMode": string(detail.permissionMode),
      "accountFolder": string(detail.accountFolder),
    ])
  }

  /// A session that wants the person: its row, why, and what it wants as data.
  static func attention(_ item: AttentionItem) -> MCPKit.JSONValue {
    let wants: MCPKit.JSONValue
    switch item.kind {
    case .askedInText, .offeredInText:
      wants = ["text": string(item.text)]
    case .permission, .question, .plan, .elicitation:
      wants = item.pending.map(pending) ?? .null
    }
    return row(item.session).merging(["kind": .string(item.kind.rawValue), "wants": wants])
  }

  // MARK: - Pending requests

  /// A request, named by its `RequestID`: what the answer tools take back.
  static func pending(_ item: PendingItem) -> MCPKit.JSONValue {
    let requestID = RequestID(item).description
    return switch item {
    case .permission(_, let request):
      permission(requestID: requestID, request: request)
    case .elicitation(_, let elicitation):
      self.elicitation(requestID: requestID, elicitation)
    }
  }

  private static func permission(requestID: String, request: PermissionRequest)
    -> MCPKit.JSONValue
  {
    let (input, truncated) = truncating(JSONBridge.mcp(request.input), limit: inputLimit)
    var fields: [String: MCPKit.JSONValue] = [
      "kind": "permission",
      "requestId": .string(requestID),
      "tool": .string(request.toolName),
      "summary": .string(request.summary),
      "input": input,
      // The session-long "always" answers drakar_answer_permission may apply, by index.
      "suggestions": .array(AlwaysOffer.offered(request).map(suggestion)),
    ]
    if truncated { fields["inputTruncated"] = true }
    if request.isChoice {
      fields["kind"] = "question"
      fields["questions"] = .array(UserQuestion.list(request.input).map(question))
    } else if request.kind == .planApproval {
      fields["kind"] = "plan"
      fields["plan"] = string(PlanApproval.plan(request.input))
    }
    return .object(fields)
  }

  /// One question of an AskUserQuestion: its text and header, whether it takes several
  /// labels (`multiSelect`, joined with ", " in the answer), and each option's label and
  /// description.
  private static func question(_ question: UserQuestion) -> MCPKit.JSONValue {
    [
      "question": .string(question.question),
      "header": string(question.header),
      "multiSelect": .bool(question.multiSelect),
      "options": .array(
        question.options.map { option in
          ["label": .string(option.label), "description": string(option.description)]
        }),
    ]
  }

  /// An offered suggestion: its index, and the rules it allows for the session or, for Codex,
  /// its decision.
  private static func suggestion(_ suggestion: PermissionSuggestion) -> MCPKit.JSONValue {
    var fields: [String: MCPKit.JSONValue] = ["index": .int(suggestion.id)]
    switch suggestion.kind {
    case .addRules(let rules): fields["rules"] = .array(rules.map(MCPKit.JSONValue.string))
    case .codexDecision(let decision): fields["decision"] = .string(decision)
    case .addDirectories, .setMode, .other: break
    }
    return .object(fields)
  }

  private static func elicitation(requestID: String, _ elicitation: Elicitation)
    -> MCPKit.JSONValue
  {
    var fields: [String: MCPKit.JSONValue] = [
      "kind": "elicitation",
      "requestId": .string(requestID),
      "server": .string(elicitation.serverName),
      "message": .string(elicitation.message),
      "fields": [],
    ]
    switch elicitation.content {
    case .form(let form): fields["fields"] = .array(form.fields.map(field))
    case .url(let url): fields["url"] = .string(url.absoluteString)
    case .nonWebLink(let link): fields["url"] = .string(link)
    case .unsupported: break
    }
    return .object(fields)
  }

  /// One form field, with what an answer must hold: its key, type and limits.
  private static func field(_ field: ElicitationField) -> MCPKit.JSONValue {
    var fields: [String: MCPKit.JSONValue] = [
      "key": .string(field.key),
      "title": .string(field.title),
      "description": string(field.description),
      "required": .bool(field.isRequired),
    ]
    func option(_ option: ElicitationField.Option) -> MCPKit.JSONValue {
      ["value": .string(option.value), "title": .string(option.title)]
    }
    func number(_ value: Double?) -> MCPKit.JSONValue {
      value.map { JSONBridge.mcp(.number($0)) } ?? .null
    }
    switch field.kind {
    case .text(let minLength, let maxLength, let format):
      fields["type"] = "text"
      if let minLength { fields["minLength"] = .int(minLength) }
      if let maxLength { fields["maxLength"] = .int(maxLength) }
      if let format { fields["format"] = .string(format) }
    case .number(let isInteger, let minimum, let maximum):
      fields["type"] = isInteger ? "integer" : "number"
      if minimum != nil { fields["minimum"] = number(minimum) }
      if maximum != nil { fields["maximum"] = number(maximum) }
    case .flag:
      fields["type"] = "boolean"
    case .choice(let options):
      fields["type"] = "choice"
      fields["options"] = .array(options.map(option))
    case .choices(let options, let minItems, let maxItems):
      fields["type"] = "choices"
      fields["options"] = .array(options.map(option))
      if let minItems { fields["minItems"] = .int(minItems) }
      if let maxItems { fields["maxItems"] = .int(maxItems) }
    }
    return .object(fields)
  }

  // MARK: - Truncation

  /// Every string value longer than `limit` UTF-8 bytes cut there; returns whether any was.
  /// The cut falls on the last whole Unicode scalar that fits, so no character is split into
  /// invalid bytes. Object keys are left alone.
  static func truncating(_ value: MCPKit.JSONValue, limit: Int) -> (
    MCPKit.JSONValue, truncated: Bool
  ) {
    switch value {
    case .string(let text):
      guard text.utf8.count > limit else { return (value, false) }
      var end = text.utf8.index(text.utf8.startIndex, offsetBy: limit)
      while end.samePosition(in: text.unicodeScalars) == nil {
        end = text.utf8.index(before: end)
      }
      return (.string(String(decoding: text.utf8[..<end], as: UTF8.self)), true)
    case .array(let items):
      var cut = false
      let kept = items.map { item in
        let (value, truncated) = truncating(item, limit: limit)
        cut = cut || truncated
        return value
      }
      return (.array(kept), cut)
    case .object(let fields):
      var cut = false
      let kept = fields.mapValues { field in
        let (value, truncated) = truncating(field, limit: limit)
        cut = cut || truncated
        return value
      }
      return (.object(kept), cut)
    case .null, .bool, .int, .double:
      return (value, false)
    }
  }
}
