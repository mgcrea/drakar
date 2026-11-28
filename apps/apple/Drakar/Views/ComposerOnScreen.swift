import AppKit
import SwiftUI

extension View {
  /// Tells `session` whether its composer is in sight: its tab is the window's shown one,
  /// and the window is not covered, minimised or hidden with the app. The agent guesses the
  /// next prompt only then (`AgentSession.setComposerOnScreen`).
  func composerOnScreen(of session: AgentSession, isSelected: Bool) -> some View {
    modifier(ComposerOnScreen(session: session, isSelected: isSelected))
  }
}

private struct ComposerOnScreen: ViewModifier {
  let session: AgentSession
  let isSelected: Bool

  @State private var window: ObjectIdentifier?
  @State private var isWindowVisible = false

  func body(content: Content) -> some View {
    content
      .background(
        WindowReader { found in
          // Not during the update that put the view in its window.
          Task { @MainActor in
            window = ObjectIdentifier(found)
            isWindowVisible = found.occlusionState.contains(.visible)
          }
        }
      )
      .onReceive(
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
      ) { notification in
        guard let changed = notification.object as? NSWindow, ObjectIdentifier(changed) == window
        else { return }
        isWindowVisible = changed.occlusionState.contains(.visible)
      }
      .onChange(of: isSelected && isWindowVisible, initial: true) { _, shown in
        session.setComposerOnScreen(shown)
      }
      // A tab let go of by the deck, or closed; and put back.
      .onDisappear { session.setComposerOnScreen(false) }
      .onAppear { session.setComposerOnScreen(isSelected && isWindowVisible) }
  }
}
