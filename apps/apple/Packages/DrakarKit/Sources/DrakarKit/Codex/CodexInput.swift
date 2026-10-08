import Foundation

/// A prompt as `turn/start` and `turn/steer` take it (`UserInput[]`, docs/codex-app-server.md,
/// "Input"): the editor's context first, as the extension's chat puts it, then the prompt,
/// then each attachment. Codex has no document input: a text file goes inline, and a PDF is
/// refused before it gets here.
public enum CodexInput {
  /// A prompt that starts with one of `skills` by name (`/deploy now`) carries that skill's
  /// item after its text, which stays as typed.
  public static func make(
    text: String, context: [EditorSelection], attachments: [Attachment],
    skills: [SkillEntry] = []
  ) -> JSONValue {
    var items = context.map { Self.text($0.promptContext) }
    if !text.isEmpty { items.append(Self.text(text)) }
    if let skill = named(in: text, among: skills), let path = skill.path {
      items.append(
        .object([
          "type": .string("skill"), "name": .string(skill.name), "path": .string(path),
        ]))
    }
    items += attachments.compactMap { item($0.block) }
    return .array(items)
  }

  /// The skill `text` starts with: `/`, its whole name, then whitespace or nothing.
  static func named(in text: String, among skills: [SkillEntry]) -> SkillEntry? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("/") else { return nil }
    let name = text.dropFirst().prefix { !$0.isWhitespace }
    guard !name.isEmpty else { return nil }
    return skills.first { $0.name == name && $0.path != nil }
  }

  public static func text(_ text: String) -> JSONValue {
    .object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])
  }

  /// An attachment's Claude block in Codex's words: an image as a data URL (verified), a text
  /// file inline in an `<attachment>` element that history reads back.
  static func item(_ block: JSONValue) -> JSONValue? {
    let source = block["source"]
    switch (block["type"]?.stringValue, source?["type"]?.stringValue) {
    case ("image", "base64"):
      guard let media = source?["media_type"]?.stringValue,
        let data = source?["data"]?.stringValue
      else { return nil }
      return .object(["type": .string("image"), "url": .string("data:\(media);base64,\(data)")])
    case ("document", "text"):
      guard let content = source?["data"]?.stringValue else { return nil }
      let name = block["title"]?.stringValue ?? "attachment"
      return text("<attachment name=\"\(name)\">\n\(content)\n</attachment>")
    default:
      return nil
    }
  }
}
