import AppKit
import DrakarKit
import SupportKitTestHost
import SwiftUI
import Testing

@testable import Drakar
@testable import DrakarKit

/// A prompt and a reply each get a copy button, in the accessibility tree even before the
/// pointer is over them. Pressing one puts that turn's own text on the clipboard. A blank
/// reply is not worth one.
@MainActor
@Suite("Copy on a turn")
struct TranscriptCopyTests {
  private let pasteboard = NSPasteboard.general

  private func entry(_ id: String, _ kind: Transcript.Kind) -> Transcript.Entry {
    Transcript.Entry(
      id: id, kind: kind, parentToolUseID: nil, context: nil, messageID: nil,
      thinkingSince: nil, thinkingDuration: nil)
  }

  private func host() -> NSWindow {
    let root = VStack(alignment: .leading, spacing: 14) {
      EntryView(entry: entry("prompt#1", .prompt("Ship the copy button")))
      EntryView(entry: entry("reply#0", .text("Done. The button copies this reply.")))
      EntryView(entry: entry("blank#0", .text("   ")))
    }
    .padding(16)
    .frame(width: 420, alignment: .leading)
    let controller = NSHostingController(rootView: root)
    let window = HostedWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
      styleMask: [.titled, .resizable])
    window.contentViewController = controller
    window.layoutIfNeeded()
    window.orderFront(nil)
    return window
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  /// SwiftUI draws the button itself, so it shows up in the accessibility tree and not as a view.
  private func buttons(identified id: String) -> [AXUIElement] {
    var found: [AXUIElement] = []
    func walk(_ element: AXUIElement) {
      if attribute(element, kAXIdentifierAttribute) == id { found.append(element) }
      var children: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
          == .success,
        let children = children as? [AXUIElement]
      else { return }
      children.forEach(walk)
    }
    walk(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
    return found
  }

  private func restored<T>(_ body: () throws -> T) rethrows -> T {
    let types = pasteboard.types ?? []
    let saved = types.compactMap { type in pasteboard.data(forType: type).map { (type, $0) } }
    defer {
      pasteboard.clearContents()
      for (type, data) in saved { pasteboard.setData(data, forType: type) }
    }
    return try body()
  }

  @Test func eachTurnCopiesItsOwnTextAndABlankReplyDoesNot() async throws {
    let window = host()
    defer { window.contentViewController = nil }
    try await Task.sleep(for: .milliseconds(200))
    window.layoutIfNeeded()

    let prompts = buttons(identified: "copy.prompt")
    let replies = buttons(identified: "copy.response")
    let prompt = try #require(prompts.first)
    let reply = try #require(replies.first)
    #expect(prompts.count == 1)
    #expect(replies.count == 1)
    #expect(attribute(prompt, kAXHelpAttribute) == "Copy")
    #expect(attribute(reply, kAXHelpAttribute) == "Copy response")

    try restored {
      #expect(AXUIElementPerformAction(prompt, kAXPressAction as CFString) == .success)
      #expect(pasteboard.string(forType: .string) == "Ship the copy button")
      #expect(AXUIElementPerformAction(reply, kAXPressAction as CFString) == .success)
      #expect(pasteboard.string(forType: .string) == "Done. The button copies this reply.")
    }
  }
}
