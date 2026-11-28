import DrakarKit
import SwiftUI

/// The conversation, pinned to the bottom while it grows.
///
/// A `LazyVStack` of `Equatable` rows, so a delta re-renders the row it lands in and not
/// the history. Whether that stays smooth at a thousand turns is PLAN.md §3's open
/// measurement; the AppKit fallback replaces this view and nothing around it.
struct TranscriptView: View {
  let transcript: Transcript
  /// Which provider runs this session, for provider-specific chrome like the working indicator.
  var agent: AgentKind = .claude
  /// The entry at the top when this session was last shown; nil while following.
  @Binding var anchor: String?
  /// Takes back a prompt queued behind the turn; nil where the agent can't, so no Cancel.
  var cancelQueued: ((QueuedPrompt) -> Void)? = nil
  /// Stops the turn so that the queue goes now; nil where it can't, so no Send now.
  var sendQueuedNow: (() -> Void)? = nil
  /// What this session continues from other providers, oldest first, shown above it.
  var earlier: [EarlierPart] = []

  @State private var position = ScrollPosition(edge: .bottom)
  /// Whether new output scrolls into view. Scrolling up to read stops it; scrolling back
  /// to the bottom resumes it. Decided when a scroll the user made comes to rest, not on
  /// every geometry change, because growing content moves the bottom away before the
  /// follow has a chance to catch up, and would read as "the user left".
  @State private var isFollowing = true
  @State private var isAtBottom = true
  /// A scroll the user is making, finger down or coasting: the follow holds off until it rests,
  /// or each delta would pull the transcript back down under them and the scroll would end
  /// at the bottom it was leaving.
  @State private var isUserScrolling = false
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

  /// What the turn is held up by, said instead of a verb.
  private var workingStatus: String? {
    if let retry = transcript.retry {
      return switch (retry.attempt, retry.maxRetries) {
      case (let attempt?, let max?): String(localized: "Retrying (\(attempt)/\(max))")
      default: String(localized: "Retrying")
      }
    }
    return transcript.isCompacting ? String(localized: "Compacting") : nil
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(earlier.indices, id: \.self) { index in
          let next = index + 1 < earlier.count ? earlier[index + 1].agent : agent
          earlierRows(earlier[index], movedTo: next)
        }
        let groups = transcript.grouped()
        let asked = Set(transcript.pendingPermissions.compactMap(\.request.toolUseID))
        ForEach(groups.top) { entry in
          let children = groups.children[entry.id] ?? []
          EntryView(
            entry: entry, children: children, task: transcript.agentTasks[entry.id],
            childTasks: EntryView.tasks(of: children, in: transcript.agentTasks),
            isAsked: asked.contains(entry.id)
          )
          .equatable()
          // Inside the row, so a jump to the prompt stops short of its bubble.
          .padding(.top, entry.isPrompt ? 12 : 0)
        }
        // Not while a permission or a question waits on the user: nothing is being worked on
        // then.
        if transcript.isRunning && !transcript.isWaitingOnPerson {
          WorkingIndicator(agent: agent, status: workingStatus)
        }
        // Below the turn they wait behind, until the CLI takes each into the conversation.
        // Send now on the first only: the queue goes whole and in order, so one further down
        // would seem to jump ahead.
        let first = transcript.queuedPrompts.first?.id
        ForEach(transcript.queuedPrompts) { prompt in
          QueuedPromptView(
            prompt: prompt, cancel: cancelQueued.map { cancel in { cancel(prompt) } },
            sendNow: prompt.id == first ? sendQueuedNow : nil)
        }
      }
      .scrollTargetLayout()
      .environment(\.thinkingDisclosure, thinkingDisclosure)
      .environment(\.agentName, agent.shortName)
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
      isUserScrolling = new == .tracking || new == .interacting || new == .decelerating
      if new == .idle, old == .interacting || old == .decelerating {
        isFollowing = isAtBottom
        // Output that arrived during the scroll was held back.
        if isFollowing { position.scrollTo(edge: .bottom) }
      }
    }
    .onChange(of: transcript.revision) {
      if isFollowing && !isUserScrolling { position.scrollTo(edge: .bottom) }
    }
    .accessibilityIdentifier("transcript")
    // A card floating below the toolbar, not an inset: the scroll view's top inset is part
    // of the toolbar's glass band, which grew when the bar arrived after the history and
    // blinked at every switch. Always up, the transcript keeps room for it from the start, so
    // its first lines and a jump to the prompt stop short of it; up only while the prompt is
    // away, it covers what is under it, so coming and going does not shift the transcript.
    .contentMargins(.top, pinsLastPrompt ? LastPromptBar.room : 0, for: .scrollContent)
    // Visibility comes from scroll layout. Animate only the overlays so their changes
    // don't also animate the scroll view's layout and feed back into visibility.
    .overlay(alignment: .top) {
      let prompt = pinsLastPrompt ? transcript.lastPrompt : offScreenPrompt
      ZStack {
        if let prompt {
          bar(for: prompt).transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.15), value: prompt?.id)
    }
    .overlay(alignment: .bottomTrailing) {
      ZStack {
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
  }

  /// Another provider's conversation, as it stood when the session moved on: its rows without
  /// rewind, forks or task controls, which would act on this session, under ids of their own
  /// so that they never meet this session's.
  @ViewBuilder private func earlierRows(_ part: EarlierPart, movedTo next: AgentKind) -> some View {
    let key = "earlier:\(part.id)"
    Label {
      Text("With \(part.agent.name)")
    } icon: {
      AgentIcon(agent: part.agent)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .id("\(key):start")
    if let earlier = part.transcript {
      let groups = earlier.grouped()
      ForEach(groups.top.filter { $0.id != Transcript.coldCacheNoteID }) { entry in
        EntryView(entry: entry, children: groups.children[entry.id] ?? [])
          .equatable()
          .padding(.top, entry.isPrompt ? 12 : 0)
          .environment(\.rewindAction, nil)
          .environment(\.taskControls, nil)
          .environment(\.askedQuestion, nil)
          .id("\(key):\(entry.id)")
      }
    } else if part.isMissing {
      Label(
        "\(part.agent.name)'s history of this conversation could not be read.",
        systemImage: "exclamationmark.triangle"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .id("\(key):missing")
    } else {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .id("\(key):loading")
    }
    MovedDivider(from: part.agent, to: next)
      .id("\(key):moved")
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
  /// On a subagent's call, the entries it wrote, drawn inside its card.
  var children: [Transcript.Entry] = []
  /// On a call the CLI runs as a task (a subagent, a long Bash), what it reported of it.
  var task: AgentTask?
  /// On a subagent's call, the same for the calls it made, by call.
  var childTasks: [String: AgentTask] = [:]
  /// On a call, that a request about it waits on the person now.
  var isAsked = false

  /// The tasks `children`'s calls run as, out of a transcript's: only theirs, so a task
  /// elsewhere changing leaves the row as it is.
  static func tasks(of children: [Transcript.Entry], in tasks: [String: AgentTask])
    -> [String: AgentTask]
  {
    guard !tasks.isEmpty else { return [:] }
    var found: [String: AgentTask] = [:]
    for child in children { found[child.id] = tasks[child.id] }
    return found
  }

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
          if !entry.attachments.isEmpty { AttachmentRow(previews: entry.attachments) }
          if !text.isEmpty {
            Text(text)
              .textSelection(.enabled)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
          }
        }
        // Beside the bubble, not on it: a prompt is often one line, and a corner button
        // would cover it. The rewind arrow, when there is one, sits further along.
        .copyOnHover(CopyText.of(text), placement: .beside, identifier: "copy.prompt")
        // A subagent's prompt is not one of the session's own: nothing to fork or rewind to.
        .rewindMenu(
          entryID: entry.id, messageID: entry.parentToolUseID == nil ? entry.messageID : nil,
          text: text)
      case .text(let text):
        // Beside the reply, on hover. The extension calls this "Copy response" and keeps
        // the icon off the words: a corner button would cover a one-line reply.
        MarkdownView(text: text)
          .copyOnHover(
            CopyText.of(text), placement: .beside, label: "Copy response",
            identifier: "copy.response")
      case .thinking(let text):
        ThinkingView(
          text: text, isThinking: entry.thinkingSince != nil, duration: entry.thinkingDuration)
      case .tool(let call) where call.kind == .question:
        QuestionCallView(call: call)
      case .tool(let call) where call.kind == .planApproval:
        PlanCallView(call: call, isAsked: isAsked)
      case .tool(let call) where call.kind == .todos:
        TodoCallView(call: call)
      case .tool(let call) where call.kind.isSubagent:
        AgentCallView(call: call, task: task, children: children, childTasks: childTasks)
      case .tool(let call):
        if case .mcp = call.kind {
          MCPCallView(call: call)
        } else {
          ToolCallView(call: call, task: task)
        }
      case .notice(let text):
        // The CLI brackets its own notes ("[Request interrupted by user]").
        Label(
          text.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      case .failure(let text):
        Label(text, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .padding(.trailing, 30)
          .frame(maxWidth: .infinity, alignment: .leading)
          .copyOnHover(text)
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
  let isThinking: Bool
  /// Known only for thinking streamed live.
  let duration: TimeInterval?
  @Environment(\.thinkingDisclosure) private var disclosure

  /// As the extension words it.
  private var title: String {
    if isThinking { return "Thinking…" }
    if let duration { return "Thought for \(max(1, Int(duration.rounded())))s" }
    return text.isEmpty ? "Thought" : "Thinking"
  }

  var body: some View {
    @Bindable var disclosure = disclosure
    if text.isEmpty {
      Label(title, systemImage: "brain")
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
        Label(title, systemImage: "brain")
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

/// A tool call as a card: name and what it acts on, collapsed; input and result inside. One
/// the CLI runs as a task gets its controls, and reads as background while it runs there.
struct ToolCallView: View {
  let call: Transcript.ToolCall
  /// What the CLI reported of the task it runs the call as, if it made one.
  var task: AgentTask? = nil
  @State private var isExpanded = false
  @Environment(\.taskControls) private var controls

  private var state: TaskCardState {
    TaskCardState.of(result: call.result, task: task, isBackground: task?.isBackgrounded == true)
  }

  private var toolTitle: String {
    // Some Antigravity calls supply the operation only in their raw input.
    if call.name == "Tool", let variant = call.input["variant"]?.stringValue,
      !variant.isEmpty
    {
      return variant
    }
    return call.name
  }

  /// Under the header: what its task's state says that its result would not.
  private var detail: String? {
    switch state {
    case .stopped: String(localized: "Stopped")
    case .running where task?.isBackgrounded == true:
      String(localized: "Running in the background")
    default: nil
    }
  }

  private var fileChanges: [FileChange] {
    guard case .fileChange(_, let edits) = call.kind else { return [] }
    return FileChange.each(edits: edits)
  }

  var body: some View {
    let offer = TaskOffer.of(call: call, task: task, controls: controls)
    let changes = fileChanges
    let diffCounts = Self.diffCounts(for: changes)
    let readRange = Self.readRange(for: call)
    VStack(alignment: .leading, spacing: 6) {
      DisclosureGroup(isExpanded: $isExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          // After the fact a Write's previous content is gone, so it shows as all added.
          if !changes.isEmpty {
            ForEach(changes, id: \.path) { change in
              FileChangeView(change: change)
            }
          } else if case .shell = call.kind, !call.summary.isEmpty {
            // The whole command, which the summary line may cut short.
            CodeBlock(text: call.summary)
          } else {
            CodeBlock(text: call.input.prettyPrinted)
          }
          if let result = call.result {
            // Without the colour escapes a terminal would have read.
            let content = ToolOutput.cleaned(result.content)
            CodeBlock(
              text: content.isEmpty ? "(no output)" : content,
              isCopyable: !content.isEmpty
            )
            .foregroundStyle(result.isError ? .red : .primary)
          }
        }
        .padding(.top, 6)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            TaskStatusIcon(state: state)
            VStack(alignment: .leading, spacing: 2) {
              Text(toolTitle)
                .fontWeight(.semibold)
                .lineLimit(1)
              let summary = displayedSummary
              if !summary.isEmpty, summary != toolTitle {
                Text(summary)
                  .font(.callout.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .help(summary)
              }
            }
            let showDiffCounts = !isExpanded && diffCounts != nil
            let showReadRange = readRange != nil
            let showStop = offer.stop && task?.taskID != nil
            if showDiffCounts || showReadRange || showStop {
              Spacer(minLength: 8)
            }
            if !isExpanded, let diffCounts {
              DiffCountsView(added: diffCounts.added, removed: diffCounts.removed)
                .accessibilityIdentifier("tool.\(call.id).diffCounts")
            }
            if let readRange {
              Text(verbatim: readRange)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityIdentifier("tool.\(call.id).readRange")
            }
            if offer.stop, let taskID = task?.taskID {
              StopTaskButton(taskID: taskID)
            }
          }
          // The whole row toggles, not only the chevron.
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
          if let detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if offer.runInBackground { RunInBackgroundLine(toolUseID: call.id) }
          if let taskID = task?.taskID { StopFailureNote(taskID: taskID) }
        }
      }
      // Opened, the card shows the whole result instead.
      if !isExpanded, let preview = ToolResultPreview.of(call, task: task) {
        ToolResultPreviewView(preview: preview, callID: call.id) {
          withAnimation(.snappy) { isExpanded = true }
        }
      }
      if offer.output, let task, let taskID = task.taskID {
        TaskOutputSection(
          taskID: taskID, isRunning: task.status == .running,
          outputFile: task.outputFile ?? TaskOutput.outputFile(inResult: call.result?.content))
      }
    }
    .padding(10)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .contextMenu {
      if let path = filePath, let openInEditor {
        Button("Open in Editor") { openInEditor(URL(filePath: path)) }
      }
    }
    // A container, so the controls inside keep their own identifiers.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tool.\(call.id)")
  }

  @Environment(\.openInEditor) private var openInEditor

  @Environment(\.sessionFolder) private var sessionFolder

  private var filePath: String? { Self.filePath(for: call) }

  /// The file or folder path this call acts on, across Claude, Codex, and Antigravity shapes.
  static func filePath(for call: Transcript.ToolCall) -> String? {
    switch call.kind {
    case .read(let path), .fileChange(let path, _):
      return path.isEmpty ? nil : path
    default:
      for key in [
        "file_path", "Path", "AbsolutePath", "DirectoryPath", "File", "TargetFile",
        "notebook_path", "path",
      ] {
        if let value = call.input[key]?.stringValue, !value.isEmpty {
          return value
        }
      }
      if case .other = call.kind, call.summary.hasPrefix("/") {
        return call.summary
      }
      return nil
    }
  }

  /// A file inside the session's folder by its path from there, as the extension shows it.
  static func displayedSummary(for call: Transcript.ToolCall, in folder: URL?) -> String {
    if let path = filePath(for: call), path == call.summary {
      return ContentView.abbreviated(path, relativeTo: folder)
    }
    if case .web = call.kind {
      return call.summary
    }
    return ContentView.abbreviatingPaths(in: call.summary, relativeTo: folder)
  }

  private var displayedSummary: String {
    Self.displayedSummary(for: call, in: sessionFolder)
  }

  static func diffCounts(for changes: [FileChange]) -> (added: Int, removed: Int)? {
    guard !changes.isEmpty else { return nil }
    return (
      changes.reduce(0) { $0 + $1.addedCount },
      changes.reduce(0) { $0 + $1.removedCount }
    )
  }

  /// Line range for a `Read` call (`L1–150`, `L45–`, `L10`), across Antigravity and Claude keys.
  static func readRange(for call: Transcript.ToolCall) -> String? {
    let isRead = if case .read = call.kind { true } else { call.name == "Read" }
    guard isRead else { return nil }
    func positiveInt(_ keys: String...) -> Int? {
      for key in keys {
        if let value = call.input[key]?.intValue, value > 0 { return value }
      }
      return nil
    }
    if let start = positiveInt("StartLine", "start_line", "startLine") {
      if let end = positiveInt("EndLine", "end_line", "endLine"), end >= start {
        return start == end ? "L\(start)" : "L\(start)\u{2013}\(end)"
      }
      return "L\(start)\u{2013}"
    }
    if let end = positiveInt("EndLine", "end_line", "endLine") {
      return end == 1 ? "L1" : "L1\u{2013}\(end)"
    }
    if let offset = call.input["offset"]?.intValue {
      let start = max(1, offset)
      if let limit = positiveInt("limit") {
        let end = start + limit - 1
        return start == end ? "L\(start)" : "L\(start)\u{2013}\(end)"
      }
      return "L\(start)\u{2013}"
    }
    if let limit = positiveInt("limit") {
      return limit == 1 ? "L1" : "L1\u{2013}\(limit)"
    }
    return nil
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

/// Where a hover copy button sits. The extension hides every one of these until the pointer
/// is over the thing it copies.
enum CopyPlacement {
  /// The top-trailing corner of a block, over a chip so it stays readable on the text.
  case corner
  /// The bottom edge, beside the text. A corner would cover a one-line turn.
  case beside
}

/// Blank text is not worth a button. The words copied are the original, not the trimmed ones.
enum CopyText {
  static func of(_ text: String) -> String? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }
}

extension View {
  /// A copy button out of sight until the pointer is over the view, as in the extension.
  /// Nil text leaves the view as it is.
  func copyOnHover(
    _ text: String?, placement: CopyPlacement = .corner, label: String = "Copy",
    identifier: String = "copy"
  ) -> some View {
    modifier(CopyOnHover(text: text, placement: placement, label: label, identifier: identifier))
  }
}

private struct CopyOnHover: ViewModifier {
  let text: String?
  var placement: CopyPlacement = .corner
  var label = "Copy"
  var identifier = "copy"

  @State private var isHovering = false

  @ViewBuilder func body(content: Content) -> some View {
    switch placement {
    case .corner:
      content
        .overlay(alignment: .topTrailing) {
          if let text { CopyIconButton(text: text, label: label, isHovering: isHovering) }
        }
        .onHover { isHovering = $0 }
    case .beside:
      if let text {
        HStack(alignment: .bottom, spacing: 6) {
          content
          CopyIconButton(
            text: text, label: label, isHovering: isHovering, showsChrome: false,
            identifier: identifier
          )
          .padding(.bottom, 4)
        }
        .onHover { isHovering = $0 }
      } else {
        content
      }
    }
  }
}

/// The extension's copy icon: `doc.on.doc` until it lands, then a check for a moment.
/// In the accessibility tree all along, as the rewind arrow is, whether or not it is on screen.
private struct CopyIconButton: View {
  let text: String
  var label: String
  var isHovering: Bool
  /// A filled chip. Corner buttons sit on the text they copy; a bare icon would get lost in it.
  var showsChrome = true
  var identifier = "copy"

  @State private var didCopy = false
  @FocusState private var isFocused: Bool

  private var isShown: Bool { isHovering || didCopy || isFocused }

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      didCopy = true
    } label: {
      Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        .font(showsChrome ? .caption : .callout)
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .background {
          if showsChrome {
            RoundedRectangle(cornerRadius: 4).fill(.background.secondary)
          }
        }
        .overlay {
          if showsChrome {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.separator)
          }
        }
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
    .padding(showsChrome ? 4 : 0)
    .opacity(isShown ? 1 : 0)
    // Opacity would otherwise drop it from the tree. It has to stay findable before the
    // pointer is over it, as the rewind arrow is.
    .accessibilityHidden(false)
    .animation(.easeOut(duration: 0.15), value: isShown)
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
  /// The runner the session's files are on, by name; nil for this Mac's. Its paths show as
  /// text, not links: none of them is a file here (remote sessions spec §4).
  @Entry var runnerName: String?
  /// Set by the transcript; one made here would be a new instance on every read.
  @Entry var thinkingDisclosure = ThinkingDisclosure()
  /// The short name of the agent running this session, for question cards.
  @Entry var agentName = "Claude"
}

/// Equal per workspace rather than a bare closure, which SwiftUI cannot compare: every
/// tool card reads it, and a new closure on each update would redraw them all.
struct OpenInEditorAction: Equatable {
  let workspace: Workspace

  func callAsFunction(_ url: URL) { workspace.open(url) }

  /// The file, with the caret on the link's line if it names one.
  func callAsFunction(_ link: FileLink) {
    guard let document = workspace.open(URL(filePath: link.path)),
      let offset = link.offset(in: document.storage.string)
    else { return }
    document.select(NSRange(location: offset, length: 0))
  }

  static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }
}

/// A prompt sent while a turn ran, waiting for the CLI to take it: dimmed, labelled, and
/// taken back with ×, or sent at once with ↑, which stops the turn.
private struct QueuedPromptView: View {
  let prompt: QueuedPrompt
  let cancel: (() -> Void)?
  let sendNow: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Label("Queued", systemImage: "clock")
        if let context = prompt.context {
          Label(context, systemImage: "doc.text")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if !prompt.attachments.isEmpty { AttachmentRow(previews: prompt.attachments, size: 40) }
      HStack(alignment: .top, spacing: 8) {
        Text(prompt.text)
          .textSelection(.enabled)
          .foregroundStyle(.secondary)
        if let sendNow {
          Button("Send Now", systemImage: "arrow.up.circle.fill", action: sendNow)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Stop the turn and send this now (Esc)")
            .accessibilityIdentifier("queued.sendNow")
        }
        if let cancel {
          Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Don't send this message")
            .accessibilityIdentifier("queued.cancel")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
          .foregroundStyle(.separator))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("queued.\(prompt.uuid)")
  }
}

/// Where a moved session's earlier conversation ends and the next provider's begins.
private struct MovedDivider: View {
  let from: AgentKind
  let to: AgentKind

  var body: some View {
    HStack(spacing: 8) {
      line
      Label {
        Text("Moved to \(to.name)")
      } icon: {
        AgentIcon(agent: to)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize()
      line
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("Moved from \(from.name) to \(to.name)"))
  }

  private var line: some View {
    Rectangle().fill(.separator).frame(height: 1)
  }
}
