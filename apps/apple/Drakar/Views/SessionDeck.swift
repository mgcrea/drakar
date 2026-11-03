import SwiftUI
import os

/// The ids shown last, the most recent first, at most `capacity` of them: what the deck keeps
/// built.
nonisolated struct RecentlyShown<ID: Hashable> {
  let capacity: Int
  /// Most recent first.
  private(set) var ids: [ID] = []

  init(capacity: Int) {
    self.capacity = max(capacity, 1)
  }

  /// `id` goes to the front; what no longer fits behind it goes, the oldest last in the list,
  /// and is returned.
  @discardableResult mutating func show(_ id: ID) -> [ID] {
    ids.removeAll { $0 == id }
    ids.insert(id, at: 0)
    guard ids.count > capacity else { return [] }
    let evicted = Array(ids[capacity...])
    ids.removeLast(ids.count - capacity)
    return evicted
  }

  mutating func remove(_ id: ID) {
    ids.removeAll { $0 == id }
  }
}

/// The session pane: the selected session, and the last few shown kept built beside it, each
/// in its own hosting view, so that switching back to one is putting its view back in the
/// window, scroll position, composer and all, rather than building it again (session tabs
/// spec, Performance). Only the shown one is in the window; the others are held out of it,
/// where nothing of theirs is laid out or drawn. SwiftUI still runs the bodies of what changes
/// in a hidden one, which stays tied to the window's hierarchy: a session streaming there
/// costs about a fifth of what it costs shown (`make bench`, deck hidden). Those let go past
/// `capacity`, and those whose tab closed, are released.
///
/// A hosting view put in the window under SwiftUI's takes its environment from there, as
/// the view it replaced did, and its sheets present on the window: a sheet asked for while
/// the session was hidden comes up when it is shown.
struct SessionDeck: NSViewRepresentable {
  let project: Project
  let selectedID: ProjectSession.ID
  /// The window's tabs: a session not among them is released.
  let tabIDs: Set<ProjectSession.ID>

  /// How many sessions stay built, the shown one among them.
  static let capacity = 6

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> DeckView {
    let container = DeckView()
    container.coordinator = context.coordinator
    return container
  }

  func updateNSView(_ container: DeckView, context: Context) {
    context.coordinator.update(
      project: project, selectedID: selectedID, tabIDs: tabIDs, in: container)
  }

  static func dismantleNSView(_ container: DeckView, coordinator: Coordinator) {
    coordinator.releaseAll()
  }

  /// Whatever the pane is given: the hosting views inside are sized to it, not it to them.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: DeckView, context: Context) -> CGSize? {
    proposal.replacingUnspecifiedDimensions()
  }

  /// The session's view, themed as the window's root is: the one thing an ancestor sets that
  /// it reads, the tint, should it ever be built outside a window that passes it on. All the
  /// rest it and the views in it read from the environment, `SessionView` sets itself.
  static func root(for item: ProjectSession, in project: Project) -> some View {
    SessionView(item: item, project: project).themed()
  }

  /// The pane's view: the shown session's hosting view is its only subview.
  final class DeckView: NSView {
    /// The deck it shows, for tests.
    weak var coordinator: Coordinator?
    /// The switch to a session put in the pane before SwiftUI gave the pane a size: ended
    /// at the first layout at one, which is when the session is laid out to be drawn.
    var undrawnSwitch: OSSignpostIntervalState?

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      if undrawnSwitch != nil, !bounds.isEmpty { needsLayout = true }
    }

    override func layout() {
      super.layout()
      guard !bounds.isEmpty, let state = undrawnSwitch else { return }
      undrawnSwitch = nil
      TabSignposts.switchDrawn(state)
    }
  }

  @MainActor final class Coordinator {
    private var recent = RecentlyShown<ProjectSession.ID>(capacity: SessionDeck.capacity)
    private var hosts: [ProjectSession.ID: NSView] = [:]
    private var shownID: ProjectSession.ID?

    /// The sessions built, the shown one among them, for tests.
    var built: [ProjectSession.ID: NSView] { hosts }

    func update(
      project: Project, selectedID: ProjectSession.ID, tabIDs: Set<ProjectSession.ID>,
      in container: DeckView
    ) {
      for id in hosts.keys where !tabIDs.contains(id) { release(id) }
      let pending = project.pendingSwitch?.id == selectedID ? project.pendingSwitch : nil
      if pending != nil { project.pendingSwitch = nil }
      // Selected again before the pane updated: shown already.
      if selectedID == shownID, let pending { TabSignposts.switchDrawn(pending.state) }
      guard selectedID != shownID,
        let item = project.sessions.first(where: { $0.id == selectedID })
      else { return }
      let host = hosts[selectedID] ?? build(item, in: project)
      for id in recent.show(selectedID) { release(id) }
      if let shownID, let shown = hosts[shownID] { hide(shown, id: shownID) }
      host.frame = container.bounds
      host.isHidden = false
      if host.superview !== container { container.addSubview(host) }
      shownID = selectedID
      // Made before SwiftUI sized the pane, it has no size yet: laid out at one, not at none.
      let isSized = !container.bounds.isEmpty
      if isSized {
        container.layoutSubtreeIfNeeded()
      } else if let pending {
        if let earlier = container.undrawnSwitch { TabSignposts.switchSuperseded(earlier) }
        container.undrawnSwitch = pending.state
      }
      let focuses = project.focusesComposer
      // Once this update is done: the session is drawn in the frame it was laid out for, and
      // the composer asked for the keys as a click on its tab asks.
      DispatchQueue.main.async {
        if isSized, let pending { TabSignposts.switchDrawn(pending.state) }
        guard focuses, self.shownID == selectedID else { return }
        Self.giveKeys(to: host)
        item.focusRequest += 1
      }
    }

    func releaseAll() {
      for id in hosts.keys { release(id) }
      shownID = nil
    }

    /// Never shown since launch, or let go since: shown at once, its history read in behind,
    /// the transcript filling in when it lands.
    private func build(_ item: ProjectSession, in project: Project) -> NSView {
      let host = NSHostingView(rootView: SessionDeck.root(for: item, in: project))
      // Sized by the pane, never sizing it: no constraints from SwiftUI's own sizes.
      host.sizingOptions = []
      host.autoresizingMask = [.width, .height]
      hosts[item.id] = host
      // Timed only when there is something to read: one read already is in at once.
      let session = item.session
      if !session.hasLoadedHistory {
        Task { await TabSignposts.historyLoad { await session.loadHistory() } }
      }
      return host
    }

    /// Out of the window, at the end of this turn of the run loop: hidden until then, with
    /// the keys it had let go, so that SwiftUI sees its composer lose them. Taken out with
    /// them, the composer went on believing it had them, and took them back when shown again
    /// by the arrow keys, which leave the keys where they are.
    private func hide(_ host: NSView, id: ProjectSession.ID) {
      if let window = host.window, Self.hasKeys(host) { window.makeFirstResponder(nil) }
      host.isHidden = true
      DispatchQueue.main.async {
        guard self.shownID != id, self.hosts[id] === host else { return }
        host.removeFromSuperview()
      }
    }

    /// The keys to the hosting view, which hands them to its own focused view, or its
    /// composer once asked: SwiftUI's focus alone did not reach a hosting view put back in
    /// the window, its composer asking for keys it believed it had.
    private static func giveKeys(to host: NSView) {
      guard let window = host.window, !hasKeys(host) else { return }
      window.makeFirstResponder(host)
    }

    private static func hasKeys(_ host: NSView) -> Bool {
      (host.window?.firstResponder as? NSView)?.isDescendant(of: host) ?? false
    }

    private func release(_ id: ProjectSession.ID) {
      hosts.removeValue(forKey: id)?.removeFromSuperview()
      recent.remove(id)
      if shownID == id { shownID = nil }
    }
  }
}
