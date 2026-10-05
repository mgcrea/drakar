import Foundation

/// A Claude model id as a person reads it: `claude-opus-5[1m]` is "Opus 5 · 1M".
public enum ModelName {
  private static let extendedSuffix = "[1m]"

  /// The family and version of a `claude-` id, with " · 1M" for the extended context
  /// window; any other id as it is. A trailing release date is dropped, and the old order
  /// (`claude-3-5-sonnet-…`) reads like the new.
  public static func display(_ id: String) -> String {
    let extended = id.hasSuffix(extendedSuffix)
    let base = extended ? String(id.dropLast(extendedSuffix.count)) : id
    guard base.hasPrefix("claude-") else { return id }
    var family: String?
    var version: [Substring] = []
    for part in base.dropFirst("claude-".count).split(separator: "-") {
      if part.allSatisfy(\.isNumber) {
        // A release date, `20250929`, is not part of the version.
        if part.count < 8 { version.append(part) }
      } else if family == nil {
        family = part.prefix(1).uppercased() + part.dropFirst()
      }
    }
    guard let family else { return id }
    let name = ([family] + (version.isEmpty ? [] : [version.joined(separator: ".")]))
      .joined(separator: " ")
    return extended ? "\(name) · 1M" : name
  }

  /// The session's model id: its process's report (`system/init`), else its newest message's
  /// (which never carries `[1m]`, so the session's own attachment lends it when it names the
  /// same model), else the attachment. A turn the CLI wrote itself names no model.
  public static func current(
    initModel: String?, messageModel: String?, attachmentModel: String?
  ) -> String? {
    if let initModel { return initModel }
    let message = messageModel == TranscriptTail.syntheticModel ? nil : messageModel
    guard let message else { return attachmentModel }
    if let attachmentModel, attachmentModel == message + extendedSuffix { return attachmentModel }
    return message
  }
}
