import Foundation

/// A permission mode the composer offers, in the order ⇧Tab goes through them
/// (docs/superpowers/specs/2026-10-06-mode-and-model-pills-design.md). The CLI's `manual`
/// (another name for `default`) and `dontAsk` are not offered.
public enum PermissionMode: String, Sendable, CaseIterable {
  case ask = "default"
  case acceptEdits
  case plan
  case auto
  case bypass = "bypassPermissions"

  public var title: String {
    switch self {
    case .ask: String(localized: "Ask before edits")
    case .acceptEdits: String(localized: "Edit automatically")
    case .plan: String(localized: "Plan")
    case .auto: String(localized: "Auto")
    case .bypass: String(localized: "Bypass permissions")
    }
  }

  public var symbol: String {
    switch self {
    case .ask: "hand.raised"
    case .acceptEdits: "pencil"
    case .plan: "list.bullet.clipboard"
    case .auto: "wand.and.stars"
    case .bypass: "exclamationmark.shield"
    }
  }

  /// The mode after `current` among `offered`, wrapping; the first when `current` is not
  /// offered any more.
  public static func next(after current: PermissionMode, among offered: [PermissionMode])
    -> PermissionMode
  {
    guard let index = offered.firstIndex(of: current) else { return offered.first ?? .ask }
    return offered[(index + 1) % offered.count]
  }

  /// `raw`'s title, or `raw` itself for a mode Drakar does not offer.
  public static func title(of raw: String) -> String {
    PermissionMode(rawValue: raw)?.title ?? raw
  }
}

/// One model an account offers, as `initialize`'s `models` lists it.
public struct ModelOption: Sendable, Hashable, Identifiable {
  /// What `--model` and `set_model` take: `default`, an alias, or a pinned id.
  public var value: String
  /// The id it stands for today (`claude-opus-5-5`).
  public var resolvedModel: String?
  public var displayName: String
  public var description: String
  public var supportsAutoMode: Bool
  /// The effort levels it takes, lowest first; none for a model without effort (Haiku).
  public var effortLevels: [String]

  public var id: String { value }

  public init(
    value: String, resolvedModel: String? = nil, displayName: String, description: String = "",
    supportsAutoMode: Bool = false, effortLevels: [String] = []
  ) {
    self.value = value
    self.resolvedModel = resolvedModel
    self.displayName = displayName
    self.description = description
    self.supportsAutoMode = supportsAutoMode
    self.effortLevels = effortLevels
  }

  init?(_ json: JSONValue) {
    guard let value = json["value"]?.stringValue else { return nil }
    self.init(
      value: value, resolvedModel: json["resolvedModel"]?.stringValue,
      displayName: json["displayName"]?.stringValue ?? value,
      description: json["description"]?.stringValue ?? "",
      supportsAutoMode: json["supportsAutoMode"]?.boolValue ?? false,
      effortLevels: json["supportsEffort"]?.boolValue == true
        ? json["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue) ?? [] : [])
  }

  /// The models an `initialize` reply lists, in its order; nil when it has no `models`.
  public static func list(fromInitialize reply: JSONValue?) -> [ModelOption]? {
    reply?["models"]?.arrayValue?.compactMap(ModelOption.init)
  }

  /// `models` without the older ones: a pinned id (`claude-opus-4-8`) that none of the list's
  /// aliases stands for today. `kept` stays whatever it is. A list with no alias but
  /// `default`, as a cloud provider's may be, is kept whole: nothing in it says which is
  /// current.
  public static func withoutLegacy(_ models: [ModelOption], keeping kept: String? = nil)
    -> [ModelOption]
  {
    let aliases = models.filter { !$0.isPinned && $0.value != "default" }
    guard !aliases.isEmpty else { return models }
    let current = Set(aliases.compactMap(\.resolvedModel))
    return models.filter { option in
      !option.isPinned || option.value == kept
        || option.resolvedModel.map(current.contains) == true
    }
  }

  /// A full model id rather than an alias.
  private var isPinned: Bool { value.hasPrefix("claude-") }
}

/// An effort level, as the CLI names it: `low`, `medium`, `high`, `xhigh`, `max`. The model
/// says which it takes (`ModelOption.effortLevels`), so the list is never written here.
public enum EffortLevel {
  /// `raw`'s title, or `raw` itself for a level Drakar does not know.
  public static func title(of raw: String) -> String {
    switch raw {
    case "low": String(localized: "Low")
    case "medium": String(localized: "Medium")
    case "high": String(localized: "High")
    case "xhigh": String(localized: "Extra high")
    case "max": String(localized: "Max")
    case "ultra": String(localized: "Ultra")
    default: raw
    }
  }

  /// A gauge filling with the level.
  public static func symbol(of raw: String?) -> String {
    switch raw {
    case "low": "gauge.with.dots.needle.0percent"
    case "medium": "gauge.with.dots.needle.33percent"
    case "high": "gauge.with.dots.needle.50percent"
    case "xhigh": "gauge.with.dots.needle.67percent"
    case "max": "gauge.with.dots.needle.100percent"
    case "ultra": "gauge.with.dots.needle.100percent"
    default: "gauge.with.dots.needle.bottom.50percent"
    }
  }

  /// The effort a `get_settings` reply says the process applies; nil for a model without
  /// effort.
  public static func applied(fromSettings reply: JSONValue?) -> String? {
    reply?["applied"]?["effort"]?.stringValue
  }
}
