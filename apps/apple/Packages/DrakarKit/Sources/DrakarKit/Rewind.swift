import Foundation

/// What a `rewind_files` request (`ClientMessage.rewindFiles`) answered, as the extension
/// reads it (docs/claude-stream-json.md, "Rewind"). A dry run names the files and counts the
/// lines; a rewind only says it could.
public struct RewindResult: Sendable, Equatable {
  /// The CLI's refusal when checkpointing is off for the process.
  static let notEnabledMarker = "File rewinding is not enabled."
  /// The CLI's refusal for a message it has no file snapshot for.
  static let noCheckpointMarker = "No file checkpoint found"

  public var canRewind: Bool
  public var error: String?
  /// Absolute paths, some maybe outside the session's folder.
  public var filesChanged: [String]
  public var insertions: Int
  public var deletions: Int
  public var skippedLinks: Int

  /// Nil without canRewind. A missing list or count reads as empty or 0.
  public init?(_ response: JSONValue?) {
    guard let canRewind = response?["canRewind"]?.boolValue else { return nil }
    self.canRewind = canRewind
    error = response?["error"]?.stringValue
    filesChanged = response?["filesChanged"]?.arrayValue?.compactMap(\.stringValue) ?? []
    insertions = response?["insertions"]?.intValue ?? 0
    deletions = response?["deletions"]?.intValue ?? 0
    skippedLinks = response?["skippedLinks"]?.intValue ?? 0
  }

  /// A refused real rewind arrives as a control `error` with no response (Task 1, answer 1):
  /// canRewind false, the error string kept, no files.
  public init(refusal error: String) {
    canRewind = false
    self.error = error
    filesChanged = []
    insertions = 0
    deletions = 0
    skippedLinks = 0
  }

  /// The CLI says checkpointing is off for this process.
  public var isNotEnabled: Bool { error?.contains(Self.notEnabledMarker) == true }
  /// The CLI has no file snapshot for the message.
  public var hasNoCheckpoint: Bool { error?.contains(Self.noCheckpointMarker) == true }
}

/// The extension's words for a rewind, and Drakar's own where it has none.
public enum RewindCopy {
  public static let succeeded = String(localized: "Code rewind successful")
  public static let failed = String(localized: "Failed to rewind code")
  public static let noCheckpoint = String(
    localized: "Failed to rewind: no checkpoint for this message")
  public static let warning = String(
    localized:
      "Restored files go back whole, losing later changes by anyone. Bash changes to other files are not undone."
  )
  public static let forkNote = String(
    localized: "A new forked conversation will be created after rewinding.")
  /// Drakar's: an empty dry run in Fork and rewind.
  public static let nothingToRewind = String(localized: "No files to rewind.")
}
