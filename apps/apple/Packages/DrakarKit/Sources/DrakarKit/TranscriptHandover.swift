import Foundation

/// Serializes a session's `Transcript` into a structured handoff prompt so another provider
/// can continue the conversation with context.
public enum TranscriptHandover {
  /// Default character cap for the serialized transcript body so long sessions fit safely
  /// within any provider's context window.
  public static let defaultMaxCharacters = 40_000

  /// Formats `transcript` into a handoff prompt from `sourceProvider` to `targetProvider`.
  /// Returns `nil` when `transcript` has no conversational entries (no prompt, text, or tool
  /// call on the main thread).
  public static func prompt(
    from transcript: Transcript,
    title: String? = nil,
    from sourceProvider: String,
    to targetProvider: String,
    maxCharacters: Int = defaultMaxCharacters
  ) -> String? {
    let blocks = formattedBlocks(from: transcript)
    guard !blocks.isEmpty else { return nil }

    let body = fittedBody(blocks, maxCharacters: max(maxCharacters, 200))
    var header = ["This conversation is moving from \(sourceProvider) to \(targetProvider)."]
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      header.append("Title: \(title)")
    }
    header.append(
      "Continue from the transcript below. Reply briefly confirming you have the context and are ready to proceed (or answer any unanswered question at the end)."
    )

    return """
      \(header.joined(separator: "\n"))

      ---
      \(body)
      ---
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
      case .prompt(let text):
        var lines = ["### User"]
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
        blocks.append(Block(text: "### Assistant\n\(body)", isCompactLine: false))
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
