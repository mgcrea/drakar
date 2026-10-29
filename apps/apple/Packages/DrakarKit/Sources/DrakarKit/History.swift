import Foundation

/// What a block of user-turn text is, once the host's markup is read.
///
/// A user turn in a transcript is not always something the user typed. Surveyed across
/// 40 transcripts on 2026-10-03: background tasks report as `<task-notification>`, a slash
/// command is stored as `<command-name>`/`<command-args>` tags, its output as
/// `<local-command-stdout>`, the CLI's own notes are bracketed (`[Request interrupted by
/// user]`), and hosts inject context blocks (`<browser_instruction>`, `<ide_opened_file>`,
/// `<ide_selection>`, `<system-reminder>`) that the person never saw as part of their message.
enum UserText: Equatable {
  case prompt(String)
  case notice(String)
  /// The open file or the selection an editor put ahead of the prompt, as its label.
  case context(String)
  case hidden

  static let contextTags = [
    "<browser_instruction>", "<ide_opened_file>", "<ide_selection>", "<system-reminder>",
    "<local-command-caveat>",
  ]

  static func classify(_ raw: String) -> UserText {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return .hidden }
    if let label = EditorSelection.label(context: text) { return .context(label) }
    if contextTags.contains(where: text.hasPrefix) { return .hidden }
    if text.hasPrefix("<task-notification>") {
      let summary = element("summary", in: text) ?? element("status", in: text) ?? "finished"
      return .notice(String(localized: "Background task: \(summary)"))
    }
    if let name = element("command-name", in: text) {
      let arguments = element("command-args", in: text) ?? ""
      return .prompt(arguments.isEmpty ? name : "\(name) \(arguments)")
    }
    if text.hasPrefix("<local-command-stdout>") {
      let output = element("local-command-stdout", in: text) ?? ""
      return output.isEmpty ? .hidden : .notice(output)
    }
    if text.hasPrefix("["), text.hasSuffix("]") {
      return .notice(String(text.dropFirst().dropLast()))
    }
    return .prompt(text)
  }

  /// The text between `<name>` and `</name>`, trimmed; nil if absent or empty.
  static func element(_ name: String, in text: String) -> String? {
    guard let open = text.range(of: "<\(name)>"),
      let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
    else { return nil }
    let inner = text[open.upperBound..<close.lowerBound].trimmingCharacters(
      in: .whitespacesAndNewlines)
    return inner.isEmpty ? nil : inner
  }
}

/// Where a fork cut before a prompt resumes (`Transcript.resumePoint(before:in:)`).
public enum ResumePoint: Equatable, Sendable {
  /// Before the first prompt: there is no message to keep.
  case start
  /// After this message uuid, the one `--resume-session-at` takes.
  case after(String)
}

extension Transcript {
  /// A session's history, folded from the transcript file Claude Code writes at
  /// `<config>/projects/<encoded cwd>/<session id>.jsonl`.
  ///
  /// `--resume` continues the session but does not replay it on stdout (checked on
  /// 2.1.288), so a resumed window draws its past from here and its future from the
  /// process. Lines are read in file order; a branch left by a rewind is not followed.
  public static func history(lines: [Data]) -> Transcript {
    var feed = ClaudeFeed()
    for line in lines {
      guard let json = try? JSONValue.parse(line) else { continue }
      feed.applyHistory(json)
    }
    feed.processExited()
    return feed.transcript
  }

  /// The history a fork ending just before the prompt `promptUUID` keeps: the lines before
  /// that prompt's, found by uuid, never by its text. The whole history when no line has it.
  public static func history(lines: [Data], endingBefore promptUUID: String) -> Transcript {
    let cut = lines.firstIndex { isLine($0, ofPrompt: promptUUID) } ?? lines.endIndex
    return history(lines: Array(lines[..<cut]))
  }

  /// The history a fork resumed at the message `messageUUID` shows (`--resume-session-at`,
  /// which keeps every message up to and including it): the lines through that message's.
  /// The whole history when no line has it.
  public static func history(lines: [Data], through messageUUID: String) -> Transcript {
    let kept = lines.firstIndex { line in
      (try? JSONValue.parse(line))?["uuid"]?.stringValue == messageUUID
    }
    return history(lines: kept.map { Array(lines[...$0]) } ?? lines)
  }

  /// Where a fork that ends just before the prompt `promptUUID` resumes, read from that
  /// prompt line's `parentUuid`: `.after` that message, which `--resume-session-at` takes,
  /// since the CLI keeps the message it is given (docs/claude-stream-json.md, "Rewind",
  /// answer 5); `.start` when it is null, as for the first prompt, which has nothing before
  /// it. Nil when no prompt line has that uuid: there is nothing to fork from.
  public static func resumePoint(before promptUUID: String, in lines: [Data]) -> ResumePoint? {
    guard let line = lines.first(where: { isLine($0, ofPrompt: promptUUID) }),
      let json = try? JSONValue.parse(line)
    else { return nil }
    return json["parentUuid"]?.stringValue.map(ResumePoint.after) ?? .start
  }

  /// Whether `line` is the `user` line of the prompt `uuid`.
  private static func isLine(_ line: Data, ofPrompt uuid: String) -> Bool {
    guard let json = try? JSONValue.parse(line) else { return false }
    return json["type"]?.stringValue == "user" && json["uuid"]?.stringValue == uuid
  }

  public static func history(contentsOf file: URL) throws -> Transcript {
    history(lines: try lines(contentsOf: file))
  }

  /// A transcript file's lines, no further than `length` bytes into it.
  public static func lines(contentsOf file: URL, upTo length: UInt64 = .max) throws -> [Data] {
    var buffer = LineBuffer()
    var lines = buffer.append(try Data(contentsOf: file).prefix(Int(clamping: length)))
    if !buffer.remainder.isEmpty { lines.append(buffer.remainder) }
    return lines
  }
}
