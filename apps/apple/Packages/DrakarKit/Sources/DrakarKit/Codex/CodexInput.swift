import Foundation

/// A prompt as `turn/start` and `turn/steer` take it (`UserInput[]`, docs/codex-app-server.md,
/// "Input"): the editor's context first, as the extension's chat puts it, then the prompt,
/// then each attachment. Codex has no document input: a text file goes inline, and a PDF is
/// refused before it gets here.
public enum CodexInput {
  public static func make(text: String, context: [EditorSelection], attachments: [Attachment])
    -> JSONValue
  {
    var items = context.map { Self.text($0.promptContext) }
    if !text.isEmpty { items.append(Self.text(text)) }
    items += attachments.compactMap { item($0.block) }
    return .array(items)
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
