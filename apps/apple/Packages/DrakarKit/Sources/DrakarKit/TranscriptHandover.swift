import Foundation

/// What a session moving to another provider sends there first: its transcript as a
/// Markdown document, attached to a short prompt, so the new session's own transcript shows
/// a file chip rather than the whole conversation pasted in.
public struct TranscriptHandover: Sendable, Equatable {
  /// The name the document is attached under.
  public static let documentName = "handover.md"
  /// Caps the document so a long session's handover costs a bounded part of the new
  /// provider's context; the opening entry and the most recent ones are kept.
  public static let defaultMaxCharacters = 100_000

  /// The prompt sent with the document.
  public let prompt: String
  /// The transcript so far, as Markdown.
  public let document: String

  /// The handover of `transcript` from `sourceProvider` to `targetProvider`, or `nil` when it
  /// has no conversational entries (no prompt, text, or tool call on the main thread).
  /// `earlier` are the conversations `transcript` itself continues, oldest first, each with
  /// the provider that held it: a session moved twice hands over all of it.
  public init?(
    from transcript: Transcript,
    earlier: [(provider: String, transcript: Transcript)] = [],
    title: String? = nil,
    from sourceProvider: String,
    to targetProvider: String,
    maxCharacters: Int = defaultMaxCharacters
  ) {
    let parts = earlier + [(provider: sourceProvider, transcript: transcript)]
    var blocks: [Block] = []
    var providers: [String] = []
    for part in parts {
      let partBlocks = Self.formattedBlocks(from: part.transcript)
      guard !partBlocks.isEmpty else { continue }
      if let previous = providers.last {
        blocks.append(
          Block(text: "_Moved from \(previous) to \(part.provider)._", isCompactLine: false))
      }
      if providers.last != part.provider { providers.append(part.provider) }
      blocks += partBlocks
    }
    guard !blocks.isEmpty else { return nil }

    let body = Self.fittedBody(blocks, maxCharacters: max(maxCharacters, 200))
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let heldWith = providers.joined(separator: ", then ")
    let header = [
      "# \(title.flatMap { $0.isEmpty ? nil : $0 } ?? "Session handover")", "",
      "Transcript of a conversation held with \(heldWith), moved to \(targetProvider).",
    ]
    document = header.joined(separator: "\n") + "\n\n" + body + "\n"
    prompt = """
      This conversation moved here from \(sourceProvider). The attached \(Self.documentName) \
      holds its transcript so far. Read it and continue from where it ends: reply briefly that \
      you have the context, or answer the question it ends on if that is still open.
      """
  }

  private struct Block {
    var text: String
    var isCompactLine: Bool
  }

  private static func formattedBlocks(from transcript: Transcript) -> [Block] {
    let main = transcript.entries.filter {
      $0.parentToolUseID == nil && $0.id != Transcript.coldCacheNoteID
    }
    let hasConversation = main.contains { entry in
      switch entry.kind {
      case .prompt, .text, .tool: true
      case .thinking, .notice, .failure: false
      }
    }
    guard hasConversation else { return [] }

    var blocks: [Block] = []
    for entry in main {
      switch entry.kind {
      case .thinking:
        continue
      case .prompt where entry.attachments.contains { $0.name == documentName }:
        // A handover's own prompt: what it handed over is already here.
        continue
      case .prompt(let text):
        var lines = ["## User"]
        if let context = entry.context, !context.isEmpty {
          lines.append("Context: \(context)")
        }
        if !entry.attachments.isEmpty {
          let names = entry.attachments.map {
            $0.name ?? ($0.kind == .pdf ? "PDF" : $0.kind == .text ? "text" : "image")
          }
          lines.append("Attachments: \(names.joined(separator: ", "))")
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append(body) }
        blocks.append(Block(text: lines.joined(separator: "\n"), isCompactLine: false))
      case .text(let text):
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { continue }
        blocks.append(Block(text: "## Assistant\n\n\(body)", isCompactLine: false))
      case .tool(let call):
        blocks.append(Block(text: formatTool(call), isCompactLine: true))
      case .notice(let text):
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { continue }
        blocks.append(Block(text: "[Note: \(body)]", isCompactLine: true))
      case .failure(let text):
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { continue }
        blocks.append(Block(text: "[Error: \(body)]", isCompactLine: true))
      }
    }

    // Merge consecutive compact lines (tool calls, notes, errors) so runs of tool calls read as
    // a single bulleted block and count together when budgeting.
    var merged: [Block] = []
    for block in blocks {
      if block.isCompactLine, let last = merged.last, last.isCompactLine {
        merged[merged.count - 1].text += "\n" + block.text
      } else {
        merged.append(block)
      }
    }
    return merged
  }

  private static func formatTool(_ call: Transcript.ToolCall) -> String {
    let summary = call.kind.summary(input: call.input)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var line =
      summary.isEmpty
      ? "- [Tool] \(call.name)"
      : "- [Tool] \(call.name): \(truncate(summary, limit: 200))"

    let answers = call.earlierAnswers ?? call.result?.answers
    if let answers, !answers.isEmpty {
      let formatted = answers.keys.sorted().compactMap { key in
        answers[key].map { "\(key): \($0)" }
      }.joined(separator: "; ")
      line += " -> User answered: \(truncate(formatted, limit: 300))"
      return line
    }

    guard let result = call.result else {
      line += " -> (pending)"
      return line
    }
    let content = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.isError {
      line += content.isEmpty ? " -> Error" : " -> Error: \(truncate(content, limit: 300))"
    } else if content.isEmpty {
      line += " -> ok"
    } else if case .read = call.kind {
      line += " -> ok (\(content.count) chars)"
    } else {
      line += " -> \(truncate(content, limit: 350))"
    }
    return line
  }

  private static func fittedBody(_ blocks: [Block], maxCharacters: Int) -> String {
    let full = join(blocks)
    guard full.count > maxCharacters else { return full }

    // Preserve the opening prompt/entry when possible, plus as many trailing blocks as fit.
    let marker = { (omitted: Int) in "[… \(omitted) earlier entries omitted …]" }
    var tail: [Block] = []
    var tailLength = 0

    let first = blocks[0]
    let sampleMarker = marker(blocks.count)
    let firstReserve = first.text.count + sampleMarker.count + 4
    let includeFirst = blocks.count > 1 && firstReserve < maxCharacters / 2

    let availableForTail = includeFirst ? maxCharacters - firstReserve : maxCharacters
    let tailRange = includeFirst ? blocks.dropFirst() : blocks[...]

    for block in tailRange.reversed() {
      let separatorCost = tail.isEmpty ? 0 : 2
      if tailLength + separatorCost + block.text.count <= availableForTail {
        tail.insert(block, at: 0)
        tailLength += separatorCost + block.text.count
      } else {
        break
      }
    }

    if tail.isEmpty, let last = blocks.last {
      let suffix = String(last.text.suffix(max(100, maxCharacters - 24)))
      return "[… earlier text truncated …]\n" + suffix
    }

    if includeFirst {
      let omitted = (blocks.count - 1) - tail.count
      if omitted > 0 {
        return ([first.text, marker(omitted)] + tail.map(\.text)).joined(separator: "\n\n")
      }
      return ([first.text] + tail.map(\.text)).joined(separator: "\n\n")
    }

    let omitted = blocks.count - tail.count
    if omitted > 0 {
      return ([marker(omitted)] + tail.map(\.text)).joined(separator: "\n\n")
    }
    return join(tail)
  }

  private static func join(_ blocks: [Block]) -> String {
    blocks.map(\.text).joined(separator: "\n\n")
  }

  private static func truncate(_ text: String, limit: Int) -> String {
    let singleLine = text.replacingOccurrences(of: "\n", with: " ")
    guard singleLine.count > limit else { return singleLine }
    return String(singleLine.prefix(limit)) + "…"
  }
}
