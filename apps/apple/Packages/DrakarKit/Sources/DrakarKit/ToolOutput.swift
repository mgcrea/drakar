import Foundation

/// A tool's result as a card shows it without being opened, as the extension does: a shell
/// call's first lines, a search's count, a refusal's reason.
public enum ToolOutput {
  /// Lines a shell result shows under its card; an error gets more, as in the extension.
  public static let previewLines = 3
  public static let errorPreviewLines = 8

  /// Read no further than this into a result for its preview, so a build log of megabytes
  /// costs no more than a short one.
  static let previewScalarLimit = 8_000

  /// Terminal output as it reads on screen: escape sequences (CSI, OSC) removed, `\r\n` a
  /// newline, a line a bare `\r` rewrote (a progress bar) only its last write, and the other
  /// control characters dropped, tab and newline kept.
  public static func cleaned(_ text: String) -> String {
    cleaned(Array(text.unicodeScalars))
  }

  static func cleaned(_ scalars: [Unicode.Scalar]) -> String {
    var shown: [Unicode.Scalar] = []
    // Where the line being written starts in `shown`, and whether a bare `\r` sent the
    // cursor back to it: the next character written starts the line over.
    var lineStart = 0
    var returned = false
    func append(_ scalar: Unicode.Scalar) {
      if returned {
        shown.removeSubrange(lineStart...)
        returned = false
      }
      shown.append(scalar)
    }
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      switch scalar {
      case "\u{1B}":
        index = endOfEscape(in: scalars, at: index)
        continue
      case "\r":
        if index + 1 < scalars.count, scalars[index + 1] == "\n" {
          index += 1
          continue
        }
        returned = true
      case "\n":
        shown.append(scalar)
        lineStart = shown.count
        returned = false
      case "\t":
        append(scalar)
      default:
        if scalar.properties.generalCategory != .control { append(scalar) }
      }
      index += 1
    }
    return String(String.UnicodeScalarView(shown))
  }

  /// The index past the escape sequence starting at `index`. CSI: `ESC [`, parameter and
  /// intermediate bytes (0x20-0x3F), a final byte in @...~. OSC: `ESC ]` up to BEL or
  /// `ESC \`. Anything else: the escape and the one character after it. A sequence cut
  /// short (a tail ending mid-escape) runs to the end of the text.
  private static func endOfEscape(in scalars: [Unicode.Scalar], at index: Int) -> Int {
    guard index + 1 < scalars.count else { return scalars.count }
    switch scalars[index + 1] {
    case "[":
      var end = index + 2
      while end < scalars.count, (0x20...0x3F).contains(scalars[end].value) { end += 1 }
      if end < scalars.count, (0x40...0x7E).contains(scalars[end].value) { return end + 1 }
      // Malformed: drop the escape alone and show what follows.
      return end < scalars.count ? index + 1 : scalars.count
    case "]":
      var end = index + 2
      while end < scalars.count {
        if scalars[end] == "\u{07}" { return end + 1 }
        if scalars[end] == "\u{1B}", end + 1 < scalars.count, scalars[end + 1] == "\\" {
          return end + 2
        }
        end += 1
      }
      return scalars.count
    default:
      return index + 2
    }
  }

  /// The first lines of a result, and whether there was more.
  public struct Preview: Sendable, Equatable {
    public var text: String
    public var isClipped: Bool

    public init(text: String, isClipped: Bool) {
      self.text = text
      self.isClipped = isClipped
    }
  }

  /// The first `lines` lines of `content`, cleaned, blank lines before and after left out;
  /// nil when nothing is left.
  public static func preview(of content: String, lines: Int) -> Preview? {
    let scalars = content.unicodeScalars
    let read = Array(scalars.prefix(previewScalarLimit))
    // Not `scalars.count`, which would walk the whole result.
    let cutShort = !scalars.dropFirst(previewScalarLimit).isEmpty
    var all = cleaned(read).split(separator: "\n", omittingEmptySubsequences: false)
    // A cut can end inside a line; it is not a whole one.
    if cutShort, all.count > 1 { all.removeLast() }
    while let first = all.first, first.allSatisfy(\.isWhitespace) { all.removeFirst() }
    while let last = all.last, last.allSatisfy(\.isWhitespace) { all.removeLast() }
    guard !all.isEmpty else { return nil }
    let kept = all.prefix(lines)
    return Preview(
      text: kept.joined(separator: "\n"), isClipped: cutShort || all.count > kept.count)
  }

  /// The CLI's refusal of a call, with the reason the user gave if they gave one.
  public struct Refusal: Sendable, Equatable {
    public var reason: String?
  }

  /// Nil unless the result is the CLI's refusal of the call.
  public static func refusal(in result: Transcript.ToolResult) -> Refusal? {
    guard result.isError, result.content.hasPrefix(UserQuestion.declinedPrefix) else {
      return nil
    }
    guard let marker = result.content.range(of: UserQuestion.declinedReasonMarker) else {
      return Refusal(reason: nil)
    }
    let reason = result.content[marker.upperBound...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Refusal(reason: reason.isEmpty ? nil : reason)
  }

  /// A search's result as one line: "Found 12 files", "34 lines of output", "No matches
  /// found", as the extension words Glob and Grep.
  public static func searchSummary(of content: String, isFileList: Bool) -> String {
    var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix(searchStoppedNote) { text.removeFirst(searchStoppedNote.count) }
    let lines = text.split(whereSeparator: \.isNewline)
      .filter { !$0.allSatisfy(\.isWhitespace) }
    let none = lines.count == 1 && noResults.contains(String(lines[0]))
    let count = none ? 0 : lines.count
    if isFileList {
      switch count {
      case 0: return String(localized: "No files found")
      case 1: return String(localized: "Found 1 file")
      default: return String(localized: "Found \(count) files")
      }
    }
    // Grep's files-only mode heads its list with its own count.
    if let first = lines.first, first.hasPrefix("Found "),
      first.hasSuffix(" file")
        || first.hasSuffix(" files")
    {
      return String(first)
    }
    switch count {
    case 0: return String(localized: "No matches found")
    case 1: return String(localized: "1 line of output")
    default: return String(localized: "\(count) lines of output")
    }
  }

  /// What Glob and Grep answer when nothing matched.
  static let noResults: Set<String> = ["No files found", "No matches found"]

  /// What the CLI puts before a search's results when its time ran out (2.1.332).
  static let searchStoppedNote =
    "The search stopped before it finished, most likely at its time limit, so these results are incomplete: more matches may exist. Search a more specific path or pattern."
}
