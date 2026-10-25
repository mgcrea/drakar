import AppKit
import Testing

@testable import Drakar

@MainActor
@Suite("Which window a new tab joins")
struct WindowTabsTests {
  private func window() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
  }

  /// New Tab with Settings or the Skills window in front joins the frontmost of Drakar's
  /// own windows, never the one in front (seen live, 2026-10-25: it tabbed into Settings).
  @Test func aNewTabJoinsTheFrontmostDrakarWindowNotSettings() {
    let settings = window()
    let project = window()
    let older = window()
    WindowTabs.adopt(project)
    WindowTabs.adopt(older)
    #expect(WindowTabs.host(among: [settings, project, older]) === project)
    #expect(WindowTabs.host(among: [settings]) == nil)
  }
}
