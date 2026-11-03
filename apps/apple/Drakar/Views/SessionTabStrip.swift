import AppKit
import DrakarKit
import SwiftUI

/// What a tab's mark says, one thing at a time, the most pressing first (session tabs spec,
/// The strip).
nonisolated enum TabStatus: Equatable {
  /// A permission, an MCP server's question, or a closing ask at a level that counts.
  case needsYou
  /// A turn running.
  case working
  /// Finished while another tab was shown.
  case unread
  case none

  /// Read from the session's status, which changes with what the session does and not with
  /// each token, and from the row's own state: a tab is not redrawn while text streams in.
  @MainActor static func of(_ item: ProjectSession) -> TabStatus {
    let status = item.session.status
    let counts = item.urgency.map { AttentionChoice.isOn($0, .counts) } ?? false
    if counts || status.isWaitingOnPerson { return .needsYou }
    if status.isRunning { return .working }
    return item.isUnread ? .unread : .none
  }
}

/// The window's sessions as tabs over the session pane, in the window's own order, which
/// only a drag changes. Each tab is its own small view, compared by value, so that what one
/// session does redraws its tab alone. With the keys, ← and → show the tab beside, Esc
/// clears the marks and ⌘A marks every tab; `FocusedPane.sessions` is the strip.
struct SessionTabStrip: View {
  let project: Project
  @FocusState private var isFocused: Bool

  static let spacing: CGFloat = 2
  static let inset: CGFloat = 6
  static let minWidth: CGFloat = 120
  static let maxWidth: CGFloat = 220

  var body: some View {
    // None over an empty window: "No session" alone, as before tabs.
    if !project.tabs.isEmpty {
      VStack(spacing: 0) {
        strip
        Divider()
      }
    }
  }

  private var strip: some View {
    let tabs = project.tabs
    let count = tabs.count
    return ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: Self.spacing) {
          ForEach(tabs) { item in
            SessionTabCell(
              item: item, project: project, isSelected: item.id == project.selectedID,
              isMarked: project.marked.contains(item.id)
            )
            .containerRelativeFrame(.horizontal) { length, _ in
              Self.tabWidth(in: length, count: count)
            }
            .id(item.id)
          }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 3)
      }
      .scrollIndicators(.never)
      .onChange(of: project.selectedID, initial: true) { _, id in
        guard let id else { return }
        withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
      }
    }
    // Dropped past the last tab: the tab goes to the end.
    .dropDestination(for: String.self) { ids, _ in Self.drop(ids, onto: nil, in: project) }
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    // The strip had the keys at the last quit: it takes them back.
    .onAppear { if project.claimsRestoredFocus(.sessions) { isFocused = true } }
    .onChange(of: isFocused) { _, focused in
      if focused { project.workspace.focusedPane = .sessions }
    }
    .onKeyPress(.leftArrow) { step(-1) }
    .onKeyPress(.rightArrow) { step(1) }
    .onKeyPress(.escape) {
      guard !project.marked.isEmpty else { return .ignored }
      project.clearMarks()
      return .handled
    }
    .onKeyPress(characters: ["a"]) { press in
      guard press.modifiers == .command else { return .ignored }
      project.markAll()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sessions")
    .accessibilityIdentifier("sessions.tabs")
  }

  private func step(_ offset: Int) -> KeyPress.Result {
    project.step(offset, wrapping: false, focusingComposer: false) ? .handled : .ignored
  }

  /// Each tab's width: the strip shared out among the tabs, down to `minWidth`, past which
  /// the strip scrolls; never wider than `maxWidth`.
  static func tabWidth(in length: CGFloat, count: Int) -> CGFloat {
    let count = max(count, 1)
    let gaps = spacing * CGFloat(count - 1) + inset * 2
    return min(maxWidth, max(minWidth, (length - gaps) / CGFloat(count)))
  }

  /// A tab dragged onto `target` takes its place, whichever side it came from; onto none,
  /// past the last tab, it goes last. The place is the tab's final one, as `moveTab` counts.
  /// False for what is not one of the window's tabs: text dragged from elsewhere, or a tab of
  /// another window.
  @discardableResult static func drop(
    _ payload: [String], onto target: ProjectSession?, in project: Project
  ) -> Bool {
    let tabs = project.tabs
    guard let id = payload.first.flatMap(UUID.init(uuidString:)),
      tabs.contains(where: { $0.id == id })
    else { return false }
    let index = target.flatMap { target in tabs.firstIndex { $0.id == target.id } }
    project.moveTab(id, to: index ?? tabs.count - 1)
    return true
  }

  /// ⌘ marks one tab more or less, ⇧ a range; a plain click shows the tab.
  static func click(_ flags: NSEvent.ModifierFlags) -> Project.RowClick {
    if flags.contains(.command) { return .toggle }
    if flags.contains(.shift) { return .extend }
    return .plain
  }
}

/// One tab as the strip lays it out: its values read from its session, where the strip
/// does not read them, and what a click, a drag or a right-click on it does.
private struct SessionTabCell: View {
  let item: ProjectSession
  let project: Project
  let isSelected: Bool
  let isMarked: Bool
  @State private var isTargeted = false

  var body: some View {
    SessionTab(
      title: item.displayTitle, status: TabStatus.of(item), agent: item.session.agent,
      isSelected: isSelected, isMarked: isMarked, isPreview: item.isWatching,
      tooltip: tooltip, select: clicked, close: { TabClosing.request(item, in: project) }
    )
    .equatable()
    .overlay {
      if isTargeted {
        RoundedRectangle(cornerRadius: SessionTab.radius)
          .strokeBorder(Theme.accent, lineWidth: 1.5)
      }
    }
    .draggable(item.id.uuidString)
    .dropDestination(for: String.self) { ids, _ in
      SessionTabStrip.drop(ids, onto: item, in: project)
    } isTargeted: {
      isTargeted = $0
    }
    .contextMenu { SessionMenu(item: item, project: project) }
    .accessibilityIdentifier("sessions.tab.\(item.sessionID ?? item.id.uuidString)")
  }

  /// A plain click shows the tab and hands the keys to its composer, as a row's did; ⌘ and
  /// ⇧ mark. A double click on the preview keeps it as a tab of the window's own.
  private func clicked() {
    let event = NSApp.currentEvent
    let click = SessionTabStrip.click(event?.modifierFlags ?? NSEvent.modifierFlags)
    if click == .plain, item.isWatching, (event?.clickCount ?? 1) >= 2 {
      project.promote(item)
      return
    }
    project.click(item, click)
  }

  /// What the row showed that the tab has no room for: the name in full, what the session
  /// is doing or wants, its account when not the window's, the subfolder it runs in.
  private var tooltip: String {
    let session = item.session
    var lines = [item.displayTitle, item.wants ?? item.stopReason ?? RowState(item).label]
    if session.features.showsAccount, !session.isOnRunner, project.runner == nil,
      let account = session.effectiveAccount,
      account.key != AccountStore.shared.windowAccount(for: project.folder).key
    {
      lines.append(AccountStore.shared.profile(for: account).name)
    }
    if let subfolder = ProjectPath.child(
      of: session.folder.path(percentEncoded: false),
      below: project.folder.path(percentEncoded: false))
    {
      lines.append(subfolder)
    }
    return lines.joined(separator: "\n")
  }
}

/// A session's tab: its mark, its name, and a × on hover and on the selected tab. Equal
/// whatever its closures, so that the strip redraws a tab only when what it shows changes.
struct SessionTab: View, Equatable {
  let title: String
  let status: TabStatus
  let agent: AgentKind
  let isSelected: Bool
  let isMarked: Bool
  /// The window's one preview tab: its name in italics, replaced by the next row opened.
  let isPreview: Bool
  let tooltip: String
  let select: () -> Void
  let close: () -> Void
  @State private var isHovered = false

  static let radius: CGFloat = 6

  nonisolated static func == (a: SessionTab, b: SessionTab) -> Bool {
    a.title == b.title && a.status == b.status && a.agent == b.agent
      && a.isSelected == b.isSelected && a.isMarked == b.isMarked && a.isPreview == b.isPreview
      && a.tooltip == b.tooltip
  }

  var body: some View {
    HStack(spacing: 5) {
      mark.frame(width: 10)
      if agent == .codex {
        Image(systemName: "terminal")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(agent.name)
          .accessibilityLabel(agent.name)
      }
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
        .italic(isPreview)
        .foregroundStyle(isSelected ? .primary : .secondary)
      Spacer(minLength: 0)
      closeButton
    }
    .font(.callout)
    .padding(.leading, 8)
    .padding(.trailing, 4)
    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
    .background(background)
    .contentShape(RoundedRectangle(cornerRadius: Self.radius))
    .onHover { isHovered = $0 }
    .onTapGesture(perform: select)
    .help(tooltip)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelected || isMarked ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction(.default, select)
    .accessibilityAction(named: "Close Tab", close)
  }

  /// One mark at a time, in the sidebar rows' colours.
  @ViewBuilder private var mark: some View {
    switch status {
    case .needsYou:
      Circle().fill(Theme.accent).frame(width: 7, height: 7)
    case .working:
      Image(systemName: "circle.dotted")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(RowState.working.tint)
    case .unread:
      Circle().fill(.secondary).frame(width: 6, height: 6)
    case .none:
      Color.clear.frame(width: 7, height: 7)
    }
  }

  private var closeButton: some View {
    let shown = isSelected || isHovered
    return Button(action: close) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help("Close Tab")
    .opacity(shown ? 1 : 0)
    .allowsHitTesting(shown)
    .accessibilityHidden(true)
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Self.radius)
      .fill(
        isMarked
          ? AnyShapeStyle(Theme.accent.opacity(0.15))
          : isSelected
            ? AnyShapeStyle(.quaternary)
            : isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
  }

  private var accessibilityLabel: String {
    let state: String? =
      switch status {
      case .needsYou: String(localized: "Needs you")
      case .working: String(localized: "Working")
      case .unread: String(localized: "Unread")
      case .none: nil
      }
    return [title, state].compactMap(\.self).joined(separator: ", ")
  }
}
