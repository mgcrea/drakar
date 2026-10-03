import AmiralKit
import SwiftUI

/// A message's Markdown: AmiralKit splits the blocks, `AttributedString` styles what is
/// inline in each (emphasis, code spans, links).
struct MarkdownView: View {
  let text: String

  var body: some View {
    let blocks = MarkdownBlock.parse(text)
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        BlockView(block: block)
      }
    }
    .textSelection(.enabled)
  }
}

private struct BlockView: View {
  let block: MarkdownBlock

  var body: some View {
    switch block {
    case .heading(let level, let text):
      Text(inline(text))
        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        .padding(.top, 4)
    case .paragraph(let text):
      Text(inline(text))
    case .code(_, let text):
      CodeBlock(text: text)
    case .listItem(let marker, let indent, let text):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(marker ?? "•")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Text(inline(text))
      }
      .padding(.leading, CGFloat(indent) * 18)
    case .quote(let text):
      Text(inline(text))
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Rectangle().fill(.tertiary).frame(width: 3)
        }
    case .table(let rows):
      Text(rows.joined(separator: "\n"))
        .font(.callout.monospaced())
    case .rule:
      Divider()
    }
  }

  /// Line breaks kept, as the model wrote them.
  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
