import AppKit
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("The windows Drakar reopens itself")
struct ReopenedWindowsTests {

  private let defaults: UserDefaults
  private let suite = "drakar-tests-\(UUID().uuidString)"
  private let first: URL
  private let second: URL

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-reopen-\(UUID().uuidString)", directoryHint: .isDirectory)
    first = root.appending(path: "first", directoryHint: .isDirectory)
    second = root.appending(path: "second", directoryHint: .isDirectory)
    for folder in [first, second] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  private func path(_ url: URL) -> String { ProjectPath.normalize(url.path(percentEncoded: false)) }

  private func window() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  /// No window restored: the launch's window becomes the first project saved, and each one
  /// arriving opens the next, a folder deleted since left out.
  @Test func theLaunchWindowBecomesTheFirstAndEachOpensTheNext() {
    defer { defaults.removePersistentDomain(forName: suite) }
    let reopened = ReopenedWindows(defaults: defaults)
    let model = window()
    model.setFrame(NSRect(x: 40, y: 60, width: 500, height: 400), display: false)
    reopened.save([
      .init(folder: path(first), frame: model.frameDescriptor),
      .init(folder: "/nowhere/\(UUID().uuidString)"),
      .init(folder: path(second), joinsPrevious: true),
    ])

    #expect(reopened.begin(launchRoute: nil) == .project(folder: path(first)))
    #expect(reopened.begin(launchRoute: nil) == nil)  // once a launch

    let one = window()
    #expect(reopened.arrived(one, folder: first) == .project(folder: path(second)))
    #expect(one.frame.size == NSSize(width: 500, height: 400))
    #expect(reopened.arrived(one, folder: first) == nil)  // seen again: nothing more

    let two = window()
    #expect(reopened.arrived(two, folder: second) == nil)
    #expect(one.tabbedWindows?.contains(two) == true)
  }

  /// macOS brought a window back: its restoration wins, and nothing is reopened.
  @Test func aRestoredWindowLeavesTheSavedOnesAlone() {
    defer { defaults.removePersistentDomain(forName: suite) }
    let reopened = ReopenedWindows(defaults: defaults)
    reopened.save([.init(folder: path(first))])
    #expect(reopened.begin(launchRoute: .project(folder: path(second))) == nil)
    #expect(reopened.arrived(window(), folder: first) == nil)
  }

  @Test func whatIsSavedReadsBack() {
    defer { defaults.removePersistentDomain(forName: suite) }
    let windows: [ReopenedWindows.Saved] = [
      .init(folder: path(first), frame: "0 0 10 10 0 0 100 100 "),
      .init(folder: path(second), joinsPrevious: true),
    ]
    ReopenedWindows(defaults: defaults).save(windows)
    #expect(ReopenedWindows(defaults: defaults).saved == windows)
  }
}
