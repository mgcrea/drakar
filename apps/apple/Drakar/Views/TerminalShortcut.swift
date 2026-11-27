import AppKit
import Carbon
import SwiftUI

/// Handles Control-backtick before a focused editor or terminal can consume it.
struct TerminalShortcut: NSViewRepresentable {
  let toggle: () -> Void

  func makeNSView(context: Context) -> ShortcutView { ShortcutView(toggle: toggle) }

  func updateNSView(_ view: ShortcutView, context: Context) { view.toggle = toggle }

  static func matches(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
    return modifiers == .control
      && (event.keyCode == UInt16(kVK_ANSI_Grave) || event.charactersIgnoringModifiers == "`")
  }

  final class ShortcutView: NSView {
    var toggle: () -> Void
    private var monitor: Any?

    init(toggle: @escaping () -> Void) {
      self.toggle = toggle
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      super.viewWillMove(toWindow: newWindow)
      guard let newWindow else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self, weak newWindow] event in
        guard let self, let newWindow, event.window === newWindow, newWindow.isKeyWindow,
          newWindow.attachedSheet == nil, TerminalShortcut.matches(event)
        else { return event }
        if !event.isARepeat { self.toggle() }
        return nil
      }
    }
  }
}
