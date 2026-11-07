import AppKit
import DrakarMCP
import Foundation
import Testing

@testable import Drakar

/// The windows the MCP server's writes find or open never take the person's keyboard. The
/// hosted test app opens no SwiftUI window here: a stand-in opener registers the project with
/// a stand-in window, asked to be key and in front as SwiftUI makes a new one, and what
/// `MCPWindows` asks of the windows after is what is tested. The stand-ins record what they
/// are asked and never reach the window server, so nothing shows on the person's screen and
/// no other suite's window is ordered under them or loses the keys.
@MainActor
@Suite("Windows opened for an agent", .serialized)
struct MCPWindowsTests {
  /// A window that records being ordered, made key or main and giving the key up, and does
  /// none of it: whether it is key or main is only what it was last asked.
  private final class StandInWindow: NSWindow {
    var madeKey = 0
    var madeMain = 0
    var resignedKey = 0
    var isKey = false
    var isMain = false
    var orders: [String] = []

    override var isVisible: Bool { !orders.isEmpty }
    override var isKeyWindow: Bool { isKey }
    override var isMainWindow: Bool { isMain }

    override func makeKey() {
      madeKey += 1
      isKey = true
    }

    override func makeMain() {
      madeMain += 1
      isMain = true
    }

    override func resignKey() {
      resignedKey += 1
      isKey = false
    }

    /// As SwiftUI shows a new window: key, main and in front.
    override func makeKeyAndOrderFront(_ sender: Any?) {
      madeKey += 1
      isKey = true
      isMain = true
      orders.append("front")
    }

    override func orderFront(_ sender: Any?) { orders.append("front") }
    override func orderBack(_ sender: Any?) { orders.append("back") }
  }

  private func window() -> StandInWindow {
    let window = StandInWindow(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-mcp-windows-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// With no window ever up, the scene has not handed its action over: refused, saying so.
  @Test func noOpenWindowActionRefused() async throws {
    let kept = WindowTabs.openWindow
    WindowTabs.openWindow = nil
    defer { WindowTabs.openWindow = kept }
    let route = WindowRoute.project(try folder())

    let result = await MCPWindows.project(for: route)
    #expect(throws: SessionError("Open a Drakar window once, then try again.")) {
      try result.get()
    }
  }

  /// A window already open is used as it is: no window call at all.
  @Test func anOpenProjectIsUsedWithNoWindowCall() async throws {
    let project = Project(folder: try folder())
    let open = OpenSessions()
    let id = UUID()
    open.register(project, window: id)
    defer {
      project.stopAll()
      open.unregister(window: id)
    }
    var opened = 0

    let result = await MCPWindows.project(
      for: .project(project.folder), in: open, opening: { _ in opened += 1 })
    #expect(try result.get() === project)
    #expect(opened == 0)
  }

  /// A window opened for an agent goes behind the others; the new one is never made key by
  /// `MCPWindows`, the key window stays the one it was, and the app is not activated.
  @Test func keyWindowUnchanged() async throws {
    let opened = window()
    let project = Project(folder: try folder())
    let open = OpenSessions()
    let id = UUID()
    defer {
      project.stopAll()
      open.unregister(window: id)
    }
    let wasActive = NSApp.isActive
    let keyBefore = NSApp.keyWindow
    var madeKeyByOpening = 0

    let result = await MCPWindows.project(
      for: .project(project.folder), in: open,
      opening: { _ in
        // As SwiftUI opens one: registered, then key and in front.
        open.register(project, window: id)
        project.workspace.window = opened
        opened.makeKeyAndOrderFront(nil)
        madeKeyByOpening = opened.madeKey
      })

    #expect(try result.get() === project)
    #expect(opened.madeKey == madeKeyByOpening)
    #expect(opened.orders == ["front", "back"])
    #expect(NSApp.isActive == wasActive)
    #expect(NSApp.keyWindow === keyBefore)
  }

  /// The ordering step alone: behind, and the key back to the window that had it only while
  /// the app was active. An inactive app is left inactive, its key window unchosen.
  @Test func settleOrdersBehindAndGivesTheKeyBack() {
    let previous = window()
    let opened = window()
    previous.orderFront(nil)
    opened.orderFront(nil)

    MCPWindows.settle(new: opened, previousKey: previous, previousMain: nil, wasActive: true)
    #expect(opened.orders == ["front", "back"])
    #expect(previous.orders == ["front"])
    #expect(previous.madeKey == 1)
    #expect(opened.madeKey == 0)

    let wasActive = NSApp.isActive
    MCPWindows.settle(new: opened, previousKey: previous, previousMain: nil, wasActive: false)
    #expect(opened.orders == ["front", "back", "back"])
    #expect(previous.madeKey == 1)
    #expect(opened.madeKey == 0)
    #expect(NSApp.isActive == wasActive)

    // A key window closed meanwhile is not brought back.
    let closed = window()
    MCPWindows.settle(new: opened, previousKey: closed, previousMain: nil, wasActive: true)
    #expect(closed.madeKey == 0)
  }

  /// The main window goes back too, when the new one took it: main is what menu commands and
  /// the window's title act on, and it is not the new window's to keep.
  @Test func settleGivesMainBack() {
    let previous = window()
    let opened = window()
    previous.orderFront(nil)
    opened.makeKeyAndOrderFront(nil)

    MCPWindows.settle(new: opened, previousKey: previous, previousMain: previous, wasActive: true)
    #expect(previous.madeMain == 1)
    #expect(opened.madeMain == 0)

    // A new window that did not take main leaves the main window as it is.
    let other = window()
    other.orderFront(nil)
    MCPWindows.settle(new: other, previousKey: previous, previousMain: previous, wasActive: true)
    #expect(previous.madeMain == 1)

    // Nor is a main window closed meanwhile brought back.
    let closed = window()
    let again = window()
    again.makeKeyAndOrderFront(nil)
    MCPWindows.settle(new: again, previousKey: nil, previousMain: closed, wasActive: true)
    #expect(closed.madeMain == 0)
  }

  /// An active app with no key window before keeps none: the new window gives the key up
  /// rather than taking typing meant for nothing. Inactive, it is left alone, the app never
  /// activated.
  @Test func anActiveAppWithNoKeyWindowLeavesTheNewOneUnkeyed() {
    let opened = window()
    opened.makeKeyAndOrderFront(nil)
    MCPWindows.settle(new: opened, previousKey: nil, previousMain: nil, wasActive: true)
    #expect(opened.resignedKey == 1)
    #expect(!opened.isKeyWindow)

    let inactive = window()
    inactive.makeKeyAndOrderFront(nil)
    let wasActive = NSApp.isActive
    MCPWindows.settle(new: inactive, previousKey: nil, previousMain: nil, wasActive: false)
    #expect(inactive.resignedKey == 0)
    #expect(NSApp.isActive == wasActive)
  }

  /// Two writes for one project whose window is not open yet open it once, and both get its
  /// project: the second waits for the first's window rather than asking for another.
  @Test func twoWritesForOneUnopenedRouteOpenOneWindow() async throws {
    let opened = window()
    let project = Project(folder: try folder())
    let open = OpenSessions()
    let id = UUID()
    defer {
      project.stopAll()
      open.unregister(window: id)
    }
    final class Count { var value = 0 }
    let openings = Count()
    // As SwiftUI opens one: the window registers its project a moment after it is asked for.
    let opening: (WindowRoute) -> Void = { _ in
      openings.value += 1
      Task<Void, Never> { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        open.register(project, window: id)
        project.workspace.window = opened
      }
    }
    let route = WindowRoute.project(project.folder)

    let first = Task<Result<Project, SessionError>, Never> {
      await MCPWindows.project(for: route, in: open, opening: opening)
    }
    let second = Task<Result<Project, SessionError>, Never> {
      await MCPWindows.project(for: route, in: open, opening: opening)
    }
    let results = (await first.value, await second.value)

    #expect(openings.value == 1)
    #expect(try results.0.get() === project)
    #expect(try results.1.get() === project)
  }

  /// A window that does not register in time is refused rather than waited on for ever.
  @Test func aWindowThatNeverRegistersIsRefused() async throws {
    let route = WindowRoute.project(try folder())
    let result = await MCPWindows.project(
      for: route, in: OpenSessions(), opening: { _ in }, limit: .milliseconds(200))
    #expect(throws: SessionError.self) { try result.get() }
  }
}
