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
    case .table(let header, let alignments, let rows):
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
        tableRow(header, alignments: alignments, isHeader: true)
        Divider().gridCellUnsizedAxes(.horizontal)
        ForEach(rows.indices, id: \.self) { index in
          tableRow(rows[index], alignments: alignments)
        }
      }
    case .rule:
      Divider()
    }
  }

  private func tableRow(
    _ cells: [String], alignments: [MarkdownBlock.TableAlignment], isHeader: Bool = false
  ) -> some View {
    GridRow(alignment: .top) {
      ForEach(cells.indices, id: \.self) { index in
        let alignment = alignments[index]
        InlineText(
          text: inline(cells[index], isBold: isHeader), textAlignment: alignment
        )
        .gridColumnAlignment(
          alignment == .center ? .center : alignment == .trailing ? .trailing : .leading
        )
        .accessibilityAddTraits(isHeader ? .isHeader : [])
      }
    }
  }

  /// Line breaks kept, as the model wrote them.
  private func inline(_ text: String, isBold: Bool = false) -> AttributedString {
    var attributed =
      (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    if isBold {
      for run in attributed.runs {
        attributed[run.range].inlinePresentationIntent =
          (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
      }
    }
    return attributed
  }
}

/// A `Text`, or a `LinkText` when it holds a link, for the pointing hand over it.
private struct InlineText: View {
  let text: AttributedString
  var isSecondary = false
  var textAlignment: MarkdownBlock.TableAlignment = .leading
  @Environment(\.runnerName) private var runner
  @Environment(\.sessionFolder) private var folder

  var body: some View {
    let text = runner == nil ? text : LinkText.withoutFileLinks(text, relativeTo: folder)
    if LinkText.holdsLink(text) {
      LinkText(text: text, isSecondary: isSecondary, textAlignment: textAlignment)
        .alignmentGuide(.firstTextBaseline) { _ in LinkText.firstBaseline }
    } else {
      Text(text).foregroundStyle(
        isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.foreground)
      )
      .multilineTextAlignment(
        textAlignment == .center ? .center : textAlignment == .trailing ? .trailing : .leading)
    }
  }
}
