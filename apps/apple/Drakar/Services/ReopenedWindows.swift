import AppKit
import DrakarKit
import Foundation

/// The project windows open at the last quit, reopened by Drakar itself when macOS restores
/// none: quitting closes windows unless the user turned that off in System Settings, and
/// ⌥⌘Q always does. Each window's sessions and tabs come back through `ProjectMemory`; this
/// brings back the windows, their frames, and which were tabs of which.
final class ReopenedWindows {
  struct Saved: Codable, Equatable {
    /// As `WindowRoute.project` holds it.
    var folder: String
    /// The runner the folder is on, nil for this Mac's: absent from what was saved before
    /// runners.
    var runner: String?
    /// `NSWindow.frameDescriptor`.
    var frame: String?
    /// A tab of the window saved before it.
    var joinsPrevious = false

    var route: WindowRoute {
      runner.map { .runnerProject(runner: $0, folder: folder) } ?? .project(folder: folder)
    }
  }

  static let shared = ReopenedWindows()
  static let key = "drakar.openWindows"

  private let defaults: UserDefaults
  /// The saved windows still to open, the next one first.
  private var queue: [Saved] = []
  private var hasBegun = false
  /// The window reopened last: the next one joins it when it is a tab.
  private weak var previous: NSWindow?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var saved: [Saved] {
    defaults.data(forKey: Self.key).flatMap {
      try? JSONDecoder().decode([Saved].self, from: $0)
    } ?? []
  }

  func save(_ windows: [Saved]) {
    defaults.set(try? JSONEncoder().encode(windows), forKey: Self.key)
  }

  /// At quit: the project windows on screen, back to front so the front one opens last, each
  /// tab group in its tab order.
  func record() {
    var folders: [ObjectIdentifier: (folder: String, runner: String?)] = [:]
    for project in OpenSessions.shared.projects.values {
      guard let window = project.workspace.window else { continue }
      folders[ObjectIdentifier(window)] = (
        ProjectPath.normalize(project.folder.path(percentEncoded: false)), project.runner
      )
    }
    var windows: [Saved] = []
    var seen: Set<ObjectIdentifier> = []
    for window in NSApp.orderedWindows.reversed() where !seen.contains(ObjectIdentifier(window)) {
      var joins = false
      for member in window.tabbedWindows ?? [window] {
        seen.insert(ObjectIdentifier(member))
        guard let (folder, runner) = folders[ObjectIdentifier(member)] else { continue }
        windows.append(
          Saved(
            folder: folder, runner: runner, frame: member.frameDescriptor, joinsPrevious: joins))
        joins = true
      }
    }
    save(windows)
  }

  /// The launch's first window asks, once: with no route, macOS restored nothing, and it
  /// becomes the first project saved. A folder deleted since is left out; a runner's is not
  /// looked for here, where it is not, and its window reopens whether the runner answers or
  /// not (remote sessions spec §4).
  func begin(launchRoute: WindowRoute?) -> WindowRoute? {
    guard !hasBegun else { return nil }
    hasBegun = true
    guard launchRoute == nil else { return nil }
    queue = saved.filter { $0.runner != nil || FileManager.default.fileExists(atPath: $0.folder) }
    return queue.first?.route
  }

  /// Whether `folder`, as `ProjectPath.normalize` writes it, on `runner` (nil for this Mac),
  /// is one still to reopen.
  func willReopen(_ folder: String, runner: String? = nil) -> Bool {
    queue.contains { $0.folder == folder && $0.runner == runner }
  }

  /// A project window is on screen: when it is the next one saved, it gets its frame and its
  /// tab group, and the one after it is returned to open. `runner`: the runner its folder is
  /// on, nil for this Mac's.
  func arrived(_ window: NSWindow, folder: URL, runner: String? = nil) -> WindowRoute? {
    guard let next = queue.first,
      next.folder == ProjectPath.normalize(folder), next.runner == runner
    else { return nil }
    queue.removeFirst()
    if let frame = next.frame { window.setFrame(from: frame) }
    if next.joinsPrevious, let previous, previous !== window {
      // A tab group shows each tab at its own frame, as `WindowTabs.adopt` keeps it.
      window.setFrame(previous.frame, display: false)
      previous.addTabbedWindow(window, ordered: .above)
    }
    previous = window
    return queue.first?.route
  }

  /// Not when the app hosts the tests, whose windows are not the user's: their launch must
  /// not reopen the user's projects, nor their quit forget them.
  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
  }
}
