import AppKit
import SupportKitTestHost
import SwiftUI
import Testing

@testable import Drakar

@MainActor
struct ProjectTerminalTests {
  @Test func controlBacktickMatchesByKeyPositionOrCharacter() throws {
    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws
      -> NSEvent
    {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: 0, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    #expect(try TerminalShortcut.matches(key("@", code: 0x32, modifiers: .control)))
    #expect(try TerminalShortcut.matches(key("`", code: 0x1A, modifiers: .control)))
    #expect(try !TerminalShortcut.matches(key("`", code: 0x32, modifiers: .command)))
    #expect(try !TerminalShortcut.matches(key("c", code: 0x08, modifiers: .control)))
  }

  @Test func hidingThePaneKeepsTheSameShellInTheProjectFolder() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }

    let suite = "ProjectTerminalTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(17, forKey: PreferenceKey.terminalFontSize)

    let terminal = ProjectTerminal()
    defer { terminal.stop() }
    let window = HostedWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240))
    func root(shown: Bool) -> some View {
      VStack {
        if shown {
          ProjectTerminalPane(terminal: terminal, folder: folder, hide: {})
        }
      }
      .defaultAppStorage(defaults)
    }
    let host = NSHostingView(rootView: root(shown: true))
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    for _ in 0..<100 where terminal.view == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    let view = try #require(terminal.view)
    let shell = try #require(view.process)
    #expect(shell.running)
    #expect(view.window === window)
    #expect(view.font.pointSize == 17)

    let surface = try #require(view.superview)
    #expect(surface.bounds.width == 640)
    #expect(view.frame.minX == 8)
    #expect(view.frame.width == 624)
    #expect(view.frame.height == surface.bounds.height)
    let leftPaddingPoint = surface.convert(
      NSPoint(x: 2, y: surface.bounds.midY), to: surface.superview)
    let rightPaddingPoint = surface.convert(
      NSPoint(x: surface.bounds.maxX - 2, y: surface.bounds.midY), to: surface.superview)
    #expect(surface.hitTest(leftPaddingPoint) === view)
    #expect(surface.hitTest(rightPaddingPoint) === view)

    window.makeFirstResponder(nil)
    #expect(window.firstResponder !== view)
    let centerPoint = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let click = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: centerPoint, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1))
    let surfaceSuperview = try #require(surface.superview)
    let hit = try #require(surface.hitTest(surfaceSuperview.convert(centerPoint, from: nil)))
    hit.mouseDown(with: click)
    #expect(window.firstResponder === view)

    defaults.set(19, forKey: PreferenceKey.terminalFontSize)
    defaults.set("visual", forKey: PreferenceKey.terminalBell)
    for _ in 0..<100 where view.font.pointSize != 19 || view.bellStyle.tagName != "visual" {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(view.font.pointSize == 19)
    #expect(view.bellStyle.tagName == "visual")
    #expect(view.process === shell)

    host.rootView = root(shown: false)
    host.layoutSubtreeIfNeeded()
    for _ in 0..<100 where view.window != nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(view.window == nil)
    let probe = folder.appendingPathComponent("working-directory")
    shell.send(data: Array("pwd -P > working-directory\n".utf8)[...])
    for _ in 0..<100 where (try? Data(contentsOf: probe).isEmpty) != false {
      try await Task.sleep(for: .milliseconds(20))
    }
    let workingDirectory = try String(contentsOf: probe, encoding: .utf8)
      .trimmingCharacters(in: .newlines)
    let actual =
      try URL(fileURLWithPath: workingDirectory)
      .resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
    let expected =
      try folder.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier as? NSObject
    #expect(try #require(actual) == #require(expected))

    host.rootView = root(shown: true)
    host.layoutSubtreeIfNeeded()
    for _ in 0..<100 where view.window == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(view.window === window)
    #expect(terminal.view === view)
    #expect(shell.running)
  }
}
