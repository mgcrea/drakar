import Foundation

/// The block structure of a Markdown message, which SwiftUI's `Text` does not draw: it
/// renders inline syntax (emphasis, code spans, links) and ignores the rest. Each block's
/// text is still inline Markdown, for `AttributedString(markdown:)` to style.
///
/// Deliberately small and line-based rather than CommonMark: it has to be cheap enough to
/// re-run on every streamed delta, and tolerate a message cut off anywhere, an unclosed
/// code fence above all. What it does not know stays a paragraph, shown as written.
public enum MarkdownBlock: Sendable, Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  /// Fenced code. `language` is the fence's info string, if any.
  case code(language: String?, text: String)
  /// One list item; consecutive items are consecutive blocks. `indent` counts nesting
  /// levels of two spaces, `marker` is `1.` for an ordered item and nil for a bullet.
  case listItem(marker: String?, indent: Int, text: String)
  case quote(String)
  /// Table rows as written, drawn monospaced so the columns line up.
  case table([String])
  case rule

  public static func parse(_ markdown: String) -> [MarkdownBlock] {
    var parser = Parser()
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      parser.consume(String(line))
    }
    return parser.finish()
  }
}

private struct Parser {
  var blocks: [MarkdownBlock] = []
  var paragraph: [String] = []
  var quote: [String] = []
  var table: [String] = []
  var fence: (language: String?, lines: [String])?

  mutating func consume(_ line: String) {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }

    if var open = fence {
      if trimmed.hasPrefix("```") {
        blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        fence = nil
      } else {
        open.lines.append(line)
        fence = open
      }
      return
    }

    if trimmed.hasPrefix("```") {
      flush()
      let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
      fence = (info.isEmpty ? nil : info, [])
    } else if trimmed.isEmpty {
      flush()
    } else if let heading = Self.heading(trimmed) {
      flush()
      blocks.append(heading)
    } else if Self.isRule(trimmed) {
      flush()
      blocks.append(.rule)
    } else if let item = Self.listItem(line) {
      flush()
      blocks.append(item)
    } else if trimmed.hasPrefix(">") {
      flushParagraph()
      flushTable()
      quote.append(String(trimmed.dropFirst().drop { $0 == " " }))
    } else if trimmed.hasPrefix("|") {
      flushParagraph()
      flushQuote()
      table.append(String(trimmed))
    } else {
      flushQuote()
      flushTable()
      paragraph.append(line)
    }
  }

  /// A fence still open when the text ends is a message still being written: show what
  /// there is as code rather than as stray backticks.
  mutating func finish() -> [MarkdownBlock] {
    if let open = fence {
      blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
      fence = nil
    }
    flush()
    return blocks
  }

  mutating func flush() {
    flushParagraph()
    flushQuote()
    flushTable()
  }

  mutating func flushParagraph() {
    guard !paragraph.isEmpty else { return }
    blocks.append(.paragraph(paragraph.joined(separator: "\n")))
    paragraph = []
  }

  mutating func flushQuote() {
    guard !quote.isEmpty else { return }
    blocks.append(.quote(quote.joined(separator: "\n")))
    quote = []
  }

  mutating func flushTable() {
    guard !table.isEmpty else { return }
    blocks.append(.table(table))
    table = []
  }

  static func heading(_ line: Substring) -> MarkdownBlock? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
  }

  static func isRule(_ line: Substring) -> Bool {
    let compact = line.filter { $0 != " " }
    guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else {
      return false
    }
    return compact.allSatisfy { $0 == first }
  }

  static func listItem(_ line: String) -> MarkdownBlock? {
    let spaces = line.prefix { $0 == " " }.count
    let rest = line.dropFirst(spaces)
    if let bullet = rest.first, "-*+".contains(bullet), rest.dropFirst().first == " " {
      return .listItem(marker: nil, indent: spaces / 2, text: String(rest.dropFirst(2)))
    }
    let digits = rest.prefix(while: \.isNumber)
    guard !digits.isEmpty, digits.count <= 9 else { return nil }
    let after = rest.dropFirst(digits.count)
    guard let punctuation = after.first, punctuation == "." || punctuation == ")",
      after.dropFirst().first == " "
    else { return nil }
    return .listItem(
      marker: "\(digits).", indent: spaces / 2, text: String(after.dropFirst(2)))
  }
}
