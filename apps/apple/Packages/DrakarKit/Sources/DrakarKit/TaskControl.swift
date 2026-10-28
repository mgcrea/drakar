import Foundation

/// What became of a `background_tasks` request (`ClientMessage.backgroundCall`), as the
/// extension reads its reply (docs/claude-stream-json.md, "Task controls").
public enum BackgroundOutcome: Sendable, Equatable {
  /// The call runs in the background now.
  case moved
  /// No foreground call by that ID: it had finished, or was in the background already.
  case notFound
  /// The session runs with `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`.
  case disabled
  case failed

  /// From the reply: success with `backgrounded` true or missing is moved, false is notFound;
  /// an error containing TaskControl.disabledMarker is disabled; any other error is failed.
  public init(isSuccess: Bool, response: JSONValue?, error: String?) {
    if isSuccess {
      self = response?["backgrounded"]?.boolValue == false ? .notFound : .moved
    } else if error?.contains(TaskControl.disabledMarker) == true {
      self = .disabled
    } else {
      self = .failed
    }
  }

  /// Nil for `.moved`; the extension's sentence otherwise.
  public var message: String? {
    switch self {
    case .moved: nil
    case .notFound:
      String(
        localized:
          "Could not move this to the background. It may have just finished or already be running in the background."
      )
    case .disabled: String(localized: "Moving to the background is turned off for this session.")
    case .failed: String(localized: "Could not move this to the background. Try again.")
    }
  }
}

/// A `get_task_output` reply (`ClientMessage.taskOutput`): a shell or Monitor task's output,
/// its tail when the whole is too long.
public struct TaskOutput: Sendable, Equatable {
  /// As the reply has it: escapes, carriage returns and a cut first line included.
  public var text: String
  /// The whole output's size, of which `text` may be the end.
  public var totalBytes: Int
  public var isTruncated: Bool

  /// Nil without output, total_bytes and truncated.
  public init?(_ response: JSONValue?) {
    guard let text = response?["output"]?.stringValue,
      let totalBytes = response?["total_bytes"]?.intValue,
      let isTruncated = response?["truncated"]?.boolValue
    else { return nil }
    self.text = text
    self.totalBytes = totalBytes
    self.isTruncated = isTruncated
  }

  /// `text` to show: a truncated tail starts on its first whole line, or past the
  /// replacement characters a cut UTF-8 sequence left; terminal escapes (CSI) and the `\r`
  /// of each `\r\n` removed.
  public var displayText: String {
    // Scalars, not Characters: "\r\n" is one Character, and an escape's bytes are not.
    var scalars = Array(text.unicodeScalars)
    if isTruncated {
      if let newline = scalars.firstIndex(of: "\n"), newline < scalars.count - 1 {
        scalars.removeFirst(newline + 1)
      } else {
        scalars = Array(scalars.drop { $0 == "\u{FFFD}" })
      }
    }
    var shown = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "[" {
        // ESC [, parameter and intermediate bytes (0x20-0x3F), a final byte in @...~. One
        // without its final byte, as a tail cut mid-escape ends, is kept as it is.
        var end = index + 2
        while end < scalars.count, (0x20...0x3F).contains(scalars[end].value) { end += 1 }
        if end < scalars.count, (0x40...0x7E).contains(scalars[end].value) {
          index = end + 1
          continue
        }
      }
      if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
        index += 1
        continue
      }
      shown.append(scalar)
      index += 1
    }
    return String(shown)
  }

  /// "Showing the end of 12 kB" when truncated, else nil.
  public var note: String? {
    guard isTruncated else { return nil }
    let size = totalBytes.formatted(.byteCount(style: .file))
    return String(localized: "Showing the end of \(size)")
  }
}

public enum TaskControl {
  /// The error `background_tasks` answers in a session with background tasks turned off.
  public static let disabledMarker = "Background tasks are disabled in this session."
  /// The extension's sentence for a `stop_task` that failed.
  public static let stopFailure = String(
    localized: "The agent could not be stopped. It may have finished already.")
  /// What an empty output reads as.
  public static let noOutput = String(localized: "No output yet.")
}
