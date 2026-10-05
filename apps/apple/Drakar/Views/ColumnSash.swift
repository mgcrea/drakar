import AppKit
import SwiftUI

/// A column's edge as `ResizeHandle` draws the panes': a strip to grab either side of the
/// split view's own divider, lit as VS Code's sash is. Set in a column's background (the
/// sidebar's, the inspector's), it finds the split view around it and lays an AppKit view
/// over the divider on `edge`, above both columns, which a SwiftUI handle cannot reach:
/// each column is its own hosting view and clips what it draws. Dragging moves the divider
/// itself, so the column keeps its own limits, and its width is whatever the split view
/// keeps.
struct ColumnSash: NSViewRepresentable {
  /// The column's edge whose divider the sash lies over.
  let edge: HorizontalEdge

  func makeNSView(context: Context) -> NSView { Locator(edge: edge) }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class Locator: NSView {
    let edge: HorizontalEdge
    private var sash: SashView?

    init(edge: HorizontalEdge) {
      self.edge = edge
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    /// The sash goes with the column: one rebuilt (the inspector shown again) lays a new one
    /// rather than leaving the old one over the divider.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      sash?.removeFromSuperview()
      sash = nil
      guard window != nil, let (split, column) = enclosingColumn else { return }
      sash = SashView(splitView: split, column: column, edge: edge)
    }

    /// The nearest side-by-side split view around this view, and its column holding it.
    private var enclosingColumn: (NSSplitView, NSView)? {
      var view = superview
      while let current = view {
        if let split = current as? NSSplitView, split.isVertical,
          let column = split.arrangedSubviews.first(where: isDescendant(of:))
        {
          return (split, column)
        }
        view = current.superview
      }
      return nil
    }
  }
}

private final class SashView: NSView {
  private weak var splitView: NSSplitView?
  private weak var column: NSView?
  private let edge: HorizontalEdge
  private var observers: [NSObjectProtocol] = []
  private var hoverTimer: Timer?
  /// Where in the strip the press landed, so the divider follows the pointer without a jump.
  private var grabOffset: CGFloat?
  private var isLit = false {
    didSet { if isLit != oldValue { needsDisplay = true } }
  }

  init(splitView: NSSplitView, column: NSView, edge: HorizontalEdge) {
    self.splitView = splitView
    self.column = column
    self.edge = edge
    super.init(frame: .zero)
    // Laid over the columns, never among them: a split view that arranges all of its
    // subviews would take this one for another column.
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

  /// The divider on the column's `edge`, counted afresh each time: the inspector appearing
  /// adds a column. Nil when that edge is the window's.
  private var divider: Int? {
    guard let splitView, let column,
      let index = splitView.arrangedSubviews.firstIndex(of: column)
    else { return nil }
    let divider = edge == .trailing ? index : index - 1
    return splitView.arrangedSubviews.indices.dropLast().contains(divider) ? divider : nil
  }

  /// The column's edge on `edge`, which is what `setPosition(_:ofDividerAt:)` moves on that
  /// side. Read off this column rather than its neighbour: the column before a divider can
  /// run on under the one after it (the detail under the sidebar, under the inspector), so
  /// its edge is not the divider's.
  private var columnEdge: CGFloat? {
    guard let column else { return nil }
    return edge == .trailing ? column.frame.maxX : column.frame.minX
  }

  /// Over the divider, the full height, hidden with the column.
  private func place() {
    guard let splitView, let column, let superview, divider != nil, let x = columnEdge
    else {
      isHidden = true
      return
    }
    isHidden = column.isHidden || splitView.isSubviewCollapsed(column) || column.frame.width < 1
    let center = x + splitView.dividerThickness / (edge == .trailing ? 2 : -2)
    let strip = NSRect(
      x: center - ResizeHandle.thickness / 2, y: 0, width: ResizeHandle.thickness,
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
    guard let splitView, divider != nil, let x = columnEdge else { return }
    hoverTimer?.invalidate()
    isLit = true
    grabOffset = splitView.convert(event.locationInWindow, from: nil).x - x
  }

  override func mouseDragged(with event: NSEvent) {
    guard let splitView, let divider, let grabOffset else { return }
    let x = splitView.convert(event.locationInWindow, from: nil).x - grabOffset
    splitView.setPosition(x, ofDividerAt: divider)
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
