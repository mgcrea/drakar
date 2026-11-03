import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Drakar

/// The session pane in a window of its own (`SelectedSessionPane` over a project, a text
/// field beside it standing in for the strip): the sessions shown lately stay built, only the
/// shown one is in the window, and the composer takes the keys after a switch only when the
/// switch asked for it. Nothing here times anything; the waits are for SwiftUI's updates.
@MainActor
@Suite("Session deck", .serialized, .timeLimit(.minutes(1)))
struct SessionDeckTests {
  private let project: Project
  private let window: NSWindow
  /// Where the keys are when the strip has them.
  private let outside = NSTextField(frame: NSRect(x: 0, y: 570, width: 200, height: 24))

  init() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-deck-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    project = Project(folder: folder)
    window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 700, height: 600),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // Above the windows of whoever is using the Mac: SwiftUI holds back the updates of a
    // window nothing of shows, and these wait on them.
    window.level = .floating
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    let pane = NSHostingView(rootView: SelectedSessionPane(project: project))
    pane.frame = NSRect(x: 0, y: 0, width: 700, height: 560)
    content.addSubview(pane)
    content.addSubview(outside)
    window.contentView = content
    window.orderFrontRegardless()
  }

  /// Until `condition` holds, or a few seconds have gone.
  private func wait(until condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  /// Lets SwiftUI update the pane, and the deck's own hops after it run.
  private func settle() async {
    for _ in 0..<5 {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(40))
    }
  }

  private var deck: SessionDeck.Coordinator? {
    func find(in view: NSView) -> SessionDeck.DeckView? {
      if let deck = view as? SessionDeck.DeckView { return deck }
      return view.subviews.lazy.compactMap(find(in:)).first
    }
    return window.contentView.flatMap(find(in:))?.coordinator
  }

  private func host(_ item: ProjectSession) -> NSView? { deck?.built[item.id] }

  /// Whether the window's first responder is in `view`: the composer's field editor is.
  private func hasKeys(_ view: NSView?) -> Bool {
    guard let view, let responder = window.firstResponder as? NSView else { return false }
    return responder.isDescendant(of: view)
  }

  /// Whether the stand-in for the strip has the keys, its field editor or itself.
  private var outsideHasKeys: Bool {
    window.firstResponder === outside
      || (window.firstResponder as? NSText)?.delegate === outside
  }

  @Test func aSessionShownAgainIsTheViewItHad() async throws {
    defer { window.close() }
    let a = project.newSession()
    await wait { host(a)?.window != nil }
    let first = try #require(host(a))
    let b = project.newSession()
    await wait { host(b)?.window != nil && first.window == nil }
    #expect(first.window == nil)
    project.select(a)
    await wait { first.window != nil }
    #expect(host(a) === first)
    #expect(deck?.built.count == 2)
  }

  @Test func theLeastRecentlyShownIsLetGoPastTheCapacity() async throws {
    defer { window.close() }
    var made: [ProjectSession] = []
    for _ in 0...SessionDeck.capacity {
      let item = project.newSession()
      made.append(item)
      await wait { host(item)?.window != nil }
    }
    #expect(deck?.built.count == SessionDeck.capacity)
    #expect(host(made[0]) == nil)
    #expect(host(made[SessionDeck.capacity])?.window != nil)
  }

  @Test func aClosedTabIsLetGo() async throws {
    defer { window.close() }
    let a = project.newSession()
    await wait { host(a)?.window != nil }
    let b = project.newSession()
    await wait { host(b)?.window != nil }
    // Hidden when it closes.
    project.closeTab(a)
    await wait { host(a) == nil }
    #expect(host(a) == nil)
    #expect(host(b)?.window != nil)
    // No tab left: "No session", and no deck.
    project.closeTab(b)
    await wait { deck == nil }
    #expect(deck == nil)
  }

  @Test func theComposerTakesTheKeysAgainWhenShownAgain() async throws {
    defer { window.close() }
    let a = project.newSession()
    await wait { hasKeys(host(a)) }
    #expect(hasKeys(host(a)))
    let b = project.newSession()
    await wait { hasKeys(host(b)) }
    #expect(hasKeys(host(b)))
    project.select(a)
    await wait { hasKeys(host(a)) }
    #expect(hasKeys(host(a)))
  }

  /// Reached with the strip's or the sidebar's arrows, a session built already leaves the
  /// keys where they are, though its composer had them when it was last shown.
  @Test func anArrowKeySwitchLeavesTheKeysWhereTheyAre() async throws {
    defer { window.close() }
    let a = project.newSession()
    await wait { hasKeys(host(a)) }
    let b = project.newSession()
    await wait { hasKeys(host(b)) }
    window.makeFirstResponder(outside)
    project.workspace.focusedPane = .sessions
    project.select(a, focusingComposer: false)
    await wait { host(a)?.window != nil }
    await settle()
    #expect(outsideHasKeys)
    #expect(!hasKeys(host(a)))
    #expect(project.workspace.focusedPane == .sessions)
    // And a click on the tab after it asks again.
    project.step(1, wrapping: false)
    await wait { hasKeys(host(b)) }
    project.select(a)
    await wait { hasKeys(host(a)) }
    #expect(hasKeys(host(a)))
  }

  /// A switch asks for the composer once: the deck asks, once the session is in the window,
  /// and neither the step nor the click that chose it asks again.
  @Test func aSwitchAsksForTheComposerOnce() async throws {
    defer { window.close() }
    let a = project.newSession()
    await wait { hasKeys(host(a)) }
    let b = project.newSession()
    await wait { hasKeys(host(b)) }
    let requests = a.focusRequest
    project.step(-1, wrapping: true)
    await wait { hasKeys(host(a)) }
    await settle()
    #expect(a.focusRequest == requests + 1)
    let clicked = b.focusRequest
    project.click(b, .plain)
    await wait { hasKeys(host(b)) }
    await settle()
    #expect(b.focusRequest == clicked + 1)
  }

  /// Made before SwiftUI sizes the pane, the deck lays nothing out at no size, and the
  /// switch is drawn at the first layout at the pane's size.
  @Test func aDeckWithNoSizeYetWaitsForOne() async throws {
    defer { window.close() }
    // A project of its own: the window's deck would take the switch.
    let project = Project(folder: project.folder)
    let item = project.newSession()
    let container = SessionDeck.DeckView(frame: .zero)
    let coordinator = SessionDeck.Coordinator()
    container.coordinator = coordinator
    let pending = try #require(project.pendingSwitch)
    coordinator.update(
      project: project, selectedID: item.id, tabIDs: [item.id], in: container)
    let host = try #require(coordinator.built[item.id])
    #expect(host.superview === container)
    #expect(container.undrawnSwitch === pending.state)
    container.setFrameSize(NSSize(width: 600, height: 400))
    container.layoutSubtreeIfNeeded()
    #expect(container.undrawnSwitch == nil)
    #expect(host.frame.size == NSSize(width: 600, height: 400))
    coordinator.releaseAll()
  }
}
