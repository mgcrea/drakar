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

extension Transcript {
  /// A session's history, folded from the transcript file Claude Code writes at
  /// `<config>/projects/<encoded cwd>/<session id>.jsonl`.
  ///
  /// `--resume` continues the session but does not replay it on stdout (checked on
  /// 2.1.288), so a resumed window draws its past from here and its future from the
  /// process. Lines are read in file order; a branch left by a rewind is not followed.
  public static func history(lines: [Data]) -> Transcript {
    var transcript = Transcript()
    for line in lines {
      guard let json = try? JSONValue.parse(line) else { continue }
      transcript.applyHistory(json)
    }
    transcript.processExited()
    return transcript
  }

  public static func history(contentsOf file: URL) throws -> Transcript {
    var buffer = LineBuffer()
    var lines = buffer.append(try Data(contentsOf: file))
    if !buffer.remainder.isEmpty { lines.append(buffer.remainder) }
    return history(lines: lines)
  }

  /// One transcript line. Unknown entry types (attachments, snapshots, cost records) and
  /// subagent sidechains are skipped.
  public mutating func applyHistory(_ json: JSONValue) {
    guard json["isSidechain"]?.boolValue != true else { return }
    switch json["type"]?.stringValue {
    case "ai-title":
      if let title = json["aiTitle"]?.stringValue, !title.isEmpty { self.title = title }
    case "assistant":
      if let message = try? StreamMessage(json: json) { apply(message) }
    case "user":
      if json["isMeta"]?.boolValue == true { return }
      if json["isCompactSummary"]?.boolValue == true {
        addNotice(String(localized: "Earlier conversation compacted"))
        return
      }
      guard case .user(let user)? = try? StreamMessage(json: json) else { return }
      let texts = user.content.compactMap { block -> String? in
        if case .text(let text) = block { return text }
        return nil
      }
      var prompt: [String] = []
      var context: String?
      for text in texts {
        switch UserText.classify(text) {
        case .prompt(let part): prompt.append(part)
        case .notice(let note): addNotice(note, parent: user.parentToolUseID)
        case .context(let label): context = label
        case .hidden: break
        }
      }
      if !prompt.isEmpty {
        addPrompt(prompt.joined(separator: "\n\n"), context: context, running: false)
      }
      // Tool results go through the live path, which pairs them with their calls.
      let results = user.content.filter {
        if case .toolResult = $0 { return true }
        return false
      }
      if !results.isEmpty {
        var resultsOnly = user
        resultsOnly.content = results
        apply(.user(resultsOnly))
      }
    default:
      break
    }
  }
}
