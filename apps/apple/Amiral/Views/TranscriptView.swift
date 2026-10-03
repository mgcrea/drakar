import AmiralKit
import SwiftUI

/// The conversation, pinned to the bottom while it grows.
///
/// A `LazyVStack` of `Equatable` rows, so a delta re-renders the row it lands in and not
/// the history. Whether that stays smooth at a thousand turns is PLAN.md §3's open
/// measurement; the AppKit fallback replaces this view and nothing around it.
struct TranscriptView: View {
  let transcript: Transcript

  @State private var position = ScrollPosition(edge: .bottom)
  /// Whether new output scrolls into view. Scrolling up to read stops it; scrolling back
  /// to the bottom resumes it. Decided when a scroll the user made comes to rest, not on
  /// every geometry change, because growing content moves the bottom away before the
  /// follow has a chance to catch up, and would read as "the user left".
  @State private var isFollowing = true
  @State private var isAtBottom = true

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(transcript.entries) { entry in
          EntryView(entry: entry).equatable()
        }
        if transcript.isRunning {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Working")
        }
      }
      .padding(16)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollPosition($position)
    .onScrollGeometryChange(for: Bool.self) { geometry in
      geometry.visibleRect.maxY >= geometry.contentSize.height - 40
    } action: { _, atBottom in
      isAtBottom = atBottom
    }
    .onScrollPhaseChange { old, new in
      if new == .idle, old == .interacting || old == .decelerating { isFollowing = isAtBottom }
    }
    .onChange(of: transcript.revision) {
      if isFollowing { position.scrollTo(edge: .bottom) }
    }
    .accessibilityIdentifier("transcript")
  }
}

struct EntryView: View, Equatable {
  let entry: Transcript.Entry

  var body: some View {
    Group {
      switch entry.kind {
      case .prompt(let text):
        Text(text)
          .textSelection(.enabled)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
      case .text(let text):
        Text(Self.markdown(text))
          .textSelection(.enabled)
      case .thinking(let text):
        ThinkingView(text: text)
      case .tool(let call):
        ToolCallView(call: call)
      case .notice(let text):
        // The CLI brackets its own notes ("[Request interrupted by user]").
        Label(
          text.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, entry.parentToolUseID == nil ? 0 : 20)
  }

  /// Inline Markdown with line breaks kept. Block syntax (headings, lists, code fences)
  /// shows as written until the transcript gets a real Markdown renderer.
  private static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

private struct ThinkingView: View {
  let text: String

  var body: some View {
    if text.isEmpty {
      Label("Thought", systemImage: "brain")
        .font(.callout)
        .foregroundStyle(.tertiary)
    } else {
      DisclosureGroup {
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } label: {
        Label("Thinking", systemImage: "brain")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// A tool call as a card: name and what it acts on, collapsed; input and result inside.
struct ToolCallView: View {
  let call: Transcript.ToolCall
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        if call.name != "Bash" || call.summary.isEmpty {
          CodeBlock(text: call.input.prettyPrinted)
        }
        if let result = call.result {
          CodeBlock(text: result.content.isEmpty ? "(no output)" : result.content)
            .foregroundStyle(result.isError ? .red : .primary)
        }
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        statusIcon
        Text(call.name).fontWeight(.semibold)
        Text(call.summary)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(10)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .accessibilityIdentifier("tool.\(call.id)")
  }

  @ViewBuilder private var statusIcon: some View {
    switch call.result {
    case nil: ProgressView().controlSize(.mini)
    case let result? where result.isError:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case _?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    }
  }
}

struct CodeBlock: View {
  let text: String

  var body: some View {
    ScrollView([.vertical, .horizontal]) {
      Text(text)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
    .frame(maxHeight: 240)
    .fixedSize(horizontal: false, vertical: true)
    .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
  }
}
