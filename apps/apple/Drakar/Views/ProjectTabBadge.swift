import AppKit
import SwiftUI

/// What a project's window tab says beside the folder's name: how many sessions the window
/// holds, and how many of them want the person, read as the session tab strip reads them.
nonisolated struct ProjectTabCount: Equatable {
  var sessions: Int
  /// Sessions whose tab shows `TabStatus.needsYou`.
  var waiting: Int

  init(sessions: Int, waiting: Int) {
    self.sessions = sessions
    self.waiting = waiting
  }

  init(_ statuses: [TabStatus]) {
    self.init(sessions: statuses.count, waiting: statuses.count { $0 == .needsYou })
  }

  /// The tab's tooltip and accessibility value.
  var help: String {
    let total = String(localized: "\(sessions) sessions")
    guard waiting > 0 else { return total }
    let wanting =
      waiting == 1
      ? String(localized: "1 needs you")
      : String(localized: "\(waiting) need you")
    return "\(total), \(wanting)"
  }
}

/// The badge itself: the session count in grey, led by the count wanting the person in an
/// accent pill when there is one, so a background project asking for something shows from
/// the tab bar.
struct ProjectTabBadge: View {
  let project: Project

  var body: some View {
    let count = ProjectTabCount(project.tabs.map(TabStatus.of))
    HStack(spacing: 3) {
      if count.waiting > 0 {
        Text(count.waiting, format: .number)
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .background(Capsule().fill(Theme.accent))
      }
      Text(count.sessions, format: .number)
        .foregroundStyle(.secondary)
    }
    .font(.system(size: 10, weight: .semibold))
    .monospacedDigit()
    .fixedSize()
    .padding(.trailing, 2)
    .help(count.help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Sessions")
    .accessibilityValue(count.help)
    .accessibilityIdentifier("window.tabBadge")
  }
}

/// Puts `ProjectTabBadge` on the window's tab (`NSWindowTab.accessoryView`), shown whenever
/// the tab bar is, and takes it off when the window goes back to home.
struct ProjectTabAccessory: NSViewRepresentable {
  let project: Project?

  func makeNSView(context: Context) -> NSView { Anchor(project: project) }

  func updateNSView(_ view: NSView, context: Context) {
    guard let anchor = view as? Anchor else { return }
    anchor.project = project
    anchor.install()
  }

  private final class Anchor: NSView {
    var project: Project?
    /// The project whose badge is on the tab, so a redraw leaves the hosting view alone.
    private weak var shown: Project?

    init(project: Project?) {
      self.project = project
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      install()
    }

    func install() {
      guard let window else { return }
      guard let project else {
        shown = nil
        window.tab.accessoryView = nil
        return
      }
      guard shown !== project || window.tab.accessoryView == nil else { return }
      shown = project
      let host = NSHostingView(rootView: ProjectTabBadge(project: project).themed())
      host.sizingOptions = [.intrinsicContentSize]
      window.tab.accessoryView = host
    }
  }
}
