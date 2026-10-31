import Foundation

/// What a permission rule does to a tool call it matches.
public enum PermissionBehavior: String, Sendable, CaseIterable {
  case allow, ask, deny
}

/// The settings files `claude edit-permission-rules` writes: the project's own, only for
/// this person (`.claude/settings.local.json`), the project's shared one
/// (`.claude/settings.json`), and the account's `settings.json`.
public enum PermissionRuleFile: String, Sendable, CaseIterable {
  case localSettings, projectSettings, userSettings
}

/// One rule of a `list_permission_rules` reply (`ClientMessage.listPermissionRules`).
public struct PermissionRule: Sendable, Hashable {
  /// The CLI's reading of a rule: "Any Bash command starting with **npm run test**".
  public struct Description: Sendable, Hashable {
    public var prefix: String
    /// The part shown strong, between `prefix` and `suffix`.
    public var emphasis: String?
    public var suffix: String?

    public init(prefix: String, emphasis: String? = nil, suffix: String? = nil) {
      self.prefix = prefix
      self.emphasis = emphasis
      self.suffix = suffix
    }
  }

  /// Whether the edit command can change the rule: `persistent` is in a settings file,
  /// `session` was approved in this process only, `readonly` is anything else.
  public enum Editability: String, Sendable {
    case persistent, session, readonly
  }

  public var behavior: PermissionBehavior
  /// Where the rule came from, as the CLI names it (`localSettings`, `cliArg`, `session`…).
  /// A name Drakar does not know is kept as it is.
  public var source: String
  /// The rule verbatim, as it goes back to the edit command. It may hold invisible or
  /// control characters; `displayed(_:)` shows them.
  public var rule: String
  public var description: Description?
  public var editability: Editability
  /// Managed settings allow only their own rules, and this one is not theirs.
  public var notInEffect: Bool

  public init(
    behavior: PermissionBehavior, source: String, rule: String, description: Description? = nil,
    editability: Editability, notInEffect: Bool = false
  ) {
    self.behavior = behavior
    self.source = source
    self.rule = rule
    self.description = description
    self.editability = editability
    self.notInEffect = notInEffect
  }

  /// Nil without a behavior Drakar knows, a source or the rule. An editability it does not
  /// know reads as `readonly`.
  init?(_ json: JSONValue) {
    guard let behavior = json["behavior"]?.stringValue.flatMap(PermissionBehavior.init),
      let source = json["source"]?.stringValue,
      let rule = json["rule"]?.stringValue
    else { return nil }
    self.behavior = behavior
    self.source = source
    self.rule = rule
    description = json["description"]?["prefix"]?.stringValue.map { prefix in
      Description(
        prefix: prefix, emphasis: json["description"]?["emphasis"]?.stringValue,
        suffix: json["description"]?["suffix"]?.stringValue)
    }
    editability = json["editability"]?.stringValue.flatMap(Editability.init) ?? .readonly
    notInEffect = json["notInEffect"]?.boolValue ?? false
  }

  /// In a file the edit command writes, so it can take the rule out.
  public var isRemovable: Bool {
    editability == .persistent && PermissionRuleFile(rawValue: source) != nil
  }

  /// `text` with each format (Cf) and control (Cc) scalar written as `\u{200B}`, so that a
  /// zero-width space or a bell in a rule shows rather than hides. Everything else, accents
  /// and symbols included, is left as it is.
  public static func displayed(_ text: String) -> String {
    var shown = ""
    for scalar in text.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .format, .control:
        let hex = String(scalar.value, radix: 16, uppercase: true)
        shown += "\\u{" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "}"
      default:
        shown.unicodeScalars.append(scalar)
      }
    }
    return shown
  }
}

/// A `list_permission_rules` reply: `{state: {rules, workspaceDirectories, managedOnly,
/// errors?}}`.
public struct PermissionRulesState: Sendable, Equatable {
  /// A folder the session may work in beyond its own.
  public struct Directory: Sendable, Hashable {
    public var path: String
    /// Where it was added, as the CLI names it.
    public var source: String

    public init(path: String, source: String) {
      self.path = path
      self.source = source
    }
  }

  /// In the CLI's order; a rule with a behavior Drakar does not know is left out.
  public var rules: [PermissionRule]
  public var directories: [Directory]
  /// Managed settings allow only their own rules: the others are listed, not applied.
  public var managedOnly: Bool
  /// Settings files skipped for a parse error, each as a line to show.
  public var errors: [String]

  public init(
    rules: [PermissionRule], directories: [Directory] = [], managedOnly: Bool = false,
    errors: [String] = []
  ) {
    self.rules = rules
    self.directories = directories
    self.managedOnly = managedOnly
    self.errors = errors
  }

  /// Nil without `state.rules`. Missing directories and errors read as empty.
  public init?(_ response: JSONValue?) {
    guard let state = response?["state"], let rules = state["rules"]?.arrayValue else {
      return nil
    }
    self.rules = rules.compactMap(PermissionRule.init)
    directories =
      state["workspaceDirectories"]?.arrayValue?.compactMap { directory in
        directory["path"]?.stringValue.map {
          Directory(path: $0, source: directory["source"]?.stringValue ?? "")
        }
      } ?? []
    managedOnly = state["managedOnly"]?.boolValue ?? false
    errors = state["errors"]?.arrayValue?.map(Self.errorText) ?? []
  }

  /// An error's `message`; else the element as compact JSON, so that nothing is dropped.
  private static func errorText(_ error: JSONValue) -> String {
    if let message = error["message"]?.stringValue ?? error.stringValue { return message }
    let line = (try? error.line()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    return line.trimmingCharacters(in: .newlines)
  }
}

/// One change for `claude edit-permission-rules --json`, written to its stdin as `json`.
public enum PermissionRuleEdit: Sendable, Equatable {
  /// Add one or more rules, all with the same behavior, to `file`.
  case add(rules: [String], behavior: PermissionBehavior, file: PermissionRuleFile)
  /// Take `rule`, verbatim as listed, out of `file`.
  case remove(rule: String, behavior: PermissionBehavior, file: PermissionRuleFile)

  /// The command's arguments after the executable.
  public static let arguments = ["edit-permission-rules", "--json"]

  public var json: JSONValue {
    switch self {
    case .add(let rules, let behavior, let file):
      .object([
        "op": .string("add"), "rules": .array(rules.map(JSONValue.string)),
        "behavior": .string(behavior.rawValue), "destination": .string(file.rawValue),
      ])
    case .remove(let rule, let behavior, let file):
      .object([
        "op": .string("remove"), "rule": .string(rule), "behavior": .string(behavior.rawValue),
        "source": .string(file.rawValue),
      ])
    }
  }
}

/// How an edit went, read from the command's exit status and output.
public enum PermissionRuleEditOutcome: Sendable, Equatable {
  /// Written. `stored` is the rules as the file now holds them, which can differ from what
  /// was sent; `warnings` are the CLI's, to show.
  case saved(warnings: [String], stored: [String])
  /// Not written, with the CLI's reason, ready to show.
  case refused(String)

  /// Exit 0 reads stdout's last non-empty line as `{ok, warnings, stored}`, a missing or
  /// unreadable list as empty: the status says it saved. Any other status is a refusal with
  /// stderr's words, less the leading `Error: `, or a sentence naming the status when
  /// stderr says nothing.
  public static func read(status: Int32, output: String, errors: String) -> Self {
    guard status == 0 else {
      var reason = errors.trimmingCharacters(in: .whitespacesAndNewlines)
      if reason.hasPrefix("Error: ") { reason.removeFirst("Error: ".count) }
      guard !reason.isEmpty else {
        return .refused(
          String(localized: "Claude Code couldn't save the rule (exit status \(status))."))
      }
      return .refused(reason)
    }
    let last = output.split(whereSeparator: \.isNewline).last {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    let reply = last.flatMap { try? JSONValue.parse(Data($0.utf8)) }
    let strings = { (key: String) in reply?[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    return .saved(warnings: strings("warnings"), stored: strings("stored"))
  }
}

/// A `get_plan` reply (`ClientMessage.getPlan`): `{exists: false}` or `{exists: true,
/// content, path}`.
public struct PlanReply: Sendable, Equatable {
  public var exists: Bool
  public var content: String?
  /// The plan's file, under the account's `plans/`.
  public var path: String?

  /// Nil without `exists`.
  public init?(_ response: JSONValue?) {
    guard let exists = response?["exists"]?.boolValue else { return nil }
    self.exists = exists
    content = response?["content"]?.stringValue
    path = response?["path"]?.stringValue
  }
}
