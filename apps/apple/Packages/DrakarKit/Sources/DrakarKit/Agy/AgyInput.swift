import Foundation

/// A prompt as ACP `session/prompt` takes it (`prompt: [ContentBlock]`, docs/agy-acp.md):
/// editor context first, then the prompt text, then images (`type: "image"`, `mimeType`, `data`)
/// and text attachments inline in `<attachment>` blocks. PDFs are refused at intake.
public enum AgyInput {
  public static func make(
    text: String, context: [EditorSelection], attachments: [Attachment]
  ) -> JSONValue {
    var items = context.map { Self.text($0.promptContext) }
    if !text.isEmpty { items.append(Self.text(text)) }
    items += attachments.compactMap { item($0.block) }
    return .array(items)
  }

  public static func text(_ text: String) -> JSONValue {
    .object(["type": .string("text"), "text": .string(text)])
  }

  /// An attachment's Claude block in ACP's shape: base64 image block (verified 2026-11-27),
  /// text file inline in `<attachment>` that history reads back.
  static func item(_ block: JSONValue) -> JSONValue? {
    let source = block["source"]
    switch (block["type"]?.stringValue, source?["type"]?.stringValue) {
    case ("image", "base64"):
      guard let media = source?["media_type"]?.stringValue,
        let data = source?["data"]?.stringValue
      else { return nil }
      return .object([
        "type": .string("image"),
        "mimeType": .string(media),
        "data": .string(data),
      ])
    case ("document", "text"):
      guard let content = source?["data"]?.stringValue else { return nil }
      let name = block["title"]?.stringValue ?? "attachment"
      return text("<attachment name=\"\(name)\">\n\(content)\n</attachment>")
    default:
      return nil
    }
  }

  /// Slash commands and skills from an `available_commands_update` notification; nil when the
  /// update carries no `availableCommands`.
  public static func commands(from update: JSONValue) -> [SkillEntry]? {
    guard let raw = update["availableCommands"]?.arrayValue else { return nil }
    let entries: [SkillEntry] = raw.compactMap { item in
      guard let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
      return SkillEntry(
        name: name,
        description: item["description"]?.stringValue ?? "",
        argumentHint: item["input"]?["hint"]?.stringValue ?? "",
        isBuiltin: false)
    }
    return ProjectCapabilities.sorted(entries)
  }
}
