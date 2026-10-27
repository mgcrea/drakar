import Foundation

/// An MCP server's question in the middle of a tool call, as Claude forwards it.
///
/// Verified on 2.1.311 (`Fixture.elicitation`): a `control_request` of subtype
/// `elicitation` carries `mcp_server_name`, `message` and `mode`; a form adds
/// `requested_schema` and `property_order`, a link adds `url` and `elicitation_id`. A request
/// that can be read but not shown (a schema outside MCP's form subset, a link that isn't
/// http or https, an unknown mode) is `.unsupported`, a card that can only decline.
public struct Elicitation: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case form(ElicitationForm)
    /// Always http or https.
    case url(URL)
    case unsupported
  }

  public var serverName: String
  public var displayName: String?
  public var message: String
  public var elicitationID: String?
  public var title: String?
  public var description: String?
  public var content: Content

  /// The name the card shows for the server.
  public var serverLabel: String { displayName ?? serverName }

  /// `request` is the control_request's `request` object (Claude's snake_case keys). Nil
  /// only when it has neither a server name nor a message, so there is nothing to show; a
  /// missing one of the two reads as "".
  public init?(claudeRequest request: JSONValue) {
    func text(_ key: String) -> String? {
      request[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
    guard text("mcp_server_name") != nil || text("message") != nil else { return nil }
    serverName = text("mcp_server_name") ?? ""
    displayName = text("display_name")
    message = text("message") ?? ""
    elicitationID = text("elicitation_id")
    title = text("title")
    description = text("description")
    // `mode` is optional and means a form when absent.
    switch request["mode"] ?? .null {
    case .null, .string("form"):
      content =
        request["requested_schema"]
        .flatMap {
          ElicitationForm(
            schema: $0, order: request["property_order"]?.arrayValue?.compactMap(\.stringValue))
        }
        .map(Content.form) ?? .unsupported
    case .string("url"):
      content =
        text("url").flatMap(URL.init(string:)).flatMap(Self.webURL).map(Content.url)
        ?? .unsupported
    default:
      content = .unsupported
    }
  }

  init(
    serverName: String, displayName: String?, message: String, elicitationID: String?,
    title: String?, description: String?, content: Content
  ) {
    self.serverName = serverName
    self.displayName = displayName
    self.message = message
    self.elicitationID = elicitationID
    self.title = title
    self.description = description
    self.content = content
  }

  private static func webURL(_ url: URL) -> URL? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host()?.isEmpty == false
    else { return nil }
    return url
  }
}

/// The form of a form elicitation: MCP's flat-object schema subset, its fields in order.
public struct ElicitationForm: Sendable, Equatable {
  public var fields: [ElicitationField]

  /// Nil when the schema isn't a flat object of the supported kinds. The fields follow
  /// `order`; without one, the required fields in `required`'s order, then the rest
  /// alphabetically. Keys `order` leaves out come last, alphabetically.
  public init?(schema: JSONValue, order: [String]?) {
    guard schema["type"]?.stringValue == "object" else { return nil }
    let properties: [String: JSONValue]
    switch schema["properties"] ?? .object([:]) {
    case .object(let object): properties = object
    default: return nil
    }
    let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
    let first = (order.flatMap { $0.isEmpty ? nil : $0 } ?? required).filter {
      properties[$0] != nil
    }
    var keys: [String] = []
    for key in first + properties.keys.sorted() where !keys.contains(key) { keys.append(key) }
    var fields: [ElicitationField] = []
    for key in keys {
      guard
        let field = ElicitationField(
          key: key, property: properties[key] ?? .null, isRequired: required.contains(key))
      else { return nil }
      fields.append(field)
    }
    self.fields = fields
  }

  /// Each problem keyed by field key; empty when the inputs can be sent.
  public func problems(in inputs: [String: ElicitationInput]) -> [String: String] {
    var problems: [String: String] = [:]
    for field in fields {
      if let problem = field.problem(with: inputs[field.key]) { problems[field.key] = problem }
    }
    return problems
  }

  /// Nil while `problems` is non-empty. Omits optional fields left empty.
  public func content(from inputs: [String: ElicitationInput]) -> [String: JSONValue]? {
    guard problems(in: inputs).isEmpty else { return nil }
    var content: [String: JSONValue] = [:]
    for field in fields {
      if let value = field.value(of: inputs[field.key]) { content[field.key] = value }
    }
    return content
  }

  /// The fields that start with an input: each one with a `default`, and a required flag as
  /// off. An optional flag without one starts absent, so it is sent only once toggled.
  public var initialInputs: [String: ElicitationInput] {
    var inputs: [String: ElicitationInput] = [:]
    for field in fields { inputs[field.key] = field.initialInput }
    return inputs
  }
}

/// One property of a form.
public struct ElicitationField: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// `format` is one of email, uri, date and date-time, or nil.
    case text(minLength: Int?, maxLength: Int?, format: String?)
    case number(isInteger: Bool, minimum: Double?, maximum: Double?)
    case flag
    case choice([Option])
    case choices([Option], minItems: Int?, maxItems: Int?)
  }

  public struct Option: Sendable, Equatable {
    public var value: String
    public var title: String

    public init(value: String, title: String) {
      self.value = value
      self.title = title
    }
  }

  public var id: String { key }
  public var key: String
  /// The schema's `title`, else the key.
  public var title: String
  public var description: String?
  public var isRequired: Bool
  /// A text field whose key or title reads as a password, secret, token or API key.
  public var isSecret: Bool
  public var kind: Kind
  let initialInput: ElicitationInput?

  /// Nil when `property` is outside the subset.
  init?(key: String, property: JSONValue, isRequired: Bool) {
    guard case .object = property else { return nil }
    let type = property["type"]?.stringValue
    switch type {
    case "string", nil:
      if let options = Self.options(property) {
        kind = .choice(options)
      } else if type == "string" {
        let format = property["format"]?.stringValue
        kind = .text(
          minLength: property["minLength"]?.intValue, maxLength: property["maxLength"]?.intValue,
          format: format.flatMap { Self.formats.contains($0) ? $0 : nil })
      } else {
        return nil
      }
    case "number", "integer":
      kind = .number(
        isInteger: type == "integer", minimum: property["minimum"]?.numberValue,
        maximum: property["maximum"]?.numberValue)
    case "boolean":
      kind = .flag
    case "array":
      guard let items = property["items"], let options = Self.options(items) else { return nil }
      kind = .choices(
        options, minItems: property["minItems"]?.intValue, maxItems: property["maxItems"]?.intValue)
    default:
      return nil
    }
    self.key = key
    title = property["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? key
    description = property["description"]?.stringValue
    self.isRequired = isRequired
    if case .text = kind {
      isSecret = Self.readsAsSecret(key) || Self.readsAsSecret(title)
    } else {
      isSecret = false
    }
    initialInput = Self.input(kind: kind, default: property["default"], isRequired: isRequired)
  }

  static let formats: Set<String> = ["email", "uri", "date", "date-time"]

  /// `enum` with its `enumNames`, or `oneOf` (or `anyOf`, the multi-select's spelling)
  /// `{const, title}`; nil when neither lists strings.
  private static func options(_ schema: JSONValue) -> [Option]? {
    if let values = schema["enum"]?.arrayValue {
      let strings = values.compactMap(\.stringValue)
      guard !strings.isEmpty, strings.count == values.count else { return nil }
      let names = schema["enumNames"]?.arrayValue?.compactMap(\.stringValue)
      let titles = names?.count == strings.count ? names ?? strings : strings
      return zip(strings, titles).map { Option(value: $0, title: $1) }
    }
    guard let entries = schema["oneOf"]?.arrayValue ?? schema["anyOf"]?.arrayValue,
      !entries.isEmpty
    else { return nil }
    var options: [Option] = []
    for entry in entries {
      guard let value = entry["const"]?.stringValue else { return nil }
      options.append(Option(value: value, title: entry["title"]?.stringValue ?? value))
    }
    return options
  }

  private static func readsAsSecret(_ name: String) -> Bool {
    name.contains(
      #/(^|[^a-z0-9])(password|passphrase|secret|token|api[ _-]?key)($|[^a-z0-9])/#
        .ignoresCase())
  }

  /// Nil without a `default` the field can take, except for a required flag, which starts off.
  private static func input(kind: Kind, default value: JSONValue?, isRequired: Bool)
    -> ElicitationInput?
  {
    switch kind {
    case .text: value?.stringValue.map(ElicitationInput.text)
    case .number: value?.numberValue.map { .text(numeral($0)) }
    case .flag: value?.boolValue.map(ElicitationInput.flag) ?? (isRequired ? .flag(false) : nil)
    case .choice: value?.stringValue.map { .picks([$0]) }
    case .choices: value?.arrayValue.map { .picks(Set($0.compactMap(\.stringValue))) }
    }
  }

  /// `number` as a person types it: a whole number without its ".0".
  private static func numeral(_ number: Double) -> String {
    Int(exactly: number).map(String.init) ?? String(number)
  }

  // MARK: - Checking an input

  /// What `input` says once sent: nil when it is empty.
  private func filled(_ input: ElicitationInput?) -> ElicitationInput? {
    switch input {
    case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      input
    case .flag: input
    case .picks(let picks) where !picks.isEmpty: input
    default: nil
    }
  }

  func problem(with input: ElicitationInput?) -> String? {
    guard let input = filled(input) else {
      return isRequired ? String(localized: "Required") : nil
    }
    switch (kind, input) {
    case (.text(let minLength, let maxLength, let format), .text(let text)):
      if let minLength, text.count < minLength {
        return String(localized: "At least \(minLength) characters")
      }
      if let maxLength, text.count > maxLength {
        return String(localized: "At most \(maxLength) characters")
      }
      return format.flatMap { Self.formatProblem(text, format: $0) }
    case (.number(let isInteger, let minimum, let maximum), .text(let text)):
      guard let number = Self.number(text) else { return String(localized: "Must be a number") }
      if isInteger, number.rounded() != number {
        return String(localized: "Must be a whole number")
      }
      if let minimum, number < minimum {
        return String(localized: "Must be at least \(Self.numeral(minimum))")
      }
      if let maximum, number > maximum {
        return String(localized: "Must be at most \(Self.numeral(maximum))")
      }
      return nil
    case (.flag, .flag):
      return nil
    case (.choice(let options), .picks(let picks)):
      return picks.count == 1 && options.contains(where: { picks.contains($0.value) })
        ? nil : String(localized: "Pick one option")
    case (.choices(let options, let minItems, let maxItems), .picks(let picks)):
      guard picks.allSatisfy({ pick in options.contains { $0.value == pick } }) else {
        return String(localized: "Pick from the options")
      }
      if let minItems, picks.count < minItems {
        return String(localized: "Pick at least \(minItems)")
      }
      if let maxItems, picks.count > maxItems {
        return String(localized: "Pick at most \(maxItems)")
      }
      return nil
    default:
      return String(localized: "Not a value this field takes")
    }
  }

  /// The JSON an input sends, when it passes `problem`; nil when it is empty.
  func value(of input: ElicitationInput?) -> JSONValue? {
    switch (kind, filled(input)) {
    case (.text, .text(let text)): .string(text)
    case (.number, .text(let text)): Self.number(text).map(JSONValue.number)
    case (.flag, .flag(let flag)): .bool(flag)
    case (.choice, .picks(let picks)): picks.first.map(JSONValue.string)
    case (.choices(let options, _, _), .picks(let picks)):
      .array(options.map(\.value).filter(picks.contains).map(JSONValue.string))
    default: nil
    }
  }

  /// A decimal as typed, spaces around it allowed: digits, an optional minus and fraction.
  /// No exponent, no grouping, no comma for the point.
  private static func number(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.wholeMatch(of: #/-?[0-9]+(\.[0-9]+)?/#) != nil else { return nil }
    return Double(trimmed)
  }

  private static func formatProblem(_ text: String, format: String) -> String? {
    switch format {
    case "email":
      let parts = text.split(separator: "@", omittingEmptySubsequences: false)
      return parts.count == 2 && parts.allSatisfy({ !$0.isEmpty })
        ? nil : String(localized: "Must be an email address")
    case "uri":
      return URL(string: text)?.scheme == nil ? String(localized: "Must be a link") : nil
    case "date":
      return (try? Date.ISO8601FormatStyle().year().month().day().parse(text)) == nil
        ? String(localized: "Must be a date, like 2026-10-27") : nil
    case "date-time":
      return (try? Date.ISO8601FormatStyle().parse(text)) == nil
        ? String(localized: "Must be a date and time, like 2026-10-27T14:30:00Z") : nil
    default:
      return nil
    }
  }
}

/// What the person entered in one field.
public enum ElicitationInput: Sendable, Equatable {
  /// Text and number fields.
  case text(String)
  case flag(Bool)
  /// Choice (at most one) and choices.
  case picks(Set<String>)
}
