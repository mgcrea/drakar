import AppKit
import DrakarMCP
import Foundation
import SwiftUI

/// The project windows the MCP server's writes need, found or opened without ever taking the
/// person's keyboard (spec §3, "Windows never take the keyboard"): no window is made key or
/// main, ordered front, or the app activated. A window already open is used as it is; one
/// opened for an agent goes behind the others, and the key goes back to the window that had
/// it. Never `WindowTabs.open`, which brings a window forward.
@MainActor enum MCPWindows {
  /// How long a window opened has to register its project.
  static let registrationLimit = Duration.seconds(10)
  private static let pollInterval = Duration.milliseconds(50)

  /// The open project for `route`, opening its window behind the others if none is, with the
  /// key window and the app's activation left as they were. The reason, when it cannot (no
  /// `WindowTabs.openWindow` yet; the window did not register within 10 s).
  static func project(for route: WindowRoute) async -> Result<Project, SessionError> {
    await project(for: route, in: .shared, opening: openWindow)
  }

  /// The scene's own way to open a window, once a window has handed it over.
  static var openWindow: ((WindowRoute) -> Void)? {
    WindowTabs.openWindow.map { action in { action(value: $0) } }
  }

  /// `project(for:)`, with the windows registered in `sessions` and opened by `opening`;
  /// tests give their own.
  static func project(
    for route: WindowRoute, in sessions: OpenSessions, opening: ((WindowRoute) -> Void)?,
    limit: Duration = registrationLimit
  ) async -> Result<Project, SessionError> {
    if let project = sessions.project(for: route) { return .success(project) }
    guard let opening else {
      return .failure(SessionError("Open a Drakar window once, then try again."))
    }
    let previousKey = NSApp.keyWindow
    let wasActive = NSApp.isActive
    // Never `OpenSessions.requestNewSession`: the window's own blank row is the one to use.
    opening(route)
    let deadline = ContinuousClock.now + limit
    while true {
      if let project = sessions.project(for: route), let window = project.workspace.window {
        settle(new: window, previousKey: previousKey, wasActive: wasActive)
        return .success(project)
      }
      guard ContinuousClock.now < deadline else { break }
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        break
      }
    }
    let folder = route.folder?.path(percentEncoded: false) ?? "the project"
    return .failure(
      SessionError("The window for \(folder) did not open in time. Try again in a moment."))
  }

  /// A window just opened for an agent goes behind the others, and the key goes back to the
  /// window that had it while the app was active. Only that window is made key, never the
  /// new one, and the app is never activated: inactive, it stays so.
  static func settle(new window: NSWindow, previousKey: NSWindow?, wasActive: Bool) {
    window.orderBack(nil)
    guard wasActive, let previousKey, previousKey !== window, previousKey.isVisible else {
      return
    }
    previousKey.makeKey()
  }
}
