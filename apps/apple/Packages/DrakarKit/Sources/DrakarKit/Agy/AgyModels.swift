import Foundation

/// Antigravity's models, efforts and modes from `session/new`, `session/resume`,
/// `session/set_config_option`, and `config_option_update` (docs/agy-acp.md).
///
/// `configOptions` lists base models (`id == "model"`) and the active model's thinking levels
/// (`id == "thought_level"`), while `models.availableModels` lists every `(model, effort)`
/// variant (`gemini-4-neon-high`, `gemini-4-neon-xhigh`, …). Combining both gives every model
/// its exact supported effort levels up front.
public enum AgyModels {
  public struct Snapshot: Sendable, Equatable {
    public var models: [ModelOption]
    public var currentModel: String?
    public var currentEffort: String?
    public var currentMode: PermissionMode?

    public init(
      models: [ModelOption] = [], currentModel: String? = nil, currentEffort: String? = nil,
      currentMode: PermissionMode? = nil
    ) {
      self.models = models
      self.currentModel = currentModel
      self.currentEffort = currentEffort
      self.currentMode = currentMode
    }
  }

  private static let effortOrder = ["low", "medium", "high", "xhigh", "max"]

  /// Reads a `session/new`, `session/resume` or `session/load` result.
  public static func snapshot(from result: JSONValue) -> Snapshot {
    let configOptions = result["configOptions"]?.arrayValue ?? []
    let available = result["models"]?["availableModels"]?.arrayValue ?? []
    let availableIDs = Set(available.compactMap { $0["modelId"]?.stringValue })

    let modelConfig = configOptions.first { $0["id"]?.stringValue == "model" }
    let thoughtConfig = configOptions.first {
      $0["category"]?.stringValue == "thought_level" || $0["id"]?.stringValue == "thought_level"
    }
    let modeConfig = configOptions.first { $0["id"]?.stringValue == "mode" }

    let currentModel =
      modelConfig?["currentValue"]?.stringValue
      ?? baseModel(from: result["models"]?["currentModelId"]?.stringValue)
    let currentEffort =
      thoughtConfig?["currentValue"]?.stringValue
      ?? effortSuffix(from: result["models"]?["currentModelId"]?.stringValue)
    let modeID =
      modeConfig?["currentValue"]?.stringValue ?? result["modes"]?["currentModeId"]?.stringValue
    let currentMode = modeID.flatMap(AgyPolicy.permissionMode(from:))

    let activeEfforts =
      thoughtConfig?["options"]?.arrayValue?.compactMap { $0["value"]?.stringValue } ?? []

    var models: [ModelOption] = []
    if let options = modelConfig?["options"]?.arrayValue, !options.isEmpty {
      for option in options {
        guard let value = option["value"]?.stringValue else { continue }
        let name = option["name"]?.stringValue ?? value
        let description = option["description"]?.stringValue ?? ""
        var levels = effortOrder.filter { availableIDs.contains("\(value)-\($0)") }
        if levels.isEmpty, value == currentModel, !activeEfforts.isEmpty {
          levels = activeEfforts
        }
        models.append(
          ModelOption(
            value: value, resolvedModel: value, displayName: name, description: description,
            supportsAutoMode: true, effortLevels: levels))
      }
    } else {
      for entry in available {
        guard let id = entry["modelId"]?.stringValue else { continue }
        models.append(
          ModelOption(
            value: id, resolvedModel: id, displayName: entry["name"]?.stringValue ?? id,
            description: entry["description"]?.stringValue ?? "",
            supportsAutoMode: true, effortLevels: []))
      }
    }

    return Snapshot(
      models: models, currentModel: currentModel, currentEffort: currentEffort,
      currentMode: currentMode)
  }

  /// Reads a `configOptions` array (from `session/set_config_option` or `config_option_update`),
  /// keeping effort levels already known for other models in `existing`.
  public static func updated(configOptions: [JSONValue], merging existing: [ModelOption])
    -> Snapshot
  {
    let knownEfforts = Dictionary(
      existing.map { ($0.value, $0.effortLevels) }, uniquingKeysWith: { first, _ in first })
    let modelConfig = configOptions.first { $0["id"]?.stringValue == "model" }
    let thoughtConfig = configOptions.first {
      $0["category"]?.stringValue == "thought_level" || $0["id"]?.stringValue == "thought_level"
    }
    let modeConfig = configOptions.first { $0["id"]?.stringValue == "mode" }

    let currentModel = modelConfig?["currentValue"]?.stringValue
    let currentEffort = thoughtConfig?["currentValue"]?.stringValue
    let currentMode = modeConfig?["currentValue"]?.stringValue.flatMap(
      AgyPolicy.permissionMode(from:))
    let activeEfforts =
      thoughtConfig?["options"]?.arrayValue?.compactMap { $0["value"]?.stringValue } ?? []

    var models: [ModelOption] = []
    if let options = modelConfig?["options"]?.arrayValue, !options.isEmpty {
      for option in options {
        guard let value = option["value"]?.stringValue else { continue }
        let name = option["name"]?.stringValue ?? value
        let description = option["description"]?.stringValue ?? ""
        let levels =
          value == currentModel && !activeEfforts.isEmpty
          ? activeEfforts : (knownEfforts[value] ?? [])
        models.append(
          ModelOption(
            value: value, resolvedModel: value, displayName: name, description: description,
            supportsAutoMode: true, effortLevels: levels))
      }
    } else {
      models = existing
    }
    return Snapshot(
      models: models, currentModel: currentModel, currentEffort: currentEffort,
      currentMode: currentMode)
  }

  private static func baseModel(from modelID: String?) -> String? {
    guard let modelID else { return nil }
    for level in effortOrder {
      let suffix = "-\(level)"
      if modelID.hasSuffix(suffix) { return String(modelID.dropLast(suffix.count)) }
    }
    return modelID
  }

  private static func effortSuffix(from modelID: String?) -> String? {
    guard let modelID else { return nil }
    for level in effortOrder where modelID.hasSuffix("-\(level)") { return level }
    return nil
  }
}
