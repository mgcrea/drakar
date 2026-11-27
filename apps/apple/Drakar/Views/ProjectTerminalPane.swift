import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// The project window retains the terminal while its pane is hidden.
@MainActor
@Observable
final class ProjectTerminal {
  private(set) var view: LocalProcessTerminalView?
  private(set) var status: String?

  func start(in folder: URL) {
    let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
    view.onExit = { [weak self, weak view] status in
      guard let self, let view, self.view === view else { return }
      self.status = status
    }
    // SwiftTerm keeps its native renderer available when Metal initialization fails.
    try? view.setUseMetal(true)
    status = nil
    self.view = view

    var environment = ProcessInfo.processInfo.environment
    let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
    view.startProcess(
      executable: shell, args: ["-l", "-i"],
      environment: environment.map { "\($0.key)=\($0.value)" },
      currentDirectory: folder.path(percentEncoded: false))
  }

  func stop() {
    let previous = view
    view = nil
    status = nil
    previous?.terminate()
  }
}

struct ProjectTerminalPane: View {
  let terminal: ProjectTerminal
  let folder: URL
  let hide: () -> Void
  @AppStorage(PreferenceKey.terminalFontSize) private var fontSize = TerminalDefaults.fontSize
  @AppStorage(PreferenceKey.terminalScrollback) private var scrollback = TerminalDefaults.scrollback
  @AppStorage(PreferenceKey.terminalBell) private var bell = TerminalDefaults.bell

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Terminal")
          .font(.caption.weight(.semibold))
        if let status = terminal.status {
          Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Button("New Shell") { terminal.start(in: folder) }
        }
        Spacer()
        Button(action: hide) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Hide Terminal")
        .accessibilityLabel("Hide Terminal")
      }
      .padding(.horizontal, 10)
      .frame(height: 28)
      Divider()
      if let view = terminal.view {
        TerminalSurface(view: view)
          .onChange(of: fontSize, initial: true) {
            let size = CGFloat(min(max(fontSize, 8), 32))
            if view.font.pointSize != size {
              view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
          }
          .onChange(of: scrollback, initial: true) {
            view.changeScrollback(min(max(scrollback, 0), 50_000))
          }
          .onChange(of: bell, initial: true) {
            view.bellStyle = BellStyle(tagName: bell) ?? .sound
          }
          .id(ObjectIdentifier(view))
      }
    }
    .task {
      if terminal.view == nil { terminal.start(in: folder) }
    }
  }
}

private struct TerminalSurface: NSViewRepresentable {
  static let horizontalPadding: CGFloat = 8
  let view: LocalProcessTerminalView

  func makeNSView(context: Context) -> TerminalContainerView {
    TerminalContainerView(terminalView: view, horizontalPadding: Self.horizontalPadding)
  }

  func updateNSView(_ container: TerminalContainerView, context: Context) {
    container.attach(view)
  }

  static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
    container.detach()
  }
}

/// Hosts `LocalProcessTerminalView` with internal horizontal padding so the margins share
/// the terminal's live background, pointer cursor, and mouse/scroll hit-testing.
private final class TerminalContainerView: NSView {
  private let horizontalPadding: CGFloat
  private(set) weak var terminalView: LocalProcessTerminalView?
  private var layerObserver: LayerBackgroundObserver?

  init(terminalView: LocalProcessTerminalView, horizontalPadding: CGFloat) {
    self.horizontalPadding = horizontalPadding
    super.init(frame: .zero)
    wantsLayer = true
    clipsToBounds = true
    attach(terminalView)
  }

  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    syncBackgroundColor()
  }

  func attach(_ view: LocalProcessTerminalView) {
    let changed = terminalView !== view
    if let current = terminalView, changed, current.superview === self {
      current.removeFromSuperview()
    }
    terminalView = view
    if view.superview !== self {
      view.removeFromSuperview()
      addSubview(view)
    }
    if changed || layerObserver == nil {
      layerObserver?.cancel()
      if let targetLayer = view.layer {
        layerObserver = LayerBackgroundObserver(layer: targetLayer) { [weak self] in
          self?.syncBackgroundColor()
        }
      } else {
        layerObserver = nil
      }
    }
    needsLayout = true
    syncBackgroundColor()
  }

  func detach() {
    layerObserver?.cancel()
    layerObserver = nil
    if let terminalView, terminalView.superview === self {
      terminalView.removeFromSuperview()
    }
    terminalView = nil
  }

  private func syncBackgroundColor() {
    guard let layer, let terminalView else { return }
    if let terminalBackground = terminalView.layer?.backgroundColor,
      terminalBackground.alpha > 0
    {
      layer.backgroundColor = terminalBackground
      return
    }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer.backgroundColor = terminalView.nativeBackgroundColor.cgColor
    }
  }

  override func layout() {
    super.layout()
    guard let terminalView, terminalView.superview === self else { return }
    let inset = min(horizontalPadding, bounds.width / 2)
    terminalView.frame = bounds.insetBy(dx: inset, dy: 0)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncBackgroundColor()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncBackgroundColor()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard hit === self, let terminalView, !terminalView.isHidden else { return hit }
    return terminalView
  }

  override func resetCursorRects() {
    guard let terminalView else { return }
    addCursorRect(bounds, cursor: terminalView.pointerCursor(modifiers: []))
  }
}

private nonisolated final class LayerBackgroundObserver: NSObject, @unchecked Sendable {
  private nonisolated(unsafe) static var context: UInt8 = 0
  private let lock = NSLock()
  private weak var layer: CALayer?
  private let onChange: @MainActor @Sendable () -> Void

  @MainActor
  init(layer: CALayer, onChange: @escaping @MainActor @Sendable () -> Void) {
    self.layer = layer
    self.onChange = onChange
    super.init()
    layer.addObserver(
      self, forKeyPath: "backgroundColor", options: [.new], context: &Self.context)
  }

  func cancel() {
    lock.lock()
    let target = layer
    layer = nil
    lock.unlock()
    target?.removeObserver(self, forKeyPath: "backgroundColor", context: &Self.context)
  }

  deinit {
    cancel()
  }

  override func observeValue(
    forKeyPath keyPath: String?, of object: Any?,
    change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
  ) {
    guard context == &Self.context else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }
    let handler = onChange
    if Thread.isMainThread {
      MainActor.assumeIsolated { handler() }
    } else {
      DispatchQueue.main.async { handler() }
    }
  }
}

private final class ShellTerminalView: LocalProcessTerminalView {
  var onExit: ((String) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    Task { @MainActor [weak self, weak window] in
      guard let self, let window, self.window === window else { return }
      window.makeFirstResponder(self)
    }
  }

  override func mouseDown(with event: NSEvent) {
    // Metal-backed SwiftTerm inserts a layer view that declines first responder and
    // forwards clicks up the responder chain without reclaiming focus itself.
    if window?.firstResponder !== self {
      window?.makeFirstResponder(self)
    }
    super.mouseDown(with: event)
  }

  override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    super.processTerminated(source, exitCode: exitCode)
    if let exitCode, exitCode != 0 {
      onExit?(String(localized: "Shell exited with status \(exitCode)"))
    } else {
      onExit?(String(localized: "Shell ended"))
    }
  }

  override func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
    super.processFailedToStart(source, error: error)
    onExit?(String(localized: "Couldn’t start the shell"))
  }
}
