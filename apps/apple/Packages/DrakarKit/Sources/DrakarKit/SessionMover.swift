import Foundation

/// Why a session was not moved.
public enum SkipReason: Sendable, Equatable {
  /// The target account already holds a transcript with this id.
  case alreadyThere
  /// A Drakar window is running a turn in it or waiting on a permission.
  case busy
  /// Open in another process: "VS Code", "a terminal", "the Claude app", "another app".
  case runningElsewhere(String)
}

public enum MoveOutcome: Sendable, Equatable {
  case moved
  case skipped(SkipReason)
  case failed(String)
}

/// Moves one session's files from one account's directory to another's
/// (`docs/superpowers/specs/2026-10-04-move-sessions-design.md`). A session belongs to the
/// account whose `projects` holds its transcript, so the transcript goes last: a move cut
/// short leaves the session where it was, and moving it again finishes.
public enum SessionMover {
  /// Where `transcript` lands under `target`: the same `projects/<folder name>/<id>.jsonl`,
  /// the folder name reused as the source has it, never encoded again from a path.
  public static func destination(of transcript: URL, to target: ClaudeAccount) -> URL {
    target.directory.appending(path: "projects", directoryHint: .isDirectory)
      .appending(
        path: transcript.deletingLastPathComponent().lastPathComponent, directoryHint: .isDirectory
      )
      .appending(path: transcript.lastPathComponent)
  }

  /// Nothing is overwritten: a transcript already at the target skips the session, and a
  /// sidecar already there is left beside the source's.
  public static func move(
    transcript: URL, from source: ClaudeAccount, to target: ClaudeAccount,
    fileManager: FileManager = .default
  ) -> MoveOutcome {
    func exists(_ url: URL) -> Bool {
      fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }
    guard exists(target.directory) else {
      return .failed(
        String(localized: "\(target.directory.path(percentEncoded: false)) no longer exists."))
    }
    let destination = destination(of: transcript, to: target)
    guard !exists(destination) else { return .skipped(.alreadyThere) }
    let id = transcript.deletingPathExtension().lastPathComponent
    let sidecars = [
      (transcript.deletingPathExtension(), destination.deletingPathExtension()),
      (
        source.directory.appending(path: "file-history").appending(path: id),
        target.directory.appending(path: "file-history").appending(path: id)
      ),
      (
        source.directory.appending(path: "session-env").appending(path: id),
        target.directory.appending(path: "session-env").appending(path: id)
      ),
    ]
    do {
      for (from, to) in sidecars where exists(from) && !exists(to) {
        try fileManager.createDirectory(
          at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: from, to: to)
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.moveItem(at: transcript, to: destination)
      return .moved
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}
