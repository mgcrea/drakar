import DrakarKit
import SwiftUI

/// The conversation, pinned to the bottom while it grows.
///
/// A `LazyVStack` of `Equatable` rows, so a delta re-renders the row it lands in and not
/// the history. Whether that stays smooth at a thousand turns is PLAN.md §3's open
/// measurement; the AppKit fallback replaces this view and nothing around it.
struct TranscriptView: View {
  let transcript: Transcript
  /// The entry at the top when this session was last shown; nil while following.
  @Binding var anchor: String?

  @State private var position = ScrollPosition(edge: .bottom)
  /// Whether new output scrolls into view. Scrolling up to read stops it; scrolling back
  /// to the bottom resumes it. Decided when a scroll the user made comes to rest, not on
  /// every geometry change, because growing content moves the bottom away before the
  /// follow has a chance to catch up, and would read as "the user left".
  @State private var isFollowing = true
  @State private var isAtBottom = true
  /// The entries in view, as of the last change: the scroll is judged at rest only after
  /// they stopped changing, so the anchor is taken from here and not from the next change.
  @State private var visibleIDs: [String] = []
  /// The entries with any part on screen, for the bar: a prompt taller than the view is never
  /// 60% visible, yet it is in sight.
  @State private var onScreenIDs: Set<String> = []
  /// The bar stays up even while the prompt is in view, instead of only once it scrolled away.
  @AppStorage(PreferenceKey.pinsLastPrompt) private var pinsLastPrompt = false
  /// `revision` when following stopped, so the follow button can tell output that arrived
  /// since from a transcript that is merely scrolled up.
  @State private var revisionWhenLeft: Int?
  @State private var thinkingDisclosure = ThinkingDisclosure()

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(transcript.entries) { entry in
          EntryView(entry: entry).equatable()
            // Inside the row, so a jump to the prompt stops short of its bubble.
            .padding(.top, entry.isPrompt ? 12 : 0)
        }
        // Not while a permission waits on the user: nothing is being worked on then.
        if transcript.isRunning && transcript.pendingPermissions.isEmpty {
          WorkingIndicator()
        }
      }
      .scrollTargetLayout()
      .environment(\.thinkingDisclosure, thinkingDisclosure)
      .padding(16)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollPosition($position)
    // A transcript shown again opens at its end rather than its top, which would blink the
    // toolbar's scroll-edge blur off and on as it jumped down.
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { visible in
      onScreenIDs = Set(visible)
    }
    .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.6) { visible in
      visibleIDs = visible
      if !isFollowing { anchor = visible.first }
    }
    .onChange(of: isFollowing) { _, following in
      anchor = following ? nil : visibleIDs.first
      revisionWhenLeft = following ? nil : transcript.revision
    }
    .onAppear {
      guard let anchor else { return }
      isFollowing = false
      position.scrollTo(id: anchor, anchor: .top)
    }
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
    // A card floating below the toolbar, not an inset: the scroll view's top inset is part
    // of the toolbar's glass band, which grew when the bar arrived after the history and
    // blinked at every switch. Always up, the transcript keeps room for it from the start, so
    // its first lines and a jump to the prompt stop short of it; up only while the prompt is
    // away, it covers what is under it, so coming and going does not shift the transcript.
    .contentMargins(.top, pinsLastPrompt ? LastPromptBar.room : 0, for: .scrollContent)
    .overlay(alignment: .top) {
      if let prompt = pinsLastPrompt ? transcript.lastPrompt : offScreenPrompt {
        bar(for: prompt).transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.15), value: offScreenPrompt?.id)
    .overlay(alignment: .bottomTrailing) {
      if showsFollowButton {
        FollowButton(isRunning: transcript.isRunning, hasUnseenOutput: hasUnseenOutput) {
          isFollowing = true
          position.scrollTo(edge: .bottom)
        }
        .padding(12)
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.15), value: showsFollowButton)
  }

  /// Not following and not at the bottom either: paused at the bottom, there is nothing to
  /// go back to until the next output pushes it away.
  private var showsFollowButton: Bool { !isFollowing && !isAtBottom }

  private var hasUnseenOutput: Bool {
    revisionWhenLeft.map { transcript.revision > $0 } ?? false
  }

  @ViewBuilder private func bar(for prompt: Transcript.Entry) -> some View {
    if let headline = prompt.headline {
      LastPromptBar(prompt: prompt, headline: headline) {
        isFollowing = false
        position.scrollTo(id: prompt.id, anchor: .top)
      }
    }
  }

  /// The newest prompt while none of it is on screen. Nothing on screen is the view before it
  /// first measured, not a prompt scrolled away.
  private var offScreenPrompt: Transcript.Entry? {
    guard let prompt = transcript.lastPrompt, !onScreenIDs.isEmpty, !onScreenIDs.contains(prompt.id)
    else { return nil }
    return prompt
  }
}

/// The newest prompt, pinned over the transcript: a long turn pushes what was asked far above
/// what is being done about it. Clicking scrolls back to it.
private struct LastPromptBar: View {
  /// What the card takes at the top of the transcript, its margin included.
  static let room: CGFloat = 46

  let prompt: Transcript.Entry
  let headline: String
  let reveal: () -> Void

  var body: some View {
    Button(action: reveal) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.turn.down.right")
        // Its own size: the headline goes first, and squeezed, "You" wrapped a letter a line.
        Text("You").fontWeight(.semibold).fixedSize()
        if let context = prompt.context {
          Label(context, systemImage: "doc.text")
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        Text(headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.to.line")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      // As the Latest button floats: a material card over the transcript.
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
      .contentShape(RoundedRectangle(cornerRadius: 10))
      .frame(maxWidth: 820 - 32)
      .padding(.horizontal, 16)
      .padding(.top, 8)
    }
    .buttonStyle(.plain)
    .help(promptText)
    .accessibilityLabel("Your last message: \(headline)")
    .accessibilityHint("Scrolls back to it")
    .accessibilityIdentifier("transcript.lastPrompt")
  }

  private var promptText: String {
    guard case .prompt(let text) = prompt.kind else { return headline }
    return String(text.prefix(1000))
  }
}

/// Back to the newest output and following it, while the transcript is scrolled away. A
/// spinner while the turn still runs; a dot when output arrived since scrolling away.
private struct FollowButton: View {
  let isRunning: Bool
  let hasUnseenOutput: Bool
  let follow: () -> Void

  var body: some View {
    Button(action: follow) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.down")
        Text("Latest")
        if isRunning {
          ProgressView().controlSize(.mini)
        } else if hasUnseenOutput {
          Circle().fill(.tint).frame(width: 6, height: 6)
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(.separator))
      .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Scroll to the newest output and keep following it")
    .accessibilityLabel(hasUnseenOutput ? "Jump to latest, new output below" : "Jump to latest")
    .accessibilityIdentifier("transcript.follow")
  }
}

extension Transcript.Entry {
  fileprivate var isPrompt: Bool {
    if case .prompt = kind { return true }
    return false
  }
}

struct EntryView: View, Equatable {
  let entry: Transcript.Entry

  var body: some View {
    Group {
      switch entry.kind {
      case .prompt(let text):
        VStack(alignment: .leading, spacing: 4) {
          if let context = entry.context {
            Label(context, systemImage: "doc.text")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
      case .text(let text):
        MarkdownView(text: text)
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
}

/// Whether the transcript's thinking is shown: opening or closing one block does it to all of
/// them, as in the extension. A class, so the rows that never think don't redraw on a toggle.
@Observable final class ThinkingDisclosure {
  var isExpanded = false
}

private struct ThinkingView: View {
  let text: String
  @Environment(\.thinkingDisclosure) private var disclosure

  var body: some View {
    @Bindable var disclosure = disclosure
    if text.isEmpty {
      Label("Thought", systemImage: "brain")
        .font(.callout)
        .foregroundStyle(.tertiary)
    } else {
      DisclosureGroup(isExpanded: $disclosure.isExpanded) {
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          // Clear of the copy button, which would otherwise sit on the first line.
          .padding(.trailing, 30)
          .frame(maxWidth: .infinity, alignment: .leading)
          .copyOnHover(text)
      } label: {
        Label("Thinking", systemImage: "brain")
          .font(.callout)
          .foregroundStyle(.secondary)
          // The whole row toggles, not only the chevron.
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { withAnimation(.snappy) { disclosure.isExpanded.toggle() } }
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
        // After the fact a Write's previous content is gone, so it shows as all added.
        if let change = FileChange(toolName: call.name, input: call.input) {
          FileChangeView(change: change)
        } else if call.name == "Bash" && !call.summary.isEmpty {
          // The whole command, which the one-line header cuts short.
          CodeBlock(text: call.summary)
        } else {
          CodeBlock(text: call.input.prettyPrinted)
        }
        if let result = call.result {
          CodeBlock(
            text: result.content.isEmpty ? "(no output)" : result.content,
            isCopyable: !result.content.isEmpty
          )
          .foregroundStyle(result.isError ? .red : .primary)
        }
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        statusIcon
        Text(call.name).fontWeight(.semibold)
        Text(displayedSummary)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      // The whole row toggles, not only the chevron.
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
    }
    .padding(10)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .contextMenu {
      if let path = call.input["file_path"]?.stringValue, let openInEditor {
        Button("Open in Editor") { openInEditor(URL(filePath: path)) }
      }
    }
    .accessibilityIdentifier("tool.\(call.id)")
  }

  @Environment(\.openInEditor) private var openInEditor

  @Environment(\.sessionFolder) private var sessionFolder

  /// A file inside the session's folder by its path from there, as the extension shows it.
  private var displayedSummary: String {
    guard call.input["file_path"]?.stringValue == call.summary, let folder = sessionFolder
    else { return call.summary }
    let base = folder.path(percentEncoded: false)
    let prefix = base.hasSuffix("/") ? base : base + "/"
    return call.summary.hasPrefix(prefix)
      ? String(call.summary.dropFirst(prefix.count)) : call.summary
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
  /// False for a placeholder such as "(no output)", which is not worth a copy button.
  var isCopyable = true

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
    .copyOnHover(isCopyable ? text : nil)
  }
}

extension View {
  /// A copy button in the top-trailing corner, out of sight until the pointer is over the
  /// view, as in the extension. Nil text leaves the view as it is.
  func copyOnHover(_ text: String?) -> some View {
    modifier(CopyOnHover(text: text))
  }
}

private struct CopyOnHover: ViewModifier {
  let text: String?

  @State private var isHovering = false
  @State private var didCopy = false

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topTrailing) {
        if let text { button(copying: text) }
      }
      .onHover { isHovering = $0 }
  }

  private func button(copying text: String) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      didCopy = true
    } label: {
      Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
    .help("Copy")
    .accessibilityLabel("Copy")
    .padding(4)
    .opacity(isHovering || didCopy ? 1 : 0)
    .animation(.easeOut(duration: 0.15), value: isHovering)
    .task(id: didCopy) {
      guard didCopy else { return }
      try? await Task.sleep(for: .seconds(1.5))
      didCopy = false
    }
  }
}

extension EnvironmentValues {
  /// The folder the session in this window works in, for showing paths relative to it.
  @Entry var sessionFolder: URL?
  /// Opens a file in this window's editor; nil where there is none (the review window).
  @Entry var openInEditor: OpenInEditorAction?
  /// Set by the transcript; one made here would be a new instance on every read.
  @Entry var thinkingDisclosure = ThinkingDisclosure()
}

/// Equal per workspace rather than a bare closure, which SwiftUI cannot compare: every
/// tool card reads it, and a new closure on each update would redraw them all.
struct OpenInEditorAction: Equatable {
  let workspace: Workspace

  func callAsFunction(_ url: URL) { workspace.open(url) }

  static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }
}
