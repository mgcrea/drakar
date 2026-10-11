import DrakarKit
import SwiftUI

/// A message's Markdown: DrakarKit splits the blocks, `AttributedString` styles what is
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
      InlineText(text: inline(text))
    case .code(_, let text):
      CodeBlock(text: text)
    case .listItem(let marker, let indent, let text):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(marker ?? "•")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        InlineText(text: inline(text))
      }
      .padding(.leading, CGFloat(indent) * 18)
    case .quote(let text):
      InlineText(text: inline(text), isSecondary: true)
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

/// A `Text`, or a `LinkText` when it holds a link, for the pointing hand over it.
private struct InlineText: View {
  let text: AttributedString
  var isSecondary = false

  var body: some View {
    if LinkText.holdsLink(text) {
      LinkText(text: text, isSecondary: isSecondary)
        .alignmentGuide(.firstTextBaseline) { _ in LinkText.firstBaseline }
    } else {
      Text(text).foregroundStyle(isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.foreground))
    }
  }
}
