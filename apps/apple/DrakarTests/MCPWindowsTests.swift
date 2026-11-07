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
  /// A window that records being ordered and made key, and does neither.
  private final class StandInWindow: NSWindow {
    var madeKey = 0
    var orders: [String] = []

    override var isVisible: Bool { !orders.isEmpty }
    override func makeKey() { madeKey += 1 }

    override func makeKeyAndOrderFront(_ sender: Any?) {
      madeKey += 1
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

    MCPWindows.settle(new: opened, previousKey: previous, wasActive: true)
    #expect(opened.orders == ["front", "back"])
    #expect(previous.orders == ["front"])
    #expect(previous.madeKey == 1)
    #expect(opened.madeKey == 0)

    let wasActive = NSApp.isActive
    MCPWindows.settle(new: opened, previousKey: previous, wasActive: false)
    #expect(opened.orders == ["front", "back", "back"])
    #expect(previous.madeKey == 1)
    #expect(opened.madeKey == 0)
    #expect(NSApp.isActive == wasActive)

    // A key window closed meanwhile is not brought back.
    let closed = window()
    MCPWindows.settle(new: opened, previousKey: closed, wasActive: true)
    #expect(closed.madeKey == 0)
  }

  /// A window that does not register in time is refused rather than waited on for ever.
  @Test func aWindowThatNeverRegistersIsRefused() async throws {
    let route = WindowRoute.project(try folder())
    let result = await MCPWindows.project(
      for: route, in: OpenSessions(), opening: { _ in }, limit: .milliseconds(200))
    #expect(throws: SessionError.self) { try result.get() }
  }
}
