import Foundation
import SupportKitTestHost
import Testing

@testable import Drakar

#if canImport(AppKit) && DEBUG
  import AppKit

  /// The hosted suite runs inside Drakar.app on the Mac someone is working at. The app it
  /// runs in never takes the front, so their keystrokes stay where they were, and every
  /// window a test opens lies off every screen, so nothing is drawn over their work
  /// (`SupportKitTestHost`, whose own tests argue about the pieces; these check the app
  /// calls it).
  @Suite("Test host")
  @MainActor
  struct TestHostTests {

    /// The app was launched by `xcodebuild` and is still not the active app, and macOS does
    /// not count it as the front one.
    @Test func theTestHostNeverTakesTheFront() {
      #expect(NSApp.activationPolicy() != .regular)
      #expect(!NSApp.isActive)
      #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid())
    }

    /// The app opened nothing at launch, and whatever window a test has open at this moment
    /// is off every display, or as far off as AppKit lets it go and transparent.
    @Test func noWindowOfTheAppIsOnAScreen() {
      let shown = NSApp.windows.filter { window in
        window.isVisible && window.alphaValue > 0 && !window.isSheet && window.parent == nil
          && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
      }
      #expect(shown.map(\.title) == [])
    }
  }
#endif
