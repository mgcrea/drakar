import Foundation

/// Codex's `model/list` as the model pill lists it (docs/codex-app-server.md, "Models and
/// effort"): visible models, each with the efforts it takes. There is no "default" entry:
/// Codex's own model is `config.toml`'s, named once a thread reports it.
public enum CodexModels {
  public static func list(_ result: JSONValue) -> [ModelOption] {
    (result["data"]?.arrayValue ?? []).compactMap { model in
      guard model["hidden"]?.boolValue != true,
        let id = model["model"]?.stringValue ?? model["id"]?.stringValue
      else { return nil }
      return ModelOption(
        value: id, resolvedModel: id, displayName: model["displayName"]?.stringValue ?? id,
        description: model["description"]?.stringValue ?? "",
        effortLevels: (model["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
          $0["reasoningEffort"]?.stringValue
        })
    }
  }
}
