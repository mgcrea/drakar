import AppKit
import DrakarMCP
import Foundation
import SwiftUI

/// The project windows the MCP server's writes need, found or opened without ever taking the
/// person's keyboard (spec §3, "Windows never take the keyboard"): no window is made key or
/// main, ordered front, or the app activated. A window already open is used as it is; one
/// opened for an agent goes behind the others, and the key and main go back to the windows
/// that had them. Never `WindowTabs.open`, which brings a window forward.
@MainActor enum MCPWindows {
  /// How long a window opened has to register its project.
  static let registrationLimit = Duration.seconds(10)
  private static let pollInterval = Duration.milliseconds(50)

  /// The open project for `route`, opening its window behind the others if none is, with the
  /// key and main windows and the app's activation left as they were. The reason, when it cannot (no
  /// `WindowTabs.openWindow` yet; the window did not register within 10 s).
  static func project(for route: WindowRoute) async -> Result<Project, SessionError> {
    await project(for: route, in: .shared, opening: openWindow)
  }

  /// The scene's own way to open a window, once a window has handed it over.
  static var openWindow: ((WindowRoute) -> Void)? {
    WindowTabs.openWindow.map { action in { action(value: $0) } }
  }

  /// The windows being opened for an agent now, by route: a second write for a project whose
  /// window is still opening waits for that window rather than asking for another.
  private static var opening: [WindowRoute: Task<Result<Project, SessionError>, Never>] = [:]

  /// `project(for:)`, with the windows registered in `sessions` and opened by `opening`;
  /// tests give their own.
  static func project(
    for route: WindowRoute, in sessions: OpenSessions, opening open: ((WindowRoute) -> Void)?,
    limit: Duration = registrationLimit
  ) async -> Result<Project, SessionError> {
    if let project = sessions.project(for: route) { return .success(project) }
    if let pending = opening[route] { return await pending.value }
    guard let open else {
      return .failure(SessionError("Open a Drakar window once, then try again."))
    }
    // Unstructured, so a caller that stops waiting leaves the others their window; the wait
    // is bounded by `limit` all the same.
    let task = Task<Result<Project, SessionError>, Never> {
      let result = await opened(route, in: sessions, opening: open, limit: limit)
      opening[route] = nil
      return result
    }
    opening[route] = task
    return await task.value
  }

  /// Opens `route`'s window and waits for it to register its project, then settles it behind
  /// the others.
  private static func opened(
    _ route: WindowRoute, in sessions: OpenSessions, opening: (WindowRoute) -> Void,
    limit: Duration
  ) async -> Result<Project, SessionError> {
    let previousKey = NSApp.keyWindow
    let previousMain = NSApp.mainWindow
    let wasActive = NSApp.isActive
    // Never `OpenSessions.requestNewSession`: the window's own blank row is the one to use.
    opening(route)
    let deadline = ContinuousClock.now + limit
    while true {
      if let project = sessions.project(for: route), let window = project.workspace.window {
        settle(
          new: window, previousKey: previousKey, previousMain: previousMain, wasActive: wasActive)
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

  /// A window just opened for an agent goes behind the others, and gives back what it took:
  /// main to the window that had it, and, while the app was active, the key to the window
  /// that had it, or to none when none did. Only those windows are made key or main, never
  /// the new one, and the app is never activated: inactive, it stays so.
  static func settle(
    new window: NSWindow, previousKey: NSWindow?, previousMain: NSWindow?, wasActive: Bool
  ) {
    window.orderBack(nil)
    if window.isMainWindow, let previousMain, previousMain !== window, previousMain.isVisible {
      previousMain.makeMain()
    }
    guard wasActive else { return }
    if let previousKey, previousKey !== window, previousKey.isVisible {
      previousKey.makeKey()
    } else if window.isKeyWindow {
      // Typing meant for no window must not land in the agent's.
      window.resignKey()
    }
  }
}
