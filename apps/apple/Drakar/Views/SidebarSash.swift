import AppKit
import SwiftUI

/// The sidebar's edge as `ResizeHandle` draws the panes': a strip to grab either side of
/// the split view's own divider, lit as VS Code's sash is. Set in the sidebar's background,
/// it finds the split view around it and lays an AppKit view over that divider, above both
/// columns, which a SwiftUI handle cannot reach: each column is its own hosting view and
/// clips what it draws. Dragging moves the divider itself, so the column keeps its own
/// limits, and its width is whatever the split view keeps.
struct SidebarSash: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Locator() }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class Locator: NSView {
    private var sash: SashView?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil, sash == nil, let split = enclosingSplitView else { return }
      sash = SashView(splitView: split)
    }

    private var enclosingSplitView: NSSplitView? {
      var view = superview
      while let current = view {
        if let split = current as? NSSplitView, split.isVertical { return split }
        view = current.superview
      }
      return nil
    }
  }
}

private final class SashView: NSView {
  private weak var splitView: NSSplitView?
  private var observers: [NSObjectProtocol] = []
  private var hoverTimer: Timer?
  /// Where in the strip the press landed, so the divider follows the pointer without a jump.
  private var grabOffset: CGFloat?
  private var isLit = false {
    didSet { if isLit != oldValue { needsDisplay = true } }
  }

  init(splitView: NSSplitView) {
    self.splitView = splitView
    super.init(frame: .zero)
    // Laid over the columns, never among them: a split view that arranges all of its
    // subviews would take this one for a third column.
    let container = splitView.arrangesAllSubviews ? splitView.superview : splitView
    container?.addSubview(self, positioned: .above, relativeTo: nil)
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } },
      center.addObserver(
        forName: NSView.frameDidChangeNotification, object: splitView, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } },
    ]
    place()
  }

  required init?(coder: NSCoder) { nil }

  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  override var isFlipped: Bool { true }

  /// Over the first divider, the full height, hidden with the sidebar.
  private func place() {
    guard let splitView, let sidebar = splitView.arrangedSubviews.first, let superview
    else { return }
    isHidden = sidebar.isHidden || splitView.isSubviewCollapsed(sidebar) || sidebar.frame.width < 1
    let edge = sidebar.frame.maxX + splitView.dividerThickness / 2
    let strip = NSRect(
      x: edge - ResizeHandle.thickness / 2, y: 0, width: ResizeHandle.thickness,
      height: splitView.bounds.height)
    frame = superview.convert(strip, from: splitView)
    window?.invalidateCursorRects(for: self)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
        owner: self))
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .columnResize) }
  override func cursorUpdate(with event: NSEvent) { NSCursor.columnResize.set() }

  override func mouseEntered(with event: NSEvent) {
    hoverTimer?.invalidate()
    let delay = ResizeHandle.hoverDelay.components
    hoverTimer = .scheduledTimer(
      withTimeInterval: Double(delay.seconds) + Double(delay.attoseconds) / 1e18, repeats: false
    ) { [weak self] _ in MainActor.assumeIsolated { self?.isLit = true } }
  }

  override func mouseExited(with event: NSEvent) {
    hoverTimer?.invalidate()
    if grabOffset == nil { isLit = false }
  }

  override func mouseDown(with event: NSEvent) {
    guard let splitView, let sidebar = splitView.arrangedSubviews.first else { return }
    hoverTimer?.invalidate()
    isLit = true
    grabOffset = splitView.convert(event.locationInWindow, from: nil).x - sidebar.frame.maxX
  }

  override func mouseDragged(with event: NSEvent) {
    guard let splitView, let grabOffset else { return }
    let x = splitView.convert(event.locationInWindow, from: nil).x - grabOffset
    splitView.setPosition(x, ofDividerAt: 0)
    place()
  }

  override func mouseUp(with event: NSEvent) {
    grabOffset = nil
    isLit = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func draw(_ dirtyRect: NSRect) {
    guard isLit else { return }
    NSColor.controlAccentColor.setFill()
    NSRect(
      x: bounds.midX - ResizeHandle.lineWidth / 2, y: 0, width: ResizeHandle.lineWidth,
      height: bounds.height
    ).fill()
  }
}
